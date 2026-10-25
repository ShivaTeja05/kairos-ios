import Contacts
import Foundation

// The person's own contacts, as the Calls and messages helper (PeopleAgent) sees them. Everything stays on this
// iPhone: the model only ever gets names, number types ("mobile") and the last three digits, never a whole number.
// Independent of the Bridge's PeopleStore on purpose (that file is still changing).

// MARK: - Access

/// Whether Kairos may read the person's contacts. Reading the status never shows a prompt.
enum PeopleAccess: Equatable, Sendable {
    case full, limited, notAsked, denied

    static var current: PeopleAccess {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized: return .full
        case .notDetermined: return .notAsked
        case .denied, .restricted: return .denied
        default:
            #if os(iOS)
            // iOS 18+: the person chose only some contacts.
            if #available(iOS 18.0, *), status == .limited { return .limited }
            #endif
            return .denied
        }
    }

    var canRead: Bool { self == .full || self == .limited }

    /// Shows iOS's Contacts prompt if it has never been shown. It only appears while Kairos is on screen, so call it
    /// at first launch (no prompts can appear behind Siri). True when Kairos can read contacts afterwards.
    @discardableResult
    static func request() async -> Bool {
        if current == .notAsked {
            _ = try? await CNContactStore().requestAccess(for: .contacts)
            PeopleDirectory.shared.invalidate()
        }
        let now = current
        if now.canRead { PeopleDirectory.shared.warmUp() }
        return now.canRead
    }
}

// MARK: - Directory

/// A cached, read-only snapshot of the contacts, plus the relations the person taught Kairos ("Priya is my daughter").
final class PeopleDirectory: @unchecked Sendable {
    static let shared = PeopleDirectory()

    struct Phone: Sendable, Hashable {
        enum Kind: String, Sendable { case mobile, home, work, other }
        var kind: Kind
        /// What iOS dials: "+447700900123", or the digits as saved when the country isn't clear.
        var dial: String
        /// International form ("+447700900123") when it can be worked out.
        var e164: String?

        /// "mobile", "home number": for sentences like "Priya's mobile".
        var spoken: String {
            switch kind {
            case .mobile: return "mobile"
            case .home: return "home number"
            case .work: return "work number"
            case .other: return "number"
            }
        }
        /// For the model, so it can tell two numbers apart without seeing either.
        var endsIn: String { String(dial.digitsOnly.suffix(3)) }
        /// A UK or Indian mobile by its digits, whatever the card's label says. Texts and WhatsApp need one.
        var looksMobile: Bool {
            guard let e164 else { return kind == .mobile }
            if e164.hasPrefix("+447"), e164.count == 13 { return true }
            if e164.hasPrefix("+91"), e164.count == 13, let lead = e164.dropFirst(3).first, "6789".contains(lead) { return true }
            return kind == .mobile
        }
    }

    struct Relation: Sendable, Hashable {
        var groups: Set<String>  // "daughter"; "son" + "daughter" for "child"
        var name: String         // as written on the card: "Priya"
    }

    struct Card: Sendable, Hashable, Identifiable {
        var id: String
        /// "Priya Shah", or the nickname or company when there is no name.
        var displayName: String
        /// "Priya": for warm sentences.
        var spokenName: String
        var phones: [Phone]
        /// Relations written on this card ("daughter: Priya"). On the owner's own card they describe the owner.
        var relations: [Relation]
        // Folded forms for matching ("dr" is stored as "doctor").
        var full: String
        var given: String
        var family: String
        var nick: String
        var org: String
        var words: Set<String>
    }

    enum Lookup: Sendable {
        /// `close`: only a near spelling ("Pria" for "Priya"); ask before using it.
        case one(Card, close: Bool)
        case many([Card])
        case none
    }

    private let lock = NSLock()
    private var cards: [Card] = []
    private var loadedAt: Date?
    private var loadedWith: PeopleAccess?
    private var observer: NSObjectProtocol?
    private let maxAge: TimeInterval = 600

