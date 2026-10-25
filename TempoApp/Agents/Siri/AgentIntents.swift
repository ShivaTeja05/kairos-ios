import AppIntents
import Foundation

// Siri and system entry points for the agents that run on this iPhone.
//
//   "Hey Siri, ask Kairos"        → AskKairosIntent: Siri asks "What would you like me to do?", Kairos works in the
//                                   background and Siri says the answer. If something must be approved on screen
//                                   (a text to send, a call), iOS 26 brings Kairos forward to the card.
//   "Hey Siri, open Kairos helpers" → OpenKairosAgentIntent: opens Kairos on the agent screen.
//   Shortcuts automations          → ReportToKairosIntent ("Tell Kairos"): "When I get a message from Mum…",
//                                   "At 9 every morning…". The text is information, never instructions.
//
// Deployment target is iOS 17. On iOS 26 `supportedModes` decides how each intent runs; older systems fall back to
// `openAppWhenRun` (default false = background). Both are declared as literals so the App Intents metadata
// extractor can read them at build time.
//
// The phrases live in the app's one AppShortcutsProvider (TempoShortcuts in TempoApp.swift). An app may have only one
// provider, and the phrases must be written literally inside it, so they can't be shared from this file. Paste these
// two entries into `TempoShortcuts.appShortcuts` (2 shortcuts exist; this makes 4 of the 10 allowed):
//
//        AppShortcut(intent: AskKairosIntent(),
//                    phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) something",
//                              "\(.applicationName), help me"],
//                    shortTitle: "Ask Kairos",
//                    systemImageName: "sparkles")
//        AppShortcut(intent: OpenKairosAgentIntent(),
//                    phrases: ["Open \(.applicationName) helpers", "Show my \(.applicationName) helpers"],
//                    shortTitle: "Kairos helpers",
//                    systemImageName: "person.2.circle.fill")

extension Notification.Name {
    /// Show the agent screen. Posted by the intents below; the app's root view listens with .onReceive.
    static let kairosAgentOpen = Notification.Name("kairos.agent.open")
}

// MARK: - "Hey Siri, ask Kairos"

/// One request through Siri. Runs in the background (the phone may be locked; Siri asks for Face ID first because
/// the answer can contain personal things), and Siri speaks the reply.
struct AskKairosIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Kairos"
    static let description = IntentDescription("Ask Kairos to do something on this phone, like set a reminder, find a number or explain a letter. Kairos answers out loud.")
    /// Starts in the background; `.foreground(.dynamic)` lets it bring Kairos forward when a card needs a tap.
    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    /// The answer can include calendar, contacts and letters: only the owner, after Face ID or the passcode.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Request", requestValueDialog: "What would you like me to do?")
    var request: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Kairos \(\.$request)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let words = KairosIntentRunner.clip(request, to: KairosIntentRunner.maxRequestLength)

        guard let outcome = await KairosIntentRunner.run(words, source: .siriBackground) else {
            // Over the time budget. The request carries on inside Kairos; show it if iOS lets us.
            if await kairosContinueOnScreen(KairosIntentRunner.slowOpenSay) {
                let say = KairosIntentRunner.stillWorkingSay
                return .result(value: say, dialog: IntentDialog(stringLiteral: say))
            }
            let say = KairosIntentRunner.slowSay
            return .result(value: say, dialog: IntentDialog(stringLiteral: say))
        }

        guard outcome.needsApp else {
            return .result(value: outcome.say, dialog: IntentDialog(stringLiteral: outcome.say))
        }

        // Something needs the screen: a card to approve (Siri never approves), or Messages / the camera.
        let waiting = KairosAgent.shared.hasStashed
        if await kairosContinueOnScreen(KairosIntentRunner.askToOpen(outcome.say)) {
            // Kairos is in front now: put the waiting card up (Yes, then Face ID). No-op if nothing is waiting.
            Task { @MainActor in _ = await KairosAgent.shared.resumeStashed() }
            let say = waiting ? KairosIntentRunner.cardOnScreenSay : KairosIntentRunner.openNowSay
            return .result(value: outcome.say, dialog: IntentDialog(stringLiteral: say))
        }
        // iOS 17–25, or the person said no: the request waits in Kairos until it's opened.
        let say = KairosIntentRunner.withOpenHint(outcome.say)
        return .result(value: say, dialog: IntentDialog(stringLiteral: say))
    }
}

