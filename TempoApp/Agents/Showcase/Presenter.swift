import Foundation
#if canImport(UIKit)
import UIKit
#endif

// Present mode's engine. Presenter.shared.run(script: .standard) and Kairos introduces itself, then shows what it can
// do BY DOING IT: each step hands one helper a real job (an alarm, a letter, a scam text, WhatsApp, a new agent, a
// routine, a photo) through the same SafetyGate, cards and Face ID as always, narrates what happened from the tool's
// own words, and ends by handing the floor to the judges.
//
// It never stalls: every action has a deadline (a Yes card or the camera adds time); a failure, a timeout or a
// refusal gets one short line and the show moves on; slow actions get "while waiting" lines so the room is never
// silent for more than about four seconds; a step never starts while a Yes/No card from earlier is still waiting.
// stop() ends everything at once: speech stops, the audio goes back, the microphone is unmuted.

// MARK: - What the overlay shows

/// The overlay's card: which helper, its SF Symbol, and what it is doing (lower case; the overlay capitalises it).
struct ShowCaption: Equatable, Sendable {
    var agentTitle: String
    var icon: String
    var doing: String
}

enum ShowStepOutcome: String, Sendable, Equatable {
    case done       // worked
    case fellBack   // the step's plan B worked
    case failed     // the helper said it couldn't
    case timedOut   // ran out of time
    case refused    // the gate refused, the owner said no, or the helper needed a detail
    case skipped    // the step before it failed, or a card was left unanswered
    case cancelled  // Stop was pressed

    var worked: Bool { self == .done || self == .fellBack }
}

struct ShowStepResult: Sendable, Equatable, Identifiable {
    var index: Int
    var id: String
    var agent: String
    var outcome: ShowStepOutcome
    /// What the helper said, when it said something.
    var say: String?
    /// Seconds the step took (in show time).
    var seconds: Double
}

/// What one plain request to Kairos came back with.
struct ShowReply: Sendable, Equatable {
    /// A helper actually did something (a "done" line in the conversation).
    var ok: Bool
    var say: String
    /// Nothing was done because the gate refused or the owner said no (a "refused" line, no "done" line).
    var refused = false
}

/// How one action ended.
enum ShowActionOutcome: Sendable, Equatable {
    case ok(String?)
    case failed(String?)
    case refused(String?)
    case timedOut
    case cancelled
}

// MARK: - The app around the show

/// Everything the presenter needs from the app. KairosShowHost is the real one; the Mac dry run fakes it.
@MainActor
protocol ShowHost: AnyObject {
    /// One tool through AgentHooks.runner (SafetyGate, card, Face ID). Nil when no runner is registered.
    func runTool(_ call: ToolCall) async -> StepReport?
    /// A plain request to Kairos (KairosAgent.handle), as if the owner typed it.
    func ask(_ text: String, images: [Data]) async -> ShowReply
    /// A Yes/No card is waiting for the owner.
    var hasPendingConfirmation: Bool { get }
    func declinePendingConfirmation()
    /// Kairos is in the middle of a request.
    var isAgentWorking: Bool { get }
    /// Kairos's camera is up (take_photo).
    var isCameraOpen: Bool { get }
    func closeCamera()
    /// A mark in Kairos's conversation, and what Kairos said after it.
    var lastLineID: UUID? { get }
    func reply(after mark: UUID?) -> ShowReply?
    /// Kairos is on screen (not WhatsApp or Maps).
    var isAppActive: Bool { get }
    /// Brings Kairos back to the front (the phone helper). True if it could.
    func bringKairosBack() async -> Bool
    /// The agent screen's microphone, for the hand-over when the live voice isn't available.
    func openAgentMic()
    func showWillStart() async
    func showDidEnd(handedOver: Bool)
    func beginBackgroundTime(_ name: String) -> Int
    func endBackgroundTime(_ token: Int)
}

/// The real host: KairosAgent, AgentHooks.runner and UIKit. The integrator sets the closures (see integration notes).
@MainActor
final class KairosShowHost: ShowHost {
    static let shared = KairosShowHost()

