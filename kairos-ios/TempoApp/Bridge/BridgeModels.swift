import Foundation

// Kairos Communications Bridge ("Write for me"): shared types for every Bridge file.
// The contract is research/Kairos-Server-Architecture.md, "The Communications Bridge" and "Our server's API".
// Rules that every Bridge file must keep:
//  * Phone numbers and emails never leave the phone. The server only ever sees `recipient_ref` (e.g. "p_7f3a").
//  * The text on screen is what gets approved. Anything a model sends (text, recipient) is ignored at hand-off.
//  * Every revision is a new version; an old version can't be approved (the server returns 409).
//  * The approval nonce is single use and expires (expires_in, 120 s). Hand off before it expires.
//  * End the ElevenLabs call before opening another app (the mic could otherwise stay live).

// MARK: - People (stored on the phone only)

enum BridgeChannel: String, Codable, CaseIterable, Identifiable {
    case whatsapp, sms, email, telegram, signal
    var id: String { rawValue }
    /// What the big send button says, e.g. "Send on WhatsApp".
    var sendLabel: String {
        switch self {
        case .whatsapp: return "Send on WhatsApp"
        case .sms: return "Send as a text message"
        case .email: return "Send as an email"
        case .telegram: return "Send on Telegram"
        case .signal: return "Send on Signal"
        }
    }
    var appName: String {
        switch self {
        case .whatsapp: return "WhatsApp"
        case .sms: return "Messages"
        case .email: return "Mail"
        case .telegram: return "Telegram"
        case .signal: return "Signal"
        }
    }
}

enum BridgeTone: String, Codable, CaseIterable, Identifiable {
    case warm, polite, formal, brief
    case keepMyWords = "keep-my-words"   // the hub's spelling for the draft tone (the revise chip is "keep_my_words")
    var id: String { rawValue }

    /// Accepts the older "keep_my_words" spelling too, so people saved before the live contract still load.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BridgeTone(rawValue: raw) ?? (raw == "keep_my_words" ? .keepMyWords : .warm)
    }
}

/// One person Kairos can write to. Lives only on this iPhone (PeopleStore). `ref` is the only thing the server sees.
struct KairosPerson: Codable, Identifiable, Hashable {
    var id: String { ref }
    let ref: String              // "p_" + 4-8 random lowercase hex, stable for this person
    var alias: String            // what the user calls them: "Amma", "Ravi", "Dr Shah"
    var relation: String?        // "mother", "son", "GP surgery"
    var channel: BridgeChannel   // how they like to be reached
    var tone: BridgeTone         // default tone for this person
    var language: String         // target language + script: "te-Telu", "te-Latn", "en-GB", "hi-Deva", "cy"
    var phone: String?           // E.164 digits, phone only, never sent to the server
    var email: String?           // phone only, never sent to the server

    /// "Amma, your mother": shown everywhere after choosing, because m/n and similar names are easy to confuse.
    var recipientLine: String {
        guard let r = relation?.trimmingCharacters(in: .whitespaces), !r.isEmpty else { return alias }
        return "\(alias), your \(r)"
    }

    static func newRef() -> String {
        "p_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
    }
}

/// Result of matching a spoken name against the People list. Only `.exact` may proceed without asking.
enum PersonMatch: Equatable {
    case exact(KairosPerson)
    case ambiguous([KairosPerson])   // e.g. "Amma" vs "Anna": always ask which one
    case none
}

// MARK: - Server contract (POST /api/bridge/draft etc.)

struct BridgeRecipient: Codable, Equatable {
    let ref: String
    let alias: String
    let relation: String?
    let lang: String
}

/// The `meta` part of POST /api/bridge/draft (multipart with `audio=<m4a>`), or the JSON body when there is no audio
/// (in-call path: the person's own transcript turns go in `transcript`).
struct BridgeDraftMeta: Codable, Equatable {
    let recipient: BridgeRecipient
    let channel: String
    let tone: String
    let target_lang: String
    let user: [String: String]?
    let transcript: String?            // in-call path only: the person's own words, joined (never with audio)
    var speech_lang: String? = nil     // the language they spoke, if known ("en", "te", ...)
}

struct BridgeFlag: Codable, Equatable, Hashable {
    let kind: String          // "time", "number", "url", "phone", "email", "iban", "money", "health", "legal", "work", ...
    let value: String?
    let in_transcript: Bool?
}

struct BridgeChecks: Codable, Equatable {
    let blocked: [BridgeFlag]   // any entry here: the draft can't be sent
    let flags: [BridgeFlag]     // show as notes; money/health/legal/work need an extra tap
    var needs_tap: Bool? = nil  // the hub's verdict: any risk topic OR any flag -> needs an explicit tap
    var risk: [String]? = nil   // the sensitive topics: "money", "health", "legal", "work"
}

