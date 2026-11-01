import Combine
import Contacts
import ContactsUI
import Foundation
import os
import SwiftUI
import UIKit

// Kairos People: the people the person writes to, kept ONLY on this iPhone.
// The server sees a person's `ref`, alias, relation and language (BridgeRecipient), never a phone number or email.
// Numbers live in Application Support (not Documents, so not in the Files app), protected until the first unlock,
// and excluded from iCloud / computer backups.

private let peopleLog = Logger(subsystem: "uk.oxhack.tempo", category: "bridge.people")

/// One number from a contact card with its label, so "Mobile: 07700 900123" can't be mistaken for the landline.
struct LabeledPhone: Hashable {
    let label: String    // as Contacts shows it ("mobile", "home", "iPhone"); "" when the card has none
    let number: String   // exactly as written on the card

    /// "Mobile: 07700 900123", or the number alone when there is no label.
    var shown: String {
        guard let first = label.first else { return number }
        // "mobile" -> "Mobile", but "iPhone" stays "iPhone".
        let keep = first.isUppercase || label.dropFirst().first?.isUppercase == true
        return (keep ? label : first.uppercased() + label.dropFirst()) + ": " + number
    }

    /// WhatsApp, texts and Telegram need a mobile; a landline reaches no one, or someone else.
    var isMobile: Bool { Self.mobileLabels.contains(label.lowercased()) }

    private static let mobileLabels: Set<String> = {
        var names: Set<String> = ["mobile", "iphone", "cell", "mobile phone", "cell phone"]
        for key in [CNLabelPhoneNumberMobile, CNLabelPhoneNumberiPhone] {
            names.insert(CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: key).lowercased())
        }
        return names
    }()
}

// MARK: - the store

@MainActor
final class PeopleStore: ObservableObject {
    @Published private(set) var people: [KairosPerson] = []

    /// The store the app is using. An editor opened without `existing:` (Write for me's picked-contact sheet) still
    /// needs everyone's names to warn about "Amma" next to "Anna", so it falls back to this one.
    private(set) static weak var active: PeopleStore?

    private let fileURL: URL?          // nil: in memory only (previews, tests)
    private var readFailed = false     // a file exists but couldn't be read yet; never overwrite it with an empty list
    private var needsRewrite = false   // people were rescued from a damaged file; write them back straight away
    private var unlockWatch: AnyCancellable?

    /// The on-disk format. A version number lets a later build migrate without guessing.
    private struct Stored: Codable {
        var version: Int
        var people: [KairosPerson]
    }

    /// Reads each person on its own, so one entry a different build wrote can't take everyone else with it.
    private struct LenientStored: Decodable {
        var people: [KairosPerson] = []
        private enum CodingKeys: String, CodingKey { case people }
        private struct Skip: Decodable { init(from decoder: Decoder) throws {} }   // accepts any value

        init(from decoder: Decoder) throws {
            var list = try decoder.container(keyedBy: CodingKeys.self).nestedUnkeyedContainer(forKey: .people)
            while !list.isAtEnd {
                let before = list.currentIndex
                if let person = try? list.decode(KairosPerson.self) { people.append(person) } else { _ = try? list.decode(Skip.self) }
                if list.currentIndex == before { break }   // never spin on a value that can't even be skipped
            }
        }
    }

    init(inMemory: Bool = false) {
        fileURL = inMemory ? nil : Self.storeURL()
        load()
        if needsRewrite { save() }
        Self.active = self
        // After a restart the file stays locked until the first unlock. Read it again then, instead of starting empty.
        unlockWatch = NotificationCenter.default
            .publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.readFailed else { return }
                    if self.recoverIfNeeded() { self.save() }
                }
            }
    }

    nonisolated static func storeURL() -> URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true) else { return nil }
        return base.appendingPathComponent("Kairos", isDirectory: true).appendingPathComponent("people.json", isDirectory: false)
    }

    func person(ref: String) -> KairosPerson? { people.first { $0.ref == ref } }

    /// Adds a person (or replaces the one with the same ref, so a double tap on Save can't make two).
    func add(_ person: KairosPerson) {
        upsert(person)
        save()
    }

    func update(_ person: KairosPerson) {
        upsert(person)
        save()
    }

    func delete(ref: String) {
        people.removeAll { $0.ref == ref }
        save()
        // "Kairos will forget their number" must cover the aside copy of a damaged file too. It can't be edited
        // (it didn't read), only removed.
        if let url = fileURL { try? FileManager.default.removeItem(at: Self.asideURL(for: url)) }
    }

    /// Who did they mean? Only `.exact` may go ahead without asking (see `match(_:in:)`).
    func match(_ spoken: String) -> PersonMatch { Self.match(spoken, in: people) }

    private func upsert(_ person: KairosPerson) {
        if let i = people.firstIndex(where: { $0.ref == person.ref }) { people[i] = person } else { people.append(person) }
    }

    // MARK: file

    private func load() {
        guard let url = fileURL else { readFailed = false; return }
        guard FileManager.default.fileExists(atPath: url.path) else { people = []; readFailed = false; return }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Most likely the phone restarted and hasn't been unlocked yet. Keep the file; try again later.
            readFailed = true
            peopleLog.error("people file not readable yet")
            return
        }
        do {
            people = try JSONDecoder().decode(Stored.self, from: data).people
            readFailed = false
        } catch {
            // A damaged file must not silently take everyone's numbers with it: keep every person that still reads,
            // and move the file aside (still on this phone, still out of backups) until someone is removed.
            let rescued = (try? JSONDecoder().decode(LenientStored.self, from: data))?.people ?? []
            let aside = Self.asideURL(for: url)
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            try? Self.excludeFromBackup(aside)
            people = rescued
            readFailed = false
            needsRewrite = !rescued.isEmpty
            peopleLog.error("people file damaged; moved aside, rescued \(rescued.count, privacy: .public)")
        }
    }

    private nonisolated static func asideURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("people.unreadable.json")
    }

    /// If an earlier read failed, read the file again and keep anything added or changed meanwhile.
    /// Returns false while the file still can't be read.
    private func recoverIfNeeded() -> Bool {
        guard readFailed else { return true }
        let pending = people
        load()
        guard !readFailed else { return false }
        pending.forEach(upsert)
        return true
    }

    private func save() {
        guard let url = fileURL else { return }
        guard recoverIfNeeded() else {
            peopleLog.error("people file locked; change kept in memory until unlock")
            return
        }
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            let data = try JSONEncoder().encode(Stored(version: 1, people: people))
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            // Numbers must not reach iCloud or computer backups. Set after every write: an atomic write replaces the file.
            try Self.excludeFromBackup(dir)
            try Self.excludeFromBackup(url)
            needsRewrite = false
            peopleLog.info("people saved (\(self.people.count, privacy: .public))")   // a count only, never names or numbers
        } catch {
            peopleLog.error("people save failed")
        }
    }

    private nonisolated static func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}