    /// Opens the on-phone agent screen (AgentHomeView), where the lines, the Yes cards and the camera appear.
    var openAgentScreen: (@MainActor () -> Void)?
    /// Starts listening on the agent screen: `AgentVoice.shared.micTapped()`.
    var startAgentMic: (@MainActor () -> Void)?
    /// Brings Kairos to the front with the phone helper (ICTRL activate_app). True if it worked.
    var bringToFront: (@MainActor () async -> Bool)?
    /// Runs before the show: delete last rehearsal's "Judge Helper" agent and "judge mode" routine.
    var prepare: (@MainActor () async -> Void)?

    private var agent: KairosAgent { KairosAgent.shared }
    private var nextToken = 0
    #if canImport(UIKit)
    private var backgroundTasks: [Int: UIBackgroundTaskIdentifier] = [:]
    private var idleTimerWas: Bool?
    private var idleRestore: Task<Void, Never>?
    #endif

    func runTool(_ call: ToolCall) async -> StepReport? {
        // KairosAgent registers itself as the runner when it is created; touching it here makes sure it has been.
        let runner: any AgentRunner = AgentHooks.runner ?? agent
        return await runner.runToolStep(call, source: .app)
    }

    func ask(_ text: String, images: [Data]) async -> ShowReply {
        let mark = agent.lines.last?.id
        let outcome = await agent.handle(text, source: .app, images: images)
        let fresh = Self.lines(after: mark, in: agent.lines)
        let ok = fresh.contains { $0.kind == .done }
        return ShowReply(ok: ok, say: outcome.say, refused: !ok && fresh.contains { $0.kind == .refused })
    }

    var hasPendingConfirmation: Bool { agent.confirmation != nil }
    /// Answers the waiting card with No. The show never answers Yes for the owner.
    func declinePendingConfirmation() { agent.answerConfirmation(false) }
    var isAgentWorking: Bool { agent.working }
    /// Set by the agent screen while its camera cover is up (it resets cameraRequested as soon as it opens it).
    var cameraIsOpen = false
    var isCameraOpen: Bool { cameraIsOpen || agent.cameraRequested }
    func closeCamera() {
        agent.cameraRequested = false
        PhotoStore.shared.clearPending()  // a late shutter tap must not start a share during the Q&A
        // The agent screen holds the camera cover itself (it resets cameraRequested as soon as it opens it), so it
        // listens for this to close it (integration note).
        NotificationCenter.default.post(name: .kairosShowCloseCamera, object: nil)
    }
    var lastLineID: UUID? { agent.lines.last?.id }

    func reply(after mark: UUID?) -> ShowReply? {
        let fresh = Self.lines(after: mark, in: agent.lines)
        guard let last = fresh.last(where: { $0.kind == .kairos }) else { return nil }
        let ok = fresh.contains { $0.kind == .done }
        return ShowReply(ok: ok, say: last.text, refused: !ok && fresh.contains { $0.kind == .refused })
    }

    /// The lines after `mark` (all of them if the mark has scrolled out of the log).
    static func lines(after mark: UUID?, in all: [AgentLine]) -> ArraySlice<AgentLine> {
        guard let mark, let i = all.lastIndex(where: { $0.id == mark }) else { return all[...] }
        return all[(i + 1)...]
    }

    var isAppActive: Bool {
        #if canImport(UIKit)
        return UIApplication.shared.applicationState == .active
        #else
        return true
        #endif
    }

    func bringKairosBack() async -> Bool { await bringToFront?() ?? false }

    func openAgentMic() { startAgentMic?() }

    func showWillStart() async {
        await prepare?()
        openAgentScreen?()
        #if canImport(UIKit)
        // The phone must not lock in the middle of the show.
        idleRestore?.cancel()
        if idleTimerWas == nil { idleTimerWas = UIApplication.shared.isIdleTimerDisabled }
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
    }

    func showDidEnd(handedOver: Bool) {
        #if canImport(UIKit)
        let restore = { [weak self] in
            guard let self, let was = self.idleTimerWas else { return }
            UIApplication.shared.isIdleTimerDisabled = was
            self.idleTimerWas = nil
        }
        idleRestore?.cancel()
        if handedOver {
            // The judges are asking things now: stay awake for ten more minutes.
            idleRestore = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
                if !Task.isCancelled { restore() }
            }
        } else {
            restore()
        }
        #endif
    }

    func beginBackgroundTime(_ name: String) -> Int {
        nextToken += 1
        let token = nextToken
        #if canImport(UIKit)
        let id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTime(token) }
        }
        if id != .invalid { backgroundTasks[token] = id }
        #endif
        return token
    }

    func endBackgroundTime(_ token: Int) {
        #if canImport(UIKit)
        if let id = backgroundTasks.removeValue(forKey: token) { UIApplication.shared.endBackgroundTask(id) }
        #endif
    }
}

