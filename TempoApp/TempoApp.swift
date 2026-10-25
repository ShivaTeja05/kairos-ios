import AppIntents
import SwiftUI

// Kairos for iPhone (the assistant formerly called Tempo; internals keep the tempo name): one big button, voice first. ElevenLabs live voice in front; the user's own Mac
// (local model + Tempo hub + phone/laptop agents) behind it. Opened by Siri ("Talk to Kairos"), Back Tap
// (Settings > Accessibility > Touch > Back Tap > Talk to Kairos), the Home Screen, or kairos://talk.

extension Notification.Name {
    static let tempoStart = Notification.Name("tempo.start")
    static let tempoLetter = Notification.Name("tempo.letter")
}

@main
struct TempoMain: App {
    @StateObject private var session = TempoSession()
    @Environment(\.scenePhase) private var phase

    init() {
        VoiceClipRecorder.removeLeftoverClips()   // a crash mid-recording must not leave a voice clip on disk
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
                .onOpenURL { url in AgentAppHooks.handle(url); session.handle(url: url) }
                .onReceive(NotificationCenter.default.publisher(for: .tempoStart)) { _ in session.startIfIdle() }
                // The on-phone helpers' screen is opening (Siri, kairos://agent): end a voice call so the mic is free.
                .onReceive(NotificationCenter.default.publisher(for: .kairosAgentOpen)) { _ in
                    if [.connecting, .listening, .speaking, .thinking].contains(session.phase) { Task { await session.stop() } }
                }
                .onChange(of: phase) { _, newPhase in
                    // Opening Kairos means "I want to talk": start listening straight away (older users),
                    // unless the on-phone helpers' screen has the mic or a Siri request is waiting there.
                    if newPhase == .active {
                        if AgentAppHooks.allowsVoiceAutoStart { session.startIfIdle(auto: true) }
                        session.startLocalWatch()
                    }
                    if newPhase == .background { session.stopLocalWatch() }
                }
        }
    }
}

/// "Hey Siri, talk to Kairos" and the Back Tap / Action menu entry.
struct TalkToTempo: AppIntent {
    static let title: LocalizedStringResource = "Talk to Kairos"
    static let description = IntentDescription("Open Kairos and start talking.")
    static let openAppWhenRun = true
    /// From a locked phone, only the owner (Face ID / passcode) can open Kairos by voice.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .tempoStart, object: nil)
        return .result()
    }
}

/// "Hey Siri, read a letter with Kairos": opens the camera screen straight away.
struct ReadLetterIntent: AppIntent {
    static let title: LocalizedStringResource = "Read a letter with Kairos"
    static let description = IntentDescription("Photograph a letter, bill or form and have Kairos explain it in your language.")
    static let openAppWhenRun = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .tempoLetter, object: nil)
        return .result()
    }
}

struct TempoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TalkToTempo(),
                    phrases: ["Talk to \(.applicationName)", "Start \(.applicationName)",
                              "Open \(.applicationName)", "Hey \(.applicationName)"],
                    shortTitle: "Talk to Kairos",
                    systemImageName: "waveform.circle.fill")
        AppShortcut(intent: ReadLetterIntent(),
                    phrases: ["Read a letter with \(.applicationName)", "Read this letter with \(.applicationName)",
                              "Explain a letter with \(.applicationName)", "What does this letter say, \(.applicationName)"],
                    shortTitle: "Read a letter",
                    systemImageName: "doc.text.viewfinder")
        // On-phone helpers (TempoApp/Agents/Siri/AgentIntents.swift). Phrases must stay literal here.
        AppShortcut(intent: AskKairosIntent(),
                    phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) something",
                              "\(.applicationName), help me"],
                    shortTitle: "Ask Kairos",
                    systemImageName: "sparkles")
        AppShortcut(intent: OpenKairosAgentIntent(),
                    phrases: ["Open \(.applicationName) helpers", "Show my \(.applicationName) helpers"],
                    shortTitle: "Kairos helpers",
                    systemImageName: "person.2.circle.fill")
        // v2: routines, Agent Studio helpers, Present mode (TempoApp/Agents/Routines, Studio, ShowcaseUI).
        AppShortcut(intent: RunRoutineIntent(),
                    phrases: ["Run \(\.$routine) with \(.applicationName)", "\(\.$routine) with \(.applicationName)",
                              "Do my \(\.$routine) with \(.applicationName)", "Run a routine with \(.applicationName)"],
                    shortTitle: "Run a routine",
                    systemImageName: "repeat.circle.fill")
        AppShortcut(intent: TalkToAgentIntent(),
                    phrases: ["Talk to \(\.$agent) in \(.applicationName)", "Open \(\.$agent) in \(.applicationName)",
                              "Talk to a helper in \(.applicationName)"],
                    shortTitle: "Talk to a helper",
                    systemImageName: "person.crop.rectangle.stack.fill")
        AppShortcut(intent: PresentKairosIntent(),
                    phrases: ["Present \(.applicationName)", "\(.applicationName), introduce yourself",
                              "Show the judges \(.applicationName)"],
                    shortTitle: "Present Kairos",
                    systemImageName: "play.rectangle.fill")
    }
}
