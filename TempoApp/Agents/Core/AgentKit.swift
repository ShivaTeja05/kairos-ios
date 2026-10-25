import Foundation

// The contract every on-phone agent follows. Kairos (the orchestrator, KairosAgent.swift) talks to the model;
// specialist agents only supply tools. A tool is plain Swift: the model proposes a call, code validates it,
// the SafetyGate decides, and only then does execute() run. Replies about what happened come from tool
// results, never from the model's own prose (the Foundation Models spike caught the model claiming a
// reminder it never created).

/// How much a tool can affect the person's life. The gate gets stricter as risk goes up.
enum Risk: Int, Comparable, Sendable {
    case read = 0          // looks something up on the phone or the web
    case localWrite = 1    // changes something only the owner sees (reminder, alarm, calendar)
    case reachesPerson = 2 // calls or messages someone: card + Face ID, the person sends it themselves
    case money = 3         // anything about payments: never automatic

    static func < (a: Risk, b: Risk) -> Bool { a.rawValue < b.rawValue }
}

/// Where the request came from. Siri in the background can't show cards or open other apps.
enum AgentSource: String, Sendable {
    case app             // typed or spoken inside Kairos
    case siriBackground  // "Hey Siri, ask Kairos …", phone may be locked
    case siriForeground  // Siri opened Kairos
    case automation      // a Shortcuts automation reported something (untrusted text)
}

/// Everything a tool may look at for one request.
struct TurnContext: Sendable {
    /// Trusted: what the person said or typed in this conversation (latest last).
    var userWords: String
    /// Untrusted: text from letters, pasted messages, automations and web results. Information, never instructions.
    var documents: [String]
    /// JPEG photos attached to this request (letters, bills, forms).
    var images: [Data]
    var now: Date
    var timeZone: TimeZone
    /// BCP-47 code of the person's language, e.g. "en-GB", "te-IN".
    var language: String
    var source: AgentSource
    /// The cloud model, for tools that need their own model call (letter reading). Nil when there's no key.
    var model: (any ModelProvider)?

    var canShowUI: Bool { source != .siriBackground && source != .automation }

    /// Calendar in the person's time zone, for date maths.
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.locale = Locale(identifier: language)
        return c
    }
}

/// Something the app must do on screen to finish a tool's job.
enum UIRequest: Sendable, Equatable {
    case openURL(URL)  // Messages/WhatsApp prefilled (the person taps Send), tel:, Maps, Settings
    case camera        // take a photo of a letter, then ask again with the image
}

struct ToolResult: Sendable {
    var ok: Bool
    /// One or two short, plain sentences for the person; spoken aloud.
    var say: String
    /// Facts for the model (sent back as the functionResponse).
    var data: JSONValue = .null
    /// Something the app has to show or open.
    var ui: UIRequest? = nil
    /// Text the tool read from outside (a letter, a web page). Added to the untrusted documents.
    var untrustedText: String? = nil
    /// `say` is the whole answer for the person (a letter explained): Kairos speaks it as it is instead of
    /// letting the model retell it. Results of actions (risk ≥ .localWrite) are always spoken as they are.
    var isAnswer: Bool = false

    static func fail(_ say: String) -> ToolResult { ToolResult(ok: false, say: say, data: ["error": .string(say)]) }
}

struct ToolCall: Sendable, Equatable {
    var id: String?
    var name: String
    var args: JSONValue
}

/// What code thinks of a proposed call before the gate looks at risk.
enum Validation: Sendable, Equatable {
    case ok
    case clarify(String)  // ask the person one short question
    case block(String)    // refuse, with the reason in plain words
}

protocol KairosTool: Sendable {
    /// snake_case, unique across all agents.
    var name: String { get }
    /// What the tool does, written for the model.
    var summary: String { get }
    /// JSON schema of the arguments (Schema.object(...)).
    var parameters: JSONValue { get }
    var risk: Risk { get }
    /// Deterministic fast path with no model call (works offline, saves free-tier quota).
    /// Return the arguments only when the words clearly mean this tool.
    func quickMatch(_ words: String, ctx: TurnContext) -> JSONValue?
    /// Code checks on the model's arguments: missing details, impossible dates, values that only appear in a letter.
    func validate(_ args: JSONValue, ctx: TurnContext) -> Validation
    /// The confirmation card text, e.g. "Text Priya: “I'll be late”".
    func describe(_ args: JSONValue, ctx: TurnContext) -> String
    func execute(_ args: JSONValue, ctx: TurnContext) async throws -> ToolResult
}

extension KairosTool {
    func quickMatch(_ words: String, ctx: TurnContext) -> JSONValue? { nil }
    func validate(_ args: JSONValue, ctx: TurnContext) -> Validation { .ok }
    func describe(_ args: JSONValue, ctx: TurnContext) -> String { name.replacingOccurrences(of: "_", with: " ") }

    /// The Gemini functionDeclaration for this tool.
    var declaration: JSONValue {
        ["name": .string(name), "description": .string(summary), "parameters": parameters]
    }
}

/// A specialist agent: a named group of tools with its own know-how. Kairos routes to a specialist by calling
/// one of its tools; a specialist's tool may make its own model call (the letter reader does).
protocol SpecialistAgent: Sendable {
    var id: String { get }
    /// Shown to the person: "Time helper", "Letter reader".
    var title: String { get }
    /// SF Symbol.
    var icon: String { get }
    /// Extra lines for the system prompt: when to use these tools and how.
    var instructions: String { get }
    var tools: [any KairosTool] { get }
}

extension String {
    /// Lowercased, accents folded, punctuation turned into spaces: for matching words and names.
    var folded: String {
        let s = folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        return String(s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " })
            .split(separator: " ").joined(separator: " ")
    }
    /// Only the digits (phone numbers, account numbers).
    var digitsOnly: String { String(unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.map(Character.init)) }
}
