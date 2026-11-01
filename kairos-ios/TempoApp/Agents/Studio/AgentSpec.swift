import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

// Agent Studio: the person's helpers. Twelve come ready-made (BuiltinAgents.swift); the person can make their own
// by just saying what they want ("make me a helper that reads my WhatsApp every evening"), change them, share them
// and add ones someone shared with them.
//
// A helper is DATA, never code: a name, a persona, and a short list of tools it may use. Every tool call it makes
// still goes through the SafetyGate and the Yes card, so a helper can never do more than Kairos itself would.
// The rules here are the second line of defence: a helper can't make helpers, can't touch money unless it's the
// person's own money helper (and then only prepare_payment), can't have more than 12 tools, and lines that try to
// talk the model out of its rules ("ignore previous instructions", "send without asking") are stripped.
//
// Storage: Application Support/Kairos/agents.json, written atomically. Built-in helpers live in code and can't
// be changed or deleted (they can be copied); what the person tells a built-in helper to remember is kept
// alongside, in the same file.

// MARK: - The contract

/// A suggested automation. The person sets it up in the Shortcuts app; `setupSteps` gives the exact taps.
struct AgentTrigger: Codable, Equatable, Sendable {
    /// time | arrive | leave | message | charger | notification
    var kind: String
    /// When it fires, in plain words: "Every day at 19:00".
    var detail: String
    /// What to ask the helper when it fires.
    var request: String

    static let kinds: [String] = ["time", "arrive", "leave", "message", "charger", "notification"]
}

struct AgentSpec: Codable, Identifiable, Equatable, Sendable {
    enum Origin: String, Codable, Sendable { case builtin, user, imported }

    /// Stable slug: "medicine-buddy" for a built-in helper, "user-1a2b3c4d" or "shared-1a2b3c4d" for the person's.
    var id: String
    /// "Medicine Buddy"
    var name: String
    /// SF Symbol.
    var icon: String
    /// "#2E7060"
    var colorHex: String
    /// One line for the card.
    var tagline: String
    /// Persona, how to behave, what to focus on. Goes into the system prompt while this helper is in charge.
    var instructions: String
    /// Tool names from the catalog. Nothing else is usable while this helper is in charge.
    var allowedTools: [String]
    /// Tap-to-try chips: "Remind me about my pills".
    var starterPhrases: [String]
    /// Names of routines this helper offers (made with create_routine).
    var routines: [String]
    /// Suggested automations.
    var triggers: [AgentTrigger]
    /// Short facts the helper keeps ("Ravi is my son"): at most 20, each at most 140 characters.
    var memory: [String]
    var origin: Origin
    var version: Int
    var createdAt: Date

    var isBuiltin: Bool { origin == .builtin }
}

/// The contract writes `Origin` on its own; this keeps both spellings working.
typealias Origin = AgentSpec.Origin

// MARK: - Errors, in plain words

enum AgentStudioError: LocalizedError, Equatable {
    case badName
    case unsafeName(String)
    case reservedName(String)
    case nameTaken(String)
    case builtinReadOnly(String)
    case builtinUndeletable(String)
    case notFound(String)
    case tooMany
    case nothingToDo
    case badFile
    case tooBig
    case storeUnavailable
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .badName: return "Please give it a name between 2 and 30 letters long."
        case .unsafeName(let n): return "“\(n)” reads like an instruction, so it can't be a helper's name. Please choose another one."
        case .reservedName(let n): return "“\(n)” is Kairos's own name. Please choose another one."
        case .nameTaken(let n): return "You already have a helper called “\(n)”. Please choose another name."
        case .builtinReadOnly(let n): return "“\(n)” is one of Kairos's own helpers, so it can't be changed. I can make you your own copy instead."
        case .builtinUndeletable(let n): return "“\(n)” is one of Kairos's own helpers, so it can't be deleted. If you don't need it, just leave it be."
        case .notFound(let n): return "I can't find a helper called “\(n)”. Say “list my helpers” to hear them."
        case .tooMany: return "You have \(StudioRules.maxOwnAgents) helpers of your own already. Please delete one you don't use first."
        case .nothingToDo: return "Please tell me what the helper should do."
        case .badFile: return "That doesn't look like a Kairos helper, so I haven't added anything."
        case .tooBig: return "That helper file is far too big to be a real one, so I haven't added it."
        case .storeUnavailable: return "I can't open your saved helpers just now. Please unlock your phone and try again."
        case .writeFailed: return "I couldn't save that on your phone. Please try again."
        }
    }
}

// MARK: - The Studio's own tool names

/// Kept here (not in StudioAgent.swift) so the library and its rules compile on their own.
enum StudioToolNames {
    static let agentID = "studio"
    static let talk = "talk_to_agent"
    static let back = "back_to_kairos"
    static let ask = "ask_agent"
    static let list = "list_agents"
    static let create = "create_agent"
    static let edit = "edit_agent"
    static let delete = "delete_agent"
    static let remember = "remember_for_agent"
    static let share = "share_agent"
    static let importAgent = "import_agent"

    /// The Studio's own tools: only Kairos makes and changes helpers.
    static let studio: Set<String> = [talk, back, ask, list, create, edit, delete, remember, share, importAgent]
    /// Tools that change what every agent may do without asking (the Trust agent's). Only the person, talking to
    /// Kairos itself, with Face ID: never a helper's to hold.
    static let kairosOnly: Set<String> = ["allow_without_asking"]
    /// No helper may ever be given these.
    static let all: Set<String> = studio.union(kairosOnly)
    /// Making things safer always works, whoever is in charge: "stop everything" (the Trust agent's revoke_permission).
    static let alwaysOn: Set<String> = ["revoke_permission"]
    /// What a focused helper offers besides its own tools: switching, hearing the list, the way back, and "stop
    /// everything".
    static let focusMode: Set<String> = Set([talk, list, back]).union(alwaysOn)
}

// MARK: - The tool catalog

/// One tool a helper could be given.
struct StudioToolRef: Sendable, Equatable {
    var name: String
    var summary: String
    var risk: Risk
}

enum StudioCatalog {
    /// Every tool in this build, read from AgentDirectory. The Studio's own agent is skipped without touching its
    /// tools (their descriptions are built from this list), and a re-entrant call returns nothing instead of looping.
    static var fromDirectory: [StudioToolRef] { cache.value }

    /// The live catalog: what the running orchestrator offers (AgentHooks), else what AgentDirectory lists.
    @MainActor
    static func current() -> [StudioToolRef] {
        if let runner = AgentHooks.runner {
            let list = runner.toolCatalog
                .filter { !StudioToolNames.all.contains($0.name) }
                .map { StudioToolRef(name: $0.name, summary: $0.summary, risk: $0.risk) }
            if !list.isEmpty { return list }
        }
        return fromDirectory
    }

    /// The real tool objects (for the rules-first match in a one-off handoff), Studio tools excluded.
    static func liveTools(named names: Set<String>) -> [any KairosTool] {
        AgentDirectory.all.filter { $0.id != StudioToolNames.agentID }
            .flatMap { $0.tools }
            .filter { names.contains($0.name) && !StudioToolNames.all.contains($0.name) }
    }

    /// First sentence of a summary, cut short: for the model's list of tools to pick from.
    static func gist(_ summary: String, max: Int = 70) -> String {
        var s = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = s.range(of: ". ") { s = String(s[..<end.lowerBound]) }
        if s.hasSuffix(".") { s.removeLast() }
        return StudioRules.clip(s, to: max)
    }

    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var cached: [StudioToolRef]?
        private var building = false

        var value: [StudioToolRef] {
            lock.lock()
            if let cached { lock.unlock(); return cached }
            if building { lock.unlock(); return [] }
            building = true
            lock.unlock()
            var out: [StudioToolRef] = []
            var seen = Set<String>()
            for agent in AgentDirectory.all where agent.id != StudioToolNames.agentID {
                for tool in agent.tools where !StudioToolNames.all.contains(tool.name) && seen.insert(tool.name).inserted {
                    out.append(StudioToolRef(name: tool.name, summary: tool.summary, risk: tool.risk))
                }
            }
            lock.lock()
            cached = out
            building = false
            lock.unlock()
            return out
        }
    }
}