// MARK: - The presenter

@MainActor
final class Presenter: ObservableObject {
    static let shared = Presenter()

    enum State: Equatable {
        case idle
        case running(stepIndex: Int)
        case finished
        case stopped
    }

    /// Where the current step is, for the overlay's animation.
    enum Beat: Equatable {
        case introducing     // the narration before the action
        case working         // a helper is on it
        case waitingForCard  // a Yes/No card is up
        case waitingForTap   // the camera is up
        case reporting       // reading out what happened
        case recovering      // it didn't work: the plan B or the "let's move on" line
        case handingOver     // over to the judges
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var beat: Beat = .introducing
    @Published private(set) var currentCaption: ShowCaption?
    /// The step on screen, counted from 0 (0..<total).
    @Published private(set) var step = 0
    @Published private(set) var total = 0
    @Published private(set) var lastResult: ShowStepResult?
    @Published private(set) var results: [ShowStepResult] = []
    /// The line being spoken, for subtitles on the projector.
    @Published private(set) var spokenLine: String?
    /// "Tap the white button…" while the camera waits for the shutter.
    @Published private(set) var awaitingTap: String?
    /// The letter or the scam text, while its step runs.
    @Published private(set) var currentProp: ShowProp?
    @Published private(set) var scriptTitle: String?

    /// The app around the show. Defaults to KairosShowHost.shared.
    var host: any ShowHost
    /// The live ElevenLabs call (set by the integrator from TempoSession).
    var live: (any LiveVoiceBridge)?
    /// A fixed narrator (tests); otherwise chosen per show from ShowSettings.voiceMode.
    var narratorOverride: (any Narrator)?
    /// Scales every wait and deadline (the Mac dry run uses 0.02).
    var timeScale: Double = 1
    /// How long a step waits for an earlier, unanswered Yes/No card before skipping.
    var cardWaitSeconds: Double = 20
    /// Silence before a "while waiting" line.
    var fillerGap: Double = 3.5
    /// Extra time a step gets once its Yes card is up (the owner reads it, taps Yes, Face ID).
    var confirmGrace: Double = 40
    /// A Yes card left this long without an answer is answered No (nothing happens) and the show moves on, so the
    /// room never sits in silence behind it. The show never answers Yes.
    var cardPatience: Double = 30
    /// How long an action waits for a request that ran out of time earlier to finish.
    var agentIdleWait: Double = 6
    /// Every line and step outcome, for the dry run and debugging.
    var log: ((String) -> Void)?

    private(set) var narrator: (any Narrator)?
    private var device: DeviceNarrator?
    private var cancel = ShowCancel()
    private var narratorReleased = false
    private var mutedLive = false
    private var tapSignalled = false

    /// The helpers' live progress (KairosAgent posts "kairos.agent.progress"), voiced during long actions.
    private var progressText: String?
    private var progressSpoken: String?
    private var progressAt = Date.distantPast
    /// At most one spoken progress update per this many seconds.
    var progressGap: Double = 4
    private var progressObserver: NSObjectProtocol?

    init(host: (any ShowHost)? = nil) {
        self.host = host ?? KairosShowHost.shared
        progressObserver = NotificationCenter.default.addObserver(forName: Notification.Name("kairos.agent.progress"),
                                                                  object: nil, queue: .main) { [weak self] n in
            let text = n.userInfo?["text"] as? String
            MainActor.assumeIsolated { self?.progressChanged(text) }
        }
    }

    private func progressChanged(_ text: String?) {
        guard isRunning, beat == .working || beat == .waitingForCard else { return }
        progressText = text
    }

