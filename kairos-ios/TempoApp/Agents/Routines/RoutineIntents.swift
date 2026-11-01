import AppIntents
import Foundation

// Routines for Siri and the Shortcuts app. iOS doesn't let an app write into Shortcuts, so each saved routine is
// offered as a "Kairos routine" App Entity and run by one intent:
//
//   "Hey Siri, run Morning with Kairos"  → RunRoutineIntent, in the background; Siri says how it went.
//   Shortcuts app → "Run Kairos routine"  → returns the spoken text, so a Shortcut can chain "Speak Text" after it.
//
// Paste this entry into `TempoShortcuts.appShortcuts` (the app's one AppShortcutsProvider; phrases must be literal
// there). An App Entity parameter is allowed in phrases:
//
//        AppShortcut(intent: RunRoutineIntent(),
//                    phrases: ["Run \(\.$routine) with \(.applicationName)",
//                              "\(\.$routine) with \(.applicationName)",
//                              "Do my \(\.$routine) with \(.applicationName)",
//                              "Run a routine with \(.applicationName)"],
//                    shortTitle: "Run a routine",
//                    systemImageName: "repeat.circle.fill")
//
// and at launch (TempoApp.init or the root view's .task), so Siri learns new routine names as they are saved:
//
//        RoutineSiri.keepUpToDate { TempoShortcuts.updateAppShortcutParameters() }

// MARK: - The routine, as Siri and Shortcuts see it

struct RoutineEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Kairos routine"
    static let defaultQuery = RoutineEntityQuery()

    /// The routine's UUID string.
    var id: String
    var name: String
    var summary: String
    var phrases: [String]

    var displayRepresentation: DisplayRepresentation {
        let subtitle: LocalizedStringResource? = summary.isEmpty ? nil : "\(summary)"
        return DisplayRepresentation(title: "\(name)", subtitle: subtitle,
                                     image: DisplayRepresentation.Image(systemName: "repeat.circle.fill"),
                                     synonyms: phrases.map { (p: String) -> LocalizedStringResource in "\(p)" })
    }

    init(_ routine: Routine) {
        id = routine.id.uuidString
        name = routine.name
        summary = routine.summary
        phrases = routine.phrases
    }
}

struct RoutineEntityQuery: EntityStringQuery {
    init() {}

    func entities(for identifiers: [RoutineEntity.ID]) async throws -> [RoutineEntity] {
        let store = RoutineStore.shared
        return identifiers.compactMap { store.routine(id: $0).map(RoutineEntity.init) }
    }

    func entities(matching string: String) async throws -> [RoutineEntity] {
        let all = RoutineStore.shared.all
        let q = string.folded
        guard !q.isEmpty else { return all.map(RoutineEntity.init) }
        // Typing "mor" finds "Morning"; a spoken "run my morning routine" finds it by whole words, so a routine
        // called "Art" doesn't turn up for "start my day".
        let spoken = " " + q + " "
        var hits = all.filter { r in
            let name = r.name.folded
            return name.contains(q) || (!name.isEmpty && spoken.contains(" " + name + " "))
                || r.phrases.contains { $0.folded.contains(q) }
        }
        if hits.isEmpty, let r = RoutineMatcher.named(string, in: all) { hits = [r] }
        return hits.map(RoutineEntity.init)
    }

    /// Most recently used first: what the Shortcuts picker and Siri's phrase list show.
    func suggestedEntities() async throws -> [RoutineEntity] {
        RoutineStore.shared.all
            .sorted { ($0.lastRunAt ?? $0.createdAt) > ($1.lastRunAt ?? $1.createdAt) }
            .map(RoutineEntity.init)
    }
}

// MARK: - "Hey Siri, run Morning with Kairos"

