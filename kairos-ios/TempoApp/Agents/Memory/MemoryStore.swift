import Foundation

// Kairos's memory of the person: short facts they asked it to keep ("My GP is Dr Shah", "I take my tablets at 8"),
// in Application Support/Kairos/memory.json on this iPhone only. At most 200 facts of up to 200 characters each,
// no duplicates (compared with case, accents and punctuation folded), and never a PIN, password, code or card number.
// Kairos sends only the few facts that matter to each question to Gemini (MemoryContext).

/// What a remembered fact is about. Shown as sections in the Memory window.
enum MemoryCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case people, health, home, preferences, routines, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .people: return "People"
        case .health: return "Health"
        case .home: return "Home"
        case .preferences: return "Likes and dislikes"
        case .routines: return "Routines"
        case .other: return "Other things"
        }
    }

    /// SF Symbol.
    var icon: String {
        switch self {
        case .people: return "person.2.fill"
        case .health: return "heart.fill"
        case .home: return "house.fill"
        case .preferences: return "star.fill"
        case .routines: return "clock.fill"
        case .other: return "square.grid.2x2.fill"
        }
    }

    /// A best guess from the words, for facts said without a category.
    static func guess(_ text: String) -> MemoryCategory {
        let words = Set(MemoryText.words(text).map(MemoryText.stem))
        let has: ([String]) -> Bool = { list in list.contains { words.contains(MemoryText.stem($0)) } }
        let f = " " + text.folded + " "
        if has(["tablet", "tablets", "medicine", "medication", "pill", "pills", "allergic", "allergy", "doctor", "gp",
                "hospital", "nurse", "pharmacy", "chemist", "surgery", "diabetes", "diabetic", "insulin", "inhaler",
                "hearing", "glasses", "blood", "heart", "nhs", "dentist", "prescription", "physio", "appointment"]) {
            return .health
        }
        if has(["mum", "mother", "dad", "father", "daughter", "son", "wife", "husband", "sister", "brother", "grandson",
                "granddaughter", "grandchild", "grandchildren", "friend", "neighbour", "neighbor", "nephew", "niece",
                "aunt", "uncle", "cousin", "partner", "carer", "amma", "nanna", "children", "child", "family"]) {
            return .people
        }
        if f.contains(" every ") || f.contains(" each ") || has(["morning", "evening", "night", "daily", "weekly", "usually",
                                                                  "monday", "tuesday", "wednesday", "thursday", "friday",
                                                                  "saturday", "sunday", "weekend", "routine"]) {
            return .routines
        }
        if has(["house", "flat", "home", "door", "key", "keys", "boiler", "bin", "bins", "garden", "heating", "landlord",
                "kitchen", "address", "street", "road", "postcode", "car", "parking", "wifi", "plumber", "electrician"]) {
            return .home
        }
        if has(["like", "likes", "love", "loves", "prefer", "prefers", "hate", "favourite", "favorite", "rather", "enjoy",
                "dislike", "call me", "louder", "slowly", "slower", "bigger"]) || f.contains(" don t like ") {
            return .preferences
        }
        return .other
    }
}

/// How a fact came to be remembered.
enum MemoryFactSource: String, Codable, Sendable {
    case said = "you said"
    case agreed = "you agreed"
    case byHand = "added by hand"
}

struct MemoryFact: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var text: String
    var category: MemoryCategory
    var source: MemoryFactSource
    var createdAt: Date
    var lastUsedAt: Date
}

/// Where the memory files live. Tests (and the macOS harness) point `base` at a temporary folder.
@MainActor
enum MemoryPaths {
    static var base: URL?

    /// Application Support/Kairos.
    static var kairos: URL {
        if let base { return base }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Kairos", isDirectory: true)
    }

