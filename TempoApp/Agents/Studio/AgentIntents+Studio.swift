import AppIntents
import Foundation

// Siri and Shortcuts for the person's helpers.
//
//   "Hey Siri, talk to Medicine Buddy in Kairos" → TalkToAgentIntent: opens Kairos with that helper in charge.
//   "Hey Siri, ask a helper in Kairos"           → AskAgentIntent: one job for one helper, in the background; Siri
//                                                  says the answer. Also the action automations use ("Ask a Kairos
//                                                  helper"), with the request the person typed when setting it up.
//
// AgentSpecEntity lets Siri and Shortcuts pick a helper by name. When helpers change, the app must call
// TempoShortcuts.updateAppShortcutParameters() so Siri learns the new names: set
// `AgentLibrary.didChange = { TempoShortcuts.updateAppShortcutParameters() }` once at launch.
//
// Paste into TempoShortcuts.appShortcuts (an app may have one provider and at most 10 shortcuts; a phrase may hold
// one entity parameter, never a String):
//
//        AppShortcut(intent: TalkToAgentIntent(),
//                    phrases: ["Talk to \(\.$agent) in \(.applicationName)",
//                              "Open \(\.$agent) in \(.applicationName)",
//                              "Talk to a helper in \(.applicationName)"],
//                    shortTitle: "Talk to a helper",
//                    systemImageName: "person.crop.rectangle.stack.fill")
//        AppShortcut(intent: AskAgentIntent(),
//                    phrases: ["Ask \(\.$agent) in \(.applicationName)",
//                              "Ask a helper in \(.applicationName)"],
//                    shortTitle: "Ask a helper",
//                    systemImageName: "person.wave.2.fill")

extension Notification.Name {
    /// Show the agent screen with the focused helper. Posted by TalkToAgentIntent; the root view listens.
    static let kairosStudioOpen = Notification.Name("kairos.studio.open")
}

/// Asks the app to show the agent screen. A flag as well as a notification, because on a cold launch the intent can
/// run before the root view is listening: the view checks `consume()` when it appears.
@MainActor
enum StudioLaunch {
    private(set) static var wanted = false

    static func request() {
        wanted = true
        NotificationCenter.default.post(name: .kairosStudioOpen, object: nil)
        // The agent screen's own notification (AgentIntents.swift, `.kairosAgentOpen`), by name.
        NotificationCenter.default.post(name: Notification.Name("kairos.agent.open"), object: nil)
    }

    /// True once after `request()`; clears the flag.
    @discardableResult
    static func consume() -> Bool {
        defer { wanted = false }
        return wanted
    }
}

// MARK: - A helper, for Siri and Shortcuts

struct AgentSpecEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Kairos helper")
    static let defaultQuery = AgentSpecQuery()

    let id: String
    var name: String
    var tagline: String
    var icon: String

    init(id: String, name: String, tagline: String, icon: String) {
        self.id = id
        self.name = name
        self.tagline = tagline
        self.icon = icon
    }

    init(_ spec: AgentSpec) {
        self.init(id: spec.id, name: spec.name, tagline: spec.tagline, icon: spec.icon)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(tagline)", image: .init(systemName: icon))
    }
}

struct AgentSpecQuery: EntityStringQuery {
    init() {}

    @MainActor
    func entities(for identifiers: [String]) async throws -> [AgentSpecEntity] {
        identifiers.compactMap { AgentLibrary.shared.spec(id: $0) }.map(AgentSpecEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [AgentSpecEntity] {
        let library = AgentLibrary.shared
        let q = string.folded
        let hits = library.agents.filter { q.isEmpty || $0.name.folded.contains(q) || $0.tagline.folded.contains(q) }
        if hits.isEmpty, let best = library.spec(named: string) { return [AgentSpecEntity(best)] }
        return hits.map(AgentSpecEntity.init)
    }

    /// Every helper: Siri builds "Talk to … in Kairos" phrases from these.
    @MainActor
    func suggestedEntities() async throws -> [AgentSpecEntity] {
        AgentLibrary.shared.agents.map(AgentSpecEntity.init)
    }
}

// MARK: - "Hey Siri, talk to Medicine Buddy in Kairos"

/// Opens Kairos with that helper in charge (focus mode) until the person says "back to Kairos".
struct TalkToAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to a Kairos helper"
    static let description = IntentDescription("Open Kairos with one of your helpers in charge, like Medicine Buddy or Scam Guardian. Say “back to Kairos” to stop.")
    /// iOS 17–25. Deprecated in the iOS 26 SDK, where `supportedModes` below is used instead.
    static let openAppWhenRun = true
    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = .foreground
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Helper", requestValueDialog: "Which helper would you like to talk to?")
    var agent: AgentSpecEntity

    init() {}

    init(agent: AgentSpecEntity) {
        self.agent = agent
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Talk to \(\.$agent)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let library = AgentLibrary.shared
        // By id, else the exact name only: a guess could hand the person to a different helper than they chose.
        guard let spec = library.spec(id: agent.id) ?? library.spec(named: agent.name, exact: true) else {
            return .result(dialog: IntentDialog(stringLiteral: "I can't find that helper any more. Open Kairos to see your helpers."))
        }
        library.focused = spec
        StudioLaunch.request()
        let say = "You're now talking to \(spec.name). Say “back to Kairos” to stop."
        return .result(dialog: IntentDialog(stringLiteral: say))
    }
}

// MARK: - "Hey Siri, ask Bill Tracker in Kairos"

/// One job for one helper, in the background. Siri asks what for, the helper does it with its own tools (anything
/// that reaches a person or money still waits for the Yes card in Kairos), and Siri says the answer.
struct AskAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask a Kairos helper"
    static let description = IntentDescription("Give one of your Kairos helpers a job, like asking Medicine Buddy to set a reminder. The helper answers out loud.")
    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    /// The answer can include calendar, contacts and letters: only the owner, after Face ID or the passcode.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Helper", requestValueDialog: "Which helper should I ask?")
    var agent: AgentSpecEntity

