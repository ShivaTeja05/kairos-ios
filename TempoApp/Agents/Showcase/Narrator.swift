import Foundation
import AVFoundation

// Present mode's voice. The Presenter speaks every line through a Narrator and waits for it to finish, so the
// next action starts the moment the line ends (a judge should never sit in silence for more than a few seconds).
//
//   DeviceNarrator      the phone's own voice (best installed en-GB voice, a touch slower than normal). Works
//                       offline, starts instantly, says exactly what is written.
//   ElevenLabsNarrator  the live ElevenLabs voice (TempoSession) through LiveVoiceBridge, with the phone's voice
//                       as the fallback when the call isn't live or the agent doesn't start speaking.

/// Speaks the presenter's lines, one at a time. `say` returns when the line has been spoken or was stopped.
@MainActor
protocol Narrator: AnyObject {
    func say(_ line: String) async
    /// Stops at once (mid-word) and gives the audio back to the rest of the phone.
    func stop() async
}

/// The live ElevenLabs conversation, as the presenter needs it. The integrator implements this on top of
/// TempoSession (see integration notes: `sayExactly`, `startForJudges`, `setPresenterMicMuted`).
@MainActor
protocol LiveVoiceBridge: AnyObject {
    /// A call is connected right now.
    var isLive: Bool { get }
    /// A call could be started (the phone is set up for voice). Defaults to `isLive`.
    var canStart: Bool { get }
    /// Has the agent say `line` word for word. Returns true when it spoke it (phase went speaking, then back to
    /// listening or idle), false when it never started (then the phone's own voice says it instead).
    /// Must give up by itself after max(4 s, words / 2.6 s) plus a few seconds to start.
    func sayExactly(_ line: String) async -> Bool
    /// Hands the floor to the judges: start the call if there isn't one, unmute, and tell the agent the show is over.
    func startConversation() async
    /// Mutes the call's microphone while the show talks, so the room doesn't interrupt it. Default: nothing.
    func setMicMuted(_ muted: Bool) async
    /// Cuts the agent off mid-line (Stop). Default: nothing.
    func stopSpeaking() async
}

extension LiveVoiceBridge {
    var canStart: Bool { isLive }
    func setMicMuted(_ muted: Bool) async {}
    func stopSpeaking() async {}
}

// MARK: - Timing

/// How long spoken lines take, for timeouts and the show's running time.
enum ShowTiming {
    /// The phone's voice at 0.94× is about 2.6 words a second; the ElevenLabs voice is close to it.
    static let wordsPerSecond = 2.6

    /// Spoken words: a dash or a lone symbol between spaces takes no time.
    static func words(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains { $0.isLetter || $0.isNumber } }.count
    }

    static func seconds(_ text: String) -> Double {
        Double(words(text)) / wordsPerSecond
    }
}

// MARK: - The phone's own voice

/// AVSpeechSynthesizer with the best installed British voice (premium, then enhanced), a little slower than normal.
/// Takes the audio session as .playback / .spokenAudio with .duckOthers for the show, and puts back what was
/// there before on stop().
@MainActor
final class DeviceNarrator: NSObject, Narrator {
    /// Optional AVSpeechSynthesisVoice identifier to force one voice (Settings → Accessibility → Spoken Content).
    static let voiceDefaultsKey = "kairos.show.voice"

    let voice: AVSpeechSynthesisVoice?
    /// Slightly slower than the default rate: clear on a projector speaker, still brisk.
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate * 0.94
    /// False while the ElevenLabs call owns the audio session (LiveKit): then this voice plays into it as it is.
    var managesAudioSession = true

    private let synth = AVSpeechSynthesizer()
    private var current: ObjectIdentifier?
    private var waiter: ShowOnce<Void>?
    #if os(iOS)
    private var savedSession: (category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                               options: AVAudioSession.CategoryOptions)?
    #endif

    override init() {
        voice = Self.bestVoice()
        super.init()
        synth.delegate = self
    }

    var voiceName: String { voice.map { "\($0.name) (\($0.language))" } ?? "system default" }

