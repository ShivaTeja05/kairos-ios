import Combine
import Foundation

/// Keeps the ElevenLabs voice in the loop: when a call starts it hears what's happening on the phone, and while the
/// call goes on it hears each thing the agents do ("Time helper did: Alarm at 07:00", "a card is waiting"), as
/// contextual updates that don't interrupt the person. Actions the voice itself asked for via phone_agent come back
/// in that tool's result, so they aren't repeated here.
@MainActor
final class VoiceContextBridge {
    static let shared = VoiceContextBridge()

    /// True while the voice waits on a phone_agent result (TempoSession sets it around the call).
    var toolCallInFlight = false

    private weak var session: TempoSession?
    private var subscriptions = Set<AnyCancellable>()
    private var seen = Set<UUID>()
    private var pending: [String] = []
    private var flushTask: Task<Void, Never>?

    var isAttached: Bool { session != nil }

    /// Call when a voice call becomes live.
    func attach(_ session: TempoSession) {
        if self.session === session { return }
        detach()
        self.session = session
        seen = Set(KairosAgent.shared.lines.map(\.id))
        session.tellKairos("Kairos update (phone status, information only, don't call a tool for it): "
                           + PhoneContext.voiceSummary())
        KairosAgent.shared.$lines
            .sink { [weak self] lines in self?.linesChanged(lines) }
            .store(in: &subscriptions)
        KairosAgent.shared.$confirmation
            .map { $0?.detail }
            .removeDuplicates()
            .sink { [weak self] detail in
                guard let detail, self?.toolCallInFlight == false else { return }
                self?.forward("A card is waiting on the screen for the owner's yes: \(detail).")
            }
            .store(in: &subscriptions)
    }

    /// Call when the call ends.
    func detach() {
        subscriptions.removeAll()
        flushTask?.cancel()
        pending.removeAll()
        session = nil
    }

    /// Any part of the app can tell the voice something (worker agents finishing, the phone operator's progress).
    func forward(_ text: String) {
        guard session != nil else { return }
        pending.append(text)
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)  // gather a burst into one update
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func linesChanged(_ lines: [AgentLine]) {
        for line in lines where !seen.contains(line.id) {
            seen.insert(line.id)
            guard !toolCallInFlight, [.done, .failed, .refused].contains(line.kind) else { continue }
            let who = line.helper ?? "Kairos"
            let verb = line.kind == .done ? "did" : (line.kind == .failed ? "couldn't do" : "refused")
            forward("\(who) \(verb): \(line.text).")
        }
    }

    private func flush() {
        guard let session, !pending.isEmpty else { return }
        let text = "Kairos update (information only, don't call a tool for it): " + pending.suffix(5).joined(separator: " ")
        pending.removeAll()
        session.tellKairos(text)
    }
}
