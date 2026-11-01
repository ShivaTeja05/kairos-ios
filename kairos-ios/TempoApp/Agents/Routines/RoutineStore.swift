import Foundation

// Routines: "make it once, run it forever". The person says "make a routine for my mornings: the weather, what's on
// today and a reminder for my pills" once; the model composes the steps and they are saved here, on the phone.
// From then on "do my morning" replays the steps in order with no model call for the replay itself (instant, and
// offline for the steps that don't need the internet). Every step still goes through the SafetyGate, so a step that
// calls or messages someone asks for approval each time it runs.
//
// iOS doesn't let apps write into the Shortcuts app, so routines live in Kairos and are offered to Siri and Shortcuts
// as an App Entity (RoutineIntents.swift). This file is pure Foundation (plus JSONValue and String.folded), so the
// self-test runs on a Mac.

extension Notification.Name {
    /// Posted on the main thread whenever a routine is added, changed or deleted. The app calls
    /// `TempoShortcuts.updateAppShortcutParameters()` so Siri learns the new names.
    static let kairosRoutinesChanged = Notification.Name("kairos.routines.changed")
}

// MARK: - The model

/// One saved routine.
struct Routine: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    /// Short name the person knows it by: "Morning", "Bedtime".
    var name: String
    /// How the person will ask for it: "do my morning", "start my day".
    var phrases: [String]
    /// What it does in a few plain words: "Weather, today's plans and a pills reminder".
    var summary: String
    var steps: [RoutineStep]
    var createdAt: Date
    var lastRunAt: Date?
    var runCount: Int
    /// What the owner said when they made it (trusted words). A replay can vouch for the names in it, so
    /// "message Priya" inside a routine still passes the "did the person say this name?" checks.
    var madeFrom: String?

    init(id: UUID = UUID(), name: String, phrases: [String] = [], summary: String = "", steps: [RoutineStep],
         createdAt: Date = Date(), lastRunAt: Date? = nil, runCount: Int = 0, madeFrom: String? = nil) {
        self.id = id
        self.name = name
        self.phrases = phrases
        self.summary = summary
        self.steps = steps
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
        self.runCount = runCount
        self.madeFrom = madeFrom
    }

    /// Some step reads {{input}} (the person's extra words, e.g. a town). Only then may extra words after its phrase
    /// be taken as input; otherwise "good morning, remind me to…" would swallow the reminder.
    var usesInput: Bool {
        guard let data = try? JSONEncoder().encode(steps), let text = String(data: data, encoding: .utf8) else { return false }
        return text.lowercased().replacingOccurrences(of: " ", with: "").contains("{{input}}")
    }
}

/// One step of a routine. Only the fields for its kind are set.
struct RoutineStep: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case tool     // run one of the agents' tools (through the SafetyGate)
        case think    // a model call that sums up or decides from what the steps found so far
        case say      // fixed words to speak
        case operate  // hand a goal to the phone operator's operate_app tool
    }

    var kind: Kind
    /// .tool: the tool's name, e.g. "get_weather".
    var tool: String?
    /// .tool: the tool's arguments; strings may hold templates such as {{today}} (see RoutineTemplate).
    var args: JSONValue?
    /// .think: e.g. "In two sentences, tell me my day".
    var prompt: String?
    /// .say: the words to speak.
    var text: String?
    /// .operate: what to get done in the other app, and which app.
    var goal: String?
    var app: String?
    /// Two or three words shown while it runs: "weather".
    var label: String?

    static func tool(_ name: String, _ args: JSONValue = [:], label: String? = nil) -> RoutineStep {
        RoutineStep(kind: .tool, tool: name, args: args, label: label)
    }
    static func think(_ prompt: String, label: String? = nil) -> RoutineStep {
        RoutineStep(kind: .think, prompt: prompt, label: label)
    }
    static func say(_ text: String) -> RoutineStep { RoutineStep(kind: .say, text: text) }
    static func operate(goal: String, app: String?, label: String? = nil) -> RoutineStep {
        RoutineStep(kind: .operate, goal: goal, app: app, label: label)
    }
}

// MARK: - The store