    func say(_ line: String) async {
        let text = Self.speakable(line)
        guard !text.isEmpty else { return }
        cutCurrent()
        takeAudio()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0.08
        let once = ShowOnce<Void>()
        let id = ObjectIdentifier(utterance)
        current = id
        waiter = once
        synth.speak(utterance)
        // If the voice never reports back (an audio route change, an interruption), carry on anyway.
        let limit = ShowTiming.seconds(text) * 1.8 + 3
        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard !Task.isCancelled, let self, self.current == id else { return }
            self.cutCurrent()
        }
        await once.value()
        watchdog.cancel()
    }

    func stop() async {
        cutCurrent()
        giveBackAudio()
    }

    /// Ends the line that is playing (if any) and lets its `say` return.
    private func cutCurrent() {
        guard current != nil || synth.isSpeaking else { return }
        current = nil
        let w = waiter
        waiter = nil
        synth.stopSpeaking(at: .immediate)
        w?.resume(())
    }

    fileprivate func finished(_ id: ObjectIdentifier) {
        guard current == id else { return }
        current = nil
        let w = waiter
        waiter = nil
        w?.resume(())
    }

    private func takeAudio() {
        #if os(iOS)
        guard managesAudioSession else { return }
        let session = AVAudioSession.sharedInstance()
        if savedSession == nil {
            savedSession = (session.category, session.mode, session.categoryOptions)
        }
        if session.category != .playback || session.mode != .spokenAudio {
            try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        }
        try? session.setActive(true)
        #endif
    }

    private func giveBackAudio() {
        #if os(iOS)
        guard let saved = savedSession else { return }
        savedSession = nil
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try? session.setCategory(saved.category, mode: saved.mode, options: saved.options)
        #endif
    }

    /// The forced voice, else the best en-GB voice installed: premium, then enhanced, preferring the warmer ones.
    static func bestVoice(language: String = "en-GB") -> AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: voiceDefaultsKey), let v = AVSpeechSynthesisVoice(identifier: id) {
            return v
        }
        let liked = ["Serena", "Jamie", "Daniel", "Kate", "Stephanie", "Arthur", "Martha", "Oliver"]
        let pool = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language == language && !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            let bonus = liked.firstIndex(where: { v.name.hasPrefix($0) }).map { 20 - $0 } ?? 0
            return v.quality.rawValue * 100 + bonus
        }
        return pool.max(by: { score($0) < score($1) }) ?? AVSpeechSynthesisVoice(language: language)
    }

    /// Without emoji, template leftovers and doubled spaces, which voices read out oddly.
    static func speakable(_ text: String) -> String {
        let noTemplates = text.replacingOccurrences(of: "{result}", with: "")
        let scalars = noTemplates.unicodeScalars.filter { !$0.properties.isEmojiPresentation && $0.value != 0xFE0F }
        return String(String.UnicodeScalarView(scalars))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

extension DeviceNarrator: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finished(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finished(id) }
    }
}

// MARK: - The live ElevenLabs voice

/// Speaks through the live ElevenLabs call when there is one. Falls back to the phone's voice when the call isn't
/// live or the agent never starts the line; never talks over a line that is still going.
@MainActor
final class ElevenLabsNarrator: Narrator {
    let bridge: any LiveVoiceBridge
    let fallback: DeviceNarrator
    private var cancel = ShowCancel()
    private var speakingLive = false

    init(bridge: any LiveVoiceBridge, fallback: DeviceNarrator? = nil) {
        self.bridge = bridge
        self.fallback = fallback ?? DeviceNarrator()
    }

    func say(_ line: String) async {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if cancel.isCancelled { cancel = ShowCancel() }
        let token = cancel
        guard bridge.isLive else {
            fallback.managesAudioSession = true
            await fallback.say(text)
            return
        }
        // The bridge has its own timeout; this one only stops a hang from freezing the show.
        let limit = max(4, ShowTiming.seconds(text)) + 16
        speakingLive = true
        let spoke = await ShowRace.within(limit, cancel: token) { [bridge] in await bridge.sayExactly(text) }
        speakingLive = false
        if token.isCancelled || spoke == true { return }  // spoken or stopped
        // Timed out: if the agent is still mid-line, don't double up; if it never got going, the phone says it.
        if spoke == nil, (bridge as? any LiveVoiceActivity)?.isSpeaking ?? true { return }
        // The agent never started (busy, call dropped): the phone's own voice says it, into the call's audio.
        fallback.managesAudioSession = !bridge.isLive
        await fallback.say(text)
    }

    func stop() async {
        cancel.cancel()
        if speakingLive { await bridge.stopSpeaking() }
        await fallback.stop()
    }
}

// MARK: - Small concurrency helpers

/// A stop button that the show's waits listen to. Main actor only.
@MainActor
final class ShowCancel {
    private(set) var isCancelled = false
    private var handlers: [UUID: () -> Void] = [:]

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        let pending = Array(handlers.values)
        handlers = [:]
        pending.forEach { $0() }
    }

    /// Runs `handler` on cancel (at once if already cancelled). Returns a key for `remove`.
    @discardableResult
    func onCancel(_ handler: @escaping () -> Void) -> UUID? {
        guard !isCancelled else { handler(); return nil }
        let key = UUID()
        handlers[key] = handler
        return key
    }

    func remove(_ key: UUID?) {
        if let key { handlers[key] = nil }
    }
}

/// A value delivered once, from any thread; `value()` waits for it (or returns it if it already came).
final class ShowOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var stored: T?
    private var continuation: CheckedContinuation<T, Never>?

    /// Delivers the value. False if one was already delivered.
    @discardableResult
    func resume(_ value: T) -> Bool {
        lock.lock()
        guard !done else { lock.unlock(); return false }
        done = true
        let c = continuation
        continuation = nil
        if c == nil { stored = value }
        lock.unlock()
        c?.resume(returning: value)
        return true
    }

    func value() async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            lock.lock()
            if done, let v = stored {
                stored = nil
                lock.unlock()
                c.resume(returning: v)
            } else {
                continuation = c
                lock.unlock()
            }
        }
    }
}

@MainActor
enum ShowRace {
    /// `work`'s value, or nil when `seconds` pass or `cancel` fires first. Work that ignores cancellation keeps
    /// running in the background; the show doesn't wait for it.
    static func within<T>(_ seconds: Double, cancel: ShowCancel? = nil,
                          _ work: @escaping @MainActor () async -> T) async -> T? {
        let once = ShowOnce<T?>()
        let worker = Task { @MainActor in once.resume(await work()) }
        let timer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            if !Task.isCancelled { once.resume(nil) }
        }
        let key = cancel?.onCancel { once.resume(nil) }
        let value = await once.value()
        timer.cancel()
        cancel?.remove(key)
        if value == nil { worker.cancel() }
        return value
    }
}
