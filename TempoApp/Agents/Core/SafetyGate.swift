import Foundation
import LocalAuthentication

/// The gate's verdict on one proposed tool call.
enum GateDecision: Equatable, Sendable {
    case allow
    case confirm(detail: String, warning: String?)  // big card, then Face ID / passcode
    case clarify(String)                            // ask the person one short question
    case block(String)                              // refuse, in plain words
}

/// Deterministic veto between the model and the tools. The model only proposes; code decides.
struct SafetyGate: Sendable {

    func check(_ tool: any KairosTool, _ args: JSONValue, ctx: TurnContext) -> GateDecision {
        switch tool.validate(args, ctx: ctx) {
        case .clarify(let question): return .clarify(question)
        case .block(let reason): return .block(reason)
        case .ok: break
        }
        var warning: String?
        if tool.risk >= .reachesPerson, let leak = Self.documentOnlyValue(in: args, ctx: ctx) {
            // A number or link the person never said, but a letter or message did: the classic injection
            // ("call 0900 … now"). Where it would be dialled or opened, refuse; inside message text, warn.
            if leak.isAddress {
                return .block("That \(leak.kind) came from the letter or message, not from you, so I won't use it. If you really want it, say it to me yourself.")
            }
            warning = "This includes a \(leak.kind) from the letter or message, not from you. Check it before you send."
        }
        // Saved things (routines, helpers, a helper's memory) outlive this conversation. While a letter or message is
        // in it, changing them needs a card unless the person's own last words asked for that kind of change.
        if tool.risk == .localWrite, !ctx.documents.isEmpty, Self.persistent.contains(tool.name) {
            let last = " " + (ctx.userWords.split(separator: "\n").last.map { String($0).folded } ?? "") + " "
            let asked = ["routine", "routines", "shortcut", "agent", "helper", "remember", "delete", "forget", "save"]
                .contains { last.contains(" \($0) ") }
            if !asked {
                return .confirm(detail: tool.describe(args, ctx: ctx),
                                warning: "A letter or message is in this conversation. Say yes only if you asked for this yourself.")
            }
        }
        switch tool.risk {
        case .read, .localWrite: return .allow
        case .reachesPerson, .money: return .confirm(detail: tool.describe(args, ctx: ctx), warning: warning)
        }
    }

    /// Tools whose effect is saved and replayed later.
    static let persistent: Set<String> = ["create_routine", "save_last_as_routine", "delete_routine", "create_agent",
                                          "edit_agent", "delete_agent", "remember_for_agent", "import_agent",
                                          "remember_relation", "remember_fact", "forget_memory"]

    struct Leak: Equatable { var kind: String; var isAddress: Bool }

    /// Argument keys whose value would be dialled, opened or paid to.
    static let addressKeys: Set<String> = ["phone", "phone_number", "number", "to", "recipient_number", "url", "link",
                                           "email", "account", "account_number", "sort_code", "iban", "payee_account"]

    /// The first phone number, account number, link or email in the arguments that appears in an untrusted
    /// document but not in anything the person said.
    static func documentOnlyValue(in args: JSONValue, ctx: TurnContext) -> Leak? {
        guard !ctx.documents.isEmpty else { return nil }
        let saidDigits = digitRuns(ctx.userWords).map(national)
        let saidPlain = plainLinks(ctx.userWords)
        let docs = ctx.documents.joined(separator: "\n")
        let docDigits = digitRuns(docs).map(national)
        let docPlain = plainLinks(docs)
        for (key, value) in flatten(args) {
            let isAddress = addressKeys.contains(key.lowercased())
            for raw in digitRuns(value) where raw.count >= 6 {
                let run = national(raw)
                if docDigits.contains(where: { $0.contains(run) || run.contains($0) && $0.count >= 6 }),
                   !saidDigits.contains(where: { $0.contains(run) }) {
                    return Leak(kind: run.count >= 9 ? "phone number" : "number", isAddress: isAddress)
                }
            }
            for link in links(value).map(plainLinks) where docPlain.contains(link) && !saidPlain.contains(link) {
                return Leak(kind: link.contains("@") ? "email address" : "web link", isAddress: true)
            }
        }
        return nil
    }

    /// One form for UK numbers: "+44 7700 900123", "0044 7700 900123" and "07700 900123" all become 07700900123.
    static func national(_ run: String) -> String {
        if run.hasPrefix("0044"), run.count >= 13 { return "0" + run.dropFirst(4) }
        if run.hasPrefix("44"), run.count >= 12 { return "0" + run.dropFirst(2) }
        return run
    }

    /// Lowercased, without "https://", "http://", "www." or a trailing "/", so a link the model tidied up
    /// ("https://www.x.co.uk/") still matches the letter's "x.co.uk".
    static func plainLinks(_ s: String) -> String {
        var t = s.lowercased()
        for p in ["https://", "http://", "www."] { t = t.replacingOccurrences(of: p, with: "") }
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }

    /// Digit sequences, allowing the spaces, dashes and brackets people put inside phone numbers.
    static func digitRuns(_ s: String) -> [String] {
        var runs: [String] = []
        var current = ""
        var gap = 0
        for ch in s {
            if ch.isASCII, ch.isNumber { current.append(ch); gap = 0 }
            else if current.isEmpty == false, " -()+.".contains(ch), gap == 0 { gap += 1 }
            else { if !current.isEmpty { runs.append(current) }; current = ""; gap = 0 }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    static func links(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".!?)(\"'<>[]:")) }  // trim BEFORE testing
            .filter { $0.hasPrefix("http") || $0.hasPrefix("www.") || $0.contains("@") || looksLikeDomain($0) }
    }

    /// "bit.ly/abc", "secure-bank.net/login", "example.co.uk": a host whose last label is 2 to 6 letters.
    static func looksLikeDomain(_ word: String) -> Bool {
        let host = word.split(separator: "/", maxSplits: 1).first.map(String.init) ?? word
        guard let dot = host.lastIndex(of: "."), dot != host.startIndex else { return false }
        let tld = host[host.index(after: dot)...]
        return (2...6).contains(tld.count) && tld.allSatisfy { $0.isASCII && $0.isLetter }
    }

    /// Every string value with the key it sits under.
    static func flatten(_ v: JSONValue, key: String = "") -> [(String, String)] {
        switch v {
        case .object(let o): return o.flatMap { flatten($0.value, key: $0.key) }
        case .array(let a): return a.flatMap { flatten($0, key: key) }
        case .string(let s): return [(key, s)]
        case .number: return [(key, v.string ?? "")]
        default: return []
        }
    }
}

/// Face ID / Touch ID / passcode: the owner, not just whoever holds the phone.
enum OwnerCheck {
    static func verify(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        // A phone with no passcode can't prove its owner; the big Yes tap is all we have.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        do { return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) }
        catch { return false }
    }
}
