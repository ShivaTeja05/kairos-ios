import SwiftUI

/// The app's colours and fonts, shared by the agent screens (same values as ContentView).
enum AgentUIStyle {
    static let paper = Color(red: 0.96, green: 0.95, blue: 0.92)
    static let green = Color(red: 0.18, green: 0.44, blue: 0.37)
    static let ink = Color(red: 0.11, green: 0.11, blue: 0.10)
    static let soft = Color(red: 0.25, green: 0.25, blue: 0.23)
    static let orange = Color(red: 0.76, green: 0.40, blue: 0.18)
    static let amber = Color(red: 0.6, green: 0.35, blue: 0.0)
    static let amberBack = Color(red: 1.0, green: 0.95, blue: 0.84)
    static let red = Color(red: 0.70, green: 0.20, blue: 0.15)
    static let mist = Color(red: 0.85, green: 0.85, blue: 0.82)
    static let personBubble = Color(red: 0.88, green: 0.93, blue: 0.91)

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// Kairos running on this phone. One giant button to talk (or type instead), "Read a letter", the
/// conversation with what each helper did, and the big Yes / No card for anything that reaches a person.
struct AgentHomeView: View {
    /// When this screen is shown over the rest of the app, this closes it (a Close button appears).
    var onClose: (() -> Void)? = nil

    @ObservedObject private var agent = KairosAgent.shared
    @ObservedObject private var voice = AgentVoice.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var showAgents = false
    @State private var showTrust = false
    @State private var showReports = false
    /// The Agents board (worker agents), opened at one agent's card when `boardRun` is set.
    @State private var showBoard = false
    @State private var boardRun: UUID?
    @State private var showSelfTest = false
    @State private var showMemory = false
    /// Worker runs whose "is done" line was already said here.
    @State private var announced: Set<UUID> = []
    @ObservedObject private var library = AgentLibrary.shared
    @State private var camera: AgentCamera.Source?
    /// The camera is open because take_photo asked for a photo (not the person's own "Read a letter").
    @State private var cameraForPhoto = false
    @State private var typing = false
    @State private var typed = ""
    /// Kairos can think about more than its rules: a Gemini key when Gemini is the brain, or a joined Mac.
    @State private var hasKey = AgentHomeView.canThink
    @FocusState private var typeFocused: Bool

    private static var canThink: Bool {
        AgentSettings.brain == .gemini ? AgentSettings.hasKey : MeshNode.shared.isPaired
    }

    private var thinking: Bool { agent.working || voice.isAsking }