// MARK: - matching a spoken name

/// Relation words, in the words and scripts people actually use. A match through a relation word only ever leads to a
/// question ("Did you mean Amma?"), and it stops a same-name match going ahead alone, because "anna" is a brother in
/// Telugu and a name in English.
private let peopleRelationSynonyms: [String: [String]] = [
    "mother": ["mum", "mom", "mother", "amma", "maa", "ammi", "mummy", "mommy", "mam", "అమ్మ", "माँ", "मां", "अम्मी", "मम्मी"],
    "father": ["dad", "father", "nanna", "appa", "abba", "papa", "daddy", "నాన్న", "पापा", "पिताजी", "अब्बा"],
    "son": ["son", "కొడుకు", "बेटा"],
    "daughter": ["daughter", "beti", "కూతురు", "बेटी"],
    "brother": ["brother", "anna", "bhai", "అన్న", "అన్నయ్య", "తమ్ముడు", "भाई", "भैया"],
    "sister": ["sister", "akka", "didi", "అక్క", "చెల్లి", "दीदी", "बहन"],
    "wife": ["wife", "భార్య", "पत्नी"],
    "husband": ["husband", "భర్త", "पति"],
    "doctor": ["doctor", "gp", "డాక్టర్", "डॉक्टर"],   // "dr" is rewritten to "doctor" by normaliseName
]

private let peopleRelationLookup: [String: String] = {
    var lookup: [String: String] = [:]
    for (group, words) in peopleRelationSynonyms { for word in words { lookup[word] = group } }
    return lookup
}()

/// Words people put in front of a name when they speak: "to my mum", "for the doctor".
private let peopleLeadingFillers: Set<String> = ["my", "to", "for", "the"]

