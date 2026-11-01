import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Present mode, on screen: while Kairos presents itself, a big card along the bottom says which helper is working
// and what it's doing ("Letter reader — Reading the council-tax letter"), with progress dots and a big red Stop.
// Sized for a projector: 40 pt title, 34 pt line, bold.
//
// While the Letter reader or Scam Shield works, the letter or the text message itself floats at the top of the screen
// (Presenter.currentProp), so the room sees what the helper is reading. The line being spoken shows on the card as a
// subtitle (Presenter.spokenLine), for a noisy hall.
//
// Put it over every screen the show can land on (one line each, all in ContentView). Sheets cover overlays, so
// the agent screen (a sheet) needs its own:
//   ContentView body:  .overlay { PresentationOverlay(compact: session.pendingApproval != nil || session.pendingPayment != nil) }
//   Agents sheet:      .sheet(isPresented: $showAgents) { AgentHomeView(onClose: { showAgents = false }).overlay { PresentationOverlay() } }
// It draws nothing when no show is on, and lets every tap through outside the card. While a Yes/No card is up
// (KairosAgent's confirmation, or `compact` from ContentView), it shrinks to a slim strip at the top so it never
// covers the buttons. When the phone operator is driving another app, Kairos isn't on screen; the card is back,
// on the current step, the moment Kairos is.

struct PresentationOverlay: View {
    /// True while the screen underneath shows its own approval or payment card: the overlay becomes a slim strip
    /// at the top instead of the big bottom card.
    var compact: Bool = false

    @ObservedObject private var presenter = Presenter.shared
    @ObservedObject private var agent = KairosAgent.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// "Over to you" after a show finishes, for a few seconds.
    @State private var showInvite = false
    @State private var inviteToken = UUID()

    private enum Mode: Equatable { case hidden, card, strip, invite }

    private var running: Bool { KairosShowUI.isRunning(presenter.state) }

    private var mode: Mode {
        if running { return (compact || agent.confirmation != nil) ? .strip : .card }
        return showInvite ? .invite : .hidden
    }