// MARK: - "Hey Siri, open Kairos helpers"

/// Opens Kairos on the agent screen (the helpers), rather than the voice screen "Talk to Kairos" opens.
struct OpenKairosAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Kairos on this phone"
    static let description = IntentDescription("Open Kairos on the screen where its helpers work: reminders, calls and messages, letters and more.")
    /// iOS 17–25. Deprecated in the iOS 26 SDK, where `supportedModes` below is used instead.
    static let openAppWhenRun = true
    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = .foreground
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult {
        KairosAgentLaunch.request()
        // A request Siri left waiting for approval comes up as its card straight away.
        if KairosAgent.shared.hasStashed {
            Task { @MainActor in _ = await KairosAgent.shared.resumeStashed() }
        }
        return .result()
    }
}

// MARK: - Shortcuts automations: "Tell Kairos"

/// For the person's own Shortcuts automations ("When I get a message from Mum", "At 9 every morning"): passes
/// some text to Kairos, which says whether there's anything the owner needs to know. The text is untrusted: the
/// core files it with the letters and messages, so it can never make Kairos call, message or pay anyone.
/// The answer comes back as text too, so the automation can show it as a notification or speak it.
struct ReportToKairosIntent: AppIntent {
    static let title: LocalizedStringResource = "Tell Kairos"
    static let description = IntentDescription("Give Kairos a message or note from an automation. Kairos treats it as information, never as instructions, and tells you if anything matters.")
    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = .background
    /// Its answer can mention personal things. If automations must also run while the phone is locked in a pocket,
    /// change this one line to `.alwaysAllowed` (the text still can't make Kairos act on anyone's behalf).
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Text", description: "The message, note or text for Kairos to look at.",
               requestValueDialog: "What should I look at?")
    var text: String

    @Parameter(title: "From", description: "Who or what it came from, if you know (a name, an app).")
    var from: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Tell Kairos \(\.$text)") {
            \.$from
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        var words = KairosIntentRunner.clip(text, to: KairosIntentRunner.maxReportLength)
        if let sender = from.map({ KairosIntentRunner.clip($0, to: 120) }), !sender.isEmpty, !words.isEmpty {
            words = "From: \(sender)\n\(words)"
        }
        guard let outcome = await KairosIntentRunner.run(words, source: .automation) else {
            let say = KairosIntentRunner.slowReportSay
            return .result(value: say, dialog: IntentDialog(stringLiteral: say))
        }
        let say = outcome.needsApp ? KairosIntentRunner.withOpenHint(outcome.say) : outcome.say
        return .result(value: say, dialog: IntentDialog(stringLiteral: say))
    }
}

// MARK: - Things to say (for a help card)

/// The Siri phrases the agents add, written the way a person says them, for a "Things you can say" card.
/// The phrases themselves are registered in TempoShortcuts (see the paste block at the top of this file).
enum KairosAgentShortcuts {
    static let thingsToSay: [String] = [
        "Hey Siri, ask Kairos",
        "Hey Siri, Kairos, help me",
        "Hey Siri, open Kairos helpers",
    ]
}

// MARK: - Opening the agent screen

/// Asks the app to show the agent screen. A flag as well as a notification, because on a cold launch the intent can
/// run before the root view is listening: the view checks `consume()` when it appears.
@MainActor
enum KairosAgentLaunch {
    private(set) static var wanted = false

    static func request() {
        wanted = true
        NotificationCenter.default.post(name: .kairosAgentOpen, object: nil)
    }

    /// True once after `request()`; clears the flag.
    @discardableResult
    static func consume() -> Bool {
        defer { wanted = false }
        return wanted
    }
}