/// Routines on this phone, in Application Support/Kairos/routines.json (atomic writes). Writes go through the actor;
/// reads are synchronous from a locked snapshot, so the rules-first match ("do my morning") costs no await.
actor RoutineStore {
    static let shared = RoutineStore()
    static let maxRoutines = 50
    static let maxSteps = 12
    static let maxNameLength = 40
    static let maxPhrases = 6

    static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Kairos", isDirectory: true)
            .appendingPathComponent("routines.json")
    }

    enum SaveError: LocalizedError, Equatable {
        case noName, noSteps, tooManySteps, full, disk

        var errorDescription: String? {
            switch self {
            case .noName: return "The routine needs a name."
            case .noSteps: return "The routine needs at least one step."
            case .tooManySteps: return "A routine can have up to \(RoutineStore.maxSteps) steps."
            case .full: return "You already have \(RoutineStore.maxRoutines) routines, which is the most I can keep. Please delete one you don't use first."
            case .disk: return "I couldn't save it on the phone just now. Please try again."
            }
        }
    }

    let fileURL: URL?
    private let box: RoutineBox

    /// `fileURL: nil` keeps routines in memory only (tests).
    init(fileURL: URL? = RoutineStore.defaultURL) {
        self.fileURL = fileURL
        let loaded = fileURL.map { Self.load(from: $0) } ?? []
        // nil: the file is there but can't be read yet (the phone hasn't been unlocked since it started). Read it
        // again later instead of treating it as empty, or the next save would overwrite every routine.
        self.box = RoutineBox(loaded ?? [], stale: loaded == nil)
    }

    // MARK: Reads (synchronous)

    nonisolated var all: [Routine] {
        if let fileURL { box.refreshIfStale { Self.load(from: fileURL) } }
        return box.get()
    }

    nonisolated func routine(id: String) -> Routine? {
        guard let uuid = UUID(uuidString: id.trimmingCharacters(in: .whitespaces)) else { return nil }
        return all.first { $0.id == uuid }
    }

    /// The routine the person's words ask for ("do my morning, I'm in London"), with any extra words they added.
    nonisolated func find(byPhrase words: String) -> RoutineMatch? { RoutineMatcher.match(words, in: all) }

    /// The routine with this name or id ("Morning", "my morning routine").
    nonisolated func find(named name: String) -> Routine? { RoutineMatcher.named(name, in: all) }

    // MARK: Writes

    /// Adds a routine, or replaces the one with the same id or the same name (keeping its id and history).
    @discardableResult
    func save(_ routine: Routine) throws -> Routine {
        var r = routine
        r.name = String(r.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxNameLength))
        guard !r.name.folded.isEmpty else { throw SaveError.noName }
        guard !r.steps.isEmpty else { throw SaveError.noSteps }
        guard r.steps.count <= Self.maxSteps else { throw SaveError.tooManySteps }
        r.phrases = Self.cleanPhrases(r.phrases)
        r.summary = String(r.summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))

        var list = try current()
        let key = r.name.folded
        if let i = list.firstIndex(where: { $0.id == r.id }) ?? list.firstIndex(where: { $0.name.folded == key }) {
            let old = list[i]
            r.id = old.id
            r.createdAt = old.createdAt
            r.lastRunAt = old.lastRunAt
            r.runCount = old.runCount
            list[i] = r
        } else {
            guard list.count < Self.maxRoutines else { throw SaveError.full }
            list.append(r)
        }
        try commit(list)
        return r
    }

    @discardableResult
    func delete(id: UUID) throws -> Routine? {
        var list = try current()
        guard let i = list.firstIndex(where: { $0.id == id }) else { return nil }
        let gone = list.remove(at: i)
        try commit(list)
        return gone
    }

    /// After a run: when, and how many times. A failed write here is harmless.
    func markRun(id: UUID, at date: Date = Date()) {
        guard var list = try? current() else { return }
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].lastRunAt = date
        list[i].runCount += 1
        try? commit(list, notify: false)
    }

    /// The routines to change. Throws when the file still can't be read, rather than saving over it.
    private func current() throws -> [Routine] {
        if let fileURL { box.refreshIfStale { Self.load(from: fileURL) } }
        guard !box.isStale else { throw SaveError.disk }
        return box.get()
    }

    private func commit(_ list: [Routine], notify: Bool = true) throws {
        if let fileURL {
            do { try Self.write(list, to: fileURL) } catch { throw SaveError.disk }
        }
        box.set(list)
        if notify {
            DispatchQueue.main.async { NotificationCenter.default.post(name: .kairosRoutinesChanged, object: nil) }
        }
    }

    // MARK: File

    private struct FileOut: Encodable { var version: Int; var routines: [Routine] }
    private struct FileIn: Decodable { var routines: [Lossy] }
    /// One bad routine (an old or hand-edited file) must not lose all the others.
    private struct Lossy: Decodable {
        var value: Routine?
        init(from decoder: Decoder) throws { value = try? Routine(from: decoder) }
    }

    static func write(_ list: [Routine], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(FileOut(version: 1, routines: list))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }

    static func read(from url: URL) -> [Routine] { load(from: url) ?? [] }

    /// The saved routines; [] when there's no file yet; nil when the file is there but can't be read right now
    /// (data protection before the first unlock), so the caller tries again instead of saving over it.
    static func load(from url: URL) -> [Routine]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(FileIn.self, from: data) else {
            // Unreadable: keep a copy so the next save doesn't silently lose it.
            let backup = url.appendingPathExtension("bad")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
            return []
        }
        return Array(file.routines.compactMap(\.value).prefix(maxRoutines))
    }

    /// Trimmed, de-duplicated (by folded words), at most 6, each at most 60 characters. A phrase made only of command
    /// words ("do my", "run the") is dropped: it would start this routine for every "do my …" request.
    static func cleanPhrases(_ phrases: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for p in phrases {
            let s = String(p.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”'"))).prefix(60))
            let key = s.folded
            guard !key.isEmpty, RoutineMatcher.hasContent(RoutineMatcher.phraseTokens(s)), seen.insert(key).inserted else { continue }
            out.append(s)
            if out.count == maxPhrases { break }
        }
        return out
    }
}