// MARK: - Names Kairos can match without waiting for the main actor

struct StudioNameEntry: Sendable, Equatable {
    var id: String
    var name: String
}

/// A thread-safe copy of the helpers' names and the focused helper, for the rules-first matcher (which runs
/// synchronously, off the main actor). AgentLibrary keeps it current.
final class StudioSnapshot: @unchecked Sendable {
    static let shared = StudioSnapshot()

    private let lock = NSLock()
    private var _entries: [StudioNameEntry] = BuiltinAgents.all.map { StudioNameEntry(id: $0.id, name: $0.name) }
    private var _focusedID: String?

    var entries: [StudioNameEntry] {
        lock.lock(); defer { lock.unlock() }
        return _entries
    }

    var focusedID: String? {
        lock.lock(); defer { lock.unlock() }
        return _focusedID
    }

    func update(_ specs: [AgentSpec]) {
        let fresh = specs.map { StudioNameEntry(id: $0.id, name: $0.name) }
        lock.lock(); _entries = fresh; lock.unlock()
    }

    func setFocused(_ id: String?) {
        lock.lock(); _focusedID = id; lock.unlock()
    }
}

// MARK: - The rules every helper must pass

/// What vetting a helper changed, so Kairos can say so.
struct StudioVetted: Sendable, Equatable {
    enum Why: String, Sendable { case unknown, money, studio, tooMany, sharedLimit, kairosOnly }
    struct Removed: Sendable, Equatable { var tool: String; var why: Why }

    var spec: AgentSpec
    var removed: [Removed] = []
    /// Lines or phrases taken out because they tried to get round the safety rules.
    var strippedLines = 0
    /// The name it asked for, when a shared helper had to be renamed.
    var renamedFrom: String?
    /// Lines a shared helper brought with phone numbers or links in them, taken out.
    var droppedContacts = 0

    /// One short sentence per change, for the person.
    var notes: [String] {
        var out: [String] = []
        let unknown = removed.filter { $0.why == .unknown }.map { "“\($0.tool.replacingOccurrences(of: "_", with: " "))”" }
        if !unknown.isEmpty {
            out.append("I left out \(StudioSpeech.list(Array(unknown.prefix(3)))), because \(unknown.count == 1 ? "that isn't" : "those aren't") something I can do on this phone yet.")
        }
        if removed.contains(where: { $0.why == .money }) {
            out.append(spec.origin == .imported
                       ? "I left out payments: a helper shared from someone else can never touch money."
                       : "I left out payments: only a money helper can get a payment ready, and only with your yes.")
        }
        if removed.contains(where: { $0.why == .studio }) {
            out.append("I left out making and changing helpers: only Kairos can do that.")
        }
        if removed.contains(where: { $0.why == .kairosOnly }) {
            out.append("I left out letting it act without asking you: only you can allow that, with Kairos and your Face ID.")
        }
        if removed.contains(where: { $0.why == .sharedLimit }) {
            out.append("I left out making or changing routines: a helper someone shared can only run the routines you made yourself.")
        }
        if removed.contains(where: { $0.why == .tooMany }) {
            out.append("I kept the first \(StudioRules.maxTools) things it can do; that's the most one helper can have.")
        }
        if strippedLines > 0 {
            out.append("I took out \(strippedLines == 1 ? "a line" : "\(strippedLines) lines") that tried to get round my safety checks.")
        }
        if droppedContacts > 0 {
            out.append("I took out \(droppedContacts == 1 ? "a line" : "\(droppedContacts) lines") with phone numbers or web links: for your safety, those only ever come from you.")
        }
        if let old = renamedFrom {
            out.append("You already had one called “\(old)”, so I've called this one “\(spec.name)”.")
        }
        return out
    }
}

enum StudioRules {
    static let maxTools = 12
    static let maxInstructions = 1500
    static let maxMemory = 20
    static let maxFact = 140
    static let nameLength = 2...30
    static let maxTagline = 90
    static let maxStarters = 5
    static let maxStarterLength = 80
    static let maxRoutines = 6
    static let maxRoutineName = 40
    static let maxTriggers = 5
    static let maxOwnAgents = 50
    static let maxShareBytes = 64_000
    static let defaultIcon = "person.crop.circle.fill"
    static let palette = ["#2E7060", "#3A5A98", "#B04A7A", "#C27C0E", "#5B4BA0", "#2C6E91", "#8A5A2B", "#4A4E69"]
    static let reservedNames: Set<String> = ["kairos", "siri", "tempo", "studio", "agent studio", "kairos helper"]
    static let reservedKeys: Set<String> = Set(reservedNames.map(skeleton))
    /// Tools a helper someone shared never gets: writing routines would let it reach any tool through the steps.
    /// A shared (imported) helper never gets routine writing, the phone operator, the camera share, Shortcuts or
    /// permission and memory changes: its instructions came from someone else.
    static let sharedNever: Set<String> = ["create_routine", "save_last_as_routine", "delete_routine", "operate_app",
                                           "read_screen", "run_my_shortcut", "share_photo", "revoke_permission",
                                           "remember_relation", "allow_without_asking"]
    static let moneyWords: Set<String> = ["money", "bill", "bills", "pay", "paying", "payment", "payments", "budget",
                                          "budgeting", "bank", "banking", "finance", "finances", "spending", "rent", "tax"]

    enum Mode: Sendable, Equatable {
        case create      // the model designed it from the person's words
        case edit        // the person changed one of theirs
        case save        // the screen saved it (unknown tools are kept: they may just not be installed yet)
        case `import`    // untrusted text from someone else
    }

