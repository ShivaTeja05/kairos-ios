import SwiftUI
import UIKit
import LocalAuthentication

/// The only way anything that reaches another person happens: Kairos shows what it wants to do in big words,
/// and the person taps a giant Yes (then Face ID) or No. Same look as the app's own approval card.
/// If nobody answers, Kairos treats it as No after 90 seconds.
struct AgentConfirmCard: View {
    let card: PendingConfirmation
    @State private var answered = false
    @State private var ownerCheck: String?

    var body: some View {
        VStack(spacing: 18) {
            Text("Kairos wants to:")
                .font(AgentUIStyle.font(26, .semibold))
                .foregroundStyle(AgentUIStyle.ink)
                .accessibilityAddTraits(.isHeader)

            Text(card.detail)
                .font(AgentUIStyle.font(30, .bold))
                .foregroundStyle(AgentUIStyle.ink)
                .multilineTextAlignment(.center)
                .lineLimit(10)
                .minimumScaleFactor(0.5)
                .fixedSize(horizontal: false, vertical: true)

            if let warning = card.warning {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(warning).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(AgentUIStyle.font(20, .semibold))
                .foregroundStyle(AgentUIStyle.amber)
                .padding(14)
                .background(AgentUIStyle.amberBack, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Warning. \(warning)")
            }

            Label(card.helper, systemImage: helperIcon)
                .font(AgentUIStyle.font(19, .medium))
                .foregroundStyle(AgentUIStyle.soft)
                .accessibilityLabel("Asked by the \(card.helper)")

            HStack(spacing: 16) {
                Button { answer(false) } label: {
                    Text("No")
                        .font(AgentUIStyle.font(30, .bold))
                        .frame(maxWidth: .infinity, minHeight: 90)
                        .background(AgentUIStyle.mist, in: RoundedRectangle(cornerRadius: 22))
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("No, don't do it")

                Button { answer(true) } label: {
                    Text("Yes, do it")
                        .font(AgentUIStyle.font(30, .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, minHeight: 90)
                        .background(AgentUIStyle.green, in: RoundedRectangle(cornerRadius: 22))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Yes, do it")
                .accessibilityHint(card.needsOwner && ownerCheck != nil ? "Then you'll be asked for \(ownerCheck ?? "Face ID")." : "")
            }
            .disabled(answered)
            .opacity(answered ? 0.6 : 1)

            if card.needsOwner, let ownerCheck {
                Text("You'll be asked for \(ownerCheck) next.")
                    .font(AgentUIStyle.font(19, .medium))
                    .foregroundStyle(AgentUIStyle.soft)
                    .multilineTextAlignment(.center)
            }
            Text("If you do nothing, nothing happens.")
                .font(AgentUIStyle.font(17))
                .foregroundStyle(AgentUIStyle.soft)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .background(.white, in: RoundedRectangle(cornerRadius: 28))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        .padding(18)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear {
            ownerCheck = Self.ownerCheckName()
            UIAccessibility.post(notification: .screenChanged, argument: "Kairos wants to: \(card.detail)")
        }
    }

    private var helperIcon: String {
        KairosAgent.shared.specialists.first { $0.title == card.helper }?.icon ?? "person.crop.circle.badge.checkmark"
    }

    private func answer(_ yes: Bool) {
        guard !answered else { return }
        answered = true
        KairosAgent.shared.answerConfirmation(yes)
    }

    /// "Face ID", "Touch ID" or "your passcode"; nil when the phone has no passcode (then there's no check).
    static func ownerCheckName() -> String? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return nil }
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return "your passcode" }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "your passcode"
        }
    }
}