    var body: some View {
        ZStack {
            switch mode {
            case .hidden:
                EmptyView()
            case .card:
                VStack(spacing: 10) {
                    if let prop = presenter.currentProp {
                        ShowPropView(prop: prop)
                            .padding(.top, 6)
                            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    }
                    Spacer(minLength: 0)
                    card
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.86),
                           value: presenter.currentProp)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            case .strip:
                strip
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
            case .invite:
                invite
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.86), value: mode)
        .environment(\.colorScheme, .light)
        .onChange(of: presenter.state) { _, state in
            if state == .finished { flashInvite() } else { showInvite = false }
            if state == .stopped { KairosShowUI.announce("Presentation stopped.") }
        }
        .onChange(of: presenter.currentCaption) { _, caption in
            guard let caption, running else { return }
            KairosShowUI.announce("\(caption.agentTitle). \(Self.sentence(caption.doing)).")
        }
    }

    // MARK: - Step maths

    private var total: Int { max(presenter.total, 0) }

    /// 0-based index of the step on screen, clamped so a stray value can never break the dots.
    private var index: Int {
        guard total > 0 else { return 0 }
        let raw = KairosShowUI.stepIsOneBased ? presenter.step - 1 : presenter.step
        return min(max(raw, 0), total - 1)
    }

    private var stepText: String { total > 0 ? "\(index + 1) of \(total)" : "" }

    /// What's on the card: the Presenter's caption, or a "getting ready" line before the first step.
    private var caption: ShowCaption {
        presenter.currentCaption ?? ShowCaption(agentTitle: "Kairos", icon: "sparkles", doing: "getting ready")
    }

    private var captionKey: String { "\(caption.agentTitle)|\(caption.icon)|\(caption.doing)" }

    // MARK: - The big card

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Old and new captions overlap while they swap, so the card never jumps in height mid-animation.
            ZStack(alignment: .topLeading) {
                captionBlock(caption)
                    .id(captionKey)
                    .transition(captionTransition)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.82),
                       value: captionKey)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(caption.agentTitle). \(Self.sentence(caption.doing)).")
            .accessibilityValue(total > 0 ? "Step \(index + 1) of \(total)" : "")
            .accessibilityAddTraits(.updatesFrequently)

            // Subtitles: the line being spoken. Fixed height, so the card doesn't jump as lines come and go.
            if KairosShowUI.showsSubtitles {
                Text(presenter.spokenLine.map { "“\($0)”" } ?? " ")
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .foregroundStyle(KairosShowUI.ink.opacity(0.68))
                    .lineLimit(3)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, minHeight: 54, maxHeight: 78, alignment: .topLeading)
                    .accessibilityHidden(true)   // VoiceOver hears the voice itself
            }

            // What the agent core is really doing right now ("Time helper: Alarm at 07:00"): proof it's live.
            if let live = agent.workingOn, !live.isEmpty {
                Label(live, systemImage: "gearshape.2.fill")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(KairosShowUI.green)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .transition(.opacity)
                    .accessibilityLabel("Working on: \(live)")
            }

            HStack(spacing: 12) {
                if total > 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        ShowProgressDots(index: index, total: total, reduceMotion: reduceMotion)
                        Text(stepText)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(KairosShowUI.ink.opacity(0.6))
                            .contentTransition(.numericText())
                            .accessibilityHidden(true)
                    }
                }
                Spacer(minLength: 8)
                stopButton(big: true)
            }
        }
        .padding(18)
        .background(.white, in: RoundedRectangle(cornerRadius: 30))
        .overlay(RoundedRectangle(cornerRadius: 30).stroke(KairosShowUI.green.opacity(0.25), lineWidth: 2))
        .shadow(color: .black.opacity(0.22), radius: 22, y: 8)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Kairos is presenting")
    }

    private var captionTransition: AnyTransition {
        if reduceMotion { return .opacity }
        // The next helper arrives from the right as the last one leaves to the left.
        return .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                           removal: .move(edge: .leading).combined(with: .opacity))
    }

    private func captionBlock(_ c: ShowCaption) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                badge(c.icon, size: 64)
                Text(c.agentTitle)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(KairosShowUI.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            }
            Text(Self.sentence(c.doing))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(KairosShowUI.ink.opacity(0.78))
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func badge(_ icon: String, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(KairosShowUI.green)
            Image(systemName: Self.symbol(icon))
                .font(.system(size: size * 0.46, weight: .bold))
                .foregroundStyle(.white)
                // Pulses while an agent is really running a tool.
                .symbolEffect(.pulse, isActive: agent.working)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func stopButton(big: Bool) -> some View {
        Button { KairosShowUI.stop() } label: {
            Label("Stop", systemImage: "stop.fill")
                .font(.system(size: big ? 30 : 20, weight: .bold, design: .rounded))
                .lineLimit(1)
                .fixedSize()   // never "■ …": the dots give way instead
                .padding(.horizontal, big ? 22 : 16)
                .frame(minHeight: big ? 68 : 46)
                .background(KairosShowUI.stopRed, in: RoundedRectangle(cornerRadius: big ? 22 : 16))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .layoutPriority(1)
        .accessibilityLabel("Stop the presentation")
    }

    // MARK: - Slim strip (while a Yes/No card is up)

    private var strip: some View {
        HStack(spacing: 10) {
            badge(caption.icon, size: 40)
            VStack(alignment: .leading, spacing: 0) {
                Text("Presenting\(total > 0 ? " · \(stepText)" : "")")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(KairosShowUI.green)
                Text(caption.agentTitle)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(KairosShowUI.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 6)
            stopButton(big: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white, in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Kairos is presenting: \(caption.agentTitle)")
    }

    // MARK: - "Over to you" (after the show)

    private var invite: some View {
        HStack(spacing: 14) {
            badge("mic.fill", size: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text("Over to you")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(KairosShowUI.ink)
                Text("Ask me something you'd like me to do.")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(KairosShowUI.ink.opacity(0.75))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
            Button { showInvite = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 20, weight: .bold))
                    .frame(width: 48, height: 48)
                    .background(KairosShowUI.quiet, in: Circle())
                    .foregroundStyle(KairosShowUI.ink)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(18)
        .background(.white, in: RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(KairosShowUI.green.opacity(0.25), lineWidth: 2))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
    }

    /// Shows "Over to you" for 20 seconds; a newer show or a tap on Close ends it sooner.
    private func flashInvite() {
        showInvite = true
        KairosShowUI.announce("Over to you. Ask me something you'd like me to do.")
        let token = UUID()
        inviteToken = token
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if inviteToken == token { showInvite = false }
        }
    }

    // MARK: - Text helpers

    /// "reading the council-tax letter" → "Reading the council-tax letter".
    static func sentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first else { return t }
        return first.uppercased() + t.dropFirst()
    }

    /// The caption's SF Symbol, or a sparkle if the name is wrong (a blank badge looks broken on a projector).
    static func symbol(_ name: String) -> String {
        #if canImport(UIKit)
        if !name.isEmpty, UIImage(systemName: name) != nil { return name }
        return "sparkles"
        #else
        return name.isEmpty ? "sparkles" : name
        #endif
    }
}

/// The letter or the text message the current step is about, at the top of the screen.
private struct ShowPropView: View {
    let prop: ShowProp

    #if canImport(UIKit)
    /// Decoded once (the letter is drawn on first use, ~0.1 s; the Presenter draws it before the show starts).
    private static let letter: UIImage? = DemoProps.letterImage
    #endif

    var body: some View {
        Group {
            switch prop {
            case .letter: letter
            case .scamText: message
            }
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(prop.title)
    }

    @ViewBuilder private var letter: some View {
        #if canImport(UIKit)
        if let image = Self.letter {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 330)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
                .rotationEffect(.degrees(-2))
        }
        #endif
    }

    private var message: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(DemoProps.scamSender, systemImage: "message.fill")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(KairosShowUI.ink.opacity(0.6))
            Text(prop.text ?? "")
                .font(.system(size: 21, weight: .regular, design: .rounded))
                .foregroundStyle(KairosShowUI.ink)
                .lineLimit(7)
                .minimumScaleFactor(0.7)
                .padding(14)
                .background(Color(red: 0.90, green: 0.90, blue: 0.92), in: RoundedRectangle(cornerRadius: 20))
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
    }
}

/// One dot per step; the current one is a long green pill that slides along as the show moves on.
private struct ShowProgressDots: View {
    let index: Int
    let total: Int
    let reduceMotion: Bool

    var body: some View {
        Group {
            if total <= 14 {
                // Sized so dots + the Stop button fit a 402 pt-wide phone (checked on the simulator), so the
                // 428 pt 12 Pro Max has room to spare.
                let size: CGFloat = total > 10 ? 7 : 9
                HStack(spacing: total > 10 ? 4 : 5) {
                    ForEach(0..<total, id: \.self) { i in
                        Capsule()
                            .fill(i == index ? KairosShowUI.green
                                  : i < index ? KairosShowUI.green.opacity(0.4) : KairosShowUI.quiet)
                            .frame(width: i == index ? size * 2.6 : size, height: size)
                    }
                }
            } else {
                // Too many steps for dots: a bar that fills up.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(KairosShowUI.quiet)
                        Capsule().fill(KairosShowUI.green)
                            .frame(width: geo.size.width * CGFloat(index + 1) / CGFloat(max(total, 1)))
                    }
                }
                .frame(height: 12)
                .frame(width: 170)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.8), value: index)
        .accessibilityHidden(true)
    }
}
