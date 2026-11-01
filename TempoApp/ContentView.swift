import SwiftUI

/// Designed for older users: one huge button, large words, calm colours, nothing to learn.
///
/// ONE Kairos: the big button talks to the on-phone agent (KairosAgent + AgentVoice), the same conversation as
/// "More". What the phone's rules don't know goes to the person's Mac over their private Tailscale network
/// (MeshNode), and the line under the title says plainly whether the Mac can be reached. The old ElevenLabs call
/// through tempo-hub, its Shield badge, Write for me and payment cards show only with TempoSession.legacyVoice.
struct ContentView: View {
    @EnvironmentObject var session: TempoSession
    @State private var showLetter = false
    /// Write for me: speak a message, Kairos drafts it in their language, you check it and send it yourself.
    @State private var showWrite = false
    /// The Guardian on the person's Mac: green, amber or grey, and a sheet with what it stopped (ShieldView.swift).
    @StateObject private var shield = Shield()
    @State private var showShield = false
    /// Kairos on this phone (TempoApp/Agents): typing, photos, helpers and settings. Same conversation.
    @State private var showAgents = false
    @State private var showSettings = false
    @ObservedObject private var agents = KairosAgent.shared
    @ObservedObject private var voice = AgentVoice.shared
    @ObservedObject private var mesh = MeshNode.shared
    @Environment(\.scenePhase) private var scenePhase
    private let legacy = TempoSession.legacyVoice

    private var status: String {
        guard legacy else { return oneStatus }
        switch session.phase {
        case .needsSetup: return "Not connected to your Mac yet."
        case .idle: return "Tap the big button and talk."
        case .connecting: return "Connecting…"
        case .listening: return "I'm listening."
        case .speaking: return "Kairos is talking."
        case .thinking: return "Thinking…"
        case .error(let message): return message
        }
    }

    // MARK: - One Kairos

    private var thinking: Bool { voice.isAsking || agents.working }

    private var oneStatus: String {
        if voice.isListening { return voice.liveWords.isEmpty ? "I'm listening." : voice.liveWords }
        if thinking { return agents.workingOn ?? "Just a moment…" }
        if voice.isSpeaking { return "Kairos is talking." }
        if let notice = voice.notice { return notice }
        return "Tap the big button and talk."
    }

    private var meshOK: Bool {
        switch mesh.status { case .ready, .working: return true; default: return false }
    }

    private var meshText: String {
        switch mesh.status {
        case .ready: return mesh.overTailscale ? "Connected to your Mac · private Tailscale link" : "Connected to your Mac"
        case .notPaired: return "Not joined to your Mac yet. Tap to join."
        default: return mesh.status.line
        }
    }

    private var meshColor: Color {
        switch mesh.status {
        case .ready, .working: return Color(red: 0.18, green: 0.55, blue: 0.37)
        case .offline: return Color(red: 0.85, green: 0.55, blue: 0.10)
        case .connecting, .notPaired: return Color(red: 0.60, green: 0.60, blue: 0.57)
        }
    }