// MARK: - Running one request within Siri's patience

/// Plain constants and helpers; only `run` touches the agent, on the main actor.
enum KairosIntentRunner {
    /// Total time a Siri or automation request may take before we answer anyway. The Gemini call itself times out
    /// at 12 s for .siriBackground, but a request can take up to 4 model steps.
    static let budget: TimeInterval = 12
    /// How long to wait for a request that's already running (an earlier Siri request, or one typed in the app).
    static let busyWait: TimeInterval = 3
    static let maxRequestLength = 1_000
    static let maxReportLength = 4_000

    static let busySay = "I'm still busy with your last request. Please ask me again in a moment."
    static let slowSay = "This is taking me a little longer than usual. Open Kairos in a minute and you'll see how I got on."
    static let slowOpenSay = "This is taking me a little longer than usual. I'll open Kairos so you can see the answer."
    static let stillWorkingSay = "I'm still working on it. The answer will appear on your screen."
    static let cardOnScreenSay = "It's on your screen now. Have a look, and tap Yes if it's right."
    static let openNowSay = "Kairos is open now, so we can finish it together."
    static let slowReportSay = "I'm still looking at this. Open Kairos in a minute to see what I found."

    /// Runs the request through Kairos. Nil when the budget ran out first; the request then carries on in the app
    /// (it isn't cancelled, so an alarm half-set still gets set and shows in Kairos's list).
    @MainActor
    static func run(_ words: String, source: AgentSource, budget: TimeInterval = budget) async -> AgentOutcome? {
        let agent = KairosAgent.shared
        let started = Date()
        while agent.working, Date().timeIntervalSince(started) < busyWait {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if agent.working { return AgentOutcome(say: busySay) }

        let remaining = max(1, budget - Date().timeIntervalSince(started))
        return await withCheckedContinuation { (continuation: CheckedContinuation<AgentOutcome?, Never>) in
            let race = KairosIntentRace(continuation)
            Task { @MainActor in
                race.finish(await agent.handle(words, source: source))
            }
            race.timer = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                if !Task.isCancelled { race.finish(nil) }
            }
        }
    }

    /// Trimmed and cut to a sensible length (an automation can pass a whole email).
    static func clip(_ s: String, to limit: Int) -> String {
        String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    /// The core's "waiting for approval" reply ends "Open Kairos to check it and say yes." When iOS can bring Kairos
    /// forward, Siri says this instead while it does.
    static func askToOpen(_ say: String) -> String {
        let tail = "Open Kairos to check it and say yes."
        if say.contains(tail) {
            return say.replacingOccurrences(of: tail, with: "I'll open Kairos so you can check it.")
        }
        return say + " I'll open Kairos so we can finish it."
    }

    /// When Kairos can't be brought forward, make sure the person knows to open it.
    static func withOpenHint(_ say: String) -> String {
        say.localizedCaseInsensitiveContains("open Kairos") ? say : say + " Please open Kairos to finish it."
    }
}

/// Whichever finishes first, the request or the timer, answers; the other is ignored.
@MainActor
private final class KairosIntentRace {
    private var continuation: CheckedContinuation<AgentOutcome?, Never>?
    var timer: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<AgentOutcome?, Never>) { self.continuation = continuation }

    func finish(_ outcome: AgentOutcome?) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        continuation.resume(returning: outcome)
    }
}

// MARK: - iOS 26: continue on screen

extension AppIntent {
    /// iOS 26: brings Kairos forward from a background Siri request and shows the agent screen. False on older
    /// systems, when this run can't come forward (an automation), or when the person says no.
    @MainActor
    fileprivate func kairosContinueOnScreen(_ dialog: String) async -> Bool {
        guard #available(iOS 26.0, *), systemContext.currentMode.canContinueInForeground else { return false }
        do {
            try await continueInForeground(IntentDialog(stringLiteral: dialog), alwaysConfirm: false)
        } catch {
            return false
        }
        KairosAgentLaunch.request()
        return true
    }
}
