import SwiftUI
import AVFoundation
import Speech

/// "Make a new agent": one big box (speak or type) for what the agent should do, with ideas to start from.
/// Kairos builds and saves the agent ("Create a helper: …"); this screen watches the library and shows the
/// new agent's card as soon as it appears, with "Try it". If Kairos asks a question first, the box takes the
/// answer. Push it inside AgentLibraryView's navigation.
struct NewAgentView: View {
    @ObservedObject private var library = AgentLibrary.shared
    @ObservedObject private var agent = KairosAgent.shared
    @StateObject private var dictation = AgentStudioUI.Dictation()
    @Environment(\.dismiss) private var dismiss
    @FocusState private var boxFocused: Bool

    @State private var words = ""
    /// What was already in the box when the microphone started (speech is added after it).
    @State private var spokenBase = ""
    /// Agents that existed before the request, so the new one can be spotted.
    @State private var knownIDs: Set<String> = []
    @State private var asked = false
    @State private var waiting = false
    @State private var reply: String?
    /// Kairos asked a question about the new agent: the box is for the answer.
    @State private var answering = false
    @State private var created: AgentSpec?
    @State private var chatting = false

    static let ideas: [String] = [
        "Remind me to take my tablets at 8 every morning and 8 at night, and check I've taken them.",
        "Every morning, tell me the weather and what's on my calendar today.",
        "Look at any message I'm not sure about and tell me if it's a scam.",
        "Help me read my letters and bills, and remind me before anything is due.",
        "Help me keep in touch with my family. Remind me to ring my son on Sundays.",
        "When I'm going out, tell me the way and whether I need a coat.",
    ]

    private var typedWords: String { words.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The newest saved version of the agent just made.
    private var made: AgentSpec? {
        guard let created else { return nil }
        return library.agents.first { $0.id == created.id } ?? created
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                topBar
                Text("Make a new agent")
                    .font(AgentUIStyle.font(34, .bold))
                    .foregroundStyle(AgentUIStyle.ink)
                    .accessibilityAddTraits(.isHeader)
                if let made { madeCard(made) } else { askArea }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(AgentUIStyle.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .environment(\.colorScheme, .light)
        .onChange(of: dictation.heard) { _, heard in
            guard !heard.isEmpty else { return }
            words = spokenBase.isEmpty ? heard : spokenBase + " " + heard
        }
        .onChange(of: library.agents) { _, agents in noticeNewAgent(in: agents) }
        .onDisappear { dictation.stop() }
        .fullScreenCover(isPresented: $chatting, onDismiss: {
            if let created { AgentStudioUI.stopTalking(to: created.id) }
        }) {
            if let created {
                AgentStudioUI.ChatScreen(agentID: created.id) { chatting = false }
            }
        }
    }

    // MARK: - Asking

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Label("Your agents", systemImage: "chevron.left")
                    .font(AgentUIStyle.font(20, .semibold))
                    .padding(.horizontal, 16)
                    .frame(minHeight: 54)
                    .background(.white, in: Capsule())
                    .foregroundStyle(AgentUIStyle.green)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to your agents")
            Spacer()
        }
        .padding(.top, 6)
    }

    private var askArea: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(answering ? "Kairos needs one more thing" : "Tell me what your new agent should do")
                .font(AgentUIStyle.font(26, .semibold))
                .foregroundStyle(AgentUIStyle.ink)
                .fixedSize(horizontal: false, vertical: true)

            if let reply { kairosSays(reply) }