extension PeopleStore {
    /// Lowercase, fold accents (Siân = sian), drop punctuation and leading "my / to / for / the", "dr" = "doctor".
    /// Telugu and Devanagari keep their exact letters (only trimmed), so every vowel sign and virama counts.
    nonisolated static func normaliseName(_ raw: String) -> String {
        let lowered = raw.precomposedStringWithCanonicalMapping.lowercased()
        let indic = lowered.unicodeScalars.contains { (0x0900...0x0DFF).contains($0.value) }
        var words: [String]
        if indic {
            words = lowered.components(separatedBy: .whitespacesAndNewlines)
                .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols)) }
                .filter { !$0.isEmpty }
        } else {
            let folded = lowered.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            words = folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .map { $0 == "dr" ? "doctor" : $0 }
        }
        while words.count > 1, let first = words.first, peopleLeadingFillers.contains(first) { words.removeFirst() }
        return words.joined(separator: " ")
    }

    /// EXACT: one person's normalised alias is the same AND nobody else is close (a near spelling within 2 letters, a
    /// shared word, or their relation). Speech-to-text mixes up m and n, so "Anna" heard for "Amma" must ask, never
    /// send. AMBIGUOUS: the same-name person first, then the closest others (near spelling, shared start of 3+ letters,
    /// shared word, relation word); at most 4. Anything not exact means "ask".
    nonisolated static func match(_ spoken: String, in people: [KairosPerson]) -> PersonMatch {
        let said = normaliseName(spoken)
        guard !said.isEmpty else { return .none }
        let saidGroups = relationGroups(of: said)
        var scored: [(person: KairosPerson, score: Double)] = []
        for person in people {
            if let score = closeness(said: said, saidGroups: saidGroups, to: person) { scored.append((person, score)) }
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score < b.score }
            return a.person.alias.localizedCaseInsensitiveCompare(b.person.alias) == .orderedAscending
        }

        let exact = people.filter { normaliseName($0.alias) == said }
        if exact.count == 1 {
            let named = exact[0]
            // 2 or less: Levenshtein 1-2, a shared word (1) or a relation (0.5). A shared start alone (2.1+) isn't close.
            let rivals = scored.filter { $0.person.ref != named.ref && $0.score <= 2 }.map { $0.person }
            return rivals.isEmpty ? .exact(named) : .ambiguous([named] + rivals.prefix(3))
        }
        let top: [KairosPerson] = scored.prefix(4).map { $0.person }
        return top.isEmpty ? .none : .ambiguous(top)
    }

    /// The other person whose alias is the same as, or within 2 letters of, `alias` (closest first). The editor warns
    /// about these before saving, by the same rule that makes `match` ask.
    nonisolated static func nameClash(_ alias: String, among others: [KairosPerson]) -> (person: KairosPerson, distance: Int)? {
        let mine = normaliseName(alias)
        guard !mine.isEmpty else { return nil }
        var best: (person: KairosPerson, distance: Int)?
        for other in others {
            let theirs = normaliseName(other.alias)
            guard !theirs.isEmpty else { continue }
            let distance = levenshtein(mine, theirs)
            if distance <= 2, distance < (best?.distance ?? .max) { best = (other, distance) }
        }
        return best
    }

    /// Lower is closer; nil means "not this person". 0 only happens when two people share an alias.
    private nonisolated static func closeness(said: String, saidGroups: Set<String>, to person: KairosPerson) -> Double? {
        let alias = normaliseName(person.alias)
        var best: Double?
        func consider(_ score: Double) { best = min(best ?? score, score) }

        if !alias.isEmpty {
            if alias == said { consider(0) }
            let distance = levenshtein(said, alias)
            if distance <= 2 { consider(Double(distance)) }
            let shared = commonPrefixLength(said, alias)
            if shared >= 3 { consider(3 - Double(min(shared, 9)) / 10) }   // 2.1 to 2.7: longer shared start, closer
            // "Shah" for "Dr Shah", "son Ravi" for "Ravi".
            let aliasWords = alias.split(separator: " ").map(String.init)
            let saidWords = said.split(separator: " ").map(String.init)
            if (aliasWords.count > 1 && aliasWords.contains(said)) || (saidWords.count > 1 && saidWords.contains(alias)) {
                consider(1)
            }
        }
        // "Mum" asks about whoever is their mother, ahead of near spellings: that is almost always who they mean.
        if !saidGroups.isEmpty {
            let relation = normaliseName(person.relation ?? "")
            let theirs = relationGroups(of: alias).union(relationGroups(of: relation))
            if !theirs.isDisjoint(with: saidGroups) { consider(0.5) }
        }
        return best
    }

    /// Also used by the in-call Bridge to check that the person themselves named the recipient.
    nonisolated static func relationGroups(of text: String) -> Set<String> {
        guard !text.isEmpty else { return [] }
        var groups = Set<String>()
        if let g = peopleRelationLookup[text] { groups.insert(g) }
        for word in text.split(separator: " ") {
            if let g = peopleRelationLookup[String(word)] { groups.insert(g) }
        }
        return groups
    }

    private nonisolated static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        zip(a.unicodeScalars, b.unicodeScalars).prefix { $0 == $1 }.count
    }

    /// Edit distance over Unicode scalars, so a Telugu virama or vowel sign counts as one edit.
    nonisolated static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
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

    // MARK: phone numbers

    /// "+" and digits in international form, or nil when it can't be sure. `defaultCountryCode` is the country the
    /// person CHOSE for a number written without + or 00 ("44": "07700 900123" -> "+447700900123"). With nil, such a
    /// number is refused: "07788 123456" is a UK mobile and an Indian one, and guessing wrong sends someone's words to a
    /// stranger.
    nonisolated static func normalisePhone(_ raw: String, defaultCountryCode: String? = nil) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let international = text.hasPrefix("+") || text.hasPrefix("＋")
        // "+44 (0)7700 900123": the (0) is only dialled from inside the country.
        if international { text = text.replacingOccurrences(of: "(0)", with: "") }
        let digits = phoneDigits(text)
        guard digits.count >= 7 else { return nil }
        let country = (defaultCountryCode ?? "").filter { $0.isASCII && $0.isNumber }

        var e164: String
        if international {
            e164 = digits
        } else if digits.hasPrefix("00") {
            e164 = String(digits.dropFirst(2))
        } else if country.isEmpty {
            return nil      // which country? Ask for the + rather than guess.
        } else if digits.hasPrefix("0") {
            // A national number: drop the trunk 0 and add the chosen country's code.
            if country == "91" && digits.count != 11 { return nil }   // India: 0 + 10 digits
            e164 = country + digits.dropFirst()
        } else if country == "91", digits.count == 10, let lead = digits.first, "6789".contains(lead) {
            e164 = "91" + digits   // an Indian mobile is usually written as its 10 digits alone
        } else if digits.hasPrefix(country), digits.count >= 10 {
            e164 = digits   // "447700900123": international digits without the "+"
        } else {
            return nil      // "7700900123" as UK: missing its 0? Ask rather than guess.
        }
        // "+44 07700…", "+91 098…": the trunk 0 never follows the country code.
        if e164.hasPrefix("440") { e164 = "44" + e164.dropFirst(3) }
        if e164.hasPrefix("910") { e164 = "91" + e164.dropFirst(3) }
        if e164.hasPrefix("44") {
            // UK: only 01/02 (landline), 03 and 07 (mobile) can take a message; 08/09 are premium or non-geographic.
            let national = e164.dropFirst(2)
            guard let lead = national.first, "1237".contains(lead), (9...10).contains(national.count) else { return nil }
            if lead == "7" && national.count != 10 { return nil }   // a UK mobile is always 07 + 9 digits
        }
        if e164.hasPrefix("91") && e164.count != 12 { return nil }  // India: 91 + 10 digits
        guard (7...15).contains(e164.count) else { return nil }      // E.164 is at most 15 digits
        return "+" + e164
    }

    /// Digits in any script (Contacts can hold Devanagari or Telugu digits) as 0-9; everything else is formatting.
    nonisolated static func phoneDigits(_ text: String) -> String {
        var digits = ""
        for scalar in text.unicodeScalars where scalar.properties.numericType == .decimal {
            if let value = scalar.properties.numericValue { digits += String(Int(value)) }
        }
        return digits
    }

    /// True when the number already says its country (+44…, 0044…), so there is no country to ask about.
    nonisolated static func phoneHasCountryCode(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("+") || text.hasPrefix("＋") || phoneDigits(text).hasPrefix("00")
    }

    /// An alias or relation goes to the server and the writing model, so a number or email in it would break
    /// "numbers and emails never leave the phone".
    nonisolated static func looksLikeContactDetail(_ text: String) -> Bool {
        text.contains("@") || text.contains("＠") || phoneDigits(text).count >= 7
    }

    /// Where the number is, said in words, so a wrong country stands out: "UK mobile", "UK", "India"; nil otherwise.
    nonisolated static func phonePlace(_ e164: String) -> String? {
        if e164.hasPrefix("+447") { return "UK mobile" }
        if e164.hasPrefix("+44") { return "UK" }
        if e164.hasPrefix("+91") { return "India" }
        return nil
    }

    /// "+447700900123" -> "+44 7700 900123", "+919848012345" -> "+91 98480 12345", easier to check by eye.
    nonisolated static func formattedPhone(_ e164: String) -> String {
        let national = Array(e164.dropFirst(3))
        if e164.hasPrefix("+44"), national.count == 10 {
            return "+44 " + String(national[0..<4]) + " " + String(national[4...])
        }
        if e164.hasPrefix("+91"), national.count == 10 {
            return "+91 " + String(national[0..<5]) + " " + String(national[5...])
        }
        return e164
    }
}

/// The country of a number written without + or 00. Always shown and chosen, never silently assumed.
enum PhoneCountry: String, CaseIterable, Identifiable {
    case unitedKingdom, india, other
    var id: String { rawValue }

    /// nil: the number itself must start with + and the country code.
    var callingCode: String? {
        switch self {
        case .unitedKingdom: return "44"
        case .india: return "91"
        case .other: return nil
        }
    }

    var title: String {
        switch self {
        case .unitedKingdom: return "United Kingdom"
        case .india: return "India"
        case .other: return "Another country"
        }
    }

    var detail: String {
        switch self {
        case .unitedKingdom: return "+44"
        case .india: return "+91"
        case .other: return "Type + and the country code"
        }
    }

    /// Only a starting point, from the phone's own region; the choice stays on screen to change.
    static var fromPhoneSettings: PhoneCountry {
        switch Locale.current.region?.identifier {
        case "GB", "JE", "GG", "IM": return .unitedKingdom   // the Channel Islands and Isle of Man use +44 too
        case "IN": return .india
        default: return .other
        }
    }
}

// MARK: - the system contact picker