    var body: some View {
        ZStack {
            AgentUIStyle.paper.ignoresSafeArea()

            VStack(spacing: 12) {
                topBar
                WorkerLiveStrip(onOpen: { id in voice.stopAll(); boardRun = id; showBoard = true })
                Text(library.focused?.name ?? "Kairos on this phone")
                    .font(AgentUIStyle.font(34, .bold))
                    .foregroundStyle(AgentUIStyle.ink)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if !hasKey { keyBanner }
                conversation
                statusLine
                micButton
                letterButton
                secondaryRow
                if typing { typeBox }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .accessibilityHidden(agent.confirmation != nil)

            if let card = agent.confirmation {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                        .accessibilityHidden(true)
                    AgentConfirmCard(card: card).id(card.id)
                }
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .environment(\.colorScheme, .light)
        // Shown as a sheet: a stray swipe must not close it while a Yes/No card or a request is waiting.
        .interactiveDismissDisabled(agent.confirmation != nil || agent.working)
        .animation(.easeOut(duration: 0.2), value: agent.confirmation?.id)
        .sheet(isPresented: $showSettings, onDismiss: { hasKey = Self.canThink }) {
            AgentSettingsView()
        }
        .sheet(isPresented: $showTrust) { TrustSettingsView() }
        .fullScreenCover(isPresented: $showBoard) {
            AgentBoardView(onClose: { showBoard = false }, openRun: boardRun)
                .overlay { PresentationOverlay() }
                .overlay { confirmOverlay }
        }
        .fullScreenCover(isPresented: $showReports) {
            ReportsView(onClose: { showReports = false }, onAsk: { AgentVoice.shared.ask($0) })
                .overlay { PresentationOverlay() }
                .overlay { confirmOverlay }
        }
        .fullScreenCover(isPresented: $showMemory) {
            MemoryWindowView(onClose: { showMemory = false }, ask: { await AgentVoice.shared.askAndSpeak($0).say })
                .overlay { PresentationOverlay() }
                .overlay { confirmOverlay }
        }
        .fullScreenCover(isPresented: $showSelfTest) {
            KairosSelfTestView(onClose: { showSelfTest = false })
        }
        .researchShareSheet()
        // A worker agent finished while this screen is open: say so here (the voice call hears it separately).
        .onReceive(NotificationCenter.default.publisher(for: .workerRunUpdated)) { note in
            guard let run = note.object as? WorkerRun, run.status == .done || run.status == .failed,
                  !announced.contains(run.id), !WorkerPool.shared.isExternal(run.id), !agent.dryRun else { return }
            announced.insert(run.id)
            agent.note(run.finishLine)
            if !voice.isBusy, !agent.working, agent.confirmation == nil { voice.speak(run.finishLine) }
        }
        .fullScreenCover(isPresented: $showAgents) {
            AgentLibraryView(onClose: { showAgents = false })
                .overlay { PresentationOverlay() }
                // The Yes/No card must be seen over "Saved helpers" too, or the request waits 90 s.
                .overlay { confirmOverlay }
        }
        .fullScreenCover(item: $camera) { source in
            AgentCamera(source: source) { jpeg in
                camera = nil
                let forPhoto = cameraForPhoto
                cameraForPhoto = false
                if let jpeg {
                    if forPhoto, let prompt = PhotoStore.shared.takePendingPrompt() {
                        // take_photo asked for this one: keep it and finish the job (post, send, save).
                        PhotoStore.shared.keep(jpeg)
                        Presenter.shared.tapped()
                        voice.ask(prompt)
                    } else {
                        voice.ask("Please read this letter.", images: [jpeg])
                    }
                } else {
                    PhotoStore.shared.clearPending()
                }
            }
            .ignoresSafeArea()
        }
        .onChange(of: agent.cameraRequested) { _, wanted in
            if wanted { agent.cameraRequested = false; openCamera(.camera, forPhoto: true) }
        }
        .onChange(of: camera) { _, c in KairosShowHost.shared.cameraIsOpen = (c != nil) }
        .onReceive(NotificationCenter.default.publisher(for: .kairosShowCloseCamera)) { _ in
            camera = nil
            cameraForPhoto = false
            PhotoStore.shared.clearPending()
        }
        .onChange(of: agent.confirmation?.id) { _, id in
            guard id != nil, let card = agent.confirmation else { return }
            // The card must be seen: close the keyboard and any sheet, and read it out.
            typeFocused = false
            showSettings = false
            showTrust = false
            voice.speak("Please check the screen. \(card.detail). Tap Yes, or No.")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { resumeFromSiri() }
            if phase == .background { voice.finishListening(send: false) }
        }
        .onAppear {
            AgentAppHooks.screenAppeared()
            hasKey = Self.canThink
            resumeFromSiri()
            if agent.cameraRequested { agent.cameraRequested = false; openCamera(.camera, forPhoto: true) }
        }
        .onDisappear { voice.stopAll(); AgentAppHooks.screenDisappeared() }
    }

    /// The Yes/No card over a full-screen page (saved helpers, the Agents board, Reports).
    @ViewBuilder
    private var confirmOverlay: some View {
        if let card = agent.confirmation {
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                AgentConfirmCard(card: card).id(card.id)
            }
        }
    }

    // MARK: - Top

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { newConversation() } label: {
                Label("New conversation", systemImage: "arrow.counterclockwise")
                    .font(AgentUIStyle.font(18, .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 52)
                    .background(.white, in: Capsule())
                    .foregroundStyle(AgentUIStyle.green)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Clears the conversation and starts again")

            Spacer(minLength: 4)

            if let onClose {
                Button(action: onClose) {
                    Text("Close")
                        .font(AgentUIStyle.font(18, .semibold))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 52)
                        .background(.white, in: Capsule())
                        .foregroundStyle(AgentUIStyle.ink)
                }
                .buttonStyle(.plain)
            }

            moreMenu

            Button { voice.stopAll(); showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .frame(width: 56, height: 56)
                    .background(.white, in: Circle())
                    .foregroundStyle(AgentUIStyle.soft)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .padding(.top, 4)
    }

    /// The Agents board, saved helpers, Reports, Permissions and Present Kairos, behind one big button.
    private var moreMenu: some View {
        Menu {
            Button { voice.stopAll(); boardRun = nil; showBoard = true } label: {
                Label("Agents board", systemImage: "square.stack.3d.up.fill")
            }
            Button { voice.stopAll(); showAgents = true } label: {
                Label("Saved helpers", systemImage: "person.crop.rectangle.stack.fill")
            }
            Button { voice.stopAll(); showReports = true } label: {
                Label("Reports", systemImage: "doc.text.magnifyingglass")
            }
            Button { voice.stopAll(); showMemory = true } label: {
                Label("Memory", systemImage: "brain.head.profile")
            }
            Button { voice.stopAll(); showTrust = true } label: {
                Label("Permissions", systemImage: "lock.shield.fill")
            }
            Button { voice.stopAll(); KairosShowUI.start(.standard) } label: {
                Label("Present Kairos", systemImage: "play.rectangle.fill")
            }
            Menu {
                Button { voice.stopAll(); showSelfTest = true } label: {
                    Label("Run self-test (dry run)", systemImage: "checklist")
                }
            } label: {
                Label("Developer", systemImage: "hammer")
            }
        } label: {
            Text("More")
                .font(AgentUIStyle.font(18, .semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
                .background(.white, in: Capsule())
                .foregroundStyle(AgentUIStyle.green)
        }
        .accessibilityHint("The Agents board, saved helpers, reports, memory, permissions, and Present Kairos")
    }

    /// Full sentence on an empty screen; one short line once the conversation needs the room.
    private var keyBanner: some View {
        let compact = !agent.lines.isEmpty
        return Button { showSettings = true } label: {
            HStack(alignment: compact ? .center : .top, spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: compact ? 20 : 24, weight: .semibold))
                    .foregroundStyle(AgentUIStyle.amber)
                if compact {
                    Text(AgentSettings.brain == .gemini ? "No Gemini key yet" : "Not joined to your Mac yet")
                        .font(AgentUIStyle.font(19, .medium))
                        .foregroundStyle(AgentUIStyle.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 4)
                    Text("Open settings")
                        .font(AgentUIStyle.font(19, .bold))
                        .foregroundStyle(AgentUIStyle.green)
                        .lineLimit(1)
                        .fixedSize()
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AgentSettings.brain == .gemini
                             ? "Add a Gemini key to turn on thinking. Alarms, timers and calls work without it."
                             : "Join your Mac to turn on thinking (its open model, no key). Alarms, timers and calls work without it.")
                            .font(AgentUIStyle.font(19, .medium))
                            .foregroundStyle(AgentUIStyle.ink)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Open settings")
                            .font(AgentUIStyle.font(19, .bold))
                            .foregroundStyle(AgentUIStyle.green)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(compact ? 12 : 14)
            .background(AgentUIStyle.amberBack, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens Kairos settings")
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if agent.lines.isEmpty && !agent.working { examples }
                    ForEach(agent.lines) { line in
                        lineView(line).id(line.id)
                    }
                    if agent.working { workingRow.id("working") }
                }
                .padding(.vertical, 6)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: agent.lines.count) { _, _ in
                guard let last = agent.lines.last?.id else { return }
                withAnimation { proxy.scrollTo(last, anchor: .bottom) }
            }
            .onChange(of: agent.workingOn) { _, _ in
                if agent.working { withAnimation { proxy.scrollTo("working", anchor: .bottom) } }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var examples: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("You can say things like:")
                .font(AgentUIStyle.font(20, .semibold))
                .foregroundStyle(AgentUIStyle.soft)
            ForEach(["“Create an agent to find the paper Attention Is All You Need and tell me what it found.”",
                     "“Set an alarm for 7 tomorrow morning.”",
                     "“Remind me to take my tablets at 8 tonight.”",
                     "“Call my daughter.”",
                     "“Is this message a scam?”"], id: \.self) { example in
                Text(example)
                    .font(AgentUIStyle.font(22, .medium))
                    .foregroundStyle(AgentUIStyle.ink)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func lineView(_ line: AgentLine) -> some View {
        switch line.kind {
        case .person:
            HStack {
                Spacer(minLength: 40)
                Text(line.text)
                    .font(AgentUIStyle.font(22))
                    .foregroundStyle(AgentUIStyle.ink)
                    .padding(14)
                    .background(AgentUIStyle.personBubble, in: RoundedRectangle(cornerRadius: 18))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You said: \(line.text)")
        case .kairos:
            HStack {
                Text(line.text)
                    .font(AgentUIStyle.font(22))
                    .foregroundStyle(AgentUIStyle.ink)
                    .padding(14)
                    .background(.white, in: RoundedRectangle(cornerRadius: 18))
                Spacer(minLength: 40)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Kairos said: \(line.text)")
        case .done, .failed, .refused:
            helperCard(line)
        }
    }

    /// What a helper did: its icon and name, the action, and a tick or a cross.
    private func helperCard(_ line: AgentLine) -> some View {
        let done = line.kind == .done
        let colour = done ? AgentUIStyle.green : (line.kind == .refused ? AgentUIStyle.amber : AgentUIStyle.red)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: line.icon ?? "gearshape.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(AgentUIStyle.green)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.helper ?? "Helper")
                    .font(AgentUIStyle.font(17, .semibold))
                    .foregroundStyle(AgentUIStyle.soft)
                Text(line.text)
                    .font(AgentUIStyle.font(20, .medium))
                    .foregroundStyle(AgentUIStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(done ? "✓" : "✗")
                .font(AgentUIStyle.font(28, .bold))
                .foregroundStyle(colour)
        }
        .padding(12)
        .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(colour.opacity(0.35), lineWidth: 1.5))
        .padding(.horizontal, 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(line.helper ?? "Helper"): \(line.text). \(done ? "Done." : "Not done.")")
    }

    private var workingRow: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .tint(AgentUIStyle.green)
            Text(agent.workingOn.map { $0.hasSuffix("…") ? $0 : $0 + "…" } ?? "Thinking…")
                .font(AgentUIStyle.font(20, .medium))
                .foregroundStyle(AgentUIStyle.soft)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .padding(.horizontal, 14)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: - Talking

    @ViewBuilder
    private var statusLine: some View {
        if voice.isListening {
            Text(voice.liveWords.isEmpty ? "I'm listening…" : "“\(voice.liveWords)”")
                .font(AgentUIStyle.font(24, .semibold))
                .foregroundStyle(AgentUIStyle.ink)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(.white, in: RoundedRectangle(cornerRadius: 18))
                .accessibilityAddTraits(.updatesFrequently)
        } else if let statusWords {
            Text(statusWords)
                .font(AgentUIStyle.font(22, .semibold))
                .foregroundStyle(voice.notice != nil && !thinking && !voice.isSpeaking ? AgentUIStyle.amber : AgentUIStyle.soft)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    /// Nil when there's nothing new to say (the conversation needs the room more than a reminder of the button).
    private var statusWords: String? {
        if voice.isSpeaking { return "Kairos is talking." }
        if thinking { return "Just a moment…" }
        if let notice = voice.notice { return notice }
        return agent.lines.isEmpty ? "Tap the big button and talk." : nil
    }

    private var micButton: some View {
        let size: CGFloat = typing ? 116 : (agent.lines.isEmpty ? 172 : 150)
        return Button { voice.micTapped() } label: {
            ZStack {
                if voice.isListening {
                    Circle()
                        .strokeBorder(AgentUIStyle.green.opacity(0.3), lineWidth: 12)
                        .frame(width: size + 28, height: size + 28)
                }
                Circle()
                    .fill(micColour)
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                    .frame(width: size, height: size)
                VStack(spacing: 6) {
                    Image(systemName: micIcon)
                        .font(.system(size: typing ? 38 : 56, weight: .bold))
                        .symbolEffect(.variableColor.iterative, isActive: voice.isListening || voice.isSpeaking)
                    Text(micLabel)
                        .font(AgentUIStyle.font(typing ? 22 : 28, .bold))
                }
                .foregroundStyle(.white)
            }
            .frame(width: size + 28, height: size + 28)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(thinking && !voice.isSpeaking)
        .accessibilityLabel(micAccessibility)
    }

    private var micColour: Color {
        if voice.isSpeaking { return AgentUIStyle.orange }
        if thinking { return AgentUIStyle.green.opacity(0.5) }
        return AgentUIStyle.green
    }

    private var micIcon: String {
        if voice.isListening { return "waveform" }
        if voice.isSpeaking { return "speaker.wave.3.fill" }
        if thinking { return "hourglass" }
        return "mic.fill"
    }

    private var micLabel: String {
        if voice.isListening { return "Stop" }
        if thinking && !voice.isSpeaking { return "Wait" }
        return "Talk"
    }

    private var micAccessibility: String {
        if voice.isListening { return "Stop listening and send what I said" }
        if voice.isSpeaking { return "Stop Kairos talking" }
        if thinking { return "Kairos is thinking" }
        return "Talk to Kairos"
    }

    // MARK: - Letter and typing

    private var letterButton: some View {
        Button { PhotoStore.shared.clearPending(); openCamera(.camera) } label: {
            Label("Read a letter", systemImage: "doc.text.viewfinder")
                .font(AgentUIStyle.font(26, .bold))
                .frame(maxWidth: .infinity, minHeight: 76)
                .background(.white, in: RoundedRectangle(cornerRadius: 22))
                .foregroundStyle(AgentUIStyle.green)
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(thinking)
        .opacity(thinking ? 0.5 : 1)
        .accessibilityHint("Take a photo of a letter or bill, and Kairos tells you what it says")
    }

    private var secondaryRow: some View {
        HStack(spacing: 12) {
            Button {
                typing.toggle()
                typeFocused = typing
            } label: {
                Label(typing ? "Hide typing" : "Type instead", systemImage: "keyboard")
                    .font(AgentUIStyle.font(19, .bold))
                    .padding(.horizontal, 8)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(.white, in: RoundedRectangle(cornerRadius: 18))
                    .foregroundStyle(AgentUIStyle.green)
            }
            .buttonStyle(.plain)

            Button { PhotoStore.shared.clearPending(); openCamera(.library) } label: {
                Label("Choose a photo", systemImage: "photo.on.rectangle")
                    .font(AgentUIStyle.font(19, .bold))
                    .padding(.horizontal, 8)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(.white, in: RoundedRectangle(cornerRadius: 18))
                    .foregroundStyle(AgentUIStyle.green)
            }
            .buttonStyle(.plain)
            .disabled(thinking)
            .opacity(thinking ? 0.5 : 1)
            .accessibilityHint("Pick a photo of a letter you already took")
        }
    }

    private var typeBox: some View {
        HStack(spacing: 10) {
            TextField("Type here", text: $typed)
                .font(AgentUIStyle.font(24))
                .foregroundStyle(AgentUIStyle.ink)
                .padding(14)
                .background(.white, in: RoundedRectangle(cornerRadius: 16))
                .focused($typeFocused)
                .submitLabel(.send)
                .onSubmit(sendTyped)
            Button(action: sendTyped) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 52, weight: .bold))
                    .foregroundStyle(AgentUIStyle.green)
            }
            .buttonStyle(.plain)
            .disabled(typedWords.isEmpty || thinking)
            .opacity(typedWords.isEmpty || thinking ? 0.4 : 1)
            .accessibilityLabel("Send")
        }
    }

    private var typedWords: String { typed.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: - Actions

    private func sendTyped() {
        let words = typedWords
        guard !words.isEmpty, !thinking else { return }
        typed = ""
        typeFocused = false
        voice.stopAll()
        voice.ask(words)
    }

    private func openCamera(_ source: AgentCamera.Source, forPhoto: Bool = false) {
        cameraForPhoto = forPhoto
        voice.stopAll()
        typeFocused = false
        showSettings = false
        camera = source == .camera && !AgentCamera.hasCamera ? .library : source
    }

    private func newConversation() {
        voice.stopAll()
        voice.notice = nil
        typed = ""
        agent.reset()
    }

    /// A Siri request left waiting for approval runs now that Kairos is on screen.
    private func resumeFromSiri() {
        guard agent.hasStashed else { return }
        Task {
            if let say = await agent.resumeStashed() { voice.speak(say) }
        }
    }
}
