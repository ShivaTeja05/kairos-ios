import AVFAudio
import Combine
import ElevenLabs
import Foundation
import LiveKit
import LocalAuthentication

/// One voice session with Tempo, plus live narration of the helpers (agents) working on the phone or laptop.
@MainActor
final class TempoSession: ObservableObject {
    struct Line: Identifiable { let id = UUID(); let fromTempo: Bool; let text: String }

    enum Phase: Equatable { case needsSetup, idle, connecting, listening, speaking, thinking, error(String) }

    @Published var phase: Phase = .idle
    @Published var lines: [Line] = []
    @Published var helperSteps: [String] = []
    @Published var helperWorking = false
    /// A risky action the helpers stopped before (call, send, claim…): only a tap here approves it, once.
    @Published var pendingApproval: (id: String, task: String)?
    /// A payment the Navigator filled in and verified on the bank's screen; waits for the owner's Yes (then Face ID).
    @Published var pendingPayment: PaymentView?
    @Published var approvalSecondsLeft: Int = 0
    private var countdown: Task<Void, Never>?
    /// The Navigator running ON this phone (OpenMinis sandbox + iCTRL runner) speaks over loopback; see navigator/card_server.py.
    @Published var localNavigatorSeen = false
    private let localNavigator = URL(string: "http://127.0.0.1:8790/navigator/")!
    private var localTask: Task<Void, Never>?
    private var localPending: (id: String, token: String)?

    private var conversation: Conversation?
    var isInCall: Bool { conversation != nil }
    /// Write for me inside a call: the agent's draft_message / deliver_message / cancel_message (Bridge/InCallBridge.swift).
    let bridge = InCallBridge()
    private var subs = Set<AnyCancellable>()
    private var watchTask: Task<Void, Never>?
    private var autoStarted = false

    private var baseURL: URL? { KeyStore.get("base").flatMap(URL.init(string:)) }
    private var phoneKey: String? { KeyStore.get("key") }

    init() {
        if phoneKey == nil || baseURL == nil { phase = .needsSetup }
    }

    // MARK: - setup and launching

    func handle(url: URL) {
        guard url.scheme == "tempo" || url.scheme == "kairos" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let wasUnconfigured = phoneKey == nil || baseURL == nil
        var stored = false
        if url.host == "setup", phoneKey == nil || baseURL == nil,  // ignored once set up: re-pointing needs a reinstall
           let key = items.first(where: { $0.name == "k" })?.value, key.count >= 16,
           let base = items.first(where: { $0.name == "u" })?.value, base.hasPrefix("https://") {
            KeyStore.set("key", key)
            KeyStore.set("base", base)
            stored = true
            phase = .idle
            say("Kairos is connected to your Mac.", fromTempo: true)
        }
        // The app's own hub login (read/ask/Bridge, never admin), added once. A link from a message or web page can't
        // plant one: it must come with the first setup in the same link, or carry the phone key already stored here.
        let linkKey = items.first(where: { $0.name == "k" })?.value
        let provesOwner = (wasUnconfigured && stored) || (linkKey != nil && linkKey == phoneKey && !wasUnconfigured)
        // A newer token (rotation) may replace the old one, but only with the same proof: no reinstall needed.
        if url.host == "setup", provesOwner, baseURL != nil,
           let token = items.first(where: { $0.name == "t" })?.value, token.count >= 20,
           token != KeyStore.get("device_token") {
            let replacing = KeyStore.get("device_token") != nil
            KeyStore.set("device_token", token)
            stored = true
            if replacing { say("Kairos's login was updated.", fromTempo: true) }
        }
        if stored { bridge.refreshAPI() }
        if url.host == "talk" { startIfIdle() }
        if url.host == "letter" { NotificationCenter.default.post(name: .tempoLetter, object: nil) }
    }

    /// Something happened outside the call (a letter was read) that Kairos should know about, so the person can
    /// just keep talking. Nothing is sent when there's no call.
    func tellKairos(_ text: String) {
        guard let conv = conversation else { return }
        Task { try? await conv.updateContext(text) }
    }

    /// Present mode (Agents/Showcase/TempoVoiceBridge.swift): a user turn the voice agent answers straight away
    /// ("Presentation: <exact words>"), and the call's microphone. False when there is no call.
    func sendToAgent(_ text: String) async -> Bool {
        guard let conv = conversation else { return false }
        do { try await conv.sendMessage(text); return true } catch { return false }
    }

    func setCallMicMuted(_ muted: Bool) async { try? await conversation?.setMuted(muted) }

