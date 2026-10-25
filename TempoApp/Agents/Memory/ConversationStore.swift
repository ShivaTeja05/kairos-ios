import Combine
import Foundation
#if canImport(UIKit)
import UIKit
#endif

// The person's chats with Kairos, kept on this iPhone so the Memory window can show them and Kairos can answer
// "what did we talk about yesterday?". It listens to KairosAgent's visible lines and keeps every new one once (by
// its id), grouped into sessions: a new session after 20 minutes of quiet, when the app starts, when the person taps
// "New conversation", when the request comes from somewhere else (Siri, a voice call, a Shortcut, Present mode), or
// on startNewSession(). One JSON file per day (Application Support/Kairos/history/YYYY-MM-DD.json), written a second
// after a change (atomically, protected until the phone is first unlocked), 90 days kept, at most 3,000 turns.

/// Where a chat happened.
enum ConversationSource: String, Codable, CaseIterable, Sendable {
    case app, voice, siri, automation, show

    /// SF Symbol for the chat list.
    var icon: String {
        switch self {
        case .app: return "iphone"
        case .voice: return "phone.fill"
        case .siri: return "mic.fill"
        case .automation: return "gearshape.2.fill"
        case .show: return "play.rectangle.fill"
        }
    }

    /// "on a voice call", for VoiceOver and the transcript's heading.
    var spoken: String {
        switch self {
        case .app: return "in Kairos"
        case .voice: return "on a voice call"
        case .siri: return "through Siri"
        case .automation: return "from a Shortcut"
        case .show: return "in Present mode"
        }
    }
}

/// One line of a saved chat.
struct ConversationTurn: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case person, kairos, done, failed, refused }
    var id: UUID
    var at: Date
    var kind: Kind
    var text: String
    /// Which helper did it ("Time helper"), for action lines.
    var helper: String?
    var icon: String?

    var isAction: Bool { kind == .done || kind == .failed || kind == .refused }
}

/// One conversation: everything from a first request until 20 minutes of quiet (or "New conversation").
struct ConversationSession: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date
    var source: ConversationSource
    /// The first request, at most 60 characters.
    var title: String
    var turns: [ConversationTurn]

    var requestCount: Int { turns.filter { $0.kind == .person }.count }
}

/// The chat list's sections: Today, Yesterday, a weekday, a date.
struct ConversationDay: Identifiable, Equatable, Sendable {
    var id: String       // "2026-10-25"
    var date: Date       // start of that day
    var sessions: [ConversationSession]   // newest first
}

@MainActor
final class ConversationStore: ObservableObject {
    static var shared = ConversationStore()

    /// Oldest first.
    @Published private(set) var sessions: [ConversationSession] = []

    /// Where the next requests come from. Set it around a Siri request or a voice call's hand-over; `.app` lets
    /// `sourceProbe` decide.
    var currentSource: ConversationSource = .app
    /// Works out where a request came from when nobody said (MemoryContext sets it: voice call, Present mode, Siri).
    static var sourceProbe: (@MainActor () -> ConversationSource?)?
    /// Each new request from the person (not from a Shortcut), for MemoryContext's choice of memories.
    var onPersonWords: (@MainActor (String) -> Void)?
    /// Requests that are mostly someone else's words ("is this a scam? <a pasted message>"): their titles stay out of
    /// Gemini's picture of the phone. MemoryContext sets it.
    static var isPastedRequest: (@MainActor (String) -> Bool)?

    nonisolated static let keepDays = 90
    nonisolated static let maxTurns = 3_000
    nonisolated static let quietGap: TimeInterval = 20 * 60
    nonisolated static let titleLength = 60
    /// How long "Ask about this chat" points the recall tool at that chat.
    nonisolated static let askWindow: TimeInterval = 10 * 60

    let directory: URL
    private let saveDelay: TimeInterval
    private let clock: () -> Date
    private var calendar: Calendar { Calendar.current }