/// Apple's contact picker. It runs outside the app, so Kairos needs no Contacts permission and only ever gets the one
/// person that was tapped. Present it in a `.sheet` and close the sheet in both callbacks.
/// The picker is a remote (out-of-process) view controller that can show as a blank sheet when it is the sheet's
/// root, so the sheet holds a plain `Host` that presents it. Each callback comes once, after the picker has closed
/// itself, so the sheet closing at the same moment can't collide with it.
struct ContactPicker: UIViewControllerRepresentable {
    /// `name` is what they're likely called (nickname, else first name, else full name or company).
    let onPick: (_ name: String, _ phones: [LabeledPhone], _ emails: [String]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> Host {
        let host = Host()
        host.coordinator = context.coordinator
        context.coordinator.host = host
        return host
    }

    func updateUIViewController(_ host: Host, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Host: UIViewController {
        weak var coordinator: Coordinator?
        private var presentedPicker = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = UIColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1)
            // Only seen if the picker fails to open or is closed without telling us: never leave them on a blank sheet.
            var look = UIButton.Configuration.filled()
            look.title = "Close"
            look.baseBackgroundColor = UIColor(red: 0.18, green: 0.44, blue: 0.37, alpha: 1)
            look.baseForegroundColor = .white
            look.cornerStyle = .large
            look.contentInsets = NSDirectionalEdgeInsets(top: 20, leading: 48, bottom: 20, trailing: 48)
            look.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = .systemFont(ofSize: 26, weight: .bold)
                return attributes
            }
            let close = UIButton(configuration: look, primaryAction: UIAction { [weak self] _ in self?.coordinator?.cancel() })
            close.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(close)
            NSLayoutConstraint.activate([
                close.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                close.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let coordinator else { return }
            guard !presentedPicker else {
                // Back on screen with the picker gone: if it never called back, treat it as Cancel. Wait a moment so
                // a late callback still wins.
                guard presentedViewController == nil else { return }
                Task { @MainActor [weak coordinator] in
                    try? await Task.sleep(for: .milliseconds(600))
                    coordinator?.cancel()
                }
                return
            }
            presentedPicker = true
            let picker = CNContactPickerViewController()
            picker.delegate = coordinator
            picker.displayedPropertyKeys = [CNContactPhoneNumbersKey, CNContactEmailAddressesKey]
            // Grey out people Kairos couldn't write to anyway.
            picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0 OR emailAddresses.@count > 0")
            // Full screen: bigger, and no half-height card to swipe away by accident.
            picker.modalPresentationStyle = .fullScreen
            present(picker, animated: true)
        }

        /// Runs `answer` once the picker has finished closing (at most 2 s later).
        func afterPickerCloses(_ answer: @escaping @MainActor () -> Void) {
            Task { @MainActor [weak self] in
                var waited = 0
                while self?.presentedViewController != nil, waited < 40 {
                    try? await Task.sleep(for: .milliseconds(50))
                    waited += 1
                }
                answer()
            }
        }
    }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        var parent: ContactPicker
        weak var host: Host?
        private var answered = false
        init(parent: ContactPicker) { self.parent = parent }

        // Only the whole-contact callback is implemented, so one tap on a name picks them (no second detail screen).
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            let (name, phones, emails) = Self.details(of: contact)
            answer { self.parent.onPick(name, phones, emails) }
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) { cancel() }

        func cancel() { answer { self.parent.onCancel() } }

        /// Exactly one answer per sheet, given after the picker has gone. UIKit calls the delegate on the main thread.
        private func answer(_ reply: @escaping @MainActor () -> Void) {
            guard !answered else { return }
            answered = true
            MainActor.assumeIsolated {
                if let host { host.afterPickerCloses(reply) } else { reply() }
            }
        }

        /// The picker hands back a snapshot; reading a key it didn't include would crash, so check each one.
        private static func details(of contact: CNContact) -> (String, [LabeledPhone], [String]) {
            func text(_ key: String, _ value: (CNContact) -> String) -> String {
                contact.isKeyAvailable(key) ? value(contact).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            }
            let nickname = text(CNContactNicknameKey) { $0.nickname }
            let given = text(CNContactGivenNameKey) { $0.givenName }
            let family = text(CNContactFamilyNameKey) { $0.familyName }
            let company = text(CNContactOrganizationNameKey) { $0.organizationName }
            let full = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
            let name = [nickname, given, full, company].first { !$0.isEmpty } ?? ""

            let phones: [LabeledPhone] = contact.isKeyAvailable(CNContactPhoneNumbersKey)
                ? contact.phoneNumbers.compactMap { entry in
                    let number = entry.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !number.isEmpty else { return nil }
                    let label = entry.label.map { CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: $0) } ?? ""
                    return LabeledPhone(label: label, number: number)
                } : []
            let emails = contact.isKeyAvailable(CNContactEmailAddressesKey)
                ? contact.emailAddresses.map { ($0.value as String).trimmingCharacters(in: .whitespacesAndNewlines) } : []
            return (name, phones, emails.filter { !$0.isEmpty })
        }
    }
}

// MARK: - look

/// The app's calm palette (ContentView), plus fixed text colours so nothing turns white-on-white in dark mode.
private enum PeopleLook {
    static let background = Color(red: 0.96, green: 0.95, blue: 0.92)
    static let green = Color(red: 0.18, green: 0.44, blue: 0.37)
    static let ink = Color(red: 0.11, green: 0.11, blue: 0.10)
    static let softInk = Color(red: 0.25, green: 0.25, blue: 0.23)
    static let placeholder = Color(red: 0.42, green: 0.42, blue: 0.40)
    static let border = Color(red: 0.78, green: 0.77, blue: 0.73)
    static let grey = Color(red: 0.85, green: 0.85, blue: 0.82)
    static let problemInk = Color(red: 0.62, green: 0.13, blue: 0.10)
    static let problemFill = Color(red: 0.99, green: 0.91, blue: 0.90)

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Generic symbols, not brand logos.
    static func icon(_ channel: BridgeChannel) -> String {
        switch channel {
        case .whatsapp: return "phone.bubble.fill"
        case .sms: return "message.fill"
        case .email: return "envelope.fill"
        case .telegram: return "paperplane.fill"
        case .signal: return "bubble.left.and.bubble.right.fill"
        }
    }
}

// MARK: - add or change a person

/// Add or change one person. Present it in a `.sheet`; it closes itself after Save, Cancel or Remove.
/// It never writes to PeopleStore itself (the caller saves in `onSave`), so the Write for me flow can use it for a
/// brand-new person too. It only reads everyone's names, to warn before two names are a letter or two apart.
struct PersonEditor: View {
    private enum Field: Hashable { case alias, relation, phone, email }

    /// What can be chosen as "the language they read". Native names first, so the person recognises their own.
    nonisolated static let languages: [(code: String, label: String, detail: String?, spoken: String)] = [
        ("en-GB", "English", nil, "English"),
        ("te-Telu", "తెలుగు", "Telugu, in Telugu letters", "Telugu, in Telugu letters"),
        ("te-Latn", "Telugu in English letters", "Like: Ela unnaru?", "Telugu in English letters"),
        ("hi-Deva", "हिन्दी", "Hindi", "Hindi"),
        ("cy", "Cymraeg", "Welsh", "Welsh"),
    ]

    /// A plain name for a language code, e.g. for "Writing in Telugu" on another screen.
    nonisolated static func languageName(_ code: String) -> String {
        languages.first { $0.code == code }?.spoken ?? code
    }