    /// The old Kairos: this ElevenLabs call through the tempo-hub server. Off since Kairos became one agent across
    /// the person's devices (the on-phone agent plus the kairos-mesh hub on their Mac). Kept, not deleted, until
    /// after Nov 1: `defaults write` the key on a test build to bring the old screen back.
    static var legacyVoice: Bool { UserDefaults.standard.bool(forKey: "kairos.legacy_voice") }

    func startIfIdle(auto: Bool = false) {
        guard Self.legacyVoice else { return }
        if auto { guard !autoStarted else { return }; autoStarted = true }
        guard !starting, conversation == nil, phase == .idle || isError else { return }
        startTask = Task { await start() }
    }

    private var startTask: Task<Void, Never>?

    /// One start at a time (a double tap or Siri + auto-start must not open two calls), and a way for stop() to
    /// cancel a call that is still connecting.
    private var starting = false
    private var startGeneration = 0

    private var isError: Bool { if case .error = phase { return true }; return false }

    // MARK: - the conversation

    func start() async {
        guard !starting, conversation == nil else { return }
        guard let base = baseURL, let key = phoneKey else { phase = .needsSetup; return }
        starting = true
        defer { starting = false }
        startGeneration &+= 1
        let gen = startGeneration
        // Ask for the microphone first: the permission pop-up must not interrupt a call that already started.
        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .error("Please allow the microphone: Settings → Kairos → Microphone.")
            return
        }
        guard gen == startGeneration else { return }
        phase = .connecting
        do {
            let (token, kairosSession) = try await fetchVoiceCredentials(base: base, key: key)
            guard gen == startGeneration else { return }   // stop() was tapped while connecting
            let config = ConversationConfig(
                dynamicVariables: kairosSession.map { ["secret__kairos_session": $0] },
                onAgentToolResponse: { [weak self] event in
                    Task { @MainActor in self?.toolFinished(event) }
                },
                onAgentToolRequest: { [weak self] event in
                    Task { @MainActor in self?.toolStarted(event) }
                },
                onUnhandledClientToolCall: { [weak self] call in
                    Task { @MainActor in await self?.clientTool(call) }
                }
            )
            let conv = try await ElevenLabs.startConversation(
                conversationToken: token, config: config,
                onDisconnect: { [weak self] _ in Task { @MainActor in self?.ended() } })
            guard gen == startGeneration else {   // stopped while connecting: hang up and let go of the mic
                await conv.endConversation()
                await Self.releaseMicrophone()
                return
            }
            conversation = conv
            bridgeScopeStart = 0
            bind(conv)
        } catch {
            await Self.releaseMicrophone()   // a failed connect can leave LiveKit's prepared mic running
            guard gen == startGeneration else { return }
            phase = .error((error as? VoiceUnavailable)?.message ?? "Couldn't reach Kairos. Check the Wi-Fi and your Mac.")
        }
    }

    func stop() async {
        startGeneration &+= 1   // a call still connecting is abandoned (start() hangs it up when it arrives)
        // Wait for a connect in flight to finish hanging itself up, so endCall really means "no call, no mic".
        if let pending = startTask { startTask = nil; pending.cancel(); await pending.value }
        await conversation?.endConversation()
        ended()
        await Self.releaseMicrophone()
    }

    /// The ElevenLabs SDK keeps LiveKit's recording engine "always prepared" after a call, so the mic would stay
    /// live in the background (UIBackgroundModes audio) while WhatsApp or the recorder takes over. Turn it off.
    static func releaseMicrophone() async {
        try? await AudioManager.shared.setRecordingAlwaysPreparedMode(false)
    }

    private func ended() {
        let wasInCall = conversation != nil
        conversation = nil
        subs.removeAll()
        if wasInCall { Task { await Self.releaseMicrophone() } }   // also when Kairos or the network ended the call
        if case .error = phase { return }
        phase = phoneKey == nil ? .needsSetup : .idle
    }

    private func bind(_ conv: Conversation) {
        subs.removeAll()
        conv.$agentState.receive(on: RunLoop.main).sink { [weak self] state in
            guard let self, self.conversation != nil else { return }
            switch state {
            case .speaking: self.phase = .speaking
            case .thinking: self.phase = .thinking
            default: self.phase = .listening
            }
        }.store(in: &subs)
        conv.$messages.receive(on: RunLoop.main).sink { [weak self] messages in
            self?.lines = messages.suffix(4).map { Line(fromTempo: $0.role == .agent, text: $0.content) }
        }.store(in: &subs)
        conv.$state.receive(on: RunLoop.main).sink { [weak self] state in
            if case .error = state { self?.phase = .error("The call dropped. Tap to try again.") }
        }.store(in: &subs)
    }

    private func say(_ text: String, fromTempo: Bool) {
        lines = Array((lines + [Line(fromTempo: fromTempo, text: text)]).suffix(4))
    }

    // MARK: - helpers (phone / laptop agents) narrated live

    private func toolStarted(_ event: AgentToolRequestEvent) {
        // A server helper (phone_task, ask_tempo) is a different subject; the Bridge's own client tools are not.
        if !["draft_message", "deliver_message", "cancel_message"].contains(event.toolName) {
            bridgeScopeStart = conversation?.messages.count ?? 0
        }
        guard event.toolName == "phone_task" else { return }
        helperWorking = true
        helperSteps = ["Your helpers are starting…"]
        watchTask?.cancel()
        watchTask = Task { await watchHelpers() }
    }

    private func toolFinished(_ event: AgentToolResponseEvent) {
        if event.toolName == "phone_task", event.isError { helperWorking = false }
    }

    /// Polls the Mac for the latest task while it runs. New steps go to Tempo as context, so it can tell the
    /// user what is happening; the final answer goes too, in case the tool reply came back before it finished.
    private func watchHelpers() async {
        guard let base = baseURL, let key = phoneKey else { return }
        var told = 0
        var taskId: String?
        for _ in 0..<120 {
            if Task.isCancelled { return }
            if let t = try? await latestTask(base: base, key: key) {
                if taskId == nil { taskId = t.id }
                if t.id == taskId {
                    let steps = t.steps ?? []
                    if steps.count > told {
                        let fresh = Array(steps[told...])
                        told = steps.count
                        helperSteps = steps.suffix(6).map { $0 }
                        try? await conversation?.updateContext("Progress on the user's task: " + fresh.joined(separator: "; "))
                    }
                    if t.status == "needs_confirmation", let id = t.id {
                        helperWorking = false
                        pendingApproval = (id, t.payment?.readback ?? t.task ?? "this action")
                        pendingPayment = t.payment
                        if let p = t.payment {
                            startCountdown(p.expires_in ?? 90)
                            try? await conversation?.updateContext(
                                "A payment card is on the user's screen: \(p.readback ?? ""). The bank's own screen shows " +
                                "\(p.cop_name ?? p.payee ?? "") and \(p.amount ?? ""). Tell them that, ask them to read the card and tap " +
                                "Yes only if it is right. Only their tap counts; nothing is sent until then.")
                        } else {
                            try? await conversation?.updateContext(
                                "The helpers stopped before a risky step. A big Yes/No card is now on the user's screen. " +
                                "Ask them to read it and tap Yes if they want it done. Only their tap counts.")
                        }
                        return
                    }
                    if t.status != "running" {
                        helperWorking = false
                        if let answer = t.answer {
                            try? await conversation?.updateContext("Phone task result: \(answer)")
                        }
                        return
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        helperWorking = false
    }

    /// The approval has a short life (the Navigator's token): when it runs out, the card goes and nothing was sent.
    private func startCountdown(_ seconds: Int) {
        countdown?.cancel()
        approvalSecondsLeft = max(1, seconds)
        countdown = Task { [weak self] in
            while let self, self.approvalSecondsLeft > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                self.approvalSecondsLeft -= 1
            }
            guard let self, self.pendingPayment != nil else { return }
            self.pendingApproval = nil
            self.pendingPayment = nil
            self.say("The time to approve ran out. Nothing was sent.", fromTempo: true)
            try? await self.conversation?.updateContext("The approval time ran out, so nothing was sent.")
        }
    }

    func decide(approve: Bool) async {
        guard let pending = pendingApproval, let base = baseURL, let key = phoneKey else { return }
        let payment = pendingPayment
        let local = localPending
        pendingApproval = nil
        pendingPayment = nil
        localPending = nil
        countdown?.cancel()
        guard approve else {
            if let local { await postLocal("decline", ["id": local.id]) }
            try? await conversation?.updateContext("The user tapped No. Do not do that action." +
                                                    (payment != nil ? " Nothing was sent." : ""))
            return
        }
        // The owner proves it's them (Face ID, or the phone passcode) before any risky action runs.
        let context = LAContext()
        let reason = payment.map { "Send \($0.amount ?? "") to \($0.cop_name ?? $0.payee ?? "")" } ?? "Approve: \(pending.task)"
        let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
        guard ok else {
            if let local { await postLocal("decline", ["id": local.id]) }
            try? await conversation?.updateContext("Face ID didn't confirm it was the owner, so nothing was done.")
            return
        }
        if let local {  // the Navigator on this phone: approve over loopback, it presses Confirm in the bank itself
            helperWorking = true
            helperSteps = ["Approved by you. Pressing Confirm in your bank…"]
            await postLocal("approve", ["id": local.id, "token": local.token])
            return
        }
        var req = URLRequest(url: base.appendingPathComponent("voice/phone-task"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "X-Tempo-Phone-Key")
        req.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["approve": pending.id, "wait": 1])
        helperWorking = true
        helperSteps = [payment != nil ? "Approved by you. Pressing Confirm in your bank…" : "Approved by you. Doing it now…"]
        try? await conversation?.updateContext(payment != nil
            ? "The user tapped Yes and passed Face ID. The Navigator is pressing Confirm in the bank app now; the result follows."
            : "The user tapped Yes on the screen. The helpers are doing it now.")
        _ = try? await URLSession.shared.data(for: req)
        watchTask?.cancel()
        watchTask = Task { await watchHelpers() }
    }

    // MARK: - the Navigator on this phone (loopback)

    /// While Kairos is on screen, look for a Navigator running on this phone. When it is waiting for the owner's
    /// Yes, show the same payment card; the approval goes back over loopback with the payment's one-time token.
    func startLocalWatch() {
        localTask?.cancel()
        localTask = Task { [weak self] in
            var shownFor: String?
            while let self, !Task.isCancelled {
                var delay: UInt64 = 1_500_000_000
                if let t = try? await self.fetchLocalStatus() {
                    self.localNavigatorSeen = true
                    if t.status == "needs_confirmation", let id = t.id, let p = t.payment, shownFor != id {
                        shownFor = id
                        self.helperWorking = false
                        self.pendingPayment = p
                        self.pendingApproval = (id, p.readback ?? t.task ?? "this payment")
                        self.localPending = (id, p.token ?? "")
                        self.startCountdown(p.expires_in ?? 90)
                    } else if t.status == "running" {
                        self.helperWorking = true
                        self.helperSteps = Array((t.steps ?? []).suffix(6))
                    } else if let id = t.id, shownFor == id, t.status != "needs_confirmation" {
                        shownFor = nil
                        self.helperWorking = false
                        if let a = t.answer { self.say(a, fromTempo: true) }
                    }
                } else {
                    delay = 5_000_000_000
                }
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }

    func stopLocalWatch() { localTask?.cancel(); localTask = nil }

    private func fetchLocalStatus() async throws -> TaskView {
        var req = URLRequest(url: localNavigator.appendingPathComponent("status"))
        req.timeoutInterval = 1.5
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(TaskView.self, from: data)
    }

    private func postLocal(_ action: String, _ body: [String: Any]) async {
        var req = URLRequest(url: localNavigator.appendingPathComponent(action))
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Bridge client tools (draft_message / deliver_message / cancel_message)

    /// Where the words for the next message start: after the last Bridge step or helper task, so an earlier
    /// conversation (or a payment card) never leaks into a message.
    private var bridgeScopeStart = 0

    private func clientTool(_ call: ClientToolCallEvent) async {
        // The on-phone helpers (TempoApp/Agents): the voice agent hands them a task with phone_agent and reads back
        // what actually happened. Anything that reaches a person shows the big card + Face ID on the main screen.
        if call.toolName == "phone_agent" {
            // Present mode: the app is already running the agents; a second request would decline the show's card.
            if Presenter.shared.isPresenting {
                try? await conversation?.sendToolResult(for: call.toolCallId, result: #"{"result":"Kairos is presenting and the app is already doing this. Do not call tools; only say the Presentation lines."}"#, isError: false)
                return
            }
            let params = (try? call.getParameters()) ?? [:]
            // Shared context: the brain on the phone (Gemini) sees the last few turns of this call, and the voice
            // isn't told twice about actions it gets back in this result (VoiceContextBridge).
            KairosAgent.shared.voiceContext = (conversation?.messages ?? []).suffix(8)
                .map { ($0.role == .user ? "Person: " : "Kairos voice: ") + $0.content }
            VoiceContextBridge.shared.attach(self)
            VoiceContextBridge.shared.toolCallInFlight = true
            let outcome = await KairosAgent.shared.handle((params["request"] as? String) ?? "", source: .app)
            VoiceContextBridge.shared.toolCallInFlight = false
            KairosAgent.shared.voiceContext = []
            let body = ["result": outcome.say, "look_at_screen": outcome.needsApp ? "yes" : "no"]
            let json = (try? JSONSerialization.data(withJSONObject: body)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            try? await conversation?.sendToolResult(for: call.toolCallId, result: json, isError: false)
            return
        }
        let all = conversation?.messages ?? []
        let from = min(bridgeScopeStart, all.count)
        // Only the person's own words go to the drafter, never the agent's.
        let mine = all[from...].filter { $0.role == .user && !$0.content.hasPrefix("Presentation:") }.map(\.content)
        let r = await bridge.handle(call, transcript: mine)
        try? await conversation?.sendToolResult(for: call.toolCallId, result: r.json, isError: r.isError)
        // Words are "spent" once a draft was shown, delivered or cancelled. A question back ("Amma or Anna?")
        // keeps them, so the follow-up call can still use what the person said.
        if r.spendsWords { bridgeScopeStart = conversation?.messages.count ?? 0 }
    }

    /// "Say it again" during a call: ask Kairos to read the exact text (the phone's speaker would fight the call).
    func readExactly(_ text: String) {
        tellKairos("Read the message on the person's screen aloud now, word for word, exactly as written, then stop: «\(text)»")
    }

    // MARK: - talking to the Mac

    private struct TokenReply: Decodable { let token: String? ; let error: String? }
    /// What the Navigator read off the bank's own review screen, plus what the person asked for.
    struct PaymentView: Decodable {
        let amount: String?; let payee: String?; let account: String?; let reference: String?
        let cop_name: String?; let cop: String?; let readback: String?; let expires_in: Int?; let extra_confirm: Bool?
        let token: String?
    }
    struct TaskView: Decodable {
        let id: String?; let task: String?; let status: String; let steps: [String]?; let answer: String?
        let payment: PaymentView?; let money: Bool?
    }

    private struct VoiceSessionReply: Decodable { let conversation_token: String?; let kairos_session: String? }
    struct VoiceUnavailable: Error { let message: String }

    /// The hub's /api/voice/session (device token) when this phone has one; otherwise the older /voice/token.
    private func fetchVoiceCredentials(base: URL, key: String) async throws -> (String, String?) {
        if let device = KeyStore.get("device_token") {
            var req = URLRequest(url: base.appendingPathComponent("api/voice/session"))
            req.httpMethod = "POST"
            req.timeoutInterval = 15
            req.setValue("Bearer \(device)", forHTTPHeaderField: "Authorization")
            req.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning")
            if let (data, resp) = try? await URLSession.shared.data(for: req) {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200, let r = try? JSONDecoder().decode(VoiceSessionReply.self, from: data),
                   let t = r.conversation_token {
                    return (t, r.kairos_session)
                }
                // 503 = voice paused by the owner's kill switch, 429 = today's voice minutes are used. The old route
                // must not get around either; Write for me keeps working.
                if code == 503 { throw VoiceUnavailable(message: "Voice is paused just now. Write for me still works.") }
                if code == 429 { throw VoiceUnavailable(message: "Today's talking time is used up. Write for me still works.") }
                if code != 404 { throw VoiceUnavailable(message: "Kairos couldn't start a call just now. Please try again.") }
            }
            // 404 (route not public yet) or no connection at all: the older phone-key route.
        }
        return (try await fetchToken(base: base, key: key), nil)
    }

    private func fetchToken(base: URL, key: String) async throws -> String {
        var req = URLRequest(url: base.appendingPathComponent("voice/token"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "X-Tempo-Phone-Key")
        req.setValue("app", forHTTPHeaderField: "X-Tempo-Client")
        req.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning")
        req.httpBody = Data(#"{"mode":"webrtc"}"#.utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let reply = try? JSONDecoder().decode(TokenReply.self, from: data)
        if let token = reply?.token { return token }
        // The voice server's own words for the off-switch (503) and the daily limit (429), shown as they are.
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 503 || code == 429 {
            throw VoiceUnavailable(message: reply?.error ?? (code == 503 ? "Voice is paused just now. Write for me still works."
                                                                        : "Today's talking time is used up. Write for me still works."))
        }
        throw URLError(.userAuthenticationRequired)
    }

    private func latestTask(base: URL, key: String) async throws -> TaskView {
        var req = URLRequest(url: base.appendingPathComponent("voice/phone-task/latest"))
        req.setValue(key, forHTTPHeaderField: "X-Tempo-Phone-Key")
        req.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning")
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(TaskView.self, from: data)
    }
}