    /// Atomic write, readable only after the phone was first unlocked since it started, and left out of iCloud and
    /// computer backups ("kept only on this iPhone").
    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        var saved = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? saved.setResourceValues(values)   // an atomic write replaces the file, so this is set every time
    }

    /// ISO 8601 with milliseconds ("2026-10-25T18:40:12.345Z"); plain ISO 8601 is read too.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(isoMillis.string(from: date))
        }
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = isoMillis.date(from: s) ?? isoPlain.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not an ISO 8601 date: \(s)")
        }
        return d
    }()

    nonisolated(unsafe) private static let isoMillis: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()
}

/// A thread-safe copy of the facts, for the tools' quick checks (quickMatch and validate are not on the main actor).
final class MemoryFactsMirror: @unchecked Sendable {
    static let shared = MemoryFactsMirror()
    private let lock = NSLock()
    private var facts: [MemoryFact] = []

    var all: [MemoryFact] {
        lock.lock(); defer { lock.unlock() }
        return facts
    }

    func set(_ new: [MemoryFact]) {
        lock.lock(); facts = new; lock.unlock()
    }
}

@MainActor
final class MemoryStore: ObservableObject {
    static var shared = MemoryStore()

    /// Newest first.
    @Published private(set) var facts: [MemoryFact] = []

    nonisolated static let maxFacts = 200
    nonisolated static let maxLength = 200
    nonisolated static let seededKey = "kairos.memory.seededRelations"

    let file: URL
    private let saveDelay: TimeInterval
    private var saveTask: Task<Void, Never>?
    private let mirror: MemoryFactsMirror

    init(file: URL? = nil, saveDelay: TimeInterval = 1, mirror: MemoryFactsMirror = .shared) {
        self.file = file ?? MemoryPaths.kairos.appendingPathComponent("memory.json")
        self.saveDelay = saveDelay
        self.mirror = mirror
        load()
    }

    enum AddOutcome: Equatable {
        case added(MemoryFact)
        case duplicate(MemoryFact)
        case refused(String)
    }

    // MARK: - Changing

    /// Adds a fact in the person's words. The same fact twice is kept once (its "last used" moves on).
    @discardableResult
    func add(_ raw: String, category: MemoryCategory? = nil, source: MemoryFactSource, now: Date = Date()) -> AddOutcome {
        let text = Self.tidy(raw)
        if let problem = Self.problem(with: text) { return .refused(problem) }
        let key = Self.key(text)
        if let i = facts.firstIndex(where: { Self.key($0.text) == key }) {
            facts[i].lastUsedAt = now
            if let category, facts[i].category == .other { facts[i].category = category }
            changed()
            return .duplicate(facts[i])
        }
        guard facts.count < Self.maxFacts else {
            return .refused("My memory is full. Please open Memory and forget something you don't need any more.")
        }
        let fact = MemoryFact(id: UUID(), text: text, category: category ?? MemoryCategory.guess(text), source: source,
                              createdAt: now, lastUsedAt: now)
        facts.insert(fact, at: 0)
        changed()
        return .added(fact)
    }

    /// Changes a fact's words or category. Returns a reason when the new words can't be kept.
    @discardableResult
    func edit(id: UUID, text raw: String, category: MemoryCategory? = nil, now: Date = Date()) -> String? {
        guard let i = facts.firstIndex(where: { $0.id == id }) else { return "I couldn't find that one any more." }
        let text = Self.tidy(raw)
        if let problem = Self.problem(with: text) { return problem }
        let key = Self.key(text)
        if facts.contains(where: { $0.id != id && Self.key($0.text) == key }) {
            facts.remove(at: i)   // it now says the same as another fact: keep one
        } else {
            facts[i].text = text
            if let category { facts[i].category = category }
            facts[i].lastUsedAt = now
        }
        changed()
        return nil
    }

    func delete(id: UUID) {
        facts.removeAll { $0.id == id }
        changed()
    }

    func deleteAll() {
        facts.removeAll()
        changed()
        saveNow()
    }

