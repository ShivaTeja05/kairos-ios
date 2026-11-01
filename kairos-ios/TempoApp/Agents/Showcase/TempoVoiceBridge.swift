import Foundation

/// Present mode's live voice: the ElevenLabs call (TempoSession) as a LiveVoiceBridge.
///
/// A line goes to the voice agent as a user turn "Presentation: <exact words>"; the agent's system prompt says to
/// say those words exactly and call no tool. The line counts as spoken when the call's phase goes to .speaking and
/// then stays off .speaking for a moment. If the agent hasn't started within a few seconds, sayExactly returns false
/// and the Presenter's phone voice says the line instead, so the room is never left waiting.
@MainActor
final class TempoVoiceBridge: LiveVoiceBridge {
    private weak var session: TempoSession?

    /// How long the agent may take to start a line before the phone's own voice takes over.
    let startWait: TimeInterval = 3.5
    /// A pause this long off .speaking ends the line (the agent can dip between sentences).
    let endGrace: TimeInterval = 0.7

    init(session: TempoSession) { self.session = session }

    var isLive: Bool {
        guard let s = session, s.isInCall else { return false }
        switch s.phase {
        case .listening, .speaking, .thinking: return true
        default: return false
        }
    }

    var canStart: Bool {
        guard let s = session else { return false }
        if s.isInCall { return true }
        switch s.phase {
        case .idle, .error: return true
        default: return false
        }
    }

    /// The agent is talking right now (Present mode skips a live progress update then).
    var isSpeaking: Bool { session?.phase == .speaking }

    func sayExactly(_ line: String) async -> Bool {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        guard let s = session, isLive else { return false }
        // Let a sentence already playing finish first (at most a few seconds).
        _ = await waitWhile(seconds: 4) { s.phase == .speaking }
        // Stopped while waiting: say nothing more (true = don't let the phone's voice say it either).
        guard !Task.isCancelled else { return true }
        guard await s.sendToAgent("Presentation: " + text) else { return false }
        // 1. Did it start? Once the line is sent, false would make the phone say it too (two voices), so a late or
        //    silent agent means "skip", not "fall back".
        let started = await waitWhile(seconds: 7) { s.isInCall && s.phase != .speaking }
        guard started, s.phase == .speaking else { return s.isInCall }
        // 2. Wait for the end, with a hard limit from the length of the line.
        let limit = max(4, ShowTiming.seconds(text)) + 4
        let end = Date().addingTimeInterval(limit)
        var quietSince: Date?
        while Date() < end, s.isInCall, !Task.isCancelled {
            if s.phase == .speaking {
                quietSince = nil
            } else if let q = quietSince {
                if Date().timeIntervalSince(q) >= endGrace { break }
            } else {
                quietSince = Date()
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }

    func startConversation() async {
        guard let s = session else { return }
        if !s.isInCall {
            s.startIfIdle()
            _ = await waitWhile(seconds: 10) { !s.isInCall }
            // Still connecting (slow hub or ngrok): give the microphone back so the agent screen can listen.
            if !s.isInCall { await s.stop(); return }
        }
        await s.setCallMicMuted(false)
        s.tellKairos("The presentation has finished. The judges will talk to you now: greet them in one short sentence, then answer their questions and do what they ask with the phone_agent tool.")
    }

    func setMicMuted(_ muted: Bool) async {
        await session?.setCallMicMuted(muted)
    }

    func stopSpeaking() async {
        // The SDK has no "stop talking" call; muting the room and moving on is enough for Stop.
        await session?.setCallMicMuted(false)
    }

    /// Waits while `condition` holds, up to `seconds`. True if it stopped holding in time.
    private func waitWhile(seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while condition() {
            if Date() >= end || Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }
}

/// Present mode waits for the live voice to finish a sentence before it voices the helpers' progress.
extension TempoVoiceBridge: LiveVoiceActivity {}