    /// "Phone operator: tapping Chats" → "Right now: tapping Chats." Nil for nothing worth saying.
    static func progressLine(_ text: String) -> String? {
        var rest = text
        if let r = text.range(of: ": ") { rest = String(text[r.upperBound...]) }
        rest = rest.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        guard rest.count >= 3, rest.count <= 140 else { return nil }
        return "Right now: " + rest + "."
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// True while the show is talking. AgentVoice should stay quiet then (it would talk over the show).
    var isPresenting: Bool { isRunning && beat != .handingOver }

    /// The camera's shutter was tapped (optional: the presenter also notices the camera closing).
    func tapped() { tapSignalled = true }

    // MARK: Run and stop

    /// Plays the whole show and returns when it has finished or was stopped. Ignored while a show is running.
    func run(script: ShowScript) async {
        guard !isRunning else { return }
        let token = ShowCancel()
        cancel = token
        narratorReleased = false
        tapSignalled = false
        results = []
        lastResult = nil
        step = 0
        total = script.steps.count
        scriptTitle = script.title
        currentCaption = nil
        currentProp = nil
        spokenLine = nil
        awaitingTap = nil
        beat = .introducing
        state = .running(stepIndex: 0)
        if script.steps.contains(where: { $0.prop == .letter }) { _ = DemoProps.letterJPEG }  // draw it now, not mid-step
        // Getting ready can start the ElevenLabs call (host.prepare), so the voice is picked afterwards.
        await host.showWillStart()
        if token.isCancelled {
            host.showDidEnd(handedOver: false)  // stopped while getting ready: stop() ran before the screen was kept awake
            return
        }
        let voice = chooseNarrator()
        narrator = voice
        note("show “\(script.title)”: \(script.steps.count) steps, about \(Int(script.estimatedSeconds.rounded())) s, voice: \(type(of: voice))")
        if let live, live.isLive {
            // The room mustn't interrupt the show: the call's microphone is off until the hand-over.
            await live.setMicMuted(true)
            mutedLive = true
        }

        var previousWorked = true
        for (index, s) in script.steps.enumerated() {
            if token.isCancelled { break }
            step = index
            state = .running(stepIndex: index)
            let r = await perform(s, index: index, previousWorked: previousWorked, token: token)
            if token.isCancelled { break }
            results.append(r)
            lastResult = r
            previousWorked = r.outcome.worked
            note("step \(index + 1)/\(total) \(s.id): \(r.outcome.rawValue)" + (r.say.map { " — \($0)" } ?? ""))
        }
        guard !token.isCancelled else { return }  // stop() has tidied up
        awaitingTap = nil
        currentProp = nil
        if !narratorReleased { await narrator?.stop() }
        if mutedLive {
            mutedLive = false
            await live?.setMicMuted(false)
        }
        host.showDidEnd(handedOver: narratorReleased)
        state = .finished
        note("finished")
    }

    /// Stops the show at once: no more steps or lines, speech cut, audio given back, the call's mic unmuted.
    func stop() async {
        guard isRunning else { return }
        cancel.cancel()
        state = .stopped
        awaitingTap = nil
        currentProp = nil
        spokenLine = nil
        note("stopped")
        if !narratorReleased { await narrator?.stop() }
        if mutedLive {
            mutedLive = false
            await live?.setMicMuted(false)
        }
        host.showDidEnd(handedOver: false)
    }

    private func chooseNarrator() -> any Narrator {
        if let narratorOverride { return narratorOverride }
        let phone = device ?? DeviceNarrator()
        device = phone
        // While the ElevenLabs call is on, LiveKit owns the audio session: the phone's voice plays into it and must
        // not switch it to .playback or deactivate it afterwards (that would leave the call silent at the hand-over).
        phone.managesAudioSession = !(live?.isLive ?? false)
        switch ShowSettings.voiceMode {
        case "device":
            return phone
        case "live":
            return live.map { ElevenLabsNarrator(bridge: $0, fallback: phone) } ?? phone
        default:
            if let live, live.isLive { return ElevenLabsNarrator(bridge: live, fallback: phone) }
            return phone
        }
    }

    // MARK: One step

    private func perform(_ s: ShowStep, index: Int, previousWorked: Bool, token: ShowCancel) async -> ShowStepResult {
        let began = Date()
        // A call that went live after the show started (auto-start on a cold launch): the room mustn't reach it.
        if !mutedLive, let live, live.isLive {
            await live.setMicMuted(true)
            mutedLive = true
        }
        let scale = max(timeScale, 0.000_1)
        func result(_ outcome: ShowStepOutcome, _ say: String? = nil) -> ShowStepResult {
            ShowStepResult(index: index, id: s.id, agent: s.agent, outcome: outcome, say: say,
                           seconds: Date().timeIntervalSince(began) / scale)
        }
        if s.skipIfPreviousFailed, !previousWorked { return result(.skipped) }

        currentCaption = ShowCaption(agentTitle: s.agent, icon: s.icon, doing: s.doing)
        currentProp = s.prop
        beat = .introducing
        let background = host.beginBackgroundTime("Kairos show: \(s.id)")
        defer { host.endBackgroundTime(background) }

        // Never start while a card from earlier is still waiting for the owner.
        if s.action.usesAgent, host.hasPendingConfirmation {
            let cleared = await waitForCardToClear(token)
            if token.isCancelled { return result(.cancelled) }
            if !cleared {
                host.declinePendingConfirmation()  // No = nothing is done; the show can't stall behind it
                await speak(ShowLines.cardSkip, token)
                return result(.skipped)
            }
        }

        // A shutter tap from now on counts (the camera opens while the step's own line is still being spoken).
        if s.tap != nil { tapSignalled = false }
        // The helper works WHILE the show explains it: an agent action starts at once and the step's own lines are
        // spoken as it runs. Other beats (a pause, the hand-over) still speak first.
        if !s.action.usesAgent {
            for line in s.before { await speak(line, token) }
            if token.isCancelled { return result(.cancelled) }
        }
        var outcome = await act(s.action, step: s, maxSeconds: s.maxSeconds,
                                during: s.action.usesAgent ? s.before : [], fillers: s.whileWaiting, token: token)
        if case .ok = outcome, let tap = s.tap { outcome = await waitForPhoto(tap, step: s, token: token) }
        if token.isCancelled { return result(.cancelled) }

        let kind: ShowStepOutcome
        let said: String?
        switch outcome {
        case .ok(let say):
            beat = .reporting
            await speakAfter(s.after, result: say, maxSentences: s.maxResultSentences, token: token)
            if s.leavesApp { await comeBack(token) }
            return result(.done, say)
        case .cancelled:
            return result(.cancelled)
        case .failed(let say):
            kind = .failed; said = say
        case .refused(let say):
            kind = .refused; said = say
        case .timedOut:
            kind = .timedOut; said = nil
        }

        // Plan B, else one short line, and on we go.
        beat = .recovering
        note("\(s.id): \(kind.rawValue)" + (said.map { " (\($0))" } ?? ""))
        if let fb = s.fallback {
            currentCaption = ShowCaption(agentTitle: fb.agent, icon: fb.icon, doing: fb.doing)
            if !fb.action.usesAgent { for line in fb.before { await speak(line, token) } }
            let second = await act(fb.action, step: s, maxSeconds: fb.maxSeconds,
                                   during: fb.action.usesAgent ? fb.before : [], fillers: [], token: token)
            if token.isCancelled { return result(.cancelled) }
            if case .ok(let say) = second {
                beat = .reporting
                await speakAfter(fb.after, result: say, maxSentences: fb.maxResultSentences ?? s.maxResultSentences,
                                 token: token)
                if s.leavesApp { await comeBack(token) }
                return result(.fellBack, say)
            }
        }
        // The helper's own words when they are the point ("OK, I haven't posted it…"), else the step's line.
        if s.readsFailure, kind != .timedOut, let words = said?.trimmingCharacters(in: .whitespacesAndNewlines),
           !words.isEmpty {
            await speak(ShowText.clip(words, sentences: 2), token)
        } else {
            await speak(s.fallbackLine, token)
        }
        if s.leavesApp { await comeBack(token) }
        return result(kind, said)
    }

    // MARK: Actions

    private func act(_ action: ShowAction, step s: ShowStep, maxSeconds: Double, during: [String] = [],
                     fillers: [String], token: ShowCancel) async -> ShowActionOutcome {
        switch action {
        case .none:
            return .ok(nil)
        case .pause(let seconds):
            beat = .working
            await pause(seconds, token)
            return token.isCancelled ? .cancelled : .ok(nil)
        case .handToJudges:
            await handToJudges(token)
            return token.isCancelled ? .cancelled : .ok(nil)
        case .tool, .ask, .operate:
            break
        }
        // A request that ran out of time earlier may still be finishing: give it a moment.
        await waitUntil(agentIdleWait, token) { !self.host.isAgentWorking }
        if token.isCancelled { return .cancelled }
        beat = .working
        progressText = nil
        progressSpoken = nil
        let box = ShowOutcomeBox()
        let worker = Task { @MainActor in box.outcome = await self.execute(action) }
        // Narrate while it works. A Yes card cuts in (watch() reads it out).
        for line in during {
            if token.isCancelled || host.hasPendingConfirmation { break }
            await speak(line, token)
        }
        switch await watch(until: { box.outcome != nil }, maxSeconds: maxSeconds, fillers: fillers, step: s, token: token) {
        case .done:
            return box.outcome ?? .failed(nil)
        case .timedOut:
            worker.cancel()
            return .timedOut
        case .cancelled:
            worker.cancel()
            return .cancelled
        }
    }

    private func execute(_ action: ShowAction) async -> ShowActionOutcome {
        switch action {
        case .tool(let call):
            return Self.outcome(await host.runTool(call))
        case .operate(let goal, let app, let person):
            var args: [String: JSONValue] = ["goal": .string(goal), "app": .string(app)]
            if let person { args["person"] = .string(person) }
            return Self.outcome(await host.runTool(ToolCall(id: nil, name: "operate_app", args: .object(args))))
        case .ask(let text, let props):
            let reply = await host.ask(text, images: props.compactMap { $0.jpeg })
            return reply.ok ? .ok(reply.say) : (reply.refused ? .refused(reply.say) : .failed(reply.say))
        case .none, .pause, .handToJudges:
            return .ok(nil)
        }
    }

    /// A runner report as an outcome. Done-but-the-routine-should-stop still counts as done.
    static func outcome(_ report: StepReport?) -> ShowActionOutcome {
        guard let report else { return .failed(nil) }  // no runner registered
        if report.ok { return .ok(report.say) }
        return report.stopped ? .refused(report.say) : .failed(report.say)
    }

    private enum WatchEnd { case done, timedOut, cancelled }

    /// Waits for `done` while keeping the room talking: a "while waiting" line after every few seconds of silence,
    /// the card line when a Yes card appears (which also extends the deadline), and a nudge if it stays up.
    private func watch(until done: @MainActor () -> Bool, maxSeconds: Double, fillers: [String], step s: ShowStep,
                       token: ShowCancel) async -> WatchEnd {
        var deadline = Date().addingTimeInterval(maxSeconds * timeScale)
        var queue = fillers[...]
        // When the step's own lines run out: a few short "still on it" lines, then quiet until the deadline.
        var patience = ShowLines.stillWorking[...]
        var lastSound = Date()
        var cardSince: Date?
        var nudged = false
        while !done() {
            if token.isCancelled { return .cancelled }
            if host.hasPendingConfirmation {
                if cardSince == nil {
                    cardSince = Date()
                    beat = .waitingForCard
                    deadline = max(deadline, Date().addingTimeInterval(confirmGrace * timeScale))
                    await speak(s.confirmLine ?? ShowLines.confirm, token)
                    lastSound = Date()
                    continue
                }
                if !nudged, let since = cardSince, Date().timeIntervalSince(since) >= 15 * timeScale {
                    nudged = true
                    await speak(ShowLines.confirmNudge, token)
                    lastSound = Date()
                    continue
                }
                if let since = cardSince, Date().timeIntervalSince(since) >= cardPatience * timeScale {
                    host.declinePendingConfirmation()  // No: nothing is done
                    note("\(s.id): the card went unanswered, so it was answered No")
                    return .timedOut
                }
            } else if cardSince != nil {
                cardSince = nil
                nudged = false
                beat = .working
            }
            if Date() >= deadline {
                // Never leave the show's own card up: No means nothing is done.
                if host.hasPendingConfirmation { host.declinePendingConfirmation() }
                return .timedOut
            }
            let quiet = Date().timeIntervalSince(lastSound)
            // What the helper is doing right now, live: at most one update every few seconds, never over the voice.
            if cardSince == nil, let p = progressText, p != progressSpoken,
               Date().timeIntervalSince(progressAt) >= progressGap * timeScale, quiet >= 0.8 * timeScale,
               (live as? any LiveVoiceActivity)?.isSpeaking != true, let line = Self.progressLine(p) {
                progressSpoken = p
                progressAt = Date()
                await speak(line, token)
                lastSound = Date()
                continue
            }
            if cardSince == nil, quiet >= fillerGap * timeScale, let next = queue.popFirst() {
                await speak(next, token)
                lastSound = Date()
                continue
            }
            if cardSince == nil, queue.isEmpty, quiet >= (fillerGap + 0.5) * timeScale, let next = patience.popFirst() {
                await speak(next, token)
                lastSound = Date()
                continue
            }
            await pause(0.15, token)
        }
        return .done
    }

    /// The camera is up: wait for the shutter, then for Kairos to do what the photo was for (the share).
    private func waitForPhoto(_ tap: ShowTap, step s: ShowStep, token: ShowCancel) async -> ShowActionOutcome {
        let mark = host.lastLineID
        beat = .waitingForTap
        // Already taken while the step's own line was spoken? Then no "tap the button" line.
        if !tapSignalled, !host.isAgentWorking {
            awaitingTap = tap.prompt
            await speak(tap.prompt, token)
        }
        let start = Date()
        var sawCamera = host.isCameraOpen
        var nudged = false
        var taken = false
        while !token.isCancelled {
            if tapSignalled || host.isAgentWorking { taken = true; break }
            if host.isCameraOpen { sawCamera = true } else if sawCamera { taken = true; break }
            let waited = Date().timeIntervalSince(start)
            if !nudged, let nudge = tap.nudge, waited >= tap.seconds * 0.5 * timeScale {
                nudged = true
                await speak(nudge, token)
                continue
            }
            if waited >= tap.seconds * timeScale { break }
            await pause(0.15, token)
        }
        awaitingTap = nil
        if token.isCancelled { return .cancelled }
        guard taken else {
            host.closeCamera()
            return .timedOut
        }
        // Kairos takes it from here: "Here's the photo for: …" → share_photo → the operator → the Yes card.
        beat = .working
        let started = await waitUntil(8, token) { self.host.isAgentWorking || self.host.reply(after: mark) != nil }
        if token.isCancelled { return .cancelled }
        guard started else { return .failed(nil) }  // the camera closed without a photo
        switch await watch(until: { !self.host.isAgentWorking }, maxSeconds: tap.followUpSeconds,
                           fillers: tap.followUpLines, step: s, token: token) {
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .timedOut
        case .done:
            guard let reply = host.reply(after: mark) else { return .failed(nil) }
            return reply.ok ? .ok(reply.say) : (reply.refused ? .refused(reply.say) : .failed(reply.say))
        }
    }

    /// After WhatsApp or Maps: make sure Kairos is back on screen before the next step.
    private func comeBack(_ token: ShowCancel) async {
        if host.isAppActive || token.isCancelled { return }
        if await waitUntil(2.5, token, { self.host.isAppActive }) { return }  // the operator usually returns by itself
        if token.isCancelled { return }
        if await host.bringKairosBack(), await waitUntil(3, token, { self.host.isAppActive }) { return }
        if token.isCancelled { return }
        await speak(ShowLines.swipeBack, token)
        await waitUntil(15, token) { self.host.isAppActive }
    }

    private func handToJudges(_ token: ShowCancel) async {
        guard !token.isCancelled else { return }
        beat = .handingOver
        currentProp = nil
        // The show's voice lets go first, so the microphone can take over.
        if !narratorReleased {
            narratorReleased = true
            await narrator?.stop()
        }
        if let live, live.isLive || (ShowSettings.handOff != "agent" && live.canStart) {
            mutedLive = false  // startConversation unmutes
            await live.startConversation()
            if live.isLive {
                note("over to the judges: the live voice")
                return
            }
        }
        note("over to the judges: the agent screen's microphone")
        host.openAgentMic()
    }

    private func waitForCardToClear(_ token: ShowCancel) async -> Bool {
        beat = .waitingForCard
        await speak(ShowLines.cardWaiting, token)
        return await waitUntil(cardWaitSeconds, token) { !self.host.hasPendingConfirmation }
    }

    // MARK: Speaking and waiting

    private func speak(_ line: String, _ token: ShowCancel) async {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !token.isCancelled, !narratorReleased, let narrator else { return }
        spokenLine = text
        note("say: \(text)")
        // While LiveKit owns the audio session the phone's voice must not switch it to .playback.
        (narrator as? DeviceNarrator)?.managesAudioSession = !(live?.isLive ?? false)
        // A voice that never reports back can't stall the show: every line has a hard limit (Stop ends it at once).
        // The live voice may wait for a sentence already playing and for the agent to start: give it that room.
        let t = ShowTiming.seconds(text)
        let limit = (narrator is ElevenLabsNarrator ? max(t * 2 + 8, max(4, t) + 18) : t * 2 + 8) * timeScale
        if await ShowRace.within(limit, cancel: token, { await narrator.say(text) }) == nil, !token.isCancelled {
            // Not stop(): for the live voice that would also unmute the call mid-show. The next line cuts this one.
            note("the voice didn't finish “\(text.prefix(40))” in time; carrying on")
        }
    }

    private func speakAfter(_ lines: [String], result: String?, maxSentences: Int, token: ShowCancel) async {
        for line in lines {
            guard let filled = Self.fill(line, result: result, maxSentences: maxSentences) else { continue }
            await speak(filled, token)
        }
    }

    /// `line` with `{result}` replaced by the first sentences of the helper's answer; nil when there's no answer.
    static func fill(_ line: String, result: String?, maxSentences: Int) -> String? {
        guard line.contains("{result}") else { return line }
        guard let r = result?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else { return nil }
        // Numbers and links from a helper's result (a chat, a letter) are never handed to the voice as cue text.
        let safe = OperatorSafety.scrub(r, userWords: "")
        return line.replacingOccurrences(of: "{result}", with: ShowText.clip(safe, sentences: maxSentences))
    }

    @discardableResult
    private func waitUntil(_ seconds: Double, _ token: ShowCancel, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds * timeScale)
        while !condition() {
            if token.isCancelled || Date() >= deadline { return false }
            await pause(0.15, token)
        }
        return true
    }