struct BridgeHeard: Codable, Equatable {
    let text: String            // verbatim transcript, shown as "I heard"
    let lang: String?
}

struct BridgeDraft: Codable, Equatable, Identifiable {
    var id: String { "\(draft_id)#\(version)" }
    let draft_id: String
    let version: Int
    let heard: BridgeHeard
    let text: String
    let back_translation: String?
    let checks: BridgeChecks
    let changes_made: [String]
    let missing: [String]
    let text_hash: String
}

/// POST /api/bridge/drafts/{id}/revise: either a chip or the person's own edited text.
struct BridgeReviseRequest: Codable, Equatable {
    let version: Int            // the version being revised (the server answers with version + 1; stale -> 409)
    let chip: String?           // "warmer" | "more_formal" | "shorter" | "keep_my_words" | "polite"
    var text: String? = nil     // their own edit, instead of a chip
}

/// POST /api/bridge/drafts/{id}/approve
struct BridgeApproveRequest: Codable, Equatable {
    let version: Int
    let text_hash: String
    let recipient_ref: String
    let channel: String
    let method: String          // "tap" (Write for me card) or "voice" (in-call deliver_message)
}

struct BridgeApproval: Codable, Equatable {
    let nonce: String
    let expires_in: Int
    let delivery: String        // "handoff" for every channel in the demo
    let text: String            // the exact stored text: this is what gets handed off
}

/// POST /api/bridge/drafts/{id}/outcome
enum BridgeOutcome: String, Codable {
    case handedOff = "handed_off"   // wa.me / tg / share sheet: we can't know if it was sent
    case sent, cancelled, failed
}

enum BridgeError: Error, Equatable {
    case notConfigured                  // no base URL / credentials on this phone
    case unclear(askUser: String)       // 422 {"error":"unclear","ask_user":"..."}
    case staleOrMismatch                // 409: a newer version exists or the text changed
    case blocked([BridgeFlag])          // the draft has blocked items; never hand off
    case expired                        // nonce expired before hand-off
    case server(Int, String)
    case network(String)
    case unreachable                    // couldn't even connect (no Wi-Fi, Mac asleep, tunnel down): never fall back

    var spoken: String {
        switch self {
        case .notConfigured: return "Kairos isn't connected to your Mac yet."
        case .unclear(let ask): return ask
        case .staleOrMismatch: return "This message changed. Please check it again before sending."
        case .blocked: return "I can't send this one, because it has something in it you didn't say."
        case .expired: return "That took too long. Please tap Send again."
        case .server(_, let m): return m.isEmpty ? "Something went wrong on your Mac." : m
        case .network: return "I can't reach your Mac. Check the Wi-Fi."
        case .unreachable: return "I can't reach your Mac right now. Nothing was sent. Check the Wi-Fi and try again."
        }
    }
}

/// Everything the Bridge needs from a server. LiveBridgeAPI talks to the hub; MockBridgeAPI is "practice mode".
protocol BridgeAPI: AnyObject {
    /// True for the mock, so the UI can show a "Practice mode" badge.
    var isPractice: Bool { get }
    /// audio: m4a bytes (Write for me) or nil with meta.transcript set (in-call path).
    func draft(audio: Data?, meta: BridgeDraftMeta) async throws -> BridgeDraft
    func revise(draftId: String, request: BridgeReviseRequest) async throws -> BridgeDraft
    func approve(draftId: String, request: BridgeApproveRequest) async throws -> BridgeApproval
    func readback(draftId: String) async throws -> Data?   // MP3 of the exact text, or nil if not available
    /// The hub needs the single-use approval nonce with the outcome.
    func outcome(draftId: String, nonce: String?, outcome: BridgeOutcome) async
    func cancel(draftId: String) async
}

// MARK: - Small shared helpers

extension BridgeDraft {
    var isBlocked: Bool { !checks.blocked.isEmpty }
    /// Drafts about money, health, legal matters or work need an extra, explicit tap.
    var needsExtraTap: Bool {
        !(checks.risk ?? []).isEmpty || checks.flags.contains { ["money", "health", "legal", "work"].contains($0.kind) }
    }
    /// Anything the person should look at before sending: sensitive topics, a value they never said, or missing facts.
    var needsCheck: Bool {
        needsExtraTap || checks.needs_tap == true || checks.flags.contains { $0.in_transcript == false } || !missing.isEmpty
    }
}

extension String {
    /// Digits only, for wa.me and tg:// (no "+", spaces or dashes).
    var bridgeDigits: String { filter(\.isNumber) }
}