    nonisolated static func toneName(_ tone: BridgeTone) -> String {
        switch tone {
        case .warm: return "Warm"
        case .polite: return "Polite"
        case .formal: return "Formal"
        case .brief: return "Brief"
        case .keepMyWords: return "Keep my words"
        }
    }

    private static func toneDetail(_ tone: BridgeTone) -> String {
        switch tone {
        case .warm: return "Friendly and kind"
        case .polite: return "Clear and courteous"
        case .formal: return "For a doctor, bank or council"
        case .brief: return "Short and to the point"
        case .keepMyWords: return "Only fixes small mistakes"
        }
    }

    private static func channelDetail(_ channel: BridgeChannel) -> String? {
        switch channel {
        case .whatsapp, .telegram: return nil
        case .sms: return "A text message"
        case .email: return "An email"
        case .signal: return "Signal opens and you choose them there"
        }
    }

    private static let relationChoices = ["mother", "father", "son", "daughter", "brother", "sister",
                                          "wife", "husband", "friend", "doctor"]

    /// What has been typed, to know whether leaving would lose anything.
    private struct Snapshot: Equatable {
        var alias = "", relation = "", channel = BridgeChannel.whatsapp, tone = BridgeTone.warm
        var language = "en-GB", phone = "", email = ""
    }

    @Environment(\.dismiss) private var dismiss
    private let ref: String?
    private let isNew: Bool
    private let initial: Snapshot
    private let existing: [KairosPerson]?
    private let onSave: (KairosPerson) -> Void
    private let onCancel: () -> Void
    private let onDelete: (() -> Void)?

    @State private var alias: String
    @State private var relation: String
    @State private var channel: BridgeChannel
    @State private var tone: BridgeTone
    @State private var language: String
    @State private var phone: String
    @State private var email: String
    @State private var country: PhoneCountry
    @State private var phoneChoices: [LabeledPhone]
    @State private var emailChoices: [String]
    @State private var showContacts = false
    @State private var problem: String?
    @State private var problemField: Field?
    @State private var scrollRequest = 0
    @State private var confirmLeave = false
    @State private var confirmRemove = false
    @State private var nearName: KairosPerson?   // someone with a name 1-2 letters away: ask before saving
    @FocusState private var focus: Field?

    /// `person: nil` adds someone new. Pass `onDelete` to offer "Remove" when changing someone.
    /// `existing`: everyone already saved, to warn about a name like theirs; nil uses the app's PeopleStore.
    init(person: KairosPerson? = nil, existing: [KairosPerson]? = nil, onSave: @escaping (KairosPerson) -> Void,
         onCancel: @escaping () -> Void = {}, onDelete: (() -> Void)? = nil) {
        var start = Snapshot()
        if let p = person {
            start = Snapshot(alias: p.alias, relation: p.relation ?? "", channel: p.channel, tone: p.tone,
                             language: p.language, phone: p.phone ?? "", email: p.email ?? "")
        }
        self.init(ref: person?.ref, start: start, phoneChoices: [], emailChoices: [], existing: existing,
                  onSave: onSave, onCancel: onCancel, onDelete: person == nil ? nil : onDelete)
    }

    /// A new person straight from the contact picker (Write for me, when nobody matched the name).
    init(contactName: String, phones: [LabeledPhone], emails: [String], existing: [KairosPerson]? = nil,
         onSave: @escaping (KairosPerson) -> Void, onCancel: @escaping () -> Void = {}) {
        let phones = Self.distinctPhones(phones), emails = Self.distinct(emails)
        var start = Snapshot()
        start.alias = contactName
        if phones.isEmpty && !emails.isEmpty { start.channel = .email }   // nothing else could reach them
        start.phone = Self.preferredPhone(phones, for: start.channel)
        start.email = emails.count == 1 ? emails[0] : ""
        self.init(ref: nil, start: start, phoneChoices: phones.count > 1 ? phones : [],
                  emailChoices: emails.count > 1 ? emails : [], existing: existing,
                  onSave: onSave, onCancel: onCancel, onDelete: nil)
    }

    private init(ref: String?, start: Snapshot, phoneChoices: [LabeledPhone], emailChoices: [String],
                 existing: [KairosPerson]?, onSave: @escaping (KairosPerson) -> Void,
                 onCancel: @escaping () -> Void, onDelete: (() -> Void)?) {
        self.ref = ref
        self.isNew = ref == nil
        self.initial = ref == nil ? Snapshot() : start
        self.existing = existing
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDelete = onDelete
        _alias = State(initialValue: start.alias)
        _relation = State(initialValue: start.relation)
        _channel = State(initialValue: start.channel)
        _tone = State(initialValue: start.tone)
        _language = State(initialValue: start.language)
        _phone = State(initialValue: start.phone)
        _email = State(initialValue: start.email)
        _country = State(initialValue: PhoneCountry.fromPhoneSettings)
        _phoneChoices = State(initialValue: phoneChoices)
        _emailChoices = State(initialValue: emailChoices)
    }