    /// Marks facts as just used (they rank a little higher next time).
    func touch(_ ids: [UUID], now: Date = Date()) {
        let wanted = Set(ids)
        var any = false
        for i in facts.indices where wanted.contains(facts[i].id) {
            facts[i].lastUsedAt = now
            any = true
        }
        if any { changed() }
    }

    // MARK: - Finding

    func fact(id: UUID) -> MemoryFact? { facts.first { $0.id == id } }

    /// The most recently added or used facts.
    func recent(_ limit: Int) -> [MemoryFact] {
        Array(facts.sorted { max($0.createdAt, $0.lastUsedAt) > max($1.createdAt, $1.lastUsedAt) }.prefix(limit))
    }

    /// Facts that share words with the request, names counting most, newer ones first among equals. Empty when
    /// nothing overlaps.
    func relevant(to words: String, limit: Int = 6, now: Date = Date()) -> [MemoryFact] {
        Self.rank(facts, for: words, now: now).prefix(limit).map(\.fact)
    }

    nonisolated static func rank(_ facts: [MemoryFact], for words: String, now: Date) -> [(fact: MemoryFact, score: Double)] {
        let asked = Set(MemoryText.contentWords(words).map(MemoryText.stem))
        guard !asked.isEmpty else { return [] }
        var scored: [(MemoryFact, Double)] = []
        for fact in facts {
            let names = Set(MemoryText.names(in: fact.text).map(MemoryText.stem))
            var score = 0.0
            for word in Set(MemoryText.contentWords(fact.text).map(MemoryText.stem)) where asked.contains(word) {
                score += names.contains(word) ? 3 : 1
            }
            guard score > 0 else { continue }
            let days = max(0, now.timeIntervalSince(max(fact.createdAt, fact.lastUsedAt)) / 86_400)
            score += 0.5 * exp(-days / 30)
            scored.append((fact, score))
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastUsedAt > $1.0.lastUsedAt }
    }

    /// Facts that contain every content word of `what` ("forget that I like tea"); else the single best partial match.
    func matching(_ what: String) -> [MemoryFact] { Self.matching(what, in: facts) }

    nonisolated static func matching(_ what: String, in facts: [MemoryFact]) -> [MemoryFact] {
        let wanted = Set(MemoryText.contentWords(what).map(MemoryText.stem))
        guard !wanted.isEmpty else { return [] }
        let full = facts.filter { wanted.isSubset(of: Set(MemoryText.contentWords($0.text).map(MemoryText.stem))) }
        if !full.isEmpty { return full }
        let partial = facts.map { fact -> (MemoryFact, Int) in
            let have = Set(MemoryText.contentWords(fact.text).map(MemoryText.stem))
            return (fact, wanted.intersection(have).count)
        }.filter { Double($0.1) / Double(wanted.count) >= 0.5 }
        guard let best = partial.max(by: { $0.1 < $1.1 }) else { return [] }
        return partial.filter { $0.1 == best.1 }.count == 1 ? [best.0] : []
    }

    // MARK: - Seeding from the relations the person taught Kairos

    /// Once per phone: "Priya Shah is my daughter" for each relation taught through "Priya is my daughter".
    /// Read-only towards PeopleDirectory; forgetting one here doesn't untrain it.
    func seedOnce(from pairs: [(name: String, relation: String)], defaults: UserDefaults = .standard, now: Date = Date()) {
        guard !defaults.bool(forKey: Self.seededKey) else { return }
        defaults.set(true, forKey: Self.seededKey)
        for pair in pairs {
            let name = pair.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let relation = pair.relation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !relation.isEmpty else { continue }
            _ = add("\(name) is my \(relation).", category: .people, source: .said, now: now)
        }
    }

    // MARK: - Rules for the words

    /// Trimmed, single spaces, without a leading "that", first letter capital.
    nonisolated static func tidy(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”'‘’")))
        if s.lowercased().hasPrefix("that ") { s = String(s.dropFirst(5)) }
        if let first = s.first, first.isLowercase { s = first.uppercased() + s.dropFirst() }
        return s
    }

