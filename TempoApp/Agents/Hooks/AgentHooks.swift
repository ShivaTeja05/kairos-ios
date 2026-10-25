import Foundation

// Hooks for agents that run OTHER agents' tools: Routines (replay saved steps) and the Phone operator
// (asks the owner before a sensitive tap). KairosAgent conforms to AgentRunner and registers itself, so these
// agents never bypass the SafetyGate or the confirmation card.

@MainActor
protocol AgentRunner: AnyObject {
    /// Runs one tool call through the SafetyGate and confirmation card exactly like a model-proposed call.
    func runToolStep(_ call: ToolCall, source: AgentSource) async -> StepReport
    /// Tool calls that succeeded during the most recent request, in order (for "save that as a routine").
    var lastExecuted: [ToolCall] { get }
    /// The big Yes/No card, then Face ID / passcode. True only if the owner approved.
    func requestApproval(helper: String, detail: String, warning: String?) async -> Bool
    /// Every tool the agents offer: name, what it does, risk. For composing routines.
    var toolCatalog: [ToolInfo] { get }
    /// Shows progress in the app ("Phone operator: tapping Chats").
    func reportProgress(_ text: String?)
}

struct StepReport: Sendable {
    var ok: Bool
    /// What the tool told the person (nil if nothing to say).
    var say: String?
    /// Facts the tool returned.
    var data: JSONValue
    /// The step was refused, declined, needs a detail, or needs the app on screen: stop the routine here.
    var stopped: Bool
}

struct ToolInfo: Sendable {
    var name: String
    var summary: String
    var risk: Risk
    var parameters: JSONValue
}

enum AgentHooks {
    @MainActor static weak var runner: (any AgentRunner)?
}

/// The phone's "hands": a UI-automation service that can see and tap any app (iCTRL's XCUITest runner on
/// 127.0.0.1:8200). The Phone operator codes against this; ICTRLHands implements it.
protocol PhoneHands: Sendable {
    /// Is the runner up and paired? Cheap.
    func status() async -> HandsStatus
    /// One-time pairing; the owner taps Allow on the phone. Saves the key in the Keychain.
    func pair(as name: String) async throws
    /// One JSON-RPC call ("page_source", "find_element", "tap", "type", "launch_app", "resolve_app", "home", …).
    func call(_ method: String, _ params: JSONValue, timeout: TimeInterval) async throws -> JSONValue
}

enum HandsStatus: Sendable, Equatable {
    case ready
    case notRunning   // the runner isn't up (start it from the Mac)
    case notPaired    // reachable but needs one Allow tap
    case locked       // the phone is locked
}

enum HandsError: LocalizedError, Equatable {
    case notRunning, notPaired, locked, rpc(String), badReply

    var errorDescription: String? {
        switch self {
        case .notRunning: return "The phone helper isn't running. Start it from the Mac, then try again."
        case .notPaired: return "The phone helper needs your OK first. Tap Allow when it asks."
        case .locked: return "Please unlock your phone, then ask me again."
        case .rpc(let message): return "The phone helper said: \(message)"
        case .badReply: return "The phone helper sent something I didn't understand."
        }
    }
}