    /// Sleeps `seconds` of show time, waking at once on Stop.
    private func pause(_ seconds: Double, _ token: ShowCancel) async {
        let end = Date().addingTimeInterval(seconds * timeScale)
        while !token.isCancelled {
            let left = end.timeIntervalSinceNow
            if left <= 0 { return }
            try? await Task.sleep(nanoseconds: UInt64(min(left, 0.1) * 1_000_000_000))
        }
    }

    private func note(_ text: String) { log?(text) }
}

/// A live voice that can say whether it is mid-sentence (TempoVoiceBridge): progress updates wait for it.
@MainActor
protocol LiveVoiceActivity: AnyObject {
    var isSpeaking: Bool { get }
}

extension Notification.Name {
    /// Present mode gave up waiting for the shutter: the agent screen closes its camera (integration note).
    static let kairosShowCloseCamera = Notification.Name("kairos.show.close_camera")
}

/// Holds an action's outcome while the presenter watches the clock.
@MainActor
private final class ShowOutcomeBox {
    var outcome: ShowActionOutcome?
}

// MARK: - Text

enum ShowText {
    /// The first `n` sentences; a final question ("Shall I remind you…?") is always kept.
    static func clip(_ text: String, sentences n: Int) -> String {
        let parts = sentences(text)
        guard n > 0, parts.count > n else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var kept = Array(parts.prefix(n))
        if let last = parts.last, last.hasSuffix("?") { kept.append(last) }
        return kept.joined(separator: " ")
    }

    /// Splits at . ! ? … followed by a space (so "£142.50" stays whole), keeping closing quotes.
    static func sentences(_ text: String) -> [String] {
        let chars = Array(text)
        var out: [String] = []
        var current = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            current.append(c)
            i += 1
            guard ".!?…".contains(c) else { continue }
            while i < chars.count, "”\"’')".contains(chars[i]) { current.append(chars[i]); i += 1 }
            if i >= chars.count || chars[i].isWhitespace {
                let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(t) }
                current = ""
            }
        }
        let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { out.append(t) }
        return out
    }
}