    /// Why a fact can't be kept, or nil.
    nonisolated static func problem(with text: String) -> String? {
        if MemoryText.contentWords(text).isEmpty && text.digitsOnly.isEmpty { return "What should I remember? Please say it in a few words." }
        if text.count > maxLength { return "That's a lot to keep. Can you say it in one short sentence?" }
        if MemorySecrets.looksSecret(text) { return MemorySecrets.refusal }
        return nil
    }

    /// The form two facts are compared in.
    nonisolated static func key(_ text: String) -> String { text.folded }

    // MARK: - Disk

    private func load() {
        defer { mirror.set(facts) }
        guard let data = try? Data(contentsOf: file),
              let saved = try? MemoryPaths.decoder.decode(SavedFacts.self, from: data) else { facts = []; return }
        // Drop anything that slipped in before a rule existed (an over-long fact, a code).
        var seen = Set<String>()
        facts = saved.facts.filter { Self.problem(with: $0.text) == nil && seen.insert(Self.key($0.text)).inserted }
            .prefix(Self.maxFacts).map { $0 }
    }

    private struct SavedFacts: Codable {
        var version = 1
        var facts: [MemoryFact]
    }

    private func changed() {
        mirror.set(facts)
        guard saveTask == nil else { return }
        let delay = saveDelay
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.saveNow()
        }
    }

    /// Writes now (the app is going to the background, or a test wants the file).
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        if facts.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        if let data = try? MemoryPaths.encoder.encode(SavedFacts(facts: facts)) {
            try? MemoryPaths.write(data, to: file)
        }
    }
}

// MARK: - Words

/// Word helpers shared by the memory, the chat history and the memory tools.
enum MemoryText {
    /// Folded words ("Dr Shah's" → "dr", "shah", "s").
    static func words(_ s: String) -> [String] { s.folded.split(separator: " ").map(String.init) }

    /// Words that carry meaning: no "the", "my", "remember", "person".
    static func contentWords(_ s: String) -> [String] {
        words(s).filter { !stopWords.contains($0) && ($0.count >= 2 || $0.allSatisfy(\.isNumber)) }
    }

    /// Capitalised words that aren't the first word of a sentence: "Priya", "Shah", "Tesco". Folded.
    static func names(in s: String) -> [String] {
        var out: [String] = []
        let sentences = s.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
        for sentence in sentences {
            let raw = sentence.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" || $0 == ":" })
            for (i, word) in raw.enumerated() {
                let clean = word.trimmingCharacters(in: CharacterSet.letters.inverted)
                guard let first = clean.first, first.isUppercase, clean.count >= 2 else { continue }
                let folded = clean.folded
                if i == 0, stopWords.contains(folded) { continue }   // "My", "The", "I"
                if ["i", "im", "ive", "id", "ill"].contains(folded) { continue }
                out.append(contentsOf: folded.split(separator: " ").map(String.init))
            }
        }
        return out.filter { !stopWords.contains($0) }
    }

    /// A light stem so "tablets"/"tablet", "liked"/"like", "walking"/"walk" match.
    static func stem(_ w: String) -> String {
        guard w.count > 4, !w.allSatisfy(\.isNumber) else { return w }
        for suffix in ["ing", "ies", "es", "ed", "s"] where w.hasSuffix(suffix) && w.count - suffix.count >= 3 {
            let base = String(w.dropLast(suffix.count))
            return suffix == "ies" ? base + "y" : base
        }
        return w
    }