            TextField(answering ? "Your answer" : "For example: remind me about my tablets…",
                      text: $words, axis: .vertical)
                .font(AgentUIStyle.font(24))
                .foregroundStyle(AgentUIStyle.ink)
                .lineLimit(4...10)
                .focused($boxFocused)
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
                .background(.white, in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22)
                    .stroke(dictation.listening ? AgentUIStyle.orange : AgentUIStyle.mist, lineWidth: dictation.listening ? 3 : 1.5))
                .disabled(waiting)
                .accessibilityLabel(answering ? "Your answer" : "What your new agent should do")

            if let status = listeningWords {
                Text(status)
                    .font(AgentUIStyle.font(21, .semibold))
                    .foregroundStyle(dictation.listening ? AgentUIStyle.ink : AgentUIStyle.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            Button { micTapped() } label: {
                Label(dictation.listening ? "Stop listening" : "Tap and speak",
                      systemImage: dictation.listening ? "stop.fill" : "mic.fill")
                    .font(AgentUIStyle.font(24, .bold))
                    .frame(maxWidth: .infinity, minHeight: 76)
                    .background(dictation.listening ? AgentUIStyle.orange : Color.white,
                                in: RoundedRectangle(cornerRadius: 22))
                    .foregroundStyle(dictation.listening ? Color.white : AgentUIStyle.green)
            }
            .buttonStyle(.plain)
            .disabled(waiting)
            .opacity(waiting ? 0.5 : 1)
            .accessibilityHint("Say what the agent should do. Your words appear in the box.")

            Button { submit() } label: {
                Label(answering ? "Send my answer" : "Make my agent",
                      systemImage: answering ? "arrow.up.circle.fill" : "sparkles")
                    .font(AgentUIStyle.font(26, .bold))
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .background(AgentUIStyle.green, in: RoundedRectangle(cornerRadius: 22))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(typedWords.isEmpty || waiting)
            .opacity(typedWords.isEmpty || waiting ? 0.45 : 1)

            if waiting { workingRow }
            if !answering && !waiting { ideasList }
        }
    }

    private var listeningWords: String? {
        if dictation.listening {
            return dictation.heard.isEmpty ? "I'm listening…" : "I'm listening. Tap Stop listening when you've finished."
        }
        return dictation.notice
    }

    private var workingRow: some View {
        HStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(AgentUIStyle.green)
            Text(agent.workingOn.map { $0.hasSuffix("…") ? $0 : $0 + "…" } ?? "Kairos is making your agent…")
                .font(AgentUIStyle.font(21, .medium))
                .foregroundStyle(AgentUIStyle.soft)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func kairosSays(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Kairos says")
                .font(AgentUIStyle.font(18, .semibold))
                .foregroundStyle(AgentUIStyle.soft)
            Text(text)
                .font(AgentUIStyle.font(22))
                .foregroundStyle(AgentUIStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }

    private var ideasList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ideas to start from")
                .font(AgentUIStyle.font(24, .bold))
                .foregroundStyle(AgentUIStyle.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Tap one to put it in the box. You can change the words before you make it.")
                .font(AgentUIStyle.font(19))
                .foregroundStyle(AgentUIStyle.soft)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Self.ideas, id: \.self) { idea in
                Button {
                    dictation.stop()
                    words = idea
                    boxFocused = false
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "lightbulb.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(AgentUIStyle.amber)
                            .accessibilityHidden(true)
                        Text(idea)
                            .font(AgentUIStyle.font(21, .medium))
                            .foregroundStyle(AgentUIStyle.ink)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 20))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Puts this idea in the box")
            }
        }
        .padding(.top, 8)
    }

    // MARK: - The new agent

    private func madeCard(_ spec: AgentSpec) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Saved in Your agents", systemImage: "checkmark.circle.fill")
                .font(AgentUIStyle.font(22, .bold))
                .foregroundStyle(AgentUIStyle.green)

            VStack(alignment: .leading, spacing: 12) {
                AgentStudioUI.Badge(spec: spec, size: 84)
                Text(spec.name)
                    .font(AgentUIStyle.font(30, .bold))
                    .foregroundStyle(AgentUIStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(spec.tagline)
                    .font(AgentUIStyle.font(22))
                    .foregroundStyle(AgentUIStyle.soft)
                    .fixedSize(horizontal: false, vertical: true)
                if !spec.allowedTools.isEmpty {
                    Text("It can:")
                        .font(AgentUIStyle.font(20, .semibold))
                        .foregroundStyle(AgentUIStyle.ink)
                        .padding(.top, 4)
                    ForEach(Array(spec.allowedTools.prefix(5).enumerated()), id: \.offset) { _, name in
                        let w = AgentStudioUI.toolWords(name)
                        Label(w.text, systemImage: w.icon)
                            .font(AgentUIStyle.font(20, .medium))
                            .foregroundStyle(AgentUIStyle.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if spec.allowedTools.count > 5 {
                        Text("and \(spec.allowedTools.count - 5) more things")
                            .font(AgentUIStyle.font(19))
                            .foregroundStyle(AgentUIStyle.soft)
                    }
                }
                if let first = spec.starterPhrases.first {
                    Text("Try saying: “\(first)”")
                        .font(AgentUIStyle.font(20, .medium))
                        .foregroundStyle(AgentUIStyle.soft)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26).stroke(AgentStudioUI.color(spec.colorHex).opacity(0.5), lineWidth: 2.5))
            .accessibilityElement(children: .combine)

            if let reply { kairosSays(reply) }

            Button { tryIt(spec) } label: {
                Label("Try it", systemImage: "mic.fill")
                    .font(AgentUIStyle.font(28, .bold))
                    .frame(maxWidth: .infinity, minHeight: 84)
                    .background(AgentStudioUI.color(spec.colorHex), in: RoundedRectangle(cornerRadius: 24))
                    .foregroundStyle(AgentStudioUI.textColour(on: spec.colorHex))
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Talk to \(spec.name) now")

            NavigationLink(value: AgentStudioUI.Route.agent(spec.id)) {
                Label("See everything it can do", systemImage: "list.bullet")
                    .font(AgentUIStyle.font(22, .bold))
                    .frame(maxWidth: .infinity, minHeight: 68)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20))
                    .foregroundStyle(AgentUIStyle.green)
            }
            .buttonStyle(.plain)

            Button { startAgain() } label: {
                Label("Make another one", systemImage: "plus")
                    .font(AgentUIStyle.font(22, .bold))
                    .frame(maxWidth: .infinity, minHeight: 68)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20))
                    .foregroundStyle(AgentUIStyle.green)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Actions

    private func micTapped() {
        if dictation.listening {
            dictation.stop()
        } else {
            boxFocused = false
            spokenBase = typedWords
            Task { await dictation.start() }
        }
    }

    private func submit() {
        let text = typedWords
        guard !text.isEmpty, !waiting else { return }
        dictation.stop()
        boxFocused = false
        AgentVoice.shared.stopAll()
        // Kairos makes agents; an agent in charge can only use its own tools.
        AgentStudioUI.backToKairos()
        if !answering { knownIDs = Set(library.agents.map(\.id)) }
        asked = true
        // "a helper": this screen saves a helper persona (the Studio). "Create an agent to …" elsewhere starts a worker.
        let request = answering ? text : "Create a helper: \(text)"
        waiting = true
        reply = nil
        Task { @MainActor in
            // One request at a time (Siri or another screen may be using Kairos).
            var waited = 0
            while KairosAgent.shared.working, waited < 150 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                waited += 1
            }
            let outcome = await KairosAgent.shared.handle(request)
            waiting = false
            noticeNewAgent(in: library.agents)
            reply = outcome.say
            if created == nil {
                answering = outcome.say.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
                if answering { words = "" }
            }
            AgentVoice.shared.speak(outcome.say)
        }
    }

    /// The library grew while Kairos was working: that's the new agent.
    private func noticeNewAgent(in agents: [AgentSpec]) {
        guard asked, created == nil,
              let new = agents.last(where: { !knownIDs.contains($0.id) && $0.origin != .builtin }) else { return }
        created = new
        answering = false
    }

    private func tryIt(_ spec: AgentSpec) {
        AgentVoice.shared.stopAll()
        AgentStudioUI.startTalking(to: spec)
        chatting = true
    }

    private func startAgain() {
        dictation.stop()
        words = ""
        spokenBase = ""
        reply = nil
        answering = false
        created = nil
        asked = false
        knownIDs = []
    }
}