/// The routines snapshot behind a lock, for synchronous reads from any thread.
final class RoutineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [Routine]
    /// The file couldn't be read when we last tried: `value` is not what's saved.
    private var stale: Bool
    init(_ value: [Routine], stale: Bool = false) { self.value = value; self.stale = stale }
    func get() -> [Routine] { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: [Routine]) { lock.lock(); value = v; stale = false; lock.unlock() }
    var isStale: Bool { lock.lock(); defer { lock.unlock() }; return stale }
    /// Reads the file again if the last read failed. `load` returns nil while it still can't be read.
    func refreshIfStale(_ load: () -> [Routine]?) {
        lock.lock(); defer { lock.unlock() }
        guard stale, let v = load() else { return }
        value = v
        stale = false
    }
}

// MARK: - Matching the person's words

struct RoutineMatch: Sendable, Equatable {
    /// How the words matched, strongest last.
    enum How: Int, Sendable, Comparable {
        case containedInside = 0  // the phrase is somewhere in the middle: the model decides
        case overlap = 1          // ≥80% of the meaningful words are the same
        case containedAtStart = 2 // the phrase, then the person's extra words
        case command = 3          // "do / run / start my <name>"
        case exact = 4            // one of its phrases, exactly

        static func < (a: How, b: How) -> Bool { a.rawValue < b.rawValue }
    }

    var routine: Routine
    var how: How
    /// The person's extra words, in their spelling: "do my morning, I'm in London" → "I'm in London".
    var input: String
    /// Phrase length, for tie-breaks.
    var score: Int

    /// Safe to run with no model call.
    var isConfident: Bool { how != .containedInside }
}

enum RoutineMatcher {
    /// The person's words: as typed (for {{input}}) and folded (for matching).
    struct Tokens: Sendable {
        var raw: [String]
        var words: [String]
        /// For each folded word, which raw word it came from.
        var rawIndex: [Int]

        init(_ s: String) {
            raw = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            words = []
            rawIndex = []
            for (i, r) in raw.enumerated() {
                for f in r.folded.split(separator: " ") {
                    words.append(String(f))
                    rawIndex.append(i)
                }
            }
        }

        /// The person's own spelling of folded words `range`, punctuation trimmed at the ends.
        func rawText(_ range: Range<Int>) -> String {
            guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= rawIndex.count else { return "" }
            let a = rawIndex[range.lowerBound], b = rawIndex[range.upperBound - 1]
            let text = raw[a...b].joined(separator: " ")
            return text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
        }
    }

    static let leadFiller: [[String]] = [
        ["hey"], ["hi"], ["hello"], ["ok"], ["okay"], ["kairos"], ["siri"], ["please"], ["now"],
        ["can", "you"], ["could", "you"], ["would", "you"], ["will", "you"],
        ["i", "want", "to"], ["i", "d", "like", "to"], ["i", "would", "like", "to"], ["let", "s"], ["lets"],
    ]
    static let tailFiller: [[String]] = [
        ["please"], ["kairos"], ["now"], ["for", "me"], ["thanks"], ["thank", "you"], ["cheers"],
    ]
    static let verbs: Set<String> = ["do", "run", "start", "begin", "play"]
    static let determiners: Set<String> = ["my", "the", "our"]
    static let afterName: Set<String> = ["routine", "shortcut", "steps", "please", "now"]
    static let connectors: Set<String> = ["and", "then", "also", "plus", "but", "after"]
    /// Ignored when counting overlap.
    static let light: Set<String> = ["my", "the", "a", "an", "our", "please", "kairos", "to", "for", "me", "i", "you",
                                     "can", "could"]
    /// Extra words starting like this are a new request, not input for the routine ("start my day, remind me to…").
    static let newRequest: Set<String> = [
        "remind", "set", "call", "ring", "phone", "text", "message", "whatsapp", "email", "what", "whats", "how", "when",
        "where", "who", "why", "which", "can", "could", "will", "would", "tell", "show", "read", "open", "add", "make",
        "create", "book", "send", "turn", "cancel", "delete", "remove", "is", "are", "do", "does", "did", "check", "find",
        "help", "pay", "save", "start", "stop", "run", "play", "give", "get", "put", "take", "wake", "let", "lets",
    ]
    static let maxInputWords = 8

    /// A phrase with at least one word of its own, beyond command words and filler ("do my" has none).
    static func hasContent(_ tokens: [String]) -> Bool {
        tokens.contains { !commandWords.contains($0) }
    }
    private static let commandWords: Set<String> = verbs.union(determiners).union(light).union(afterName)
        .union(connectors).union((leadFiller + tailFiller).flatMap { $0 })