    /// Checks and cleans a helper. Throws only for problems the person must fix (the name); everything else is
    /// cleaned and reported in `notes`.
    static func vet(_ draft: AgentSpec, purpose: String = "", catalog: [StudioToolRef], takenNames: Set<String>,
                    mode: Mode, now: Date = Date()) throws -> StudioVetted {
        var spec = draft
        var removed: [StudioVetted.Removed] = []
        var stripped = 0
        var renamedFrom: String?

        // Who wrote it.
        switch mode {
        case .create: spec.origin = .user
        case .import: spec.origin = .imported
        case .edit, .save: if spec.origin == .builtin { spec.origin = .user }
        }

        // Name. Look-alike letters ("Mеdicine Buddy" with a Cyrillic е) are read as Latin, so a helper can't pose as
        // another one or as Kairos; a name that is itself an instruction never reaches the prompt.
        var name = unmix(cleanName(draft.name))
        guard nameLength.contains(name.count) else { throw AgentStudioError.badName }
        guard !reservedKeys.contains(nameKey(name)) else { throw AgentStudioError.reservedName(name) }
        if isOverride(name) {
            guard mode == .import else { throw AgentStudioError.unsafeName(name) }
            stripped += 1
            name = "Shared helper"
        }
        let takenKeys = Set(takenNames.map(skeleton))
        if takenKeys.contains(nameKey(name)) {
            guard mode == .import else { throw AgentStudioError.nameTaken(name) }
            renamedFrom = name
            name = uniqueName(name, taken: takenKeys)
        }
        spec.name = name

        // Text that reaches the model: invisible characters out, override attempts out, lengths capped.
        let purposeLine = cleanLine(purpose)
        let (instructions, cut) = stripOverrides(cleanBlock(draft.instructions))
        stripped += cut
        spec.instructions = clip(instructions, to: maxInstructions)
        if spec.instructions.isEmpty, !purposeLine.isEmpty {
            let (p, pc) = stripOverrides(purposeLine)
            stripped += pc
            if !p.isEmpty { spec.instructions = clip("Help the person with this: \(p)", to: maxInstructions) }
        }

        let (cleanTagline, tc) = stripOverrides(cleanLine(draft.tagline))
        var tagline = cleanTagline
        stripped += tc
        // A shared helper never brings its own phone numbers or links: on the Yes card they would look like the
        // person's own words. (The person can still tell it a number to remember.)
        var contacts = 0
        if mode == .import {
            let (i, ic) = stripContacts(spec.instructions)
            let (t, tcc) = stripContacts(tagline)
            spec.instructions = i
            tagline = t
            contacts += ic + tcc
        }
        spec.tagline = clip(tagline.isEmpty ? (purposeLine.isEmpty ? "Your own helper" : stripOverrides(purposeLine).text) : tagline,
                            to: maxTagline)
        if spec.tagline.isEmpty { spec.tagline = "Your own helper" }

        // Tools.
        let byName = Dictionary(catalog.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let known = Set(byName.keys)
        let moneyHelper = spec.origin != .imported && isMoneyHelper(spec, purpose: purposeLine)
        var kept: [String] = []
        for raw in draft.allowedTools.prefix(40) {
            let tool = normaliseToolName(raw, known: known)
            guard !tool.isEmpty, !kept.contains(tool), !removed.contains(where: { $0.tool == tool }) else { continue }
            if StudioToolNames.kairosOnly.contains(tool) {
                removed.append(.init(tool: tool, why: .kairosOnly)); continue
            }
            if StudioToolNames.alwaysOn.contains(tool) { continue }   // every helper has "stop everything" already
            if StudioToolNames.all.contains(tool) {
                removed.append(.init(tool: tool, why: .studio)); continue
            }
            // A routine's steps can be any tool, so a shared helper that could write routines could reach tools it
            // was never given. It may still run the person's own routines.
            if spec.origin == .imported, sharedNever.contains(tool) {
                removed.append(.init(tool: tool, why: .sharedLimit)); continue
            }
            let risk = byName[tool]?.risk ?? (tool == "prepare_payment" ? .money : nil)
            if risk == nil, mode != .save {
                removed.append(.init(tool: tool, why: .unknown)); continue
            }
            if risk == .money || (risk == nil && looksLikeMoney(tool)) {
                guard moneyHelper, tool == "prepare_payment" else {
                    removed.append(.init(tool: tool, why: .money)); continue
                }
            }
            guard kept.count < maxTools else {
                removed.append(.init(tool: tool, why: .tooMany)); continue
            }
            kept.append(tool)
        }
        spec.allowedTools = kept

        guard !spec.instructions.isEmpty || !kept.isEmpty else { throw AgentStudioError.nothingToDo }
        if spec.instructions.isEmpty {
            spec.instructions = "Help the person kindly with what they ask, using only the tools you have."
        }

        // Card and chips.
        spec.icon = validIcon(draft.icon) ?? defaultIcon
        spec.colorHex = validHex(draft.colorHex) ?? palette[stableHash(name) % palette.count]
        spec.starterPhrases = cleanList(draft.starterPhrases, max: maxStarters, length: maxStarterLength, stripped: &stripped)
        spec.routines = cleanList(draft.routines, max: maxRoutines, length: maxRoutineName, stripped: &stripped)
        spec.triggers = draft.triggers.prefix(10).compactMap { t -> AgentTrigger? in
            let kind = t.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard AgentTrigger.kinds.contains(kind) else { return nil }
            let (request, rc) = stripOverrides(cleanLine(t.request))
            let (detail, dc) = stripOverrides(cleanLine(t.detail))
            stripped += rc + dc
            guard !request.isEmpty else { return nil }
            return AgentTrigger(kind: kind, detail: clip(detail.isEmpty ? kind.capitalized : detail, to: 80),
                                request: clip(request, to: 200))
        }
        if spec.triggers.count > maxTriggers { spec.triggers = Array(spec.triggers.prefix(maxTriggers)) }
        if mode == .import {
            let before = spec.starterPhrases.count + spec.routines.count + spec.triggers.count
            spec.starterPhrases.removeAll(where: hasContact)
            spec.routines.removeAll(where: hasContact)
            spec.triggers.removeAll { hasContact($0.request) || hasContact($0.detail) }
            contacts += before - (spec.starterPhrases.count + spec.routines.count + spec.triggers.count)
        }
        spec.memory = cleanMemory(draft.memory, stripped: &stripped)

        // Identity.
        if spec.id.isEmpty || mode == .create || mode == .import || BuiltinAgents.ids.contains(spec.id) {
            spec.id = newID(for: spec.origin)
        }
        if mode == .create || mode == .import {
            spec.version = 1
            spec.createdAt = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        } else {
            spec.version = max(1, spec.version)
        }
        return StudioVetted(spec: spec, removed: removed, strippedLines: stripped, renamedFrom: renamedFrom,
                            droppedContacts: contacts)
    }

    /// True when the text holds a phone or account number (six digits or more) or a web link or email address.
    static func hasContact(_ s: String) -> Bool {
        SafetyGate.digitRuns(s).contains { $0.count >= 6 } || !SafetyGate.links(s).isEmpty
    }

    /// Takes out sentences with a phone number, account number or link. Returns the text and how many went.
    static func stripContacts(_ text: String) -> (text: String, removed: Int) {
        var removed = 0
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            let sentences = splitSentences(line)
            let kept = sentences.filter { s in
                if hasContact(s) { removed += 1; return false }
                return true
            }
            let joined = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty || sentences.isEmpty { lines.append(joined) }
        }
        var out = lines.joined(separator: "\n")
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return (out.trimmingCharacters(in: .whitespacesAndNewlines), removed)
    }

    // MARK: Overrides