    /// Where the Mac is, in one line. Tap: try again now (or join, when this iPhone hasn't joined yet).
    private var meshChip: some View {
        Button { if mesh.isPaired { mesh.retry() } else { showSettings = true } } label: {   // retry() only acts when offline
            VStack(spacing: 4) {
                HStack(spacing: 10) {
                    Circle().fill(meshColor).frame(width: 14, height: 14)
                    Text(meshText)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = mesh.note {
                    Text(note).font(.system(size: 16, design: .rounded)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else if !meshOK, mesh.isPaired {
                    Text("Alarms, reminders and calls still work.")
                        .font(.system(size: 16, design: .rounded)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.white, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(!mesh.isPaired ? "Opens settings to join your Mac" : (meshOK ? "" : "Tries to reach your Mac again"))
    }

    private func lineText(_ line: AgentLine) -> String {
        switch line.kind {
        case .done: return "✓ " + line.text
        case .failed: return "✗ " + line.text
        case .refused: return "✋ " + line.text
        default: return line.text
        }
    }

    /// Siri "Read a letter" and kairos://letter: the camera only when there is a model that can read the photo.
    static func readLetter() {
        guard AgentSettings.brain == .gemini, AgentSettings.hasKey else {
            let say = "Reading letters needs Gemini for now. Your Mac's open model can't read photos yet."
            AgentVoice.shared.notice = say
            AgentVoice.shared.speak(say)
            return
        }
        KairosAgent.shared.cameraRequested = true
    }

    private var footer: String {
        var text = "Your voice is turned into words on this iPhone."
        if AgentSettings.brain == .gemini {
            text += " What Kairos can't do with its own rules goes to Google (Gemini) with your key."
        } else {
            text += " What Kairos can't do here goes to the open model on your own Mac, over your private Tailscale network."
        }
        return text + " Calls, messages and payments always need your Face ID."
    }

    /// Tap to talk; it stops by itself after a short quiet, or tap again to send. A tap while Kairos talks stops it.
    private var talkButton: some View {
        Button { if voice.isSpeaking { voice.stopSpeaking() } else { voice.micTapped() } } label: {
            ZStack {
                Circle()
                    .fill(voice.isSpeaking ? Color(red: 0.76, green: 0.40, blue: 0.18) : Color(red: 0.18, green: 0.44, blue: 0.37))
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                VStack(spacing: 8) {
                    Image(systemName: thinking ? "hourglass" : (voice.isListening ? "arrow.up.circle.fill"
                                                                : (voice.isSpeaking ? "stop.fill" : "mic.fill")))
                        .font(.system(size: 64, weight: .bold))
                    Text(thinking ? "Thinking" : (voice.isListening ? "Send" : (voice.isSpeaking ? "Stop" : "Talk")))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
            }
            .frame(width: 250, height: 250)
            .scaleEffect(voice.isListening ? 1.03 : 1.0)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: voice.isListening)
        }
        .disabled(thinking)
        .accessibilityLabel(voice.isListening ? "Send what you said to Kairos"
                            : (voice.isSpeaking ? "Stop Kairos talking" : "Talk to Kairos"))
    }

    /// The old ElevenLabs call (TempoSession.legacyVoice only).
    private var legacyTalkButton: some View {
        Button {
            if inCall { Task { await session.stop() } } else { session.startIfIdle() }
        } label: {
            ZStack {
                Circle()
                    .fill(session.phase == .speaking ? Color(red: 0.76, green: 0.40, blue: 0.18)
                                                     : Color(red: 0.18, green: 0.44, blue: 0.37))
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                VStack(spacing: 8) {
                    Image(systemName: inCall ? "stop.fill" : "mic.fill")
                        .font(.system(size: 64, weight: .bold))
                    Text(inCall ? "Stop" : "Talk")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
            }
            .frame(width: 250, height: 250)
            .scaleEffect(session.phase == .listening ? 1.03 : 1.0)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: session.phase == .listening)
        }
        .disabled(session.phase == .needsSetup)
        .accessibilityLabel(inCall ? "Stop talking to Kairos" : "Talk to Kairos")
    }

    /// The only way a risky action happens: the user reads it and taps a giant Yes.
    private func approvalCard(_ task: String) -> some View {
        VStack(spacing: 18) {
            Text("Kairos wants to:")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
            Text(task)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Button { Task { await session.decide(approve: false) } } label: {
                    Text("No").font(.system(size: 30, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity, minHeight: 90)
                        .background(Color(red: 0.85, green: 0.85, blue: 0.82), in: RoundedRectangle(cornerRadius: 22))
                        .foregroundStyle(.black)
                }
                Button { Task { await session.decide(approve: true) } } label: {
                    Text("Yes, do it").font(.system(size: 30, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity, minHeight: 90)
                        .background(Color(red: 0.18, green: 0.44, blue: 0.37), in: RoundedRectangle(cornerRadius: 22))
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(24)
        .background(.white, in: RoundedRectangle(cornerRadius: 28))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        .padding(18)
        .accessibilityElement(children: .contain)
    }

    /// A payment the Navigator filled in and checked on the bank's own screen. Big, plain, nothing to interpret.
    private func paymentCard(_ p: TempoSession.PaymentView) -> some View {
        VStack(spacing: 12) {
            Label("Kairos checked your bank's screen", systemImage: "checkmark.shield.fill")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.18, green: 0.44, blue: 0.37))
            Text(p.amount ?? "")
                .font(.system(size: 48, weight: .bold, design: .rounded))
            Text("to \(p.cop_name ?? p.payee ?? "")")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
            if let acct = p.account, !acct.isEmpty {
                Text(acct).font(.system(size: 20, design: .rounded)).foregroundStyle(.secondary)
            }
            if let ref = p.reference, !ref.isEmpty {
                Text("Reference: \(ref)").font(.system(size: 20, design: .rounded)).foregroundStyle(.secondary)
            }
            Text("The name on the bank's screen matches \(p.payee ?? "your payee book").")
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
            if p.extra_confirm == true {
                Text("This is unusual for you. Please read it twice.")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.6, green: 0.35, blue: 0.0))
            }
            Text("Approve within \(session.approvalSecondsLeft) s, or nothing is sent.")
                .font(.system(size: 17, design: .rounded)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
            HStack(spacing: 16) {
                Button { Task { await session.decide(approve: false) } } label: {
                    Text("No").font(.system(size: 30, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity, minHeight: 84)
                        .background(Color(red: 0.85, green: 0.85, blue: 0.82), in: RoundedRectangle(cornerRadius: 22))
                        .foregroundStyle(.black)
                }
                Button { Task { await session.decide(approve: true) } } label: {
                    Text("Yes, send it").font(.system(size: 28, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity, minHeight: 84)
                        .background(Color(red: 0.18, green: 0.44, blue: 0.37), in: RoundedRectangle(cornerRadius: 22))
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(22)
        .background(.white, in: RoundedRectangle(cornerRadius: 28))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        .padding(16)
        .accessibilityElement(children: .contain)
    }

    private var inCall: Bool {
        [.listening, .speaking, .thinking, .connecting].contains(session.phase)
    }

    var body: some View {
        ZStack {
            Color(red: 0.96, green: 0.95, blue: 0.92).ignoresSafeArea()
            if legacy, let payment = session.pendingPayment {
                paymentCard(payment).zIndex(2)
            } else if legacy, let pending = session.pendingApproval {
                approvalCard(pending.task).zIndex(2)
            }
            if !showAgents, let card = agents.confirmation {
                AgentConfirmCard(card: card).zIndex(3)
            }
            VStack(spacing: 22) {
                Text("Kairos")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.11, green: 0.11, blue: 0.10))
                    .padding(.top, 12)
                    .kairosShowUnlock()   // five taps show the Present button (Present mode)

                if !legacy {
                    meshChip
                } else if session.phase != .needsSetup {
                    Button { showShield = true } label: { ShieldBadge(shield: shield) }
                        .buttonStyle(.plain)
                }

                Text(status)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color(red: 0.25, green: 0.25, blue: 0.23))
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.updatesFrequently)

                if legacy { legacyTalkButton } else { talkButton }

                // The letter reader: photograph a letter, bill or form; Kairos explains it in the person's language.
                // It needs a model that can see; the Mac's open model can't read photos yet.
                if legacy || AgentSettings.brain == .gemini {
                    Button { if legacy { showLetter = true } else { agents.cameraRequested = true } } label: {
                        Label("Read a letter", systemImage: "doc.text.viewfinder")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity, minHeight: 76)
                            .background(.white, in: RoundedRectangle(cornerRadius: 22))
                            .foregroundStyle(Color(red: 0.18, green: 0.44, blue: 0.37))
                            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
                    }
                    .disabled(legacy && session.phase == .needsSetup)
                    .accessibilityHint("Take a photo of a letter or bill and Kairos explains what it says")
                }

                if legacy {
                    Button { showWrite = true } label: {
                        Label("Write for me", systemImage: "square.and.pencil")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity, minHeight: 76)
                            .background(.white, in: RoundedRectangle(cornerRadius: 22))
                            .foregroundStyle(Color(red: 0.18, green: 0.44, blue: 0.37))
                            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
                    }
                    // During a call, say "write a message to Amma" instead: the card comes up in the call.
                    .disabled(session.phase == .needsSetup || inCall)
                    .accessibilityHint("Say a message for someone. Kairos writes it in their language, and you check it before sending")
                }

                PresentButton()   // draws nothing unless Present mode is unlocked or a show is running

                // The same Kairos with a keyboard, the camera, the helpers and settings.
                Button { showAgents = true } label: {
                    Label(legacy ? "Kairos on this phone" : "More: type, photos, helpers",
                          systemImage: legacy ? "iphone.gen3" : "ellipsis.circle")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity, minHeight: 76)
                        .background(.white, in: RoundedRectangle(cornerRadius: 22))
                        .foregroundStyle(Color(red: 0.18, green: 0.44, blue: 0.37))
                        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
                }
                .accessibilityHint("Opens the same conversation with a keyboard, the camera, Kairos's helpers and settings")

                if legacy, session.helperWorking || !session.helperSteps.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(session.helperWorking ? "Your helpers are working" : "Your helpers finished",
                              systemImage: session.helperWorking ? "gearshape.2.fill" : "checkmark.circle.fill")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                        ForEach(session.helperSteps, id: \.self) { step in
                            Text("• " + step).font(.system(size: 18, design: .rounded))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if legacy {
                            ForEach(session.lines) { line in
                                Text(line.text)
                                    .font(.system(size: 22, design: .rounded))
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: line.fromTempo ? .leading : .trailing)
                                    .background(line.fromTempo ? Color.white : Color(red: 0.88, green: 0.93, blue: 0.91),
                                                in: RoundedRectangle(cornerRadius: 14))
                            }
                        } else {
                            ForEach(agents.lines.suffix(4)) { line in
                                Text(lineText(line))
                                    .font(.system(size: 22, design: .rounded))
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: line.kind == .person ? .trailing : .leading)
                                    .background(line.kind == .person ? Color(red: 0.88, green: 0.93, blue: 0.91) : Color.white,
                                                in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                    }
                }

                Text(legacy
                     ? "Your voice and Kairos's replies go through ElevenLabs and Google (Gemini). Photos of letters and messages you write go to Gemini or ElevenLabs through your Kairos server. Phone numbers stay on this phone."
                     : footer)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showLetter) { LetterView().environmentObject(session) }
        .sheet(isPresented: $showShield) { ShieldView(shield: shield) }
        .sheet(isPresented: $showWrite) {
            WriteForMeView(api: session.bridge.api, endCall: { await session.stop() }, onClose: { showWrite = false })
                .environmentObject(session.bridge.people)
        }
        .modifier(InCallBridgePresenter(bridge: session.bridge, endCall: { await session.stop() },
                                        askKairosToRead: { session.readExactly($0) }))
        // A drafted message must be seen: close any other sheet so the card can appear (one sheet at a time).
        .onReceive(session.bridge.$showCard) { on in
            if on { showLetter = false; showWrite = false; showShield = false }
        }
        .sheet(isPresented: $showAgents) { AgentHomeView(onClose: { showAgents = false }).overlay { PresentationOverlay() } }
        .sheet(isPresented: $showSettings) { AgentSettingsView() }
        // A kairos://mesh link (the QR on the Mac) never joins by itself: the person says yes, naming the Mac.
        .alert("Join your Mac?", isPresented: Binding(get: { mesh.pendingLink != nil },
                                                     set: { if !$0 { mesh.cancelLink() } }),
               presenting: mesh.pendingLink) { link in
            // The link is captured here: the alert clears pendingLink before the task runs.
            Button("Join") { Task { await mesh.confirmLink(link) } }
            Button("Not now", role: .cancel) { mesh.cancelLink() }
        } message: { link in
            Text("Kairos on this iPhone will share one conversation with \(link.host). Kairos checks it is on your private Tailscale network and asks for Face ID. That Mac can then ask this iPhone for help while Kairos is open; calls, messages and payments still need your Face ID here.")
        }
        // The alert can't show over a sheet: close them when a pairing link arrives.
        .onChange(of: mesh.pendingLink?.id) { _, id in
            if id != nil { showLetter = false; showWrite = false; showShield = false; showSettings = false; showAgents = false }
        }
        .onAppear {
            if legacy { shield.start() }
            AgentAppHooks.connect(session)
            KairosShowHost.shared.openAgentScreen = {   // Present mode runs on the agent screen: one sheet at a time
                guard !showAgents else { return }
                let otherOpen = showLetter || showWrite || showShield || showSettings
                showLetter = false; showWrite = false; showShield = false; showSettings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + (otherOpen ? 0.6 : 0)) { showAgents = true }
            }
            if KairosAgentLaunch.consume() || StudioLaunch.consume() { showAgents = true }  // Siri opened Kairos before this view listened
        }
        .onDisappear { shield.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .tempoLetter)) { _ in
            if legacy { showLetter = true } else { Self.readLetter() }
        }
        // Siri ("Ask Kairos", "Open Kairos helpers") or a kairos://agent link: one sheet at a time.
        .onReceive(NotificationCenter.default.publisher(for: .kairosAgentOpen)) { _ in
            KairosAgentLaunch.consume()
            guard !showAgents else { return }
            let otherOpen = showLetter || showWrite || showShield || showSettings
            showLetter = false; showWrite = false; showShield = false; showSettings = false
            DispatchQueue.main.asyncAfter(deadline: .now() + (otherOpen ? 0.6 : 0)) { showAgents = true }
        }
        // A Siri request is waiting for the person's Yes: bring the helpers' screen up to show the card.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, KairosAgent.shared.hasStashed, !showAgents { showAgents = true }
        }
        // "Take a pic" from the voice call: the camera lives on the helpers' screen, so bring it up.
        .onChange(of: agents.cameraRequested) { _, wanted in
            if wanted, !showAgents {
                let otherOpen = showLetter || showWrite || showShield || showSettings
                showLetter = false; showWrite = false; showShield = false; showSettings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + (otherOpen ? 0.6 : 0)) { showAgents = true }
            }
        }
        // A Yes/No card must be seen: close the other sheets that would hide it.
        .onChange(of: agents.confirmation?.id) { _, id in
            if id != nil, !showAgents { showLetter = false; showWrite = false; showShield = false; showSettings = false }
        }
        // Shared context: once a voice call is live, the ElevenLabs voice hears what the agents on the phone do.
        .onChange(of: session.phase) { _, phase in
            switch phase {
            case .listening, .speaking, .thinking: VoiceContextBridge.shared.attach(session)
            case .idle, .needsSetup, .error: VoiceContextBridge.shared.detach()
            case .connecting: break
            }
        }
        .overlay { PresentationOverlay(compact: session.pendingApproval != nil || session.pendingPayment != nil) }
    }
}