    /// The words after a routine's phrase or name may be its {{input}}: only when it reads {{input}}, they're short,
    /// and they don't start a new request or another step ("and set an alarm").
    static func extraIsInput(_ extra: [String], for routine: Routine) -> Bool {
        guard let first = extra.first else { return true }
        return routine.usesInput && extra.count <= maxInputWords && !connectors.contains(first) && !newRequest.contains(first)
    }

    /// The folded words with polite filler taken off both ends ("Kairos, can you do my morning please").
    static func coreRange(_ w: [String]) -> Range<Int> {
        var lo = 0, hi = w.count
        var changed = true
        while changed {
            changed = false
            for f in leadFiller where hi - lo > f.count && Array(w[lo..<(lo + f.count)]) == f {
                lo += f.count; changed = true
            }
            for f in tailFiller where hi - lo > f.count && Array(w[(hi - f.count)..<hi]) == f {
                hi -= f.count; changed = true
            }
        }
        return lo..<hi
    }

    static func phraseTokens(_ s: String) -> [String] {
        let w = s.folded.split(separator: " ").map(String.init)
        return Array(w[coreRange(w)])
    }

    /// A routine's name as folded words. No filler is taken off: "Hello Priya" stays "hello priya", so a bare
    /// "Priya" (say, the answer to "who should I message?") doesn't start it.
    static func nameTokens(_ name: String) -> [String] { name.folded.split(separator: " ").map(String.init) }

    /// The name without "my" in front or "routine" behind: "My morning routine" → ["morning"].
    static func coreName(_ name: String) -> [String] { core(nameTokens(name)) }

    static func core(_ tokens: [String]) -> [String] {
        var w = tokens
        while w.count > 1, let f = w.first, determiners.contains(f) { w.removeFirst() }
        while w.count > 1, let l = w.last, ["routine", "routines", "shortcut"].contains(l) { w.removeLast() }
        return w
    }

    private static func exactPhrases(_ r: Routine) -> [[String]] {
        let core = coreName(r.name)
        // The first six are the name's forms; the person's phrases follow (match() relies on this order). Phrases
        // with no word of their own ("do my", saved before cleanPhrases dropped them) are left out.
        let out: [[String]] = [nameTokens(r.name), core, ["my"] + core, core + ["routine"], ["my"] + core + ["routine"],
                               ["the"] + core + ["routine"]]
        return out + r.phrases.map(phraseTokens).filter(hasContent)
    }

    private static func find(_ needle: [String], in hay: [String]) -> Int? {
        guard !needle.isEmpty, needle.count <= hay.count else { return nil }
        for i in 0...(hay.count - needle.count) where Array(hay[i..<(i + needle.count)]) == needle { return i }
        return nil
    }

    /// The best saved routine for these words, or nil.
    static func match(_ words: String, in routines: [Routine]) -> RoutineMatch? {
        guard !routines.isEmpty else { return nil }
        let t = Tokens(words)
        let span = coreRange(t.words)
        let w = Array(t.words[span])
        guard !w.isEmpty, w.count <= 30 else { return nil }

        var best: RoutineMatch?
        func offer(_ m: RoutineMatch) {
            guard let b = best else { best = m; return }
            if m.how > b.how || (m.how == b.how && m.score > b.score) { best = m }
        }
        func rest(from i: Int) -> (range: Range<Int>, words: [String]) {
            let range = (span.lowerBound + i)..<span.upperBound
            return (range, Array(t.words[range]))
        }

        let said = Set(w).subtracting(light)
        for r in routines {
            let exact = exactPhrases(r)
            // 1. Exactly one of its phrases (or its name).
            for p in exact where p == w {
                offer(RoutineMatch(routine: r, how: .exact, input: "", score: p.count))
            }

            // 2. "do / run / start [my|the] <name> [routine]" and then the person's extra words.
            let core = coreName(r.name)
            if let verb = w.first, verbs.contains(verb), !core.isEmpty {
                var i = 1
                if i < w.count, determiners.contains(w[i]) { i += 1 }
                if i + core.count <= w.count, Array(w[i..<(i + core.count)]) == core {
                    i += core.count
                    while i < w.count, afterName.contains(w[i]) { i += 1 }
                    let after = rest(from: i)
                    if extraIsInput(after.words, for: r) {
                        offer(RoutineMatch(routine: r, how: .command, input: t.rawText(after.range), score: core.count + 1))
                    } else {
                        offer(RoutineMatch(routine: r, how: .containedInside, input: "", score: core.count))
                    }
                }
            }

            // 3. One of its phrases inside the words.
            for p in exact.dropFirst(6) where p.count >= 2 {
                guard let at = find(p, in: w) else { continue }
                if at == 0 {
                    let after = rest(from: p.count)
                    let clean = extraIsInput(after.words, for: r)
                    offer(RoutineMatch(routine: r, how: clean ? .containedAtStart : .containedInside,
                                       input: clean ? t.rawText(after.range) : "", score: p.count))
                } else {
                    offer(RoutineMatch(routine: r, how: .containedInside, input: "", score: p.count))
                }
            }

            // 4. Nearly the same words in another order ("routine for bedtime" ~ "bedtime routine").
            for p in exact {
                let phrase = Set(p).subtracting(light)
                guard phrase.count >= 2, !said.isEmpty else { continue }
                let common = phrase.intersection(said).count
                if Double(common) / Double(max(phrase.count, said.count)) >= 0.8 {
                    offer(RoutineMatch(routine: r, how: .overlap, input: "", score: phrase.count))
                }
            }
        }
        return best
    }