    static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "so", "of", "to", "in", "on", "at", "by", "for", "with", "from", "as",
        "is", "are", "was", "were", "be", "been", "am", "do", "does", "did", "has", "have", "had", "it", "its", "this",
        "that", "these", "those", "there", "here", "i", "im", "ive", "id", "ill", "me", "my", "mine", "myself", "you",
        "your", "yours", "we", "us", "our", "they", "them", "their", "he", "him", "his", "she", "her", "s", "t", "d",
        "ll", "re", "ve", "m", "not", "no", "yes", "please", "remember", "remembered", "forget", "kairos", "person",
        "persons", "owner", "user", "about", "what", "when", "where", "who", "which", "how", "why", "can", "could",
        "would", "will", "shall", "should", "just", "also", "very", "really", "all", "any", "some", "thing", "things",
        "know", "tell", "told", "say", "said", "keep", "mind", "note", "ok", "okay", "hey", "oh", "well", "now", "then",
        "into", "up", "out", "dont", "doesnt", "isnt", "than", "too", "much", "many", "one",
        "dr", "mr", "mrs", "ms", "miss", "prof", "sir",   // "Dr Shah" and "Doctor Shah" are the same person
    ]
}

// MARK: - Secrets

/// PINs, passwords, codes and card numbers: Kairos never keeps them, whoever asks.
enum MemorySecrets {
    static let refusal = "I won't keep PINs, passwords, codes or card numbers. Please keep those somewhere safe yourself."

    static func looksSecret(_ text: String) -> Bool {
        let words = MemoryText.words(text)
        let padded = " " + words.joined(separator: " ") + " "
        let runs = MemoryDigits.runs(text)
        // A card number anywhere, spaced or not.
        let squashed = text.filter { !" -".contains($0) }
        for run in runs + MemoryDigits.runs(squashed) where (13...19).contains(run.count) && luhn(run) { return true }
        // Passwords and passcodes, with or without digits: "my wifi password is fluffy".
        let secretNouns = ["password", "passcode", "passphrase", "passwd", "pwd", "pin", "pin number", "pin code", "otp",
                           "cvv", "cvc", "security code", "verification code", "one time code", "one time passcode",
                           "memorable word", "memorable information", "secret answer", "security answer",
                           "login details", "sign in details"]
        let saysValue = padded.range(of: #" (is|are|was|it s|its|=) "#, options: .regularExpression) != nil
            || text.contains(":") || runs.contains { $0.count >= 3 }
        for noun in secretNouns where padded.contains(" \(noun) ") {
            if saysValue { return true }
        }
        // "door code 1234", "the code is 482913": a code with 4–8 digits, but not a postcode or dialling code.
        if padded.contains(" code "), runs.contains(where: { (4...8).contains($0.count) }) {
            let harmless = [" post code ", " postcode ", " zip code ", " area code ", " dialling code ", " dialing code ",
                            " sort code "]
            if !harmless.contains(where: { padded.contains($0) }) || padded.contains(" door code ") { return true }
        }
        // Bank details: a sort code with an account number.
        if padded.contains(" sort code ") || padded.contains(" account number ") {
            if runs.contains(where: { $0.count >= 6 }) { return true }
        }
        // Government numbers fraudsters ask for.
        if padded.contains(" national insurance ") || padded.contains(" passport number ") || padded.contains(" ni number ") {
            if runs.contains(where: { $0.count >= 6 }) || text.range(of: #"\b[A-Za-z]{2}\s?\d{2}\s?\d{2}\s?\d{2}\s?[A-Da-d]\b"#, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    /// The card-number checksum, so a long phone number isn't mistaken for a card.
    static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard var d = ch.wholeNumberValue else { return false }
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }
}

/// Digit runs that allow one space, dash or bracket between digits ("07700 900123" is one run). The same rule as
/// SafetyGate.digitRuns, kept here so the memory files build on their own.
enum MemoryDigits {
    static func runs(_ s: String) -> [String] {
        var runs: [String] = []
        var current = ""
        var gap = 0
        for ch in s {
            if ch.isASCII, ch.isNumber { current.append(ch); gap = 0 }
            else if !current.isEmpty, " -()+.".contains(ch), gap == 0 { gap += 1 }
            else { if !current.isEmpty { runs.append(current) }; current = ""; gap = 0 }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }
}