    /// Takes out sentences that try to change Kairos's rules or get round its checks. Returns the cleaned text and
    /// how many sentences went.
    static func stripOverrides(_ text: String) -> (text: String, removed: Int) {
        var removed = 0
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            let sentences = splitSentences(line)
            let kept = sentences.filter { s in
                if isOverride(s) { removed += 1; return false }
                return true
            }
            let joined = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty || sentences.isEmpty { lines.append(joined) }
        }
        var out = lines.joined(separator: "\n")
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return (out.trimmingCharacters(in: .whitespacesAndNewlines), removed)
    }

    /// True when a sentence tries to talk the model out of its rules.
    static func isOverride(_ sentence: String) -> Bool {
        // Look-alike letters are read as Latin first, so "Ignоre previous instructions" (Cyrillic о) is caught too.
        let raw = String(sentence.trimmingCharacters(in: .whitespaces).map { lookAlikes[$0] ?? $0 })
        if raw.range(of: #"^\W{0,4}(system|assistant|developer|model)\s*[:>\]]"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if raw.contains("<|") || raw.contains("|>") || raw.lowercased().contains("[inst]") { return true }
        let f = " " + raw.folded + " "
        let range = NSRange(f.startIndex..., in: f)
        func hit(_ r: NSRegularExpression, _ s: String) -> Bool { r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        if overridePatterns.contains(where: { hit($0, f) }) { return true }
        let coaxing = coaxingWords.firstMatch(in: f, range: range) != nil
        // "Send without asking" is an override; "Never send a message without asking first" is a safety rule. A rule
        // that turns round ("never wait, just send", "don't ever refuse to skip the checks") is not.
        if forbiddablePatterns.contains(where: { hit($0, f) }) {
            let negations = negationWords.numberOfMatches(in: f, range: range)
            let safeRule = hit(safeLead, f) && negations == 1 && !coaxing && !hit(contrastWords, f)
                && raw.rangeOfCharacter(from: CharacterSet(charactersIn: ",:;\u{2013}\u{2014}(")) == nil
            if !safeRule { return true }
        }
        // Asking for secrets or paying in gift cards: fine only as a warning ("banks never ask for your PIN"). Each
        // clause is judged on its own, so "don't ask for the PIN, instead ask for the card number" is caught.
        for clause in clauses(raw) {
            let c = " " + clause.folded + " "
            guard negatablePatterns.contains(where: { hit($0, c) }) else { continue }
            if !hit(warningNegation, c) || coaxing { return true }
        }
        return false
    }

    /// A sentence cut at commas, colons, dashes and words like "but" and "instead".
    private static func clauses(_ s: String) -> [String] {
        var t = s
        for sep in [",", ":", "\u{2013}", "\u{2014}", "(", ")", " but ", " instead ", " then ", " however ", " though "] {
            t = t.replacingOccurrences(of: sep, with: "\n", options: .caseInsensitive)
        }
        return t.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func rx(_ p: String) -> NSRegularExpression {
        // The patterns are fixed and tested in StudioSelfTest; a typo must fail loudly in development.
        try! NSRegularExpression(pattern: p, options: [])
    }

    /// Run on folded text (lowercase, punctuation turned into spaces, so "don't" is "don t").
    /// Run on folded text (lowercase, punctuation turned into spaces, so "don't" is "don t"). Always an override.
    private static let overridePatterns: [NSRegularExpression] = [
        rx(#"\b(no need|don t need|do not need|never need|don t have|do not have|needn t)\b.{0,12}\b(to )?(ask|check|confirm|approve|wait for)\b"#),
        rx(#"\b(don t|do not|dont|never|no need to|needn t)\b.{0,10}\b(wait|waiting|bother)\b.{0,30}\b(yes|approval|approve|permission|ok|okay|go ahead|confirmation|confirm|confirming|the card|a reply|an answer|their answer|asking|checking)\b"#),
        rx(#"\b(new|real|updated|true|actual|secret|hidden|override)\b.{0,6}\b(rules|orders|directive|directives)\b"#),
        rx(#"\b(rules|instructions|guidelines|checks|restrictions|limits)\b.{0,25}\b(don t apply|do not apply|no longer apply|doesn t apply|does not apply|are void|are cancelled|are canceled|are off|are lifted|are suspended|are outdated|no longer count|don t count|are not real|are fake)\b"#),
        rx(#"\b(forget|ignore|disregard|drop)\b.{0,12}\b(everything|all that|anything|all of that|whatever)\b.{0,30}\b(told|said|above|before|earlier|previously|instructed|taught)\b"#),
        rx(#"\b(don t|do not|never|stop)\b.{0,6}\b(ask|asking|check|checking|confirm|confirming)\b.{0,20}\b(before|first|the owner|the person|for approval|for permission)\b"#),
        rx(#"\b(system prompt|developer mode|dev mode|jailbreak|jail break|dan mode|god mode|unrestricted mode|no restrictions|without restrictions|no limits|new instructions|real instructions|hidden instructions|secret instructions)\b"#),
        rx(#"\b(you are|you re|act as|pretend|roleplay|role play)\b.{0,30}\b(not kairos|no longer kairos|no longer bound|free from|without rules|no rules|unfiltered|uncensored)\b"#),
        rx(#"\b(you may|you can|you are allowed to|you re allowed to|feel free to|always)\b.{0,15}\b(send|pay|transfer|delete|call|dial|ring|buy)\b.{0,30}\b(anyone|anybody|any number|whoever|whatever|any amount)\b"#),
    ]

    /// Overrides when said as a command ("send it automatically"), safety rules when forbidden ("never send
    /// anything automatically", "do not skip the safety checks").
    private static let forbiddablePatterns: [NSRegularExpression] = [
        rx(#"\b(ignore|disregard|forget|override|overrule|bypass|drop|skip|abandon)\b.{0,40}\b(previous|prior|above|earlier|all|any|your|the|these|those|system|safety|kairos|other|original)\b.{0,30}\b(instruction|instructions|rule|rules|prompt|prompts|guideline|guidelines|direction|directions|policy|policies|restriction|restrictions|limit|limits|checks)\b"#),
        rx(#"\b(tap|press|hit|click|choose|select)\b.{0,12}\b(send|pay|confirm|buy|order|transfer|yes|approve|allow)\b.{0,25}\b(for them|for the person|for the owner|on their behalf|on behalf|yourself|without)\b"#),
        rx(#"\b(approve|accept|confirm|say yes to|tap yes on|tap yes for)\b.{0,25}\b(for them|for the person|for the owner|on their behalf|on behalf of|yourself|by yourself)\b"#),
        rx(#"\b(skip|bypass|turn off|switch off|disable|ignore|avoid|get round|get around|get past|work around)\b.{0,30}\b(face id|passcode|confirmation|confirm|card|safety|scam|check|checks|gate|approval|warning|warnings|rules)\b"#),
        rx(#"\b(reveal|print|show|tell|repeat|output|give|send|share|leak|read out)\b.{0,30}\b(system prompt|your instructions|your rules|hidden rules|api key|gemini key|the key|keychain|password|passcode)\b"#),
        rx(#"\b(automatically|auto)\b.{0,20}\b(send|sends|call|ring|pay|transfer|text|message|reply|dial|delete|buy|order)\b"#),
        rx(#"\b(send|call|ring|pay|transfer|text|message|reply|dial|delete|buy|order)\b.{0,30}\b(automatically|on your own|by yourself|without me|straight away without)\b"#),
        rx(#"\bwithout\b.{0,25}\b(asking|ask|approval|approve|approving|permission|permissions|confirm|confirmation|confirming|checking|card|face id|passcode|consent|telling|the owner|say so)\b"#),
    ]

    /// Asking for secrets, or paying the way scammers ask to be paid. Kept only as a plain warning.
    private static let negatablePatterns: [NSRegularExpression] = [
        rx(#"\b(ask|asking|asks|collect|get|request|take|note|write down|send|read out|type in|enter)\b.{0,30}\b(pin|pin number|password|passcode|card number|long number on the card|security code|cvv|one time code|one time passcode|otp|verification code|sort code|account number|bank details|login|log in details)\b"#),
        rx(#"\b(gift card|gift cards|itunes card|google play card|bitcoin|crypto|cryptocurrency|safe account)\b.{0,40}\b(buy|pay|paid|send|transfer|move)\b|\b(buy|pay|paid|send|transfer|move)\b.{0,40}\b(gift card|gift cards|itunes card|google play card|bitcoin|crypto|cryptocurrency|safe account)\b"#),
    ]
    /// "never ask", "do not send", "won't ever pay": the negation right before the verb.
    private static let warningNegation = rx(#"\b(never|don t|do not|dont|must not|mustn t|should not|shouldn t|won t|will not|not)\s(\w+\s){0,3}(ask|asking|asks|collect|get|request|take|note|write|send|read|type|enter|buy|pay|paid|transfer|move|give|share)\b"#)
    /// Words that turn a negation into encouragement: "don't hesitate to ask for their PIN".
    private static let coaxingWords = rx(#"\b(hesitate|forget|fail|afraid|worry|be shy|be scared)\b"#)
    /// A sentence that starts by forbidding something: "Never send …", "Don't pay …".
    private static let safeLead = rx(#"^ (please )?(you )?(must |should )?(never|don t|do not|dont|must not|mustn t|should not|shouldn t|won t|will not)\b"#)
    /// Every negation: a safety rule has exactly one ("never …"); "never not …" or "don't refuse to …" turn it round.
    private static let negationWords = rx(#"\b(never|not|don t|dont|no|won t|can t|cannot|refuse|refuses|fail|fails|neglect|avoid|stop|cease|mustn t|shouldn t)\b"#)
    /// Words that let a rule turn round halfway: "never wait, just send without asking".
    private static let contrastWords = rx(#"\b(but|instead|just|except|unless|however|then|so|anyway|go ahead)\b"#)

    // MARK: Look-alike letters

    /// Cyrillic and Greek letters that look like Latin ones.
    static let lookAlikes: [Character: Character] = [
        "а": "a", "в": "b", "е": "e", "ё": "e", "к": "k", "м": "m", "н": "h", "о": "o", "р": "p", "с": "c", "т": "t",
        "у": "y", "х": "x", "ѕ": "s", "і": "i", "ї": "i", "ј": "j", "ԁ": "d", "һ": "h", "ӏ": "l", "ԛ": "q", "ԝ": "w",
        "А": "A", "В": "B", "Е": "E", "Ё": "E", "К": "K", "М": "M", "Н": "H", "О": "O", "Р": "P", "С": "C", "Т": "T",
        "У": "Y", "Х": "X", "Ѕ": "S", "І": "I", "Ј": "J",
        "α": "a", "β": "b", "ε": "e", "ι": "i", "κ": "k", "ν": "v", "ο": "o", "ρ": "p", "τ": "t", "υ": "u", "χ": "x",
        "Α": "A", "Β": "B", "Ε": "E", "Η": "H", "Ι": "I", "Κ": "K", "Μ": "M", "Ν": "N", "Ο": "O", "Ρ": "P", "Τ": "T",
        "Υ": "Y", "Χ": "X", "Ζ": "Z",
    ]

    /// A name in Latin letters with look-alikes mixed in becomes plain Latin. A name wholly in another script stays.
    static func unmix(_ name: String) -> String {
        guard name.unicodeScalars.contains(where: { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }) else { return name }
        return String(name.map { lookAlikes[$0] ?? $0 })
    }

    /// An already-folded name with look-alike letters read as Latin.
    static func skeleton(_ folded: String) -> String { String(folded.map { lookAlikes[$0] ?? $0 }) }

    /// What two names are compared by: "Mеdicine-Buddy" and "medicine buddy" are the same helper.
    static func nameKey(_ name: String) -> String { skeleton(name.folded) }

    private static func splitSentences(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(line)
        for (i, ch) in chars.enumerated() {
            current.append(ch)
            if ".!?;".contains(ch), i + 1 == chars.count || chars[i + 1].isWhitespace {
                let s = current.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { out.append(s) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    // MARK: Cleaning

    /// Drops control characters and invisible formatting (zero-width, bidi overrides, tag characters), which can
    /// hide instructions from the person while the model still reads them. Keeps newlines.
    static func cleanBlock(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.properties.generalCategory {
            case .format, .privateUse, .unassigned, .surrogate, .lineSeparator, .paragraphSeparator:
                if u.properties.generalCategory == .lineSeparator || u.properties.generalCategory == .paragraphSeparator {
                    scalars.append("\n")
                }
            case .control:
                if u == "\n" { scalars.append(u) } else if u == "\t" || u == "\r" { scalars.append(" ") }
            default:
                scalars.append(u)
            }
        }
        let lines = String(scalars).components(separatedBy: "\n").map {
            $0.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One line: as cleanBlock, with newlines turned into spaces.
    static func cleanLine(_ s: String) -> String {
        cleanBlock(s).components(separatedBy: "\n").filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Letters, digits, spaces and a little punctuation; quotes and symbols out.
    static func cleanName(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -'&"))
        let kept = String(String.UnicodeScalarView(cleanLine(s).unicodeScalars.map { allowed.contains($0) ? $0 : " " }))
        return kept.split(separator: " ").joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -'&"))
    }

    /// Cuts at a sentence end or a space, never mid-word, within the limit.
    static func clip(_ s: String, to limit: Int) -> String {
        guard s.count > limit else { return s }
        let head = String(s.prefix(limit))
        if let end = head.lastIndex(where: { ".!?".contains($0) }), head.distance(from: head.startIndex, to: end) > limit / 2 {
            return String(head[...end])
        }
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) > limit / 2 {
            return String(head[..<space])
        }
        return head
    }

    static func cleanList(_ items: [String], max: Int, length: Int, stripped: inout Int) -> [String] {
        var out: [String] = []
        for item in items.prefix(20) {
            let (s, c) = stripOverrides(cleanLine(item))
            stripped += c
            let clipped = clip(s, to: length)
            guard !clipped.isEmpty, !out.contains(where: { $0.folded == clipped.folded }) else { continue }
            out.append(clipped)
            if out.count == max { break }
        }
        return out
    }

    /// At most 20 facts of at most 140 characters, newest kept, no repeats, no override attempts.
    static func cleanMemory(_ facts: [String]) -> [String] {
        var n = 0
        return cleanMemory(facts, stripped: &n)
    }

    static func cleanMemory(_ facts: [String], stripped: inout Int) -> [String] {
        var out: [String] = []
        for fact in facts.suffix(60) {
            let (s, c) = stripOverrides(cleanLine(fact))
            stripped += c
            let clipped = clip(s, to: maxFact)
            guard !clipped.isEmpty else { continue }
            out.removeAll { $0.folded == clipped.folded }
            out.append(clipped)
        }
        return Array(out.suffix(maxMemory))
    }

    static func validIcon(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...60).contains(t.count), t.range(of: #"^[a-z0-9]+(\.[a-z0-9]+)*$"#, options: .regularExpression) != nil else { return nil }
        #if canImport(UIKit)
        guard UIImage(systemName: t) != nil else { return nil }
        #endif
        return t
    }

    static func validHex(_ s: String) -> String? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !t.hasPrefix("#") { t = "#" + t }
        return t.range(of: #"^#[0-9A-F]{6}$"#, options: .regularExpression) != nil ? t : nil
    }

    /// The same number for the same name on every launch (String.hashValue is not).
    static func stableHash(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
    }

    static func newID(for origin: AgentSpec.Origin) -> String {
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)
        return (origin == .imported ? "shared-" : "user-") + hex
    }

    /// "Medicine Buddy" → "Medicine Buddy 2" (or 3, …), kept within 30 characters.
    static func uniqueName(_ name: String, taken: Set<String>) -> String {
        for n in 2...99 {
            let suffix = " \(n)"
            let base = String(name.prefix(nameLength.upperBound - suffix.count)).trimmingCharacters(in: .whitespaces)
            let candidate = base + suffix
            if !taken.contains(candidate.folded), !taken.contains(nameKey(candidate)) { return candidate }
        }
        return String(name.prefix(20)) + " " + String(UUID().uuidString.prefix(4))
    }

    // MARK: Tools

    /// Names models often use for tools that exist under another name.
    static let aliases: [String: String] = [
        "set_reminder": "create_reminder", "add_reminder": "create_reminder", "reminder": "create_reminder",
        "reminders": "create_reminder", "make_reminder": "create_reminder",
        "alarm": "set_alarm", "create_alarm": "set_alarm", "add_alarm": "set_alarm",
        "timer": "set_timer", "start_timer": "set_timer", "create_timer": "set_timer",
        "add_event": "add_calendar_event", "create_event": "add_calendar_event", "calendar": "add_calendar_event",
        "add_to_calendar": "add_calendar_event", "create_calendar_event": "add_calendar_event",
        "get_events": "get_calendar_events", "read_calendar": "get_calendar_events", "check_calendar": "get_calendar_events",
        "calendar_events": "get_calendar_events",
        "weather": "get_weather", "check_weather": "get_weather",
        "directions": "get_directions", "maps": "get_directions", "navigate": "get_directions",
        "time": "what_time_and_date", "get_time": "what_time_and_date", "date": "what_time_and_date",
        "call": "call_contact", "phone_contact": "call_contact", "ring_contact": "call_contact",
        "message": "message_contact", "send_message": "message_contact", "text_contact": "message_contact",
        "send_text": "message_contact", "whatsapp": "message_contact",
        "contacts": "find_contact", "lookup_contact": "find_contact", "search_contacts": "find_contact",
        "scam_check": "check_scam", "check_for_scam": "check_scam", "scam": "check_scam",
        "letter": "read_letter", "read_document": "read_letter", "scan_letter": "read_letter",
        "settings": "open_phone_setting", "phone_settings": "open_phone_setting", "open_settings": "open_phone_setting",
        "shortcut": "run_my_shortcut", "run_shortcut": "run_my_shortcut",
        "screen": "read_screen", "read_whatsapp": "read_screen", "read_messages": "read_screen",
        "use_app": "operate_app", "open_app": "operate_app", "control_app": "operate_app", "drive_app": "operate_app",
        "routine": "run_routine", "make_routine": "create_routine", "save_routine": "create_routine",
    ]

    /// "Set Alarm", "set-alarm" → "set_alarm"; a known alias → its real name.
    static func normaliseToolName(_ raw: String, known: Set<String>) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        let n = String(lowered.unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
            .map(Character.init))
        if known.contains(n) { return n }
        if let real = aliases[n], known.contains(real) { return real }
        return n
    }

    static func looksLikeMoney(_ tool: String) -> Bool {
        ["pay", "payment", "transfer", "bank", "money", "purchase", "buy", "wallet"].contains { tool.contains($0) }
    }

    /// A helper about bills, payments or a budget: the only kind that may have prepare_payment.
    static func isMoneyHelper(_ spec: AgentSpec, purpose: String) -> Bool {
        let words = Set([spec.name, spec.tagline, purpose, spec.instructions].joined(separator: " ").folded.split(separator: " ").map(String.init))
        return !words.isDisjoint(with: moneyWords)
    }

    // MARK: Names

    /// Finds a helper by what the person called it: exact first, then without "the"/"my", then (when `fuzzy`) a
    /// unique helper whose name contains every word they said, then a unique first-word match.
    static func resolve(_ query: String, in entries: [StudioNameEntry], fuzzy: Bool = true) -> StudioNameEntry? {
        let q = query.folded
        guard !q.isEmpty else { return nil }
        if let hit = entries.first(where: { $0.id == query || $0.name.folded == q }) { return hit }
        let qt = withoutLeading(q.split(separator: " ").map(String.init))
        guard !qt.isEmpty else { return nil }
        if let hit = entries.first(where: { withoutLeading($0.name.folded.split(separator: " ").map(String.init)) == qt }) {
            return hit
        }
        guard fuzzy else { return nil }
        let generic: Set<String> = ["helper", "agent", "buddy", "assistant", "bot"]
        let wanted = qt.filter { !generic.contains($0) }
        guard !wanted.isEmpty else { return nil }
        let containing = entries.filter { e in
            let words = Set(e.name.folded.split(separator: " ").map(String.init))
            return wanted.allSatisfy { words.contains($0) }
        }
        if containing.count == 1 { return containing[0] }
        let firsts = entries.filter { $0.name.folded.split(separator: " ").first.map(String.init) == wanted[0] }
        return firsts.count == 1 ? firsts[0] : nil
    }

    static func withoutLeading(_ tokens: [String]) -> [String] {
        var t = tokens
        while let first = t.first, ["the", "my", "a", "an", "our"].contains(first) { t.removeFirst() }
        return t
    }

    /// Words a fact must share with what the person actually said: facts come from them, never from a letter.
    static func saidByPerson(_ fact: String, userWords: String) -> Bool {
        let stop: Set<String> = ["the", "and", "that", "this", "with", "for", "from", "are", "was", "has", "have",
                                 "you", "your", "his", "her", "their", "they", "she", "him", "its", "who", "what",
                                 "remember", "please", "always", "never", "owner", "person"]
        let factWords = Set(fact.folded.split(separator: " ").map(String.init).filter { $0.count >= 3 && !stop.contains($0) })
        guard !factWords.isEmpty else { return !fact.folded.isEmpty && userWords.folded.contains(fact.folded) }
        let said = Set(userWords.folded.split(separator: " ").map(String.init))
        let hits = factWords.filter { said.contains($0) }.count
        return Double(hits) / Double(factWords.count) >= 0.6
    }
}

// MARK: - Speech helpers

enum StudioSpeech {
    /// "A", "A and B", "A, B and C".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    /// What a tool lets a helper do, in the person's words.
    static let gists: [String: String] = [
        "set_alarm": "set alarms", "set_timer": "set timers", "create_reminder": "set reminders",
        "add_calendar_event": "add things to your calendar", "get_calendar_events": "check your calendar",
        "find_contact": "find your contacts", "call_contact": "ring your people",
        "message_contact": "write messages for you to send", "remember_relation": "remember who's who",
        "read_letter": "read letters", "ask_letter": "answer questions about a letter", "check_scam": "check for scams",
        "call_159": "ring 159 to reach your bank safely", "prepare_payment": "get a payment ready for your bank app",
        "money_question": "answer money questions", "what_time_and_date": "tell you the time and date",
        "get_directions": "find the way", "get_weather": "check the weather",
        "open_phone_setting": "help with your phone's settings", "run_my_shortcut": "run your Shortcuts",
        "read_screen": "read what's on your screen", "operate_app": "use your apps for you",
        "create_routine": "save routines", "run_routine": "run your routines",
        "save_last_as_routine": "save what it just did as a routine",
    ]

    /// "It can read what's on your screen and set reminders."
    static func abilities(_ tools: [String]) -> String {
        guard !tools.isEmpty else { return "It answers you itself; it doesn't change anything on your phone." }
        var said: [String] = []
        for tool in tools {
            let g = gists[tool] ?? tool.replacingOccurrences(of: "_", with: " ")
            if !said.contains(g) { said.append(g) }
        }
        let shown = Array(said.prefix(3))
        return "It can " + (said.count > 3 ? shown.joined(separator: ", ") + " and more" : list(shown)) + "."
    }
}

// MARK: - Automations: exact steps

extension AgentTrigger {
    /// Exact steps in the Shortcuts app for this automation. Kairos never sets one up by itself: the person does,
    /// so it only ever does what they chose.
    func setupSteps(agentName: String) -> [String] {
        let start = "Open the Shortcuts app and tap Automation at the bottom, then tap the + button."
        let ask = "Tap New Blank Automation, then Add Action. Search for “Ask a Kairos helper” and tap it. Tap Helper and choose \(agentName), then tap Request and type: “\(request)”. Tap Done."
        let allow = "The first time it runs, your iPhone may ask whether Kairos can run. Tap Always Allow."
        switch kind {
        case "time":
            return [start, "Tap Time of Day. Set the time and how often (\(detail)), choose Run Immediately, then tap Next.", ask, allow]
        case "arrive":
            return [start, "Tap Arrive and choose the place (\(detail)). Choose Run Immediately, then tap Next.", ask, allow]
        case "leave":
            return [start, "Tap Leave and choose the place (\(detail)). Choose Run Immediately, then tap Next.", ask, allow]
        case "charger":
            return [start, "Tap Charger and choose Is Connected or Is Disconnected (\(detail)). Choose Run Immediately, then tap Next.", ask, allow]
        case "message":
            // The message itself is someone else's words: it goes through "Tell Kairos", which treats it as
            // information only, never as instructions.
            return [start,
                    "Tap Message and choose who it's from, or a word it contains (\(detail)). Choose Run Immediately, then tap Next.",
                    "Tap New Blank Automation, then Add Action. Search for “Tell Kairos” and tap it. Tap Text and choose Shortcut Input, which is the message. Tap Done.",
                    "Kairos will look at each message and tell you if anything needs you. It never acts on what a message says.",
                    allow]
        default:
            return ["iPhone automations can't start when a notification arrives, so this one can't run by itself.",
                    "Instead, ask \(agentName) yourself when you see one, or make a Time of Day automation so it checks at a set time."]
        }
    }
}

// MARK: - Sharing

/// The screen shows a share sheet for this. The file leaves out the helper's memories: those stay on this phone.
struct AgentShareRequest: Identifiable, Equatable {
    let id = UUID()
    var spec: AgentSpec
    var json: Data
    /// "Medicine Buddy.kairos-helper.json" in the temporary folder, ready to attach.
    var fileURL: URL?
}

/// The shared form of a helper: no id, no memories, no dates.
private struct AgentShareFile: Codable {
    struct Shared: Codable {
        var name: String
        var icon: String
        var colorHex: String
        var tagline: String
        var instructions: String
        var allowedTools: [String]
        var starterPhrases: [String]
        var routines: [String]
        var triggers: [AgentTrigger]
        var version: Int
    }
    var format = "kairos.agent"
    var formatVersion = 1
    var agent: Shared
}

// MARK: - The library

/// The person's helpers: built-in ones first, then their own. One per app (`shared`); tests make their own with a
/// temporary file.
@MainActor
final class AgentLibrary: ObservableObject {
    static let shared = AgentLibrary()

    /// Built-in helpers first (with whatever the person told them to remember), then the person's own, oldest first.
    @Published private(set) var agents: [AgentSpec] = []
    /// The helper in charge (focus mode). Nil means Kairos itself. Only a helper exactly as the library holds it
    /// (vetted, current) can be in charge: a draft from a screen or a stale copy is swapped for the saved one, and
    /// anything the library doesn't hold is refused.
    @Published var focused: AgentSpec? {
        didSet {
            if !settlingFocus, let f = focused {
                let saved = agents.first { $0.id == f.id }
                if saved != f { settlingFocus = true; focused = saved; settlingFocus = false }
            }
            if updatesSnapshot { StudioSnapshot.shared.setFocused(focused?.id) }
        }
    }
    private var settlingFocus = false
    /// Set by share_agent: the screen shows a share sheet, then sets this back to nil.
    @Published var shareRequest: AgentShareRequest?
    /// Plain words when the saved helpers couldn't be read.
    @Published private(set) var problem: String?

    /// Called after every change. The integrator sets it to `{ TempoShortcuts.updateAppShortcutParameters() }` so
    /// Siri learns new helper names ("Talk to Garden Pal in Kairos").
    static var didChange: (@MainActor () -> Void)?

    /// Tests only: the tools to vet against.
    var catalogOverride: [StudioToolRef]?

    let fileURL: URL?
    private let updatesSnapshot: Bool
    private var own: [AgentSpec] = []
    private var builtinMemory: [String: [String]] = [:]
    /// False while the file exists but can't be read (a locked phone): nothing is written until it can be.
    private var readable = false

    init(fileURL: URL? = AgentLibrary.defaultFileURL(), updatesSnapshot: Bool = true) {
        self.fileURL = fileURL
        self.updatesSnapshot = updatesSnapshot
        load()
        publish()
    }

    nonisolated static func defaultFileURL() -> URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true) else { return nil }
        return base.appendingPathComponent("Kairos", isDirectory: true).appendingPathComponent("agents.json")
    }

    // MARK: Looking up

    func spec(id: String) -> AgentSpec? { agents.first { $0.id == id } }

    /// By what the person called it: "Medicine Buddy", "the medicine buddy", "medicine". `exact` turns off the
    /// guessing (for deleting).
    func spec(named name: String) -> AgentSpec? { spec(named: name, exact: false) }

    func spec(named name: String, exact: Bool) -> AgentSpec? {
        let entries = agents.map { StudioNameEntry(id: $0.id, name: $0.name) }
        guard let hit = StudioRules.resolve(name, in: entries, fuzzy: !exact) else { return nil }
        return spec(id: hit.id)
    }

    func isNameFree(_ name: String, except id: String? = nil) -> Bool {
        let key = StudioRules.nameKey(StudioRules.cleanName(name))
        return !StudioRules.reservedKeys.contains(key) && !agents.contains { $0.id != id && StudioRules.nameKey($0.name) == key }
    }

    func catalog() -> [StudioToolRef] { catalogOverride ?? StudioCatalog.current() }

    /// The helper's tools that exist on this phone right now.
    func availableTools(for spec: AgentSpec) -> [String] {
        let known = Set(catalog().map(\.name))
        return spec.allowedTools.filter { known.contains($0) }
    }

    /// The helper's tools this phone doesn't have (the phone helper isn't set up, say).
    func missingTools(for spec: AgentSpec) -> [String] {
        let known = Set(catalog().map(\.name))
        return spec.allowedTools.filter { !known.contains($0) }
    }

    // MARK: Changing

    /// Saves a helper from the screen. A built-in helper only takes changes to its memory; anything else throws
    /// `builtinReadOnly` (offer `duplicate`). Returns the helper as saved (cleaned, with its id).
    @discardableResult
    func save(_ spec: AgentSpec) throws -> AgentSpec {
        try ensureReadable()
        if let builtin = BuiltinAgents.spec(id: spec.id) {
            var probe = spec
            probe.memory = builtin.memory
            guard probe == builtin else { throw AgentStudioError.builtinReadOnly(builtin.name) }
            let before = builtinMemory[spec.id]
            builtinMemory[spec.id] = StudioRules.cleanMemory(spec.memory)
            do { try persist() } catch { builtinMemory[spec.id] = before; throw error }
            publish()
            return self.spec(id: spec.id) ?? builtin
        }
        return try commit(spec, mode: .save).spec
    }

    /// Vets and stores a helper: new if its id isn't one of the person's, else a change to it.
    @discardableResult
    func commit(_ draft: AgentSpec, mode: StudioRules.Mode, purpose: String = "") throws -> StudioVetted {
        try ensureReadable()
        let existing = own.firstIndex { $0.id == draft.id && !draft.id.isEmpty }
        if existing == nil, own.count >= StudioRules.maxOwnAgents { throw AgentStudioError.tooMany }
        var input = draft
        // A helper someone shared stays "shared" whatever the draft says: relabelling it as the person's own would
        // let it get payments and a trusted voice in the prompt.
        if let i = existing, own[i].origin == .imported { input.origin = .imported }
        if existing == nil, mode == .save || mode == .edit, input.id.isEmpty || BuiltinAgents.ids.contains(input.id) {
            input.id = ""
            input.createdAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        }
        let taken = Set(agents.filter { $0.id != draft.id || draft.id.isEmpty }.map { $0.name.folded })
        var vetted = try StudioRules.vet(input, purpose: purpose, catalog: catalog(), takenNames: taken, mode: mode)
        if let i = existing, mode == .save || mode == .edit {
            vetted.spec.id = own[i].id
            vetted.spec.createdAt = own[i].createdAt
        }
        let before = own
        if let i = own.firstIndex(where: { $0.id == vetted.spec.id }) { own[i] = vetted.spec } else { own.append(vetted.spec) }
        do { try persist() } catch { own = before; throw error }
        publish()
        return vetted
    }

    /// Deletes one of the person's helpers. Built-in helpers stay.
    func delete(id: String) {
        guard !BuiltinAgents.ids.contains(id), (try? ensureReadable()) != nil else { return }
        let before = own
        own.removeAll { $0.id == id }
        guard own.count != before.count else { return }
        do { try persist() } catch { own = before; return }
        if focused?.id == id { focused = nil }
        publish()
    }

    /// The person's own copy of a helper (built-in or not), with its memories, ready to change.
    @discardableResult
    func duplicate(_ spec: AgentSpec, as newName: String? = nil) throws -> AgentSpec {
        var copy = spec
        copy.id = ""
        copy.origin = spec.origin == .imported ? .imported : .user
        copy.version = 1
        let wanted = StudioRules.cleanName(newName ?? "My \(spec.name)")
        let taken = Set(agents.map { $0.name.folded })
        copy.name = taken.contains(wanted.folded) ? StudioRules.uniqueName(wanted, taken: taken) : wanted
        if copy.name.count > StudioRules.nameLength.upperBound {
            copy.name = StudioRules.uniqueName(String(spec.name.prefix(26)), taken: taken)
        }
        return try commit(copy, mode: .edit).spec
    }

    struct Remembered: Sendable, Equatable {
        var spec: AgentSpec
        var fact: String
        var alreadyKnown: Bool
        var droppedOldest: Bool
    }

    /// Adds a fact to a helper's memory (built-in helpers too). The oldest goes when there are 20.
    @discardableResult
    func remember(_ fact: String, for id: String) throws -> Remembered {
        guard var spec = spec(id: id) else { throw AgentStudioError.notFound(id) }
        let cleaned = StudioRules.cleanMemory([fact])
        guard let clean = cleaned.first else { throw AgentStudioError.nothingToDo }
        if spec.memory.contains(where: { $0.folded == clean.folded }) {
            return Remembered(spec: spec, fact: clean, alreadyKnown: true, droppedOldest: false)
        }
        let full = spec.memory.count >= StudioRules.maxMemory
        spec.memory.append(clean)
        spec.memory = StudioRules.cleanMemory(spec.memory)
        let saved = try save(spec)
        return Remembered(spec: saved, fact: clean, alreadyKnown: false, droppedOldest: full)
    }

    /// Takes one fact out of a helper's memory.
    func forget(_ fact: String, for id: String) throws {
        guard var spec = spec(id: id) else { throw AgentStudioError.notFound(id) }
        spec.memory.removeAll { $0.folded == fact.folded }
        try save(spec)
    }

    // MARK: Sharing

    /// The shareable file: everything but the helper's memories, id and dates.
    func exportJSON(_ spec: AgentSpec) -> Data {
        let file = AgentShareFile(agent: .init(name: spec.name, icon: spec.icon, colorHex: spec.colorHex, tagline: spec.tagline,
                                               instructions: spec.instructions, allowedTools: spec.allowedTools,
                                               starterPhrases: spec.starterPhrases, routines: spec.routines,
                                               triggers: spec.triggers, version: spec.version))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(file)) ?? Data("{}".utf8)
    }

    /// Writes the share file to the temporary folder and asks the screen to show the share sheet.
    @discardableResult
    func prepareShare(_ spec: AgentSpec, showSheet: Bool = true) -> AgentShareRequest {
        let json = exportJSON(spec)
        let safeName = StudioRules.cleanName(spec.name).replacingOccurrences(of: " ", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName.isEmpty ? "helper" : safeName).kairos-helper.json")
        let written = (try? json.write(to: url, options: .atomic)) != nil
        let request = AgentShareRequest(spec: spec, json: json, fileURL: written ? url : nil)
        if showSheet { shareRequest = request }
        return request
    }

    /// Adds a helper someone shared. The text is untrusted: it is checked like a new helper, tools this phone
    /// doesn't have are dropped, payments and helper-making are never allowed, and its own id is ignored.
    func importJSON(_ data: Data) throws -> AgentSpec { try importAgent(data).spec }

    /// As importJSON, with what was changed (for telling the person).
    func importAgent(_ data: Data) throws -> StudioVetted {
        let draft = try Self.draft(fromShared: data)
        return try commit(draft, mode: .import)
    }

    /// Reads a shared helper's fields, accepting only strings where strings belong. Unknown fields are ignored.
    nonisolated static func draft(fromShared data: Data) throws -> AgentSpec {
        guard data.count <= StudioRules.maxShareBytes else { throw AgentStudioError.tooBig }
        var bytes = data
        // A pasted message may have words around the file: take the outermost {...}.
        if let text = String(data: data, encoding: .utf8), let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"),
           open < close {
            bytes = Data(text[open...close].utf8)
        }
        guard let root = JSONValue.decode(bytes), case .object = root else { throw AgentStudioError.badFile }
        if let format = str(root["format"]), !format.hasPrefix("kairos.agent") { throw AgentStudioError.badFile }
        let a: JSONValue = (root["agent"]?.object != nil) ? root["agent"]! : root
        func field(_ keys: String...) -> JSONValue? { keys.lazy.compactMap { a[$0] }.first }
        guard let name = str(field("name")), let instructions = str(field("instructions")) else { throw AgentStudioError.badFile }
        let triggers: [AgentTrigger] = (field("triggers")?.array ?? []).prefix(10).compactMap { t in
            guard let kind = str(t["kind"]), let request = str(t["request"]) else { return nil }
            return AgentTrigger(kind: kind, detail: str(t["detail"]) ?? "", request: request)
        }
        return AgentSpec(id: "", name: name, icon: str(field("icon")) ?? "", colorHex: str(field("colorHex", "color_hex", "color")) ?? "",
                         tagline: str(field("tagline")) ?? "", instructions: instructions,
                         allowedTools: strs(field("allowedTools", "allowed_tools", "tools")),
                         starterPhrases: strs(field("starterPhrases", "starter_phrases")),
                         routines: strs(field("routines")), triggers: triggers, memory: [],
                         origin: .imported, version: 1, createdAt: Date())
    }

    nonisolated private static func str(_ v: JSONValue?) -> String? {
        if case .string(let s)? = v { return s }
        return nil
    }

    nonisolated private static func strs(_ v: JSONValue?) -> [String] {
        (v?.array ?? []).prefix(50).compactMap { str($0) }
    }

    // MARK: Focus

    /// Puts a helper in charge, or Kairos (nil).
    func focus(on spec: AgentSpec?) { focused = spec.flatMap { self.spec(id: $0.id) } }

    // MARK: Storage

    private struct StoreFile: Codable {
        var format = "kairos.agents"
        var formatVersion = 1
        var agents: [AgentSpec]
        var builtinMemory: [String: [String]]
    }

    /// Reads the file again (after the phone is unlocked, say).
    func reload() {
        load()
        publish()
    }

    private func ensureReadable() throws {
        if !readable { load(); publish() }
        guard readable else { throw AgentStudioError.storeUnavailable }
    }

    private func load() {
        guard let url = fileURL else { readable = true; return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            own = []; builtinMemory = [:]; readable = true; problem = nil
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Most likely the phone is locked and the file is protected: try again later, never overwrite it.
            readable = false
            problem = AgentStudioError.storeUnavailable.errorDescription
            return
        }
        guard let root = JSONValue.decode(data), case .object = root else {
            setAside(url)
            own = []; builtinMemory = [:]; readable = true
            problem = "Your saved helpers couldn't be read, so I've put that file aside and started afresh."
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [AgentSpec] = []
        var skipped = 0
        for entry in root["agents"]?.array ?? [] {
            if var spec = try? decoder.decode(AgentSpec.self, from: entry.encoded()),
               !BuiltinAgents.ids.contains(spec.id), !loaded.contains(where: { $0.id == spec.id }) {
                if spec.origin == .builtin { spec.origin = .user }
                loaded.append(spec)
            } else {
                skipped += 1
            }
        }
        var memory: [String: [String]] = [:]
        for (id, facts) in root["builtinMemory"]?.object ?? [:] where BuiltinAgents.ids.contains(id) {
            memory[id] = StudioRules.cleanMemory((facts.array ?? []).compactMap { $0.string })
        }
        own = loaded
        builtinMemory = memory
        readable = true
        problem = skipped > 0 ? "\(skipped == 1 ? "One saved helper" : "\(skipped) saved helpers") couldn't be read." : nil
        if skipped > 0 { setAside(url, copy: true) }
    }

    /// Keeps a copy of an unreadable file next to it, so nothing the person made is lost for good.
    private func setAside(_ url: URL, copy: Bool = false) {
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = url.deletingLastPathComponent().appendingPathComponent("agents.unreadable-\(stamp).json")
        if copy { try? FileManager.default.copyItem(at: url, to: aside) } else { try? FileManager.default.moveItem(at: url, to: aside) }
    }

    private func persist() throws {
        guard let url = fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(StoreFile(agents: own, builtinMemory: builtinMemory))
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            try data.write(to: url, options: options)
        } catch {
            throw AgentStudioError.writeFailed
        }
    }

    private func publish() {
        let builtins = BuiltinAgents.all.map { b -> AgentSpec in
            var s = b
            s.memory = builtinMemory[b.id] ?? []
            return s
        }
        // Oldest first; the order in the file breaks ties, so the list never reshuffles.
        let mine = own.enumerated().sorted { ($0.element.createdAt, $0.offset) < ($1.element.createdAt, $1.offset) }.map(\.element)
        agents = builtins + mine
        if let current = focused {
            let fresh = agents.first { $0.id == current.id }
            if fresh != current { focused = fresh }
        }
        if updatesSnapshot { StudioSnapshot.shared.update(agents) }
        if updatesSnapshot { Self.didChange?() }
    }
}