    private var current: Snapshot {
        Snapshot(alias: alias, relation: relation, channel: channel, tone: tone, language: language, phone: phone, email: email)
    }
    private var hasChanges: Bool { current != initial }
    private var needsPhone: Bool { [.whatsapp, .sms, .telegram].contains(channel) }
    private var trimmedAlias: String { alias.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedRelation: String { relation.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// A number with no + or 00: which country it is in must be chosen on screen.
    private var asksCountry: Bool {
        !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !PeopleStore.phoneHasCountryCode(phone)
    }
    private var phoneNumber: String? { PeopleStore.normalisePhone(phone, defaultCountryCode: country.callingCode) }
    /// Everyone else, to compare names against.
    private var others: [KairosPerson] { (existing ?? PeopleStore.active?.people ?? []).filter { $0.ref != ref } }

    /// Keep a language Kairos doesn't list (set elsewhere) instead of silently changing it.
    private var languageOptions: [(code: String, label: String, detail: String?, spoken: String)] {
        Self.languages.contains { $0.code == language } ? Self.languages : Self.languages + [(language, language, nil, language)]
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        contactsButton
                        nameSection.id(Field.alias)
                        relationSection.id(Field.relation)
                        channelSection
                        phoneSection.id(Field.phone)
                        emailSection.id(Field.email)
                        toneSection
                        languageSection
                        if onDelete != nil { removeButton }
                    }
                    .padding(20)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: scrollRequest) { _, _ in
                    guard let target = problemField else { return }
                    withAnimation { proxy.scrollTo(target, anchor: .top) }
                }
            }
            .background(PeopleLook.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { saveBar }
            .navigationTitle(isNew ? "Add someone" : "Change details")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                // The phone keypad has no return key; without this the keyboard can't be put away.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focus = nil }.font(PeopleLook.font(22, .bold)).tint(PeopleLook.green)
                }
            }
        }
        .environment(\.colorScheme, .light)
        .interactiveDismissDisabled(hasChanges)   // a stray swipe mustn't lose a typed-in number
        .onChange(of: [alias, relation, phone, email, channel.rawValue, country.rawValue]) { _, _ in
            problem = nil; problemField = nil
        }
        .sheet(isPresented: $showContacts) {
            ContactPicker(onPick: { name, phones, emails in
                showContacts = false
                useContact(name: name, phones: phones, emails: emails)
            }, onCancel: { showContacts = false })
            .ignoresSafeArea()
        }
        .alert(Text(verbatim: "\(trimmedAlias) looks like \(nearName?.alias ?? "")"),
               isPresented: Binding(get: { nearName != nil }, set: { if !$0 { nearName = nil } }),
               presenting: nearName) { _ in
            Button("Change the name", role: .cancel) { focus = .alias }
            Button("Keep both names") { save(keepingNearName: true) }
        } message: { other in
            Text(verbatim: "You already have \(other.recipientLine). \(differentNameAdvice()) "
                 + "If you keep both, Kairos will always ask which one you mean.")
        }
        .alert("Leave without saving?", isPresented: $confirmLeave) {
            Button("Keep changing", role: .cancel) {}
            Button("Leave", role: .destructive) { onCancel(); dismiss() }
        } message: {
            Text("What you typed here will not be kept.")
        }
        .alert("Remove \(trimmedAlias.isEmpty ? "this person" : trimmedAlias)?", isPresented: $confirmRemove) {
            Button("Keep them", role: .cancel) {}
            Button("Remove", role: .destructive) { onDelete?(); dismiss() }
        } message: {
            Text("Kairos will forget their number and email on this phone.")
        }
    }

    // MARK: sections

    private var contactsButton: some View {
        Button { focus = nil; showContacts = true } label: {
            Label("Pick from Contacts", systemImage: "person.crop.circle.badge.plus")
                .font(PeopleLook.font(26, .bold))
                .frame(maxWidth: .infinity, minHeight: 72)
                .background(.white, in: RoundedRectangle(cornerRadius: 20))
                .foregroundStyle(PeopleLook.green)
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(PeopleLook.green, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Choose them from your contacts to fill in their name and number")
    }

    private var nameSection: some View {
        section("What do you call them?") {
            input("For example: Amma, Ravi, Dr Shah", text: $alias, field: .alias)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()   // autocorrect "fixes" names
                .accessibilityLabel("What you call them")
        }
    }

    private var relationSection: some View {
        section("Who are they to you?", note: "You can leave this empty.") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(Self.relationChoices, id: \.self) { word in
                    let selected = relation.trimmingCharacters(in: .whitespaces).lowercased() == word
                    Button { focus = nil; relation = selected ? "" : word } label: {
                        Text(word.capitalized)
                            .font(PeopleLook.font(22, .semibold))
                            .frame(maxWidth: .infinity, minHeight: 60)
                            .foregroundStyle(selected ? .white : PeopleLook.ink)
                            .background(selected ? PeopleLook.green : .white, in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? PeopleLook.green : PeopleLook.border, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            input("Or write it, like: GP surgery", text: $relation, field: .relation)
                .accessibilityLabel("Who they are to you")
        }
    }

    private var channelSection: some View {
        section("How do you send them messages?") {
            ForEach(BridgeChannel.allCases) { option in
                choice(option.appName, detail: Self.channelDetail(option), icon: PeopleLook.icon(option),
                       selected: channel == option) { channel = option }
            }
        }
    }

    private var phoneSection: some View {
        section("Phone number", note: needsPhone ? "Needed for \(channel.appName)." : "You can leave this empty.") {
            if phoneChoices.count > 1 {
                let chosenMobile = phoneChoices.contains { $0.number == phone && $0.isMobile }
                Text(chosenMobile ? "They have \(phoneChoices.count) numbers. The mobile is chosen. Tap another to change it."
                                  : "They have \(phoneChoices.count) numbers. Tap the one to use.")
                    .font(PeopleLook.font(22, .semibold)).foregroundStyle(PeopleLook.ink)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(phoneChoices, id: \.self) { option in
                    choice(option.shown, detail: nil, icon: nil, selected: phone == option.number) { phone = option.number }
                        .accessibilityLabel(option.label.isEmpty ? Text(option.number).speechSpellsOutCharacters()
                                            : Text(verbatim: option.label + ", ") + Text(option.number).speechSpellsOutCharacters())
                }
            }
            input(country == .india ? "For example: 98480 12345" : "For example: 07700 900123", text: $phone, field: .phone)
                .keyboardType(.phonePad)
                .accessibilityLabel("Their phone number")
            if asksCountry { countryChoice }
            if let e164 = phoneNumber {
                let place = PeopleStore.phonePlace(e164).map { $0 + " " } ?? ""
                let shown = PeopleStore.formattedPhone(e164)
                Label {
                    Text(verbatim: "Kairos will use \(place)\(shown)")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .font(PeopleLook.font(22, .semibold))
                .foregroundStyle(PeopleLook.green)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "Kairos will use \(place)") + Text(shown).speechSpellsOutCharacters())
            }
            stayNote("This number stays on this phone. Kairos never sends it anywhere.")
        }
    }

    /// The same digits are a different person in another country, so the country is chosen, never assumed.
    private var countryChoice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which country is this number from?")
                .font(PeopleLook.font(24, .bold))
                .foregroundStyle(PeopleLook.ink)
            ForEach(PhoneCountry.allCases) { option in
                choice(option.title, detail: option.detail, icon: nil, selected: country == option) { country = option }
            }
            if country == .other {
                Text("Type + and the country code at the start of the number, like +1 for the USA or +353 for Ireland.")
                    .font(PeopleLook.font(22, .semibold))
                    .foregroundStyle(PeopleLook.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var emailSection: some View {
        section("Email address", note: channel == .email ? "Needed for email." : "You can leave this empty.") {
            if emailChoices.count > 1 {
                Text("They have \(emailChoices.count) email addresses. Tap the one to use.")
                    .font(PeopleLook.font(22, .semibold)).foregroundStyle(PeopleLook.ink)
                ForEach(emailChoices, id: \.self) { address in
                    choice(address, detail: nil, icon: nil, selected: email == address) { email = address }
                }
            }
            input("name@example.com", text: $email, field: .email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Their email address")
            stayNote("Their email address stays on this phone too.")
        }
    }

    private var toneSection: some View {
        section("How should messages sound?") {
            ForEach(BridgeTone.allCases) { option in
                choice(Self.toneName(option), detail: Self.toneDetail(option), icon: nil, selected: tone == option) { tone = option }
            }
        }
    }

    private var languageSection: some View {
        section("Which language do they read?") {
            ForEach(languageOptions, id: \.code) { option in
                choice(option.label, detail: option.detail, icon: nil, selected: language == option.code) { language = option.code }
                    .accessibilityLabel(option.spoken)
            }
        }
    }

    private var removeButton: some View {
        Button { focus = nil; confirmRemove = true } label: {
            Label("Remove \(trimmedAlias.isEmpty ? "this person" : trimmedAlias)", systemImage: "trash")
                .font(PeopleLook.font(24, .bold))
                .frame(maxWidth: .infinity, minHeight: 68)
                .foregroundStyle(PeopleLook.problemInk)
                .background(.white, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(PeopleLook.problemInk, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .padding(.top, 10)
    }

    /// Save and Cancel are always on screen (not small toolbar words), and a problem shows right above them.
    private var saveBar: some View {
        VStack(spacing: 10) {
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .font(PeopleLook.font(22, .semibold))
                    .foregroundStyle(PeopleLook.problemInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(PeopleLook.problemFill, in: RoundedRectangle(cornerRadius: 16))
            }
            HStack(spacing: 14) {
                Button { cancel() } label: {
                    Text("Cancel").font(PeopleLook.font(26, .bold))
                        .frame(maxWidth: .infinity, minHeight: 68)
                        .background(PeopleLook.grey, in: RoundedRectangle(cornerRadius: 20))
                        .foregroundStyle(PeopleLook.ink)
                }
                Button { save() } label: {
                    Text("Save").font(PeopleLook.font(26, .bold))
                        .frame(maxWidth: .infinity, minHeight: 68)
                        .background(PeopleLook.green, in: RoundedRectangle(cornerRadius: 20))
                        .foregroundStyle(.white)
                }
                .accessibilityHint(isNew ? "Adds them to your people" : "Keeps these changes")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background {
            PeopleLook.background
                .shadow(color: .black.opacity(0.12), radius: 8, y: -2)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    // MARK: building blocks

    private func section<Content: View>(_ title: String, note: String? = nil,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(PeopleLook.font(28, .bold))
                .foregroundStyle(PeopleLook.ink)
                .accessibilityAddTraits(.isHeader)
            if let note {
                Text(note).font(PeopleLook.font(22)).foregroundStyle(PeopleLook.softInk)
            }
            content()
        }
    }

    private func input(_ placeholder: String, text: Binding<String>, field: Field) -> some View {
        let flagged = problemField == field && problem != nil
        return TextField("", text: text, prompt: Text(placeholder).foregroundStyle(PeopleLook.placeholder))
            .font(PeopleLook.font(28, .semibold))
            .foregroundStyle(PeopleLook.ink)
            .tint(PeopleLook.green)
            .focused($focus, equals: field)
            .submitLabel(.done)
            .padding(.horizontal, 16)
            .frame(minHeight: 68)
            .background(.white, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(flagged ? PeopleLook.problemInk : PeopleLook.border,
                                                               lineWidth: flagged ? 3 : 2))
    }

    /// One big choice: the whole row is the button, and VoiceOver hears "selected".
    private func choice(_ title: String, detail: String?, icon: String?, selected: Bool,
                        action: @escaping () -> Void) -> some View {
        Button { focus = nil; action() } label: {
            HStack(spacing: 14) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 30, weight: .semibold))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(PeopleLook.font(24, .bold))
                    if let detail { Text(detail).font(PeopleLook.font(20)) }
                }
                Spacer(minLength: 0)
                if let icon {
                    Image(systemName: icon).font(.system(size: 26, weight: .semibold)).accessibilityHidden(true)
                }
            }
            .foregroundStyle(selected ? .white : PeopleLook.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .background(selected ? PeopleLook.green : .white, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(selected ? PeopleLook.green : PeopleLook.border, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func stayNote(_ text: String) -> some View {
        Label(text, systemImage: "lock.fill")
            .font(PeopleLook.font(22, .medium))
            .foregroundStyle(PeopleLook.softInk)
    }

    // MARK: actions

    private func useContact(name: String, phones: [LabeledPhone], emails: [String]) {
        let phones = Self.distinctPhones(phones), emails = Self.distinct(emails)
        // Keep a name they already typed ("Amma"); the contact card often says "Lakshmi Rao".
        if trimmedAlias.isEmpty { alias = name }
        phoneChoices = phones.count > 1 ? phones : []
        if !phones.isEmpty { phone = Self.preferredPhone(phones, for: channel) }
        emailChoices = emails.count > 1 ? emails : []
        if !emails.isEmpty { email = emails.count == 1 ? emails[0] : "" }
    }

    private func cancel() {
        focus = nil
        if hasChanges { confirmLeave = true } else { onCancel(); dismiss() }
    }

    private func save(keepingNearName: Bool = false) {
        focus = nil
        let rawPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = rawPhone.isEmpty ? nil : phoneNumber

        if trimmedAlias.isEmpty || PeopleStore.normaliseName(trimmedAlias).isEmpty {
            return show("Please write the name you call them, like Amma or Ravi.", at: .alias)
        }
        // The name and relation go to the Mac to write the message; numbers and emails must not.
        if PeopleStore.looksLikeContactDetail(trimmedAlias) {
            return show("Please write the name you call them, not their number or email.", at: .alias)
        }
        if PeopleStore.looksLikeContactDetail(trimmedRelation) {
            return show("Please write who they are to you, like mother or GP surgery, not a number or email.", at: .relation)
        }
        // Only for a new or changed name: a pair they already chose to keep shouldn't be asked about on every edit.
        let nameChanged = isNew || PeopleStore.normaliseName(trimmedAlias) != PeopleStore.normaliseName(initial.alias)
        let clash = nameChanged ? PeopleStore.nameClash(trimmedAlias, among: others) : nil
        if let clash, clash.distance == 0 {
            return show("You already have \(clash.person.recipientLine). \(differentNameAdvice())", at: .alias)
        }
        if !rawPhone.isEmpty && number == nil {
            return show(phoneProblem(rawPhone), at: .phone)
        }
        if needsPhone && number == nil {
            let how = channel == .sms ? "send a text message" : "send on \(channel.appName)"
            return show("To \(how), Kairos needs their phone number.", at: .phone)
        }
        if !mail.isEmpty && !Self.looksLikeEmail(mail) {
            return show("That email address doesn't look right. Please check it.", at: .email)
        }
        if channel == .email && mail.isEmpty {
            return show("To send an email, Kairos needs their email address.", at: .email)
        }
        // Last, so "Keep both names" saves straight away instead of meeting another problem.
        if let clash, !keepingNearName {
            nearName = clash.person
            return
        }
        let person = KairosPerson(ref: ref ?? KairosPerson.newRef(), alias: trimmedAlias,
                                  relation: trimmedRelation.isEmpty ? nil : trimmedRelation,
                                  channel: channel, tone: tone, language: language, phone: number,
                                  email: mail.isEmpty ? nil : mail)
        onSave(person)
        dismiss()
    }

    private func phoneProblem(_ rawPhone: String) -> String {
        if PeopleStore.phoneHasCountryCode(rawPhone) {
            return "That phone number doesn't look right. Please check it."
        }
        switch country {
        case .unitedKingdom:
            return "That doesn't look like a UK number. Please check it. If it isn't a UK number, tap the right country above."
        case .india:
            return "That doesn't look like a number in India. Please check it. If it isn't, tap the right country above."
        case .other:
            return "Please type + and the country code at the start of the number, like +1 for the USA."
        }
    }

    /// "Use a different name, like Amma (Mum)." The suggestion is checked so it doesn't clash with anyone either.
    private func differentNameAdvice() -> String {
        if !trimmedRelation.isEmpty {
            let word: String
            switch trimmedRelation.lowercased() {
            case "mother": word = "Mum"
            case "father": word = "Dad"
            default: word = trimmedRelation.prefix(1).uppercased() + trimmedRelation.dropFirst()
            }
            let suggestion = "\(trimmedAlias) (\(word))"
            if PeopleStore.nameClash(suggestion, among: others) == nil { return "Use a different name, like \(suggestion)." }
        }
        return "Use a different name, for example add their first name after \(trimmedAlias)."
    }

    private func show(_ message: String, at field: Field) {
        problem = message
        problemField = field
        scrollRequest += 1
        AccessibilityNotification.Announcement(message).post()
    }

    // MARK: helpers

    private static func looksLikeEmail(_ s: String) -> Bool {
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !s.contains(where: \.isWhitespace) else { return false }
        let domain = parts[1]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }

    private static func distinct(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// "07700 900123" and "+44 7700 900123" on one card are the same number: offer it once, keeping the + form
    /// (it needs no country question) and whichever label the card has.
    private static func distinctPhones(_ values: [LabeledPhone]) -> [LabeledPhone] {
        let code = PhoneCountry.fromPhoneSettings.callingCode
        var kept: [LabeledPhone] = []
        var index: [String: Int] = [:]
        for value in values where !value.number.isEmpty {
            let key = PeopleStore.normalisePhone(value.number, defaultCountryCode: code) ?? PeopleStore.phoneDigits(value.number)
            guard let i = index[key] else {
                index[key] = kept.count
                kept.append(value)
                continue
            }
            let old = kept[i]
            let number = !PeopleStore.phoneHasCountryCode(old.number) && PeopleStore.phoneHasCountryCode(value.number)
                ? value.number : old.number
            kept[i] = LabeledPhone(label: old.label.isEmpty ? value.label : old.label, number: number)
        }
        return kept
    }

    /// One number: use it. Several: the only mobile, when the way they're reached needs one. Otherwise they choose;
    /// Kairos doesn't guess.
    private static func preferredPhone(_ phones: [LabeledPhone], for channel: BridgeChannel) -> String {
        if phones.count == 1 { return phones[0].number }
        let mobiles = phones.filter(\.isMobile)
        if [.whatsapp, .sms, .telegram].contains(channel), mobiles.count == 1 { return mobiles[0].number }
        return ""
    }
}

// MARK: - the list

/// Everyone Kairos can write to. Tap a person to change them; swipe (or open them) to remove.
struct PeopleListView: View {
    @EnvironmentObject var people: PeopleStore
    @State private var adding = false
    @State private var editing: KairosPerson?
    @State private var removing: KairosPerson?

    private var sorted: [KairosPerson] {
        people.people.sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Your people")
                        .font(PeopleLook.font(34, .bold))
                        .foregroundStyle(PeopleLook.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("Kairos can write to these people for you. Their numbers and emails stay on this phone.")
                        .font(PeopleLook.font(22))
                        .foregroundStyle(PeopleLook.softInk)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
            }
            Section {
                if sorted.isEmpty {
                    Text("No one here yet. Tap Add someone to add the people you write to.")
                        .font(PeopleLook.font(22))
                        .foregroundStyle(PeopleLook.ink)
                        .padding(.vertical, 12)
                        .listRowBackground(Color.white)
                }
                ForEach(sorted) { person in row(person) }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(PeopleLook.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            Button { adding = true } label: {
                Label("Add someone", systemImage: "person.badge.plus")
                    .font(PeopleLook.font(28, .bold))
                    .frame(maxWidth: .infinity, minHeight: 76)
                    .background(PeopleLook.green, in: RoundedRectangle(cornerRadius: 22))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(PeopleLook.background.ignoresSafeArea(edges: .bottom))
        }
        .environment(\.colorScheme, .light)
        .sheet(isPresented: $adding) {
            PersonEditor(existing: people.people, onSave: { people.add($0) })
        }
        .sheet(item: $editing) { person in
            PersonEditor(person: person, existing: people.people, onSave: { people.update($0) },
                         onDelete: { people.delete(ref: person.ref) })
        }
        // "Amma, your mother", not just "Amma": Amma and Anna are one letter apart.
        .alert(Text(verbatim: "Remove \(removing?.recipientLine ?? "this person")?"),
               isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
               presenting: removing) { person in
            Button("Keep them", role: .cancel) {}
            Button("Remove", role: .destructive) { people.delete(ref: person.ref) }
        } message: { _ in
            Text("Kairos will forget their number and email on this phone.")
        }
    }

    private func subtitle(_ p: KairosPerson) -> String {
        let relation = (p.relation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let shownRelation = relation.prefix(1).uppercased() + relation.dropFirst()
        return relation.isEmpty ? p.channel.appName : "\(shownRelation) · \(p.channel.appName)"
    }

    private func row(_ p: KairosPerson) -> some View {
        Button { editing = p } label: {
            HStack(spacing: 16) {
                Image(systemName: PeopleLook.icon(p.channel))
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(PeopleLook.green)
                    .frame(width: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.alias)
                        .font(PeopleLook.font(26, .bold))
                        .foregroundStyle(PeopleLook.ink)
                    Text(subtitle(p))
                        .font(PeopleLook.font(20))
                        .foregroundStyle(PeopleLook.softInk)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(PeopleLook.softInk)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 76)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.white)
        // Not role: .destructive, which would animate the row away before they've confirmed.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button { removing = p } label: { Label("Remove", systemImage: "trash") }
                .tint(.red)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(p.alias), \(subtitle(p))")
        .accessibilityHint("Opens their details so you can change them")
    }
}
