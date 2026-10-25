import Foundation

/// The few places the rest of the app touches the on-phone agents. The app's shared files (TempoApp.swift,
/// ContentView.swift) call these, so their edits stay one line each.
@MainActor
enum AgentAppHooks {
    /// True while "Kairos on this phone" is on screen. The ElevenLabs call must not start by itself then.
    static var screenShowing = false

    private static let askedKey = "kairos.agents.askedPermissionsUpFront"

    /// Whether the app may start the ElevenLabs voice call on its own right now (it would take the microphone
    /// away from the on-phone screen, or start talking over a card Siri left waiting).
    static var allowsVoiceAutoStart: Bool {
        !screenShowing && !AgentVoice.shared.isBusy && !KairosAgent.shared.hasStashed && !KairosAgentLaunch.wanted
            && !KairosShowUI.isShowing && !KairosShowUI.launchPending   // Present mode: a new call would talk over the show
            && !KairosSelfTest.requestedAtLaunch && !KairosSelfTestProgress.shared.running  // the self-test is quiet
    }

    /// kairos://agent (open the screen) and the Shortcuts return links (kairos://agent/shortcut-done …).
    /// Returns true when the link was for the agents; TempoSession ignores host "agent" anyway.
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard url.scheme == "kairos" || url.scheme == "tempo", url.host == "agent" else { return false }
        if let back = HelpersShortcuts.callback(url) {
            if let output = back.output {
                // A Shortcut's output is untrusted text: it goes in as .automation, never as the person's words.
                Task {
                    let outcome = await KairosAgent.shared.handle(output, source: .automation)
                    AgentVoice.shared.speak(outcome.say)
                }
            } else {
                KairosAgent.shared.note(back.say)
                AgentVoice.shared.speak(back.say)
            }
        }
        KairosAgentLaunch.request()
        return true
    }

    /// Stop the two voices fighting over the microphone. Call once where the TempoSession is in scope.
    static func connect(_ session: TempoSession) {
        _ = KairosAgent.shared   // registers AgentHooks.runner for Routines, the Phone operator, Studio and Present mode
        // Worker agents: Kairos's picture of the phone, the voice hearing when one finishes, the board's voice.
        WorkerWiring.install()
        // Launched with -KairosSelfTest: run the routing self-test (dry run) once the first screen is up.
        KairosSelfTest.presentIfLaunchedForIt()
        // Siri learns new routine and helper names.
        RoutineSiri.keepUpToDate { TempoShortcuts.updateAppShortcutParameters() }
        AgentLibrary.didChange = { TempoShortcuts.updateAppShortcutParameters() }
        // Present mode speaks through the live ElevenLabs call when there is one.
        if !(Presenter.shared.live is TempoVoiceBridge) { Presenter.shared.live = TempoVoiceBridge(session: session) }
        let host = KairosShowHost.shared
        host.startAgentMic = { AgentVoice.shared.micTapped() }
        host.bringToFront = { (try? await ICTRLHands.shared.activateApp(bundleID: Bundle.main.bundleIdentifier ?? "")) != nil }
        host.prepare = { [weak session] in
            // ElevenLabs explains the show (#10): start the call first if it isn't on, and let its greeting finish.
            // A call that can't connect in time is closed again, so the phone's own voice and mic work.
            if ShowSettings.voiceMode != "device", let session, !session.isInCall {
                session.startIfIdle()
                let end = Date().addingTimeInterval(15)
                var spoke = false
                while Date() < end {
                    if session.phase == .speaking { spoke = true }
                    if session.isInCall, spoke, session.phase == .listening { break }
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
                if !session.isInCall { await session.stop() }
            }
            // A clean stage: no helper in charge, last rehearsal's Judge Helper and "judge mode" routine gone.
            AgentLibrary.shared.focused = nil
            if let old = AgentLibrary.shared.spec(named: "Judge Helper", exact: true) { AgentLibrary.shared.delete(id: old.id) }
            if let r = RoutineStore.shared.all.first(where: { $0.name.folded == "judge mode" }) {
                _ = try? await RoutineStore.shared.delete(id: r.id)
            }
            KairosAgent.shared.reset()
        }
        AgentVoice.shared.otherCallActive = { [weak session] in
            if Presenter.shared.isPresenting { return true }   // the show is talking: the screen's own voice stays quiet
            guard let session else { return false }
            switch session.phase {
            case .listening, .speaking, .thinking, .connecting: return true
            default: return false
            }
        }
    }

    /// The agent screen appeared. The first time, ask for Reminders, Calendar, Alarms and Contacts one after
    /// another while Kairos is in front: Siri in the background can't show these prompts. Listening permission
    /// is asked the first time the person taps the microphone.
    static func screenAppeared() {
        screenShowing = true
        if PeopleAccess.current.canRead { PeopleDirectory.shared.warmUp() }
        guard !UserDefaults.standard.bool(forKey: askedKey) else { return }
        UserDefaults.standard.set(true, forKey: askedKey)
        Task {
            await PlannerAgent.askPermissionsUpFront()
            if PeopleAccess.current == .notAsked { _ = await PeopleAccess.request() }
        }
    }

    static func screenDisappeared() { screenShowing = false }
}