    @Parameter(title: "Request", requestValueDialog: "What would you like it to do?")
    var request: String

    init() {}

    init(agent: AgentSpecEntity, request: String) {
        self.agent = agent
        self.request = request
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$agent) to \(\.$request)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let library = AgentLibrary.shared
        // By id only: an automation made for a helper that has since been deleted must never run as another helper
        // that happens to have the same or a similar name (one someone shared, say).
        guard let spec = library.spec(id: agent.id) else {
            let say = "I can't find that helper any more. Open Kairos to see your helpers."
            return .result(value: say, dialog: IntentDialog(stringLiteral: say))
        }
        let words = String(request.trimmingCharacters(in: .whitespacesAndNewlines).prefix(StudioIntentRunner.maxRequestLength))
        guard !words.isEmpty else {
            let say = "What would you like \(spec.name) to do?"
            return .result(value: say, dialog: IntentDialog(stringLiteral: say))
        }

        guard let say = await StudioIntentRunner.ask(spec, words) else {
            let say = "\(spec.name) is taking a little longer than usual. Open Kairos in a minute to see how it got on."
            return .result(value: say, dialog: IntentDialog(stringLiteral: say))
        }

        // Something is waiting for the owner's yes: bring Kairos forward to the card if iOS lets us.
        if KairosAgent.shared.hasStashed {
            if await studioContinueOnScreen("I'll open Kairos so you can check it.") {
                Task { @MainActor in _ = await KairosAgent.shared.resumeStashed() }
                return .result(value: say, dialog: IntentDialog(stringLiteral: "It's on your screen now. Have a look, and tap Yes if it's right."))
            }
            let withHint = say.localizedCaseInsensitiveContains("open Kairos") ? say : say + " Please open Kairos to finish it."
            return .result(value: withHint, dialog: IntentDialog(stringLiteral: withHint))
        }
        return .result(value: say, dialog: IntentDialog(stringLiteral: say))
    }
}

// MARK: - Running a helper's job within Siri's patience

@MainActor
enum StudioIntentRunner {
    static let budget: TimeInterval = 12
    static let busyWait: TimeInterval = 3
    static let maxRequestLength = 1_000
    static let busySay = "I'm still busy with your last request. Please ask me again in a moment."

    /// The helper's answer, or nil if the time ran out (the job carries on inside Kairos).
    static func ask(_ spec: AgentSpec, _ words: String) async -> String? {
        let kairos = KairosAgent.shared
        let started = Date()
        while kairos.working, Date().timeIntervalSince(started) < busyWait {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if kairos.working { return busySay }
        let remaining = max(1, budget - Date().timeIntervalSince(started))

        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let race = StudioIntentRace(continuation)
            Task { @MainActor in
                race.finish(await run(spec, words))
            }
            race.timer = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                if !Task.isCancelled { race.finish(nil) }
            }
        }
    }

    /// With KairosAgent's runScoped the job runs as that helper alone; without it, through Kairos's own front door
    /// ("Ask Bill Tracker: …"), which hands it over with ask_agent. While another helper is in charge in the app,
    /// the front door would reach that helper instead, so the job goes straight to the one the person named.
    private static func run(_ spec: AgentSpec, _ words: String) async -> String {
        if let scoped = StudioHandoff.scopedRunner() {
            let report = await scoped.runScoped(spec, request: words, source: .siriBackground)
            return report.say ?? "Done."
        }
        if AgentLibrary.shared.focused != nil {
            let ctx = TurnContext(userWords: words, documents: [], images: [], now: Date(), timeZone: .current,
                                  language: AgentLanguage.current, source: .siriBackground,
                                  model: AgentSettings.provider(timeout: 12))
            return await StudioHandoff.run(spec, request: words, ctx: ctx).say
        }
        return await KairosAgent.shared.handle("Ask \(spec.name): \(words)", source: .siriBackground).say
    }
}

/// Whichever finishes first, the job or the timer, answers; the other is ignored.
@MainActor
private final class StudioIntentRace {
    private var continuation: CheckedContinuation<String?, Never>?
    var timer: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }

    func finish(_ value: String?) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        continuation.resume(returning: value)
    }
}

extension AppIntent {
    /// iOS 26: brings Kairos forward from a background Siri request. False on older systems, when this run can't
    /// come forward, or when the person says no.
    @MainActor
    fileprivate func studioContinueOnScreen(_ dialog: String) async -> Bool {
        guard #available(iOS 26.0, *), systemContext.currentMode.canContinueInForeground else { return false }
        do {
            try await continueInForeground(IntentDialog(stringLiteral: dialog), alwaysConfirm: false)
        } catch {
            return false
        }
        StudioLaunch.request()
        return true
    }
}