// MARK: - Speaking into the box

extension AgentStudioUI {
    /// Speech to words for the "new agent" box. Unlike AgentVoice's big button it never sends anything:
    /// the words land in the box for the person to check. It stops by itself after a short quiet spell,
    /// uses the phone's own recogniser when it can, and stays out of the ElevenLabs call's way.
    @MainActor
    final class Dictation: ObservableObject {
        @Published private(set) var listening = false
        /// Everything heard since the microphone started.
        @Published private(set) var heard = ""
        /// One plain sentence about a problem.
        @Published var notice: String?

        let quietSeconds: Double = 2.5
        let firstWordSeconds: Double = 8
        let longestListen: Double = 55

        private var engine: AVAudioEngine?
        private var recognizer: SFSpeechRecognizer?
        private var request: SFSpeechAudioBufferRecognitionRequest?
        private var task: SFSpeechRecognitionTask?
        private var timer: Task<Void, Never>?
        private var listenID = UUID()
        private var started = Date()
        private var starting = false

        func start() async {
            guard !listening, !starting else { return }
            notice = nil
            let voice = AgentVoice.shared
            voice.stopAll()
            if voice.otherCallActive() {
                notice = "You're on a voice call with Kairos. End that call first, or type instead."
                return
            }
            starting = true
            defer { starting = false }
            guard await voice.askPermissions() else {
                notice = voice.notice ?? "Kairos isn't allowed to listen yet. You can type instead."
                voice.notice = nil
                return
            }
            let (found, languageNote) = AgentVoice.recognizer(for: AgentLanguage.current)
            guard let recognizer = found else {
                notice = "I can't listen on this phone just now. Please type instead."
                return
            }
            let audio = AVAudioSession.sharedInstance()
            do {
                try audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers])
                try audio.setActive(true)
            } catch {
                notice = "The microphone is busy just now. Please try again in a moment."
                return
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            request.addsPunctuation = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                notice = "I can't hear the microphone. Please try again."
                release()
                return
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.feed(request))
            engine.prepare()
            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                notice = "I couldn't start listening. Please try again."
                release()
                return
            }

            let id = UUID()
            listenID = id
            self.engine = engine
            self.recognizer = recognizer
            self.request = request
            task = recognizer.recognitionTask(with: request, resultHandler: Self.report { [weak self] text, isFinal, failed in
                let me = self
                Task { @MainActor in me?.got(text, isFinal: isFinal, failed: failed, id: id) }
            })
            heard = ""
            started = Date()
            listening = true
            notice = languageNote
            arm(firstWordSeconds, id: id)
        }

        /// Stops listening; what was heard stays in `heard`.
        func stop() {
            guard listening else { return }
            listening = false
            listenID = UUID()
            timer?.cancel()
            timer = nil
            engine?.stop()
            engine?.inputNode.removeTap(onBus: 0)
            request?.endAudio()
            task?.cancel()
            engine = nil
            request = nil
            task = nil
            recognizer = nil
            release()
        }

        private func got(_ text: String?, isFinal: Bool, failed: Bool, id: UUID) {
            guard listening, id == listenID else { return }
            if let text, !text.isEmpty, text != heard {
                heard = text
                arm(quietSeconds, id: id)
            }
            if isFinal || failed {
                if heard.isEmpty { notice = "I didn't hear anything. Tap the button and try again." }
                stop()
            }
        }

        private func arm(_ seconds: Double, id: UUID) {
            timer?.cancel()
            let left = longestListen - Date().timeIntervalSince(started)
            let wait = max(0.3, min(seconds, left))
            timer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled, let self, self.listening, self.listenID == id else { return }
                if self.heard.isEmpty { self.notice = "I didn't hear anything. Tap the button and try again." }
                self.stop()
            }
        }

        /// Hands the audio back unless Kairos's own voice or the ElevenLabs call is using it.
        private func release() {
            let voice = AgentVoice.shared
            guard !listening, !voice.isSpeaking, !voice.isListening, !voice.otherCallActive() else { return }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }

        // Callbacks made off the main actor.

        nonisolated private static func feed(_ request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
            { buffer, _ in request.append(buffer) }
        }

        nonisolated private static func report(
            _ deliver: @escaping @Sendable (String?, Bool, Bool) -> Void
        ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
            { result, error in
                deliver(result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
            }
        }
    }
}