/// Runs one saved routine through Kairos (run_routine, so the SafetyGate and the cards apply to every step) and says
/// how it went. Starts in the background; on iOS 26 it can bring Kairos forward when a step needs a Yes on screen.
struct RunRoutineIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Kairos routine"
    static let description = IntentDescription("Run one of the routines you made in Kairos, like your morning or bedtime steps. Kairos tells you how it went.")
    /// iOS 26: background first; `.foreground(.dynamic)` lets it bring Kairos forward when a card needs a tap.
    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    /// The answer can include calendar, reminders and contacts: only the owner, after Face ID or the passcode.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Routine", requestValueDialog: "Which routine would you like?")
    var routine: RoutineEntity

    @Parameter(title: "Extra words", description: "Anything to add for this run, like “I'm in London”.")
    var input: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$routine)") {
            \.$input
        }
    }

    init() {}

    init(routine: RoutineEntity) {
        self.routine = routine
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let agent = KairosAgent.shared  // on a cold launch this also brings up the runner hook
        let store = RoutineStore.shared
        // By id; else only a routine with exactly the same name (a Shortcut made before it was re-made). Never a
        // near match: a stale "Morning walk" must not start "Morning".
        let wanted = routine.name.folded
        guard let saved = store.routine(id: routine.id) ?? store.all.first(where: { !wanted.isEmpty && $0.name.folded == wanted }) else {
            let say = RoutineSiri.missingSay
            return .result(value: say, dialog: IntentDialog(stringLiteral: say))
        }

        let started = Date()
        while agent.working, Date().timeIntervalSince(started) < RoutineSiri.busyWait {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if agent.working {
            let say = RoutineSiri.busySay
            return .result(value: say, dialog: IntentDialog(stringLiteral: say))
        }

        var args: [String: JSONValue] = ["id": .string(saved.id.uuidString), "name": .string(saved.name)]
        if let extra = input?.trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty {
            args["input"] = .string(String(extra.prefix(200)))
        }
        let call = ToolCall(id: nil, name: "run_routine", args: .object(args))

        guard let say = await RoutineIntentRace.run(call, fallbackWords: "run my \(saved.name)", budget: RoutineSiri.budget) else {
            // Over Siri's patience. The routine carries on inside Kairos; show it if iOS lets us.
            if await routineContinueOnScreen(RoutineSiri.slowOpenSay) {
                let say = RoutineSiri.stillWorkingSay
                return .result(value: say, dialog: IntentDialog(stringLiteral: say))
            }
            let say = RoutineSiri.slowSay
            return .result(value: say, dialog: IntentDialog(stringLiteral: say))
        }

        // A step (a call, a message) is waiting for a Yes on screen: Siri never approves.
        guard agent.hasStashed else {
            return .result(value: say, dialog: IntentDialog(stringLiteral: say))
        }
        if await routineContinueOnScreen(RoutineSiri.openForCardSay) {
            Task { @MainActor in _ = await KairosAgent.shared.resumeStashed() }
            return .result(value: say, dialog: IntentDialog(stringLiteral: RoutineSiri.cardOnScreenSay))
        }
        let hinted = say.localizedCaseInsensitiveContains("open Kairos") ? say : say + " Please open Kairos to finish it."
        return .result(value: hinted, dialog: IntentDialog(stringLiteral: hinted))
    }
}

// MARK: - Keeping Siri's list of routine names fresh

@MainActor
enum RoutineSiri {
    static let budget: TimeInterval = 15
    static let busyWait: TimeInterval = 3

    static let missingSay = "I couldn't find that routine any more. Open Kairos to see the ones you have."
    static let busySay = "I'm still busy with your last request. Please ask me again in a moment."
    static let slowSay = "Your routine is taking a little longer than usual. Open Kairos in a minute to see how it went."
    static let slowOpenSay = "Your routine is taking a little longer than usual. I'll open Kairos so you can see it."
    static let stillWorkingSay = "I'm still working through your routine. You'll see it on your screen."
    static let openForCardSay = "One step needs your OK. I'll open Kairos so you can check it."
    static let cardOnScreenSay = "One step needs your OK. It's on your screen now: have a look, and tap Yes if it's right."

    private static var observer: NSObjectProtocol?

    /// Calls `update` now and whenever routines change. Pass `{ TempoShortcuts.updateAppShortcutParameters() }`.
    static func keepUpToDate(_ update: @escaping @Sendable () -> Void) {
        update()
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .kairosRoutinesChanged, object: nil, queue: .main) { _ in
            update()
        }
    }
}

// MARK: - Running within Siri's patience

/// Whichever finishes first, the routine or the timer, answers; the other is ignored. The routine is not cancelled.
@MainActor
private final class RoutineIntentRace {
    private var continuation: CheckedContinuation<String?, Never>?
    var timer: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }

    func finish(_ say: String?) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        continuation.resume(returning: say)
    }

    /// run_routine through the runner (the gate and the cards apply); if the runner isn't registered, the same
    /// words through Kairos's own front door. Nil when the budget ran out first.
    static func run(_ call: ToolCall, fallbackWords: String, budget: TimeInterval) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let race = RoutineIntentRace(continuation)
            Task { @MainActor in
                let say: String
                if let runner = AgentHooks.runner {
                    let report = await runner.runToolStep(call, source: .siriBackground)
                    say = report.say ?? (report.ok ? "Done." : "Sorry, that routine didn't work this time.")
                } else {
                    say = await KairosAgent.shared.handle(fallbackWords, source: .siriBackground).say
                }
                race.finish(say)
            }
            race.timer = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                if !Task.isCancelled { race.finish(nil) }
            }
        }
    }
}

// MARK: - iOS 26: continue on screen

extension AppIntent {
    /// iOS 26: brings Kairos forward from a background Siri request and shows the agent screen. False on older
    /// systems, when this run can't come forward, or when the person says no.
    @MainActor
    fileprivate func routineContinueOnScreen(_ dialog: String) async -> Bool {
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