    /// The session new turns go into; nil after launch or "New conversation" until the next turn.
    private(set) var currentID: UUID?
    /// The id of the person's latest request (so "what did we talk about today?" doesn't find itself).
    private(set) var latestRequestID: UUID?
    private var seen = Set<UUID>()
    private var hadLines = false
    private var dirtyDays = Set<String>()
    private var saveTask: Task<Void, Never>?
    private var subscription: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private(set) var askingAbout: (id: UUID, at: Date)?

    init(directory: URL? = nil, saveDelay: TimeInterval = 1, clock: @escaping () -> Date = Date.init) {
        self.directory = directory ?? MemoryPaths.kairos.appendingPathComponent("history", isDirectory: true)
        self.saveDelay = saveDelay
        self.clock = clock
        load()
        #if canImport(UIKit)
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            })
        }
        #endif
    }

    // MARK: - Listening to Kairos

    /// Keeps every new line Kairos shows. Safe to call more than once.
    func attach(to agent: KairosAgent) {
        guard subscription == nil else { return }
        subscription = agent.$lines.sink { [weak self] lines in
            MainActor.assumeIsolated { self?.ingest(lines) }
        }
    }

    func detach() {
        subscription?.cancel()
        subscription = nil
    }

    /// The visible lines changed: keep the ones not seen before. An empty list means "New conversation".
    func ingest(_ lines: [AgentLine]) {
        guard !lines.isEmpty else {
            if hadLines { startNewSession() }
            hadLines = false
            seen.removeAll()
            return
        }
        hadLines = true
        let fresh = lines.filter { !seen.contains($0.id) }
        seen = Set(lines.map(\.id))   // lines only ever drop off the front, so this stays small
        for line in fresh {
            record(Self.kind(line.kind), line.text, helper: line.helper, icon: line.icon, id: line.id)
        }
    }

    nonisolated static func kind(_ k: AgentLine.Kind) -> ConversationTurn.Kind {
        switch k {
        case .person: return .person
        case .kairos: return .kairos
        case .done: return .done
        case .failed: return .failed
        case .refused: return .refused
        }
    }

    /// Adds one turn (KairosAgent's lines come through ingest; tests and other screens may call this directly).
    func record(_ kind: ConversationTurn.Kind, _ rawText: String, helper: String? = nil, icon: String? = nil,
                id: UUID = UUID()) {
        let text = String(rawText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
        guard !text.isEmpty else { return }
        let now = clock()
        let source = resolveSource(kind, text)
        var index = currentIndex
        if let i = index {
            let quiet = now.timeIntervalSince(sessions[i].endedAt) > Self.quietGap
            let elsewhere = kind == .person && sessions[i].source != source
            if quiet || elsewhere { index = nil }
        }
        let turn = ConversationTurn(id: id, at: now, kind: kind, text: text, helper: helper, icon: icon)
        if let i = index {
            if kind == .person, !sessions[i].turns.contains(where: { $0.kind == .person }) {
                sessions[i].title = Self.title(text)
            }
            sessions[i].turns.append(turn)
            sessions[i].endedAt = now
            markDirty(sessions[i])
        } else {
            let session = ConversationSession(id: UUID(), startedAt: now, endedAt: now, source: source,
                                              title: Self.title(text), turns: [turn])
            sessions.append(session)
            currentID = session.id
            markDirty(session)
        }
        if kind == .person {
            latestRequestID = id
            if source != .automation { onPersonWords?(Self.plainRequest(text)) }
        }
        prune(now: now)
        scheduleSave()
    }

    /// The next turn starts a new chat.
    func startNewSession() {
        currentID = nil
    }

    private var currentIndex: Int? {
        guard let currentID else { return nil }
        return sessions.lastIndex { $0.id == currentID }
    }

    private func resolveSource(_ kind: ConversationTurn.Kind, _ text: String) -> ConversationSource {
        if kind == .person {
            if text.hasPrefix("From a Shortcut:") { return .automation }
            if currentSource != .app { return currentSource }
            return Self.sourceProbe?() ?? .app
        }
        if let i = currentIndex { return sessions[i].source }
        if currentSource != .app { return currentSource }
        return Self.sourceProbe?() ?? .app
    }

    /// The first request as a title: no photo mark, at most 60 characters, cut at a word.
    nonisolated static func title(_ text: String) -> String {
        let plain = plainRequest(text)
        guard plain.count > titleLength else { return plain }
        let cut = String(plain.prefix(titleLength - 1))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > 30 {
            return String(cut[..<space]) + "…"
        }
        return cut + "…"
    }

    /// "📄 Please read this" → "Please read this".
    nonisolated static func plainRequest(_ text: String) -> String {
        var t = text
        if t.hasPrefix("📄") { t = String(t.dropFirst()) }
        return t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Reading

    func session(id: UUID) -> ConversationSession? { sessions.first { $0.id == id } }

    /// Sections for the Memory window, newest day first, newest chat first.
    var sessionsByDay: [ConversationDay] { Self.group(sessions, calendar: calendar) }

    nonisolated static func group(_ sessions: [ConversationSession], calendar: Calendar) -> [ConversationDay] {
        var byDay: [String: [ConversationSession]] = [:]
        for s in sessions { byDay[dayKey(s.startedAt, calendar: calendar), default: []].append(s) }
        return byDay.map { key, list in
            ConversationDay(id: key, date: calendar.startOfDay(for: list[0].startedAt),
                            sessions: list.sorted { $0.startedAt > $1.startedAt })
        }.sorted { $0.date > $1.date }
    }

    /// Chats whose words contain every word searched for (the start of a word is enough), newest first.
    func search(_ query: String) -> [ConversationSession] {
        let wanted = MemoryText.words(query)
        guard !wanted.isEmpty else { return sessions.reversed() }
        return sessions.reversed().filter { s in
            let have = Self.searchWords(s)
            return wanted.allSatisfy { w in have.contains { $0.hasPrefix(w) } }
        }
    }

    private nonisolated static func searchWords(_ s: ConversationSession) -> Set<String> {
        var all = MemoryText.words(s.title)
        for t in s.turns { all += MemoryText.words(t.text + " " + (t.helper ?? "")) }
        return Set(all)
    }

    /// Chats in a time span (nil = any time), with the turns about a topic (all turns when there's no topic),
    /// newest first. The person's request being answered right now is left out.
    func find(in span: DateInterval?, topic: String?, limit: Int = 3) -> [(session: ConversationSession, turns: [ConversationTurn])] {
        var out: [(ConversationSession, [ConversationTurn])] = []
        for s in sessions.reversed() {
            if let span, !(span.contains(s.startedAt) || span.contains(s.endedAt)
                           || (s.startedAt < span.start && s.endedAt > span.end)) { continue }
            var turns = s.turns.filter { $0.id != latestRequestID }
            if let span { turns = turns.filter { span.contains($0.at) } }
            turns = Self.turns(turns, about: topic)
            guard !turns.isEmpty else { continue }
            out.append((s, turns))
            if out.count >= limit { break }
        }
        return out
    }

    /// The turns that mention the topic's words (all of them when the topic has no real words).
    nonisolated static func turns(_ turns: [ConversationTurn], about topic: String?) -> [ConversationTurn] {
        let wanted = Set(MemoryText.contentWords(topic ?? "").filter { !MemoryWhen.timeWords.contains($0) }.map(MemoryText.stem))
        guard !wanted.isEmpty else { return turns }
        return turns.filter { t in
            let have = Set(MemoryText.contentWords(t.text + " " + (t.helper ?? "")).map(MemoryText.stem))
            return !have.isDisjoint(with: wanted) || wanted.contains { w in w.count >= 4 && have.contains { $0.hasPrefix(w) } }
        }
    }

    // MARK: - "Ask about this chat"

    /// The Memory window's "Ask about this chat": the recall tool answers from this chat for the next few minutes.
    func askAbout(_ id: UUID) { askingAbout = (id, clock()) }

    /// The chat the person is asking about, if they tapped "Ask about this chat" a moment ago.
    var askedAboutSession: ConversationSession? {
        guard let a = askingAbout, clock().timeIntervalSince(a.at) < Self.askWindow else { return nil }
        return session(id: a.id)
    }

    // MARK: - For Gemini's picture of the phone

    /// "Earlier chats today (titles only): 09:12 “Set an alarm for 7”; yesterday 18:40 “…”." The last three chats
    /// from the past two days, without the one going on now, Shortcut text, long numbers or links. Nil when none.
    func recentSummary(now: Date? = nil) -> String? {
        let now = now ?? clock()
        let since = now.addingTimeInterval(-48 * 3_600)
        let earlier = sessions.reversed().filter { $0.id != currentID && $0.source != .automation && $0.endedAt >= since }
            .prefix(3)
        guard !earlier.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "HH:mm"
        let items = earlier.map { s -> String in
            let day = calendar.isDate(s.startedAt, inSameDayAs: now) ? "today"
                : (calendar.isDate(s.startedAt, inSameDayAs: now.addingTimeInterval(-86_400)) ? "yesterday" : "earlier")
            return "\(day) \(f.string(from: s.startedAt)) \(Self.contextTitle(s))"
        }
        return "Earlier chats with the person (titles only; recall_conversation reads one): " + items.joined(separator: "; ") + "."
    }

    /// A chat's title for Gemini: quoted, without long numbers or links, or a plain description when the request was
    /// a pasted message.
    static func contextTitle(_ s: ConversationSession) -> String {
        let first = s.turns.first { $0.kind == .person }?.text ?? s.title
        if isPastedRequest?(first) == true { return "(a message you asked me to check)" }
        return "“\(scrubbed(s.title))”"
    }

    /// Long numbers and links out: context lines must not carry a number for the model to dial.
    nonisolated static func scrubbed(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"(https?://|www\.)\S+"#, with: "[link]", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\S+@\S+\.\S+"#, with: "[email]", options: .regularExpression)
        for run in MemoryDigits.runs(t) where run.count >= 6 {
            // Remove the run as written (with its spaces or dashes).
            let pattern = run.map { String($0) }.joined(separator: #"[\s\-().+]?"#)
            t = t.replacingOccurrences(of: pattern, with: "[number]", options: .regularExpression)
        }
        return t
    }

    // MARK: - Sharing

    /// The chat as Markdown, for Share.
    func exportMarkdown(_ session: ConversationSession) -> String { Self.markdown(session) }

    nonisolated static func markdown(_ s: ConversationSession) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_GB")
        day.dateFormat = "EEEE d MMMM yyyy 'at' HH:mm"
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_GB")
        time.dateFormat = "HH:mm"
        var md = "# \(s.title)\n\n"
        md += "_A chat with Kairos \(s.source.spoken), \(day.string(from: s.startedAt)). "
        md += "\(s.turns.count) line\(s.turns.count == 1 ? "" : "s")._\n\n"
        for t in s.turns {
            let at = time.string(from: t.at)
            switch t.kind {
            case .person: md += "**\(at) You:** \(t.text)\n\n"
            case .kairos: md += "**\(at) \(t.helper ?? "Kairos"):** \(t.text)\n\n"
            case .done: md += "- \(at) ✓ \(t.helper ?? "Helper"): \(t.text)\n\n"
            case .failed: md += "- \(at) ✗ \(t.helper ?? "Helper") couldn't: \(t.text)\n\n"
            case .refused: md += "- \(at) ✗ \(t.helper ?? "Helper") didn't: \(t.text)\n\n"
            }
        }
        return md
    }

    // MARK: - Deleting

    func delete(sessionID: UUID) {
        guard let s = session(id: sessionID) else { return }
        sessions.removeAll { $0.id == sessionID }
        if currentID == sessionID { currentID = nil }
        if askingAbout?.id == sessionID { askingAbout = nil }
        markDirty(s)
        flush()
    }

    func deleteAll() {
        sessions.removeAll()
        currentID = nil
        askingAbout = nil
        dirtyDays.removeAll()
        saveTask?.cancel()
        saveTask = nil
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where Self.day(fromFileName: file.lastPathComponent) != nil {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Keeping it small

    private func prune(now: Date) {
        let cutoff = calendar.date(byAdding: .day, value: -Self.keepDays, to: calendar.startOfDay(for: now)) ?? now
        let old = sessions.filter { $0.endedAt < cutoff }
        if !old.isEmpty {
            old.forEach(markDirty)
            sessions.removeAll { $0.endedAt < cutoff }
        }
        var total = sessions.reduce(0) { $0 + $1.turns.count }
        while total > Self.maxTurns, let first = sessions.first {
            if first.id == currentID || sessions.count == 1 {
                // Only the chat going on now is left: drop its oldest turns.
                let extra = total - Self.maxTurns
                sessions[0].turns.removeFirst(min(extra, sessions[0].turns.count - 1))
                if let start = sessions[0].turns.first?.at { sessions[0].startedAt = min(sessions[0].startedAt, start) }
                markDirty(sessions[0])
                break
            }
            markDirty(first)
            sessions.removeFirst()
            total -= first.turns.count
        }
    }

    // MARK: - Disk

    private struct DayFile: Codable {
        var version = 1
        var day: String
        var sessions: [ConversationSession]
    }

    nonisolated static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "2026-10-25.json" → "2026-10-25".
    nonisolated static func day(fromFileName name: String) -> String? {
        guard name.range(of: #"^\d{4}-\d{2}-\d{2}\.json$"#, options: .regularExpression) != nil else { return nil }
        return String(name.dropLast(5))
    }

    private func file(_ day: String) -> URL { directory.appendingPathComponent(day + ".json") }

    private func markDirty(_ s: ConversationSession) { dirtyDays.insert(Self.dayKey(s.startedAt, calendar: calendar)) }

    private func load() {
        let now = clock()
        let cutoffDay = Self.dayKey(calendar.date(byAdding: .day, value: -Self.keepDays, to: calendar.startOfDay(for: now)) ?? now,
                                    calendar: calendar)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var loaded: [ConversationSession] = []
        for url in files {
            guard let day = Self.day(fromFileName: url.lastPathComponent) else { continue }
            if day < cutoffDay {   // ISO dates sort as text
                try? FileManager.default.removeItem(at: url)
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let saved = try? MemoryPaths.decoder.decode(DayFile.self, from: data) else { continue }
            loaded += saved.sessions
        }
        var ids = Set<UUID>()
        sessions = loaded.filter { ids.insert($0.id).inserted }.sorted { $0.startedAt < $1.startedAt }
        currentID = nil   // a new launch is a new chat
        prune(now: now)
        if !dirtyDays.isEmpty { flush() }
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        let delay = saveDelay
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Writes the days that changed now.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard !dirtyDays.isEmpty else { return }
        let days = dirtyDays
        dirtyDays.removeAll()
        var byDay: [String: [ConversationSession]] = [:]
        for s in sessions { byDay[Self.dayKey(s.startedAt, calendar: calendar), default: []].append(s) }
        for day in days {
            let list = byDay[day] ?? []
            if list.isEmpty {
                try? FileManager.default.removeItem(at: file(day))
            } else if let data = try? MemoryPaths.encoder.encode(DayFile(day: day, sessions: list)) {
                try? MemoryPaths.write(data, to: file(day))
            }
        }
    }
}