    /// A routine by name or id, for tool arguments ("Morning", "my morning routine", a UUID).
    static func named(_ query: String, in routines: [Routine]) -> Routine? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !routines.isEmpty else { return nil }
        if let id = UUID(uuidString: q), let r = routines.first(where: { $0.id == id }) { return r }
        let squash = { (w: [String]) in w.joined() }
        let qCore = squash(core(phraseTokens(q))), qAll = squash(phraseTokens(q))
        if let r = routines.first(where: { squash(coreName($0.name)) == qCore || squash(nameTokens($0.name)) == qAll
            || squash(nameTokens($0.name)) == squash(nameTokens(q)) }) {
            return r
        }
        if let m = match(q, in: routines), m.isConfident { return m.routine }
        // Loose: every word of a routine's name is in the query; the longest name wins ("morning walk" over "morning").
        let said = Set(phraseTokens(q))
        return routines
            .filter { let c = coreName($0.name); return !c.isEmpty && Set(c).isSubset(of: said) }
            .max { coreName($0.name).count < coreName($1.name).count }
    }

    /// The person wants to make, change or save a routine. Other tools' rules-first matches should stand aside
    /// ("make a routine that tells me the weather" is not a weather question).
    static func wantsToCompose(_ words: String) -> Bool {
        let f = " " + words.folded + " "
        let w = Set(f.split(separator: " ").map(String.init))
        let nouns: Set<String> = ["routine", "routines", "shortcut", "shortcuts"]
        let makers: Set<String> = ["create", "make", "new", "build", "setup", "set", "save", "add", "change", "update",
                                   "edit", "teach", "design", "write", "keep", "remember"]
        if !w.isDisjoint(with: nouns), !w.isDisjoint(with: makers) { return true }
        return [" save that as ", " save this as ", " save it as ", " save what you ", " save what we ",
                " keep that as ", " remember that as ", " remember this as "].contains { f.contains($0) }
    }
}

// MARK: - Templates in step arguments

/// Placeholders a routine's arguments may hold, filled in when it runs:
/// {{today}} {{tomorrow}} (YYYY-MM-DD in Europe/London), {{now_hhmm}}, {{input}} (the person's extra words),
/// {{next_at:HH:MM}} (the next time the clock shows HH:MM), {{today_at:HH:MM}}, {{tomorrow_at:HH:MM}} (full
/// date-times with the right UTC offset, so GMT/BST is never wrong) and {{in_minutes:N}}.
enum RoutineTemplate {
    static let london = TimeZone(identifier: "Europe/London") ?? .current

    /// For the model: what it may write in args.
    static let help = "{{today}} and {{tomorrow}} (dates, YYYY-MM-DD), {{now_hhmm}}, {{input}} (any extra words the "
        + "person adds when they start it, e.g. a town), {{next_at:HH:MM}} (the next time the clock says HH:MM, as a full "
        + "date-time; best for reminders), {{today_at:HH:MM}}, {{tomorrow_at:HH:MM}} and {{in_minutes:N}}"

    struct Vars: Sendable {
        var now: Date
        var input: String = ""
        var timeZone: TimeZone = RoutineTemplate.london
    }

    // MARK: Filling in

    /// Every string filled in. Keys (and array items) whose text comes out empty are left out, so "{{input}}" with
    /// no extra words means "not given".
    static func resolve(_ args: JSONValue, _ vars: Vars) -> JSONValue {
        switch args {
        case .string(let s):
            return .string(resolve(s, vars))
        case .array(let a):
            return .array(a.map { resolve($0, vars) }.filter { !isBlank($0) })
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (k, v) in o {
                let r = resolve(v, vars)
                if !isBlank(r) { out[k] = r }
            }
            return .object(out)
        default:
            return args
        }
    }

    static func resolve(_ s: String, _ vars: Vars) -> String {
        guard s.contains("{{") else { return s }
        var out = ""
        var rest = Substring(s)
        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else {
                out += rest[open.lowerBound...]
                rest = ""
                break
            }
            let token = String(rest[open.upperBound..<close.lowerBound])
            out += value(of: token, vars) ?? String(rest[open.lowerBound..<close.upperBound])
            rest = rest[close.upperBound...]
        }
        out += rest
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text for one placeholder, or nil when it isn't one we know.
    static func value(of rawToken: String, _ vars: Vars) -> String? {
        let token = rawToken.trimmingCharacters(in: .whitespaces).lowercased()
        let cal = calendar(vars.timeZone)
        switch token {
        case "today": return day(vars.now, offset: 0, cal)
        case "tomorrow": return day(vars.now, offset: 1, cal)
        case "now_hhmm", "now": return hhmm(vars.now, cal)
        case "input": return vars.input.trimmingCharacters(in: .whitespacesAndNewlines)
        default: break
        }
        guard let colon = token.firstIndex(of: ":") else { return nil }
        let head = String(token[..<colon]), arg = String(token[token.index(after: colon)...])
        switch head {
        case "today_at", "tomorrow_at", "next_at":
            guard let (h, m) = clock(arg) else { return nil }
            guard var date = at(vars.now, dayOffset: head == "tomorrow_at" ? 1 : 0, h, m, cal) else { return nil }
            if head == "next_at", date <= vars.now, let later = at(vars.now, dayOffset: 1, h, m, cal) { date = later }
            return iso(date, vars.timeZone)
        case "in_minutes":
            guard let n = Int(arg.trimmingCharacters(in: .whitespaces)), (0...10_080).contains(n) else { return nil }
            return iso(vars.now.addingTimeInterval(Double(n) * 60), vars.timeZone)
        default:
            return nil
        }
    }

