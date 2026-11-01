import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Present mode, entry points on screen.
//
//   PresentButton            a big "Present Kairos" button. Tap = the full show (about 3 minutes).
//                            Touch and hold = Full show (3 min) / Quick pitch (1 min) / Hide this button.
//                            Hidden unless UserDefaults "kairos.show.enabled" is true, so everyday users never see it.
//   .kairosShowUnlock()      put on the "Kairos" title: five quick taps shows or hides the button.
//   KairosShowUI             start/stop helpers shared by the button, the overlay and the Siri intent.
//
// The show itself (what Kairos says, which agents run) is the Presenter's job; this file only starts and stops it.

/// Shared helpers and look for present mode.
@MainActor
enum KairosShowUI {
    /// UserDefaults key that shows the Present button. Also settable as an Xcode launch argument:
    /// `-kairos.show.enabled YES`.
    static let enabledKey = "kairos.show.enabled"

    /// The overlay assumes `Presenter.step` is the 0-based index of the step on screen (0..<total).
    /// If the Presenter counts from 1 (step = i + 1), set this to true. Only the dots and "3 of 7" change.
    static let stepIsOneBased = false

    /// The card shows the line being spoken as a subtitle (for a noisy hall, or a projector with a weak speaker).
    static let showsSubtitles = true

    // Kairos colours (ContentView).
    static let paper = Color(red: 0.96, green: 0.95, blue: 0.92)
    static let green = Color(red: 0.18, green: 0.44, blue: 0.37)
    static let ink = Color(red: 0.11, green: 0.11, blue: 0.10)
    static let stopRed = Color(red: 0.74, green: 0.15, blue: 0.13)
    static let quiet = Color(red: 0.85, green: 0.85, blue: 0.82)

    /// Stops a second start sneaking in before the Presenter has switched to .running (a double tap, Siri + tap).
    private static var launching = false

    static func isRunning(_ state: Presenter.State) -> Bool {
        if case .running = state { return true }
        return false
    }

    static var isShowing: Bool { isRunning(Presenter.shared.state) }

    /// Starts a show unless one is already on. Returns at once; the show runs on the main actor.
    static func start(_ script: ShowScript) {
        guard !launching, !isShowing else { return }
        launching = true
        haptic(.medium)
        Task { @MainActor in
            await Presenter.shared.run(script: script)
        }
        // Only guards the moment before the Presenter says .running; never blocks a later restart.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            launching = false
        }
    }

    /// True from "Hey Siri, present Kairos" until the show has been started (at most ~6 s). The app's voice
    /// auto-start can check it (with `isShowing`) so the ElevenLabs call doesn't open the mic over the show.
    private(set) static var launchPending = false

    /// For Siri: the intent can run before the app is on screen (cold launch). Wait until Kairos is active and the
    /// main screen has drawn, then start.
    static func startWhenReady(_ script: ShowScript) {
        launchPending = true
        Task { @MainActor in
            defer { launchPending = false }
            #if canImport(UIKit)
            let deadline = Date().addingTimeInterval(5)
            while UIApplication.shared.applicationState != .active, Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            #endif
            try? await Task.sleep(nanoseconds: 700_000_000)
            start(script)
        }
    }

    static func stop() {
        haptic(.heavy)
        Task { @MainActor in await Presenter.shared.stop() }
    }

    static func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: style).impactOccurred()
        #endif
    }

    static func announce(_ text: String) {
        #if canImport(UIKit)
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: text)
        #endif
    }
}

/// The big "Present Kairos" button. Drop it into ContentView's VStack under "Write for me".
struct PresentButton: View {
    @ObservedObject private var presenter = Presenter.shared
    @AppStorage(KairosShowUI.enabledKey) private var enabled = false

    private var running: Bool { KairosShowUI.isRunning(presenter.state) }

    var body: some View {
        // Always visible while a show is on, so it can be stopped even if someone hid the button mid-show.
        if enabled || running {
            Button {
                if running { KairosShowUI.stop() } else { KairosShowUI.start(.standard) }
            } label: {
                Label(running ? "Stop presenting" : "Present Kairos",
                      systemImage: running ? "stop.fill" : "play.rectangle.fill")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, minHeight: 76)
                    .background(running ? KairosShowUI.stopRed : KairosShowUI.green,
                                in: RoundedRectangle(cornerRadius: 22))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 22))
            .contextMenu {
                if running {
                    Button("Stop presenting", systemImage: "stop.fill", role: .destructive) { KairosShowUI.stop() }
                } else {
                    Button("Full show (3 min)", systemImage: "play.rectangle.fill") { KairosShowUI.start(.standard) }
                    Button("Quick pitch (1 min)", systemImage: "hare.fill") { KairosShowUI.start(.short) }
                }
                Divider()
                Button("Hide this button", systemImage: "eye.slash") { enabled = false }
            }
            .accessibilityLabel(running ? "Stop the presentation" : "Present Kairos")
            .accessibilityHint(running ? "" : "Kairos introduces itself and shows what its helpers can do. Touch and hold for a one-minute version.")
            .accessibilityAction(named: "Quick pitch, one minute") {
                if !running { KairosShowUI.start(.short) }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }
}

/// Five quick taps on the view (the "Kairos" title) show or hide the Present button.
private struct KairosShowUnlock: ViewModifier {
    @AppStorage(KairosShowUI.enabledKey) private var enabled = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(count: 5) { toggle() }
            .accessibilityAction(named: enabled ? "Hide the Present button" : "Show the Present button") { toggle() }
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: 0.25)) { enabled.toggle() }
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(enabled ? .success : .warning)
        #endif
        KairosShowUI.announce(enabled ? "Present button is on." : "Present button is hidden.")
    }
}

extension View {
    /// Five quick taps show or hide the Present Kairos button. Put it on the "Kairos" title in ContentView.
    func kairosShowUnlock() -> some View { modifier(KairosShowUnlock()) }
}