    init() {
        observer = NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: nil) { [weak self] _ in
            self?.invalidate()
        }
    }

    func invalidate() {
        lock.lock(); loadedAt = nil; lock.unlock()
    }

    /// Loads the contacts in the background so the first "call Priya" answers at once.
    func warmUp() {
        DispatchQueue.global(qos: .utility).async { _ = self.all() }
    }

    /// Every contact (cached for 10 minutes, refreshed when Contacts changes). Empty without access. Never prompts.
    func all() -> [Card] {
        let access = PeopleAccess.current
        guard access.canRead else { return [] }
        lock.lock()
        if let at = loadedAt, loadedWith == access, Date().timeIntervalSince(at) < maxAge {
            let snapshot = cards
            lock.unlock()
            return snapshot
        }
        lock.unlock()
        let fresh = Self.load()
        lock.lock()
        cards = fresh; loadedAt = Date(); loadedWith = access
        lock.unlock()
        return fresh
    }

    // MARK: Finding someone

    /// Finds who the person means: "Priya", "my daughter", "my daughter Priya", "Dr Shah", "the GP", "amma".
    /// Relations the person taught Kairos come first, then a contact saved under that very name, then relations on
    /// cards and (for the doctor) surgeries. More than one answer means "ask", never "guess".
    func find(_ said: String) -> Lookup { find(said, in: all()) }

    /// The matching itself, on any set of cards (tests pass their own).
    func find(_ said: String, in cards: [Card]) -> Lookup {
        let q = Self.queryTokens(said)
        guard !q.isEmpty, !cards.isEmpty else { return .none }
        let phrase = q.joined(separator: " ")
        let book = taught()

        // Exactly what they taught: "my eldest daughter", "the plumber".
        let exactTaught = taughtCards(keys: [phrase], book: book, in: cards)
        if !exactTaught.isEmpty { return Self.best(exactTaught.map { ($0, 0) }) }

        let inLaw = phrase.contains("in law")
        var groups = Set<String>()
        var nameTokens: [String] = []
        for token in q {
            if !inLaw, let g = Self.relationWords[token] { groups.formUnion(g) } else { nameTokens.append(token) }
        }
        let whole = nameMatches(q, in: cards)

        if !groups.isEmpty, !nameTokens.isEmpty {
            // "my daughter Priya", "Doctor Shah": the name decides; the relation only narrows it down.
            if whole.contains(where: { $0.1 == 0 }) { return Self.best(whole) }
            let named = nameMatches(nameTokens, in: cards)
            guard !named.isEmpty else { return .none }
            let related = Set(taughtCards(keys: groups, book: book, in: cards).map(\.id))
                .union(relationCards(groups, in: cards).map(\.id))
            let both = named.filter { related.contains($0.0.id) }
            return Self.best(both.isEmpty ? named : both)
        }
        if !groups.isEmpty {
            // "my daughter", "amma", "anna": what they taught Kairos and a contact saved under that word count the same,
            // so "Anna" the friend and "anna" the brother lead to a question, not a guess.
            let primary = taughtCards(keys: groups, book: book, in: cards).map { ($0, 0) }
                + whole.filter { $0.1 <= 1 }.map { ($0.0, 0) }
            if !primary.isEmpty { return Self.best(primary) }
            return Self.best(relationCards(groups, in: cards).map { ($0, 1) })
        }
        return Self.best(whole)
    }

    func card(id: String) -> Card? { all().first { $0.id == id } }

    /// Names only, no relation words or taught relations: for "Priya is my daughter", where "Priya" must be a name.
    func findByName(_ said: String) -> Lookup { findByName(said, in: all()) }

    func findByName(_ said: String, in cards: [Card]) -> Lookup {
        let q = Self.queryTokens(said)
        guard !q.isEmpty else { return .none }
        return Self.best(nameMatches(q, in: cards))
    }

    /// Name matches with a tier: 0 the whole name, 1 a first name, surname or every word, 2 a start ("Chris" for
    /// Christopher), 3 a near spelling. Tiers 2 and 3 are only ever offered as a question.
    private func nameMatches(_ tokens: [String], in cards: [Card]) -> [(Card, Int)] {
        let phrase = tokens.joined(separator: " ")
        guard !phrase.isEmpty else { return [] }
        let allowed = phrase.count >= 7 ? 2 : (phrase.count >= 4 ? 1 : 0)
        var out: [(Card, Int)] = []
        for card in cards {
            let names = [card.full, card.nick, card.org].filter { !$0.isEmpty }
            if names.contains(phrase) { out.append((card, 0)); continue }
            if tokens.count == 1 ? card.words.contains(phrase) : tokens.allSatisfy(card.words.contains) {
                out.append((card, 1)); continue
            }
            if tokens.count == 1, phrase.count >= 3,
               [card.given, card.nick].contains(where: { !$0.isEmpty && $0.hasPrefix(phrase) }) {
                out.append((card, 2)); continue
            }
            if allowed > 0, ([card.given, card.full, card.nick] + [card.org]).contains(where: {
                !$0.isEmpty && Self.levenshtein($0, phrase) <= allowed
            }) {
                out.append((card, 3))
            }
        }
        return out
    }

    /// Contacts linked to a relation: saved under the word itself ("Mum", "Amma"), named in a relation on a card
    /// ("daughter: Priya"), or a surgery / "Dr …" for the doctor.
    private func relationCards(_ groups: Set<String>, in cards: [Card]) -> [Card] {
        var out: [Card] = []
        var seen = Set<String>()
        func add(_ card: Card) { if seen.insert(card.id).inserted { out.append(card) } }
        for card in cards {
            if Self.savedAsRelation(card, groups) { add(card) }
            for relation in card.relations where !relation.groups.isDisjoint(with: groups) {
                for (match, tier) in nameMatches(Self.queryTokens(relation.name), in: cards) where tier <= 1 && match.id != card.id {
                    add(match)
                }
            }
            if groups.contains("doctor"), Self.looksMedical(card) { add(card) }
        }
        return out
    }

    private static func savedAsRelation(_ card: Card, _ groups: Set<String>) -> Bool {
        // The whole name is a relation word: "Mum", "Amma", "Nanna".
        for name in [card.full, card.nick, card.given] where !name.isEmpty {
            if let g = relationWords[name], !g.isDisjoint(with: groups) { return true }
        }
        // An English relation word inside the name: "Mum mobile", "Priya (daughter)". Not "Anna Smith".
        for word in card.words where plainRelationWords.contains(word) {
            if let g = relationWords[word], !g.isDisjoint(with: groups) { return true }
        }
        return false
    }

    private static func looksMedical(_ card: Card) -> Bool {
        let text = " " + [card.full, card.nick, card.org].joined(separator: " ") + " "
        let notGP = ["dental", "dentist", "vet", "vets", "veterinary", "optician", "opticians", "pharmacy", "chemist"]
        if notGP.contains(where: { text.contains(" \($0) ") }) { return false }
        let words = ["surgery", "medical", "clinic", "gp", "doctor", "doctors", "health centre", "health center", "practice"]
        return words.contains { text.contains(" \($0) ") }
    }

    private static func best(_ scored: [(Card, Int)]) -> Lookup {
        guard let top = scored.map(\.1).min() else { return .none }
        var seen = Set<String>()
        var picks: [Card] = []
        for (card, tier) in scored where tier == top && seen.insert(card.id).inserted { picks.append(card) }
        if picks.count == 1 { return .one(picks[0], close: top >= 2) }
        return .many(picks.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending })
    }

    // MARK: Relations the person taught Kairos

    struct Taught: Codable, Sendable, Hashable {
        var id: String
        var name: String
    }

    static let taughtKey = "kairos.people.relations"
    /// Relations that only ever have one person; teaching a new one replaces the old.
    private static let onlyOne: Set<String> = ["mother", "father", "wife", "husband"]

    func taught() -> [String: [Taught]] {
        guard let data = UserDefaults.standard.data(forKey: Self.taughtKey),
              let book = try? JSONDecoder().decode([String: [Taught]].self, from: data) else { return [:] }
        return book
    }

    /// Remembers "Priya is my daughter" under the words they used and under the relation itself.
    func teach(_ relation: String, _ card: Card) {
        let q = Self.queryTokens(relation)
        let phrase = q.joined(separator: " ")
        guard !phrase.isEmpty else { return }
        var keys: Set<String> = [phrase]
        if !phrase.contains("in law") {
            for token in q { if let g = Self.relationWords[token] { keys.formUnion(g) } }
        }
        var book = taught()
        for key in keys {
            var list = book[key] ?? []
            list.removeAll { $0.id == card.id }
            if Self.onlyOne.contains(key) || key == phrase && Self.relationWords[phrase] == nil { list.removeAll() }
            list.insert(Taught(id: card.id, name: card.displayName), at: 0)
            book[key] = Array(list.prefix(6))
        }
        if let data = try? JSONEncoder().encode(book) { UserDefaults.standard.set(data, forKey: Self.taughtKey) }
    }

    private func taughtCards(keys: Set<String>, book: [String: [Taught]], in cards: [Card]) -> [Card] {
        var out: [Card] = []
        var seen = Set<String>()
        for key in keys.sorted() {
            for entry in book[key] ?? [] {
                // A card's id can change after an iCloud re-sync; fall back to its exact name.
                let card = cards.first { $0.id == entry.id } ?? {
                    let same = cards.filter { $0.full == Self.queryTokens(entry.name).joined(separator: " ") }
                    return same.count == 1 ? same[0] : nil
                }()
                if let card, seen.insert(card.id).inserted { out.append(card) }
            }
        }
        return out
    }

    // MARK: Words

    /// Folded words, with "dr" read as "doctor".
    static func tokens(_ s: String) -> [String] {
        s.folded.split(separator: " ").map { $0 == "dr" ? "doctor" : String($0) }
    }

    private static let fillers: Set<String> = ["my", "the", "to", "for", "our", "dear", "please", "s", "a", "an", "on", "at",
                                               "her", "his", "their", "number", "phone", "mobile", "home", "work",
                                               "landline", "cell", "now", "contact", "called", "named", "with"]

    /// A name as said, without "my", "the", "'s", "mobile" and the like. Keeps the words when nothing else is left
    /// (a contact saved as "Home").
    static func queryTokens(_ s: String) -> [String] {
        let all = tokens(s)
        let kept = all.filter { !fillers.contains($0) }
        if !kept.isEmpty { return kept }
        return all.filter { !["my", "the", "to", "for", "our", "s", "a", "an"].contains($0) }
    }

    /// "Priya's mobile" -> .mobile. Only when there is a name besides the number type.
    static func kindNamed(in s: String) -> Phone.Kind? {
        let t = Set(tokens(s))
        guard !queryTokens(s).isEmpty, t.count > 1 else { return nil }
        if !t.isDisjoint(with: ["mobile", "cell", "iphone"]) { return .mobile }
        if !t.isDisjoint(with: ["home", "landline", "house"]) { return .home }
        if !t.isDisjoint(with: ["work", "office"]) { return .work }
        return nil
    }

    /// Relation words in the words and scripts people use, to the relation groups they mean.
    private static let relationTable: [(Set<String>, [String])] = [
        (["mother"], ["mum", "mom", "mother", "mam", "mummy", "mommy", "maa", "amma", "ammi", "mata", "mataji",
                      "అమ్మ", "माँ", "मां", "मम्मी", "माता"]),
        (["father"], ["dad", "daddy", "father", "papa", "nanna", "appa", "abba", "baba", "pitaji", "నాన్న", "पापा", "पिताजी"]),
        (["mother", "father"], ["parent", "parents"]),
        (["son"], ["son", "beta", "koduku", "కొడుకు", "बेटा"]),
        (["daughter"], ["daughter", "beti", "kuthuru", "కూతురు", "बेटी"]),
        (["son", "daughter"], ["child", "children", "kid", "kids"]),
        (["brother"], ["brother", "bro", "bhai", "bhaiya", "anna", "annayya", "thammudu", "అన్న", "అన్నయ్య", "తమ్ముడు", "भाई", "भैया"]),
        (["sister"], ["sister", "sis", "akka", "chelli", "didi", "behen", "bahen", "అక్క", "చెల్లి", "दीदी", "बहन"]),
        (["brother", "sister"], ["sibling", "siblings"]),
        (["wife"], ["wife", "missus", "patni", "bharya", "భార్య", "पत्नी"]),
        (["husband"], ["husband", "hubby", "pati", "bharta", "భర్త", "पति"]),
        (["partner"], ["partner"]),
        (["wife", "husband", "partner"], ["spouse"]),
        (["grandson"], ["grandson"]),
        (["granddaughter"], ["granddaughter"]),
        (["grandson", "granddaughter"], ["grandchild", "grandchildren", "grandkid", "grandkids"]),
        (["grandmother"], ["grandmother", "grandma", "granny", "gran", "nan", "nanny", "nani", "dadi", "ammamma", "nannamma"]),
        (["grandfather"], ["grandfather", "grandad", "granddad", "grandpa", "gramps", "thatha", "tatha", "తాత", "తాతయ్య", "दादा"]),
        (["grandmother", "grandfather"], ["grandparent", "grandparents"]),
        (["aunt"], ["aunt", "auntie", "aunty", "chachi", "mausi", "pinni", "atta"]),
        (["uncle"], ["uncle", "chacha", "babai", "mamayya"]),
        (["cousin"], ["cousin"]),
        (["niece"], ["niece"]),
        (["nephew"], ["nephew"]),
        (["friend"], ["friend"]),
        (["neighbour"], ["neighbour", "neighbor"]),
        (["carer"], ["carer", "caregiver", "careworker"]),
        (["doctor"], ["doctor", "doc", "gp", "physician", "డాక్టర్", "डॉक्टर"]),
    ]

    static let relationWords: [String: Set<String>] = {
        var lookup: [String: Set<String>] = [:]
        for (groups, words) in relationTable {
            for word in words {
                let key = word.folded
                guard !key.isEmpty else { continue }
                lookup[key, default: []].formUnion(groups)
            }
        }
        return lookup
    }()

    /// English relation words that are never someone's name, so they count inside a longer contact name.
    private static let plainRelationWords: Set<String> = [
        "mum", "mom", "mother", "mummy", "mommy", "dad", "daddy", "father", "son", "daughter", "brother", "sister",
        "wife", "husband", "grandma", "granny", "grandmother", "grandad", "granddad", "grandpa", "grandfather",
        "grandson", "granddaughter", "auntie", "aunty", "aunt", "uncle", "cousin", "niece", "nephew", "neighbour",
        "neighbor", "carer", "gp", "doctor",
    ]

    /// Groups for a relation label on a card ("_$!<Daughter>!$_", "younger sister"), never for an in-law.
    static func relationGroups(label: String?) -> Set<String> {
        guard let label, !label.isEmpty else { return [] }
        var names = [CNLabeledValue<CNContactRelation>.localizedString(forLabel: label)]
        if label.hasPrefix("_$!<"), label.hasSuffix(">!$_") { names.append(String(label.dropFirst(4).dropLast(4))) }
        for name in names {
            let t = tokens(name)
            let joined = t.joined(separator: " ")
            if joined.contains("law") || joined.isEmpty { continue }
            if let g = relationWords[joined] { return g }
            if let last = t.last, let g = relationWords[last] { return g }
        }
        return []
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        if abs(x.count - y.count) > 2 { return 3 }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }

    // MARK: Phone numbers

    /// The phone's region ("GB"), which decides what "07700 900123" means.
    static var region: String? { Locale.current.region?.identifier }
    static var isUK: Bool { ["GB", "JE", "GG", "IM"].contains(region ?? "GB") }

    private static func callingCode(_ region: String?) -> String? {
        switch region {
        case "GB", "JE", "GG", "IM": return "44"
        case "IE": return "353"
        case "IN": return "91"
        case "US", "CA": return "1"
        case "AU": return "61"
        default: return nil
        }
    }

    /// 0-9 only; digits in other scripts (Telugu, Devanagari) become 0-9.
    static func asciiDigits(_ s: String) -> String {
        String(s.compactMap { c -> Character? in
            guard c.isNumber, let v = c.wholeNumberValue, (0...9).contains(v) else { return nil }
            return Character(String(v))
        })
    }

    /// "+447700900123" from "07700 900123", "+44 (0)7700 900123", "0044 7700…" or "447700900123" (UK phone).
    /// Nil when the country can't be known; then the number is dialled as written.
    static func normalise(_ raw: String, region: String? = PeopleDirectory.region) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let plus = text.hasPrefix("+") || text.hasPrefix("＋")
        if plus { text = text.replacingOccurrences(of: "(0)", with: "") }
        let digits = asciiDigits(text)
        guard digits.count >= 7 else { return nil }
        var e164: String
        if plus {
            e164 = digits
        } else if digits.hasPrefix("00") {
            e164 = String(digits.dropFirst(2))
        } else if let cc = callingCode(region) {
            if cc == "1" {
                if digits.count == 10 { e164 = "1" + digits }
                else if digits.count == 11, digits.hasPrefix("1") { e164 = digits }
                else { return nil }
            } else if digits.hasPrefix("0") {
                e164 = cc + digits.dropFirst()
            } else if cc == "91", digits.count == 10, let lead = digits.first, "6789".contains(lead) {
                e164 = "91" + digits
            } else if digits.hasPrefix(cc), digits.count >= 10 {
                e164 = digits
            } else {
                return nil
            }
        } else {
            return nil
        }
        // "+44 07700…": the trunk 0 never follows the country code.
        for cc in ["44", "91", "353", "61"] where e164.hasPrefix(cc + "0") {
            e164 = cc + e164.dropFirst(cc.count + 1)
            break
        }
        if e164.hasPrefix("44") {
            let national = e164.dropFirst(2)
            guard (9...10).contains(national.count) else { return nil }
            if national.first == "7", national.count != 10 { return nil }  // a UK mobile is 07 + 9 digits
        }
        guard (7...15).contains(e164.count) else { return nil }
        return "+" + e164
    }

    /// The digits as saved, keeping a leading "+". Pauses, * and # are dropped (iOS won't dial them from a link).
    static func dialable(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.hasPrefix("+") ? "+" : "") + asciiDigits(trimmed)
    }

    /// "+447700900123" -> "07700 900123", "+442079460000" -> "020 7946 0000": easy to check by eye on the card.
    static func shown(_ dial: String) -> String {
        if dial.hasPrefix("+44") {
            let n = Array(dial.dropFirst(3))
            if n.count == 10 {
                if n[0] == "2" { return "0" + String(n[0..<2]) + " " + String(n[2..<6]) + " " + String(n[6...]) }
                return "0" + String(n[0..<4]) + " " + String(n[4...])
            }
        }
        return dial
    }

    /// Number type from the card's label; nil for fax and pager, which reach no one.
    static func kind(label: String?, e164: String?) -> Phone.Kind? {
        let l = label ?? ""
        if l == CNLabelPhoneNumberMobile || l == CNLabelPhoneNumberiPhone { return .mobile }
        if l == CNLabelHome || l == CNLabelPhoneNumberMain { return .home }
        if l == CNLabelWork { return .work }
        if [CNLabelPhoneNumberHomeFax, CNLabelPhoneNumberWorkFax, CNLabelPhoneNumberOtherFax, CNLabelPhoneNumberPager].contains(l) {
            return nil
        }
        let words = Set(tokens(l.isEmpty ? "" : CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: l)))
            .union(tokens(l))
        if !words.isDisjoint(with: ["fax", "pager"]) { return nil }
        if !words.isDisjoint(with: ["mobile", "cell", "iphone", "cellular", "personal"]) { return .mobile }
        if !words.isDisjoint(with: ["home", "landline", "house"]) { return .home }
        if !words.isDisjoint(with: ["work", "office", "business"]) { return .work }
        if let e164, e164.hasPrefix("+447"), e164.count == 13 { return .mobile }
        return .other
    }

    // MARK: Loading

    private static func load() -> [Card] {
        let keys: [CNKeyDescriptor] = [CNContactNamePrefixKey, CNContactGivenNameKey, CNContactFamilyNameKey,
                                       CNContactMiddleNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
                                       CNContactPhoneNumbersKey, CNContactRelationsKey].map { $0 as CNKeyDescriptor }
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true
        let region = Self.region
        var out: [Card] = []
        var byName: [String: [Int]] = [:]  // full name -> indexes in `out`
        do {
            try CNContactStore().enumerateContacts(with: request) { contact, _ in
                guard let card = makeCard(contact, region: region) else { return }
                // The same person saved twice (same name, a shared number, or one card with no number): one card.
                let numbers = Set(card.phones.map(\.dial))
                if let i = byName[card.full]?.first(where: { i in
                    let earlier = Set(out[i].phones.map(\.dial))
                    return earlier.isEmpty || numbers.isEmpty || !earlier.isDisjoint(with: numbers)
                }) {
                    for phone in card.phones where !out[i].phones.contains(where: { $0.dial == phone.dial }) {
                        out[i].phones.append(phone)
                    }
                    out[i].relations += card.relations
                    return
                }
                byName[card.full, default: []].append(out.count)
                out.append(card)
            }
        } catch {
            return []
        }
        return out
    }

    static func makeCard(_ c: CNContact, region: String?) -> Card? {
        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let given = clean(c.givenName), family = clean(c.familyName), middle = clean(c.middleName)
        let prefix = c.isKeyAvailable(CNContactNamePrefixKey) ? clean(c.namePrefix) : ""  // "Dr", "Mrs"
        let nick = clean(c.nickname), org = clean(c.organizationName)
        let fullName = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
        let display = !fullName.isEmpty ? fullName : (!nick.isEmpty ? nick : org)
        guard !display.isEmpty else { return nil }

        var phones: [Phone] = []
        for entry in c.phoneNumbers {
            let raw = entry.value.stringValue
            let e164 = normalise(raw, region: region)
            let dial = e164 ?? dialable(raw)
            guard dial.digitsOnly.count >= 3, let kind = kind(label: entry.label, e164: e164),
                  !phones.contains(where: { $0.dial == dial }) else { continue }
            phones.append(Phone(kind: kind, dial: dial, e164: e164))
        }
        let relations: [Relation] = c.contactRelations.compactMap { entry in
            let name = clean(entry.value.name)
            let groups = relationGroups(label: entry.label)
            return name.isEmpty || groups.isEmpty ? nil : Relation(groups: groups, name: name)
        }
        func folded(_ s: String) -> String { tokens(s).joined(separator: " ") }
        let words = Set([prefix, given, middle, family, nick, org].flatMap { tokens($0) })
        return Card(id: c.identifier, displayName: display, spokenName: given.isEmpty ? display : given,
                    phones: phones, relations: relations,
                    full: folded(fullName.isEmpty ? display : fullName), given: folded(given), family: folded(family),
                    nick: folded(nick), org: folded(org), words: words)
    }
}