    /// Placeholders in a value that aren't known (a model mistake), for validation.
    static func unknownPlaceholders(in args: JSONValue) -> [String] {
        let probe = Vars(now: Date(timeIntervalSince1970: 1_790_000_000))
        var bad: [String] = []
        func scan(_ v: JSONValue) {
            switch v {
            case .string(let s):
                var rest = Substring(s)
                while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
                    let token = String(rest[open.upperBound..<close.lowerBound])
                    if value(of: token, probe) == nil { bad.append(token) }
                    rest = rest[close.upperBound...]
                }
            case .array(let a): a.forEach(scan)
            case .object(let o): o.values.forEach(scan)
            default: break
            }
        }
        scan(args)
        return bad
    }

    // MARK: Generalising what was just done

    /// Turns the fixed dates in calls that just ran into placeholders, so a saved routine still works tomorrow:
    /// a date-time in the next 24 hours → {{next_at:HH:MM}}; today's or tomorrow's date → {{today}} / {{tomorrow}}.
    /// An alarm's day (`day_iso` next to `time_hhmm`) is dropped when it's today or tomorrow: the alarm then rings
    /// the next time that clock comes round.
    static func generalize(_ args: JSONValue, now: Date, timeZone: TimeZone = london) -> JSONValue {
        let cal = calendar(timeZone)
        let today = day(now, offset: 0, cal), tomorrow = day(now, offset: 1, cal)
        func one(_ v: JSONValue) -> JSONValue {
            switch v {
            case .string(let s):
                let t = s.trimmingCharacters(in: .whitespaces)
                if t == today { return "{{today}}" }
                if t == tomorrow { return "{{tomorrow}}" }
                guard t.count >= 16, let date = parseDateTime(t, timeZone) else { return v }
                let local = day(date, offset: 0, cal), clock = hhmm(date, cal)
                if date > now, date.timeIntervalSince(now) <= 86_400 { return .string("{{next_at:\(clock)}}") }
                if local == today { return .string("{{today_at:\(clock)}}") }
                if local == tomorrow { return .string("{{tomorrow_at:\(clock)}}") }
                return v
            case .array(let a):
                return .array(a.map(one))
            case .object(var o):
                if o["time_hhmm"] != nil, let d = o["day_iso"]?.string, d == today || d == tomorrow { o["day_iso"] = nil }
                return .object(o.mapValues(one))
            default:
                return v
            }
        }
        return one(args)
    }

    // MARK: Helpers

    static func calendar(_ tz: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        c.locale = Locale(identifier: "en_GB")
        return c
    }

    static func day(_ date: Date, offset: Int, _ cal: Calendar) -> String {
        let d = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: date)) ?? date
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func hhmm(_ date: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// "9:00", "09:00", "0900" → (9, 0).
    static func clock(_ s: String) -> (Int, Int)? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let parts = t.split(separator: ":")
        let h: Int?, m: Int?
        if parts.count == 2 { h = Int(parts[0]); m = Int(parts[1]) }
        else if parts.count == 1, t.count == 4 { h = Int(t.prefix(2)); m = Int(t.suffix(2)) }
        else { return nil }
        guard let h, let m, (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }

    static func at(_ now: Date, dayOffset: Int, _ h: Int, _ m: Int, _ cal: Calendar) -> Date? {
        guard let d = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: now)) else { return nil }
        var c = cal.dateComponents([.year, .month, .day], from: d)
        c.hour = h
        c.minute = m
        c.second = 0
        return cal.date(from: c)
    }

    /// ISO 8601 with the offset written out ("+00:00", "+01:00"), as the planner's tools expect.
    static func iso(_ date: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return f.string(from: date)
    }

    static func parseDateTime(_ s: String, _ tz: TimeZone) -> Date? {
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = tz
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    private static func isBlank(_ v: JSONValue) -> Bool {
        if case .string(let s) = v { return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return false
    }
}

// MARK: - Self-test (runs on a Mac: swiftc JSONValue.swift AgentKit.swift RoutineStore.swift main.swift)

extension RoutineStore {
    /// Failures, or an empty list when everything passes.
    static func selfTest() -> [String] {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: @autoclosure () -> String) { if !ok { failures.append(what()) } }
        let cal = RoutineTemplate.calendar(RoutineTemplate.london)
        func london(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
            cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
        }

        // Templates. 25 October 2026 is the day the clocks go back (BST → GMT at 02:00).
        let morning = RoutineTemplate.Vars(now: london(2026, 10, 25, 8, 30), input: "")
        func expect(_ template: String, _ vars: RoutineTemplate.Vars, _ want: String) {
            let got = RoutineTemplate.resolve(template, vars)
            check(got == want, "template \(template): got \"\(got)\", wanted \"\(want)\"")
        }
        expect("{{today}}", morning, "2026-10-25")
        expect("{{tomorrow}}", morning, "2026-10-26")
        expect("{{now_hhmm}}", morning, "08:30")
        expect("{{today_at:09:00}}", morning, "2026-10-25T09:00:00+00:00")
        expect("{{next_at:9:00}}", morning, "2026-10-25T09:00:00+00:00")
        expect("{{next_at:07:00}}", morning, "2026-10-26T07:00:00+00:00")
        expect("{{in_minutes:30}}", morning, "2026-10-25T09:00:00+00:00")
        expect("Plan for {{today}} at {{ now_hhmm }}", morning, "Plan for 2026-10-25 at 08:30")
        expect("{{weather}}", morning, "{{weather}}")
        let saturdayNight = RoutineTemplate.Vars(now: london(2026, 10, 24, 23, 0))
        expect("{{today_at:09:00}}", saturdayNight, "2026-10-24T09:00:00+01:00")
        expect("{{tomorrow_at:09:00}}", saturdayNight, "2026-10-25T09:00:00+00:00")
        let summer = RoutineTemplate.Vars(now: london(2026, 7, 1, 9, 30))
        expect("{{now_hhmm}}", summer, "09:30")
        expect("{{next_at:20:00}}", summer, "2026-07-01T20:00:00+01:00")

        let noInput = RoutineTemplate.resolve(["place": "{{input}}", "day": "today"], morning)
        check(noInput == ["day": "today"], "empty {{input}} should drop the key, got \(noInput.compactString)")
        var withInput = morning
        withInput.input = "London"
        let filled = RoutineTemplate.resolve(["place": "{{input}}", "days": ["{{today}}", "{{input}}"]], withInput)
        check(filled == ["place": "London", "days": ["2026-10-25", "London"]], "{{input}} filled: \(filled.compactString)")
        check(RoutineTemplate.unknownPlaceholders(in: ["a": "{{today}}", "b": ["{{weather}}", "{{next_at:25:00}}"]])
                == ["weather", "next_at:25:00"], "unknown placeholders")
        check(RoutineTemplate.unknownPlaceholders(in: ["a": "{{in_minutes:20}} {{input}} {{tomorrow_at:7:15}}"]).isEmpty,
              "known placeholders flagged")

        // Generalising what was just done (saved at 21:00 on the 25th).
        let night = london(2026, 10, 25, 21, 0)
        let general = RoutineTemplate.generalize([
            "due_iso": "2026-10-26T07:00:00+00:00", "date_iso": "2026-10-25", "far": "2026-10-30T10:00:00+00:00",
            "past": "2026-10-25T09:00:00+00:00",
        ], now: night)
        check(general == ["due_iso": "{{next_at:07:00}}", "date_iso": "{{today}}", "far": "2026-10-30T10:00:00+00:00",
                          "past": "{{today_at:09:00}}"], "generalize: \(general.compactString)")
        let alarm = RoutineTemplate.generalize(["time_hhmm": "07:00", "label": "Wake up", "day_iso": "2026-10-26"], now: night)
        check(alarm == ["time_hhmm": "07:00", "label": "Wake up"], "alarm day should go: \(alarm.compactString)")

        // Matching.
        // Morning reads {{input}} (a town for the weather); Bedtime doesn't, so words after its phrase aren't its input.
        let am = Routine(name: "Morning", phrases: ["do my morning", "start my day"],
                         steps: [.tool("get_weather", ["place": "{{ input }}"]), .say("Good morning")])
        let walk = Routine(name: "Morning walk", phrases: [], steps: [.say("Shoes on")])
        let bed = Routine(name: "Bedtime", phrases: ["bedtime routine", "good night Kairos"], steps: [.say("Night night")])
        let priya = Routine(name: "Hello Priya", phrases: ["do my", "run the"], steps: [.say("Hi")])
        let all = [am, walk, bed, priya]
        check(am.usesInput && !bed.usesInput, "usesInput")
        func hit(_ words: String, _ want: Routine?, input: String = "", confident: Bool = true) {
            let m = RoutineMatcher.match(words, in: all)
            guard let want else {
                if let m, m.isConfident { failures.append("\"\(words)\": should not run a routine, got \(m.routine.name) (\(m.how))") }
                return
            }
            guard let m else { failures.append("\"\(words)\": no match, wanted \(want.name)"); return }
            check(m.routine.id == want.id, "\"\(words)\": got \(m.routine.name), wanted \(want.name)")
            check(m.input == input, "\"\(words)\": input \"\(m.input)\", wanted \"\(input)\"")
            check(m.isConfident == confident, "\"\(words)\": confident \(m.isConfident) (\(m.how)), wanted \(confident)")
        }
        hit("do my morning", am)
        hit("Do my morning, I'm in London.", am, input: "I'm in London")
        hit("Kairos, can you start my day please", am)
        hit("start my day in Leeds", am, input: "in Leeds")
        hit("run my morning walk", walk)
        hit("do the morning routine", am)
        hit("morning", am)
        hit("Bedtime routine please", bed)
        hit("my bedtime routine", bed)
        hit("routine for bedtime", bed)
        hit("Good night, Kairos!", bed)
        hit("start bedtime", bed)
        hit("set an alarm for tomorrow morning", nil)
        hit("what's the weather like", nil)
        hit("do my morning and set an alarm for 7", nil)
        hit("how do i do my morning", nil)
        hit("remind me about my morning pills", nil)
        // Words after a phrase are a new request, or the routine takes no input: the model decides, not the rules.
        hit("Good night, set an alarm for 7", nil)
        hit("bedtime routine, I'm tired", nil)
        hit("start my day, remind me to take my pills at 9", nil)
        hit("do my morning what's the weather in Leeds", nil)
        hit("do my morning, then text Priya", nil)
        hit("start my day in the lovely old town of Much Wenlock in Shropshire please", nil)
        hit("run my bedtime now", bed)
        // A phrase of command words only never matches; names keep their first word ("Hello Priya" isn't "Priya").
        hit("do my shopping list", nil)
        hit("run the bath", nil)
        hit("Priya", nil)
        hit("do my hello priya", priya)
        check(RoutineMatcher.named("Hello Priya", in: all)?.id == priya.id, "named: Hello Priya")
        check(cleanPhrases(["do my", "run the", "please", "do my errands"]) == ["do my errands"], "cleanPhrases drops command-only")
        check(RoutineMatcher.match("do my morning", in: []) == nil, "no routines, no match")

        check(RoutineMatcher.named("morning routine", in: all)?.id == am.id, "named: morning routine")
        check(RoutineMatcher.named("Bed time", in: all)?.id == bed.id, "named: Bed time")
        check(RoutineMatcher.named("the morning walk one", in: all)?.id == walk.id, "named: morning walk")
        check(RoutineMatcher.named(bed.id.uuidString, in: all)?.id == bed.id, "named: by id")
        check(RoutineMatcher.named("lunch", in: all) == nil, "named: lunch should be nil")

        check(RoutineMatcher.wantsToCompose("Create a routine for my mornings: tell me the weather"), "compose: create")
        check(RoutineMatcher.wantsToCompose("make me a shortcut that tells me the weather"), "compose: shortcut")
        check(RoutineMatcher.wantsToCompose("save that as bedtime"), "compose: save that as")
        check(!RoutineMatcher.wantsToCompose("do my morning routine"), "compose: run is not compose")
        check(!RoutineMatcher.wantsToCompose("what's the weather tomorrow"), "compose: weather")

        // The file: round trip, and one broken routine doesn't lose the rest.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kairos-routines-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("routines.json")
        let saved = [Routine(name: "Morning", phrases: ["do my morning"], summary: "Weather and plans",
                             steps: [.tool("get_weather", ["day": "today", "place": "{{input}}"], label: "weather"),
                                     .tool("get_calendar_events", ["date_iso": "{{today}}"]),
                                     .think("In two sentences, tell me my day"),
                                     .operate(goal: "Open my bus app", app: "Citymapper")],
                             createdAt: Date(timeIntervalSince1970: 1_790_000_000), madeFrom: "make a morning routine")]
        do {
            try write(saved, to: url)
            check(read(from: url) == saved, "file round trip")
            var text = try String(contentsOf: url, encoding: .utf8)
            text = text.replacingOccurrences(of: "\"routines\" : [", with: "\"routines\" : [ {\"name\": 5},")
            try text.write(to: url, atomically: true, encoding: .utf8)
            check(read(from: url) == saved, "a broken routine should be skipped, the rest kept")
            try "not json".write(to: url, atomically: true, encoding: .utf8)
            check(read(from: url).isEmpty, "garbage file reads as empty")
            check(FileManager.default.fileExists(atPath: url.appendingPathExtension("bad").path), "garbage file backed up")
            // A file that is there but can't be read yet (locked phone) is "try again", not "no routines".
            try write(saved, to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
            let locked = load(from: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            check(locked == nil, "unreadable file should load as nil, got \(locked?.count ?? -1)")
            check(load(from: url) == saved, "readable again")
            check(load(from: dir.appendingPathComponent("none.json")) == [], "missing file is empty")
        } catch {
            failures.append("file: \(error)")
        }
        check(cleanPhrases([" Do my morning ", "do my morning!", "", "start my day"]) == ["Do my morning", "start my day"],
              "cleanPhrases")
        return failures
    }
}
