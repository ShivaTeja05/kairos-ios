import Foundation
import AVFoundation
import Speech
import NaturalLanguage

/// Kairos's own ears and voice on this phone. Tap to talk; it stops by itself about two seconds after you stop
/// talking, sends your words to Kairos, and reads the answer out loud a little slower than normal.
/// Speech is turned into words on the phone itself whenever the phone can do that for the chosen language.
///
/// It keeps out of the way of the ElevenLabs call (TempoSession, which it never touches): it won't listen or
/// speak while `otherCallActive()` says that call is on, and it lets go of the audio session when it is done.
@MainActor
final class AgentVoice: NSObject, ObservableObject {
    static let shared = AgentVoice()

    @Published private(set) var isListening = false
    @Published private(set) var isSpeaking = false
    /// Words, a typed message or a photo from this screen are with Kairos.
    @Published private(set) var isAsking = false
    /// What the person has said so far, shown live while listening.
    @Published private(set) var liveWords = ""
    /// One plain sentence about a problem (not allowed to listen, nothing heard). Shown under the button.
    @Published var notice: String?

    /// Set by the integrator: true while the ElevenLabs voice call has the microphone. While it does, this voice
    /// doesn't listen or speak (Kairos's answers still appear on screen).
    var otherCallActive: @MainActor () -> Bool = { false }

    /// True while this voice is listening, speaking or waiting for Kairos. The ElevenLabs call (and its
    /// auto-start on foreground) should wait while this is true.
    var isBusy: Bool { isListening || isSpeaking || isAsking || starting }

    /// Seconds of quiet after the last new word before Kairos stops listening.
    let silenceSeconds: Double = 1.8
    /// How long to wait for the first word.
    let firstWordSeconds: Double = 8
    /// Apple's recogniser stops at about a minute; stop a little before.
    let longestListen: Double = 55
    /// A little slower than the default, for older listeners.
    let rate: Float = AVSpeechUtteranceDefaultSpeechRate * 0.88

    private var engine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Task<Void, Never>?
    private var listenID = UUID()
    private var listenStarted = Date()
    private var starting = false
    private let synth = AVSpeechSynthesizer()
    private var currentUtterance: AVSpeechUtterance?
    private var interruptionObserver: NSObjectProtocol?

    private override init() {
        super.init()
        synth.delegate = self
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in AgentVoice.shared.interrupted() }
        }
    }

    // MARK: - The big button

    /// Tap to talk, tap again to send. Tapping while Kairos is talking stops it and listens instead.
    func micTapped() {
        if isListening { finishListening(send: true); return }
        stopSpeaking()
        Task { await startListening() }
    }

    func startListening() async {
        guard !isListening, !starting, !isAsking else { return }
        if KairosAgent.shared.working {
            notice = "I'm still finishing the last request. Tap here again in a moment."
            return
        }
        notice = nil
        if otherCallActive() {
            notice = "You're on a voice call with Kairos. End that call first, then tap here."
            return
        }
        starting = true
        defer { starting = false }
        guard await askPermissions() else { return }

        let (found, languageNote) = Self.recognizer(for: AgentLanguage.current)
        guard let recognizer = found else {
            notice = "I can't listen on this phone just now. Please type instead."
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers])
            try await activate(session)
        } catch {
            notice = "The microphone is busy just now. Please try again in a moment."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            notice = "I can't hear the microphone. Please try again."
            releaseAudio()
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.feed(request))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            notice = "I couldn't start listening. Please try again."
            releaseAudio()
            return
        }

        let id = UUID()
        listenID = id
        self.engine = engine
        self.recognizer = recognizer
        self.request = request
        task = recognizer.recognitionTask(with: request, resultHandler: Self.report { text, isFinal, failed in
            Task { @MainActor in AgentVoice.shared.heard(text, isFinal: isFinal, failed: failed, id: id) }
        })
        liveWords = ""
        listenStarted = Date()
        isListening = true
        notice = languageNote
        armTimer(firstWordSeconds, id: id)
    }

    /// Stops listening. With `send`, what was heard goes to Kairos.
    func finishListening(send: Bool) {
        guard isListening else { return }
        isListening = false
        listenID = UUID()
        silenceTimer?.cancel()
        silenceTimer = nil
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        engine = nil
        request = nil
        task = nil
        recognizer = nil
        let words = liveWords.trimmingCharacters(in: .whitespacesAndNewlines)
        liveWords = ""
        releaseAudio()
        guard send else { return }
        guard !words.isEmpty else {
            notice = "I didn't hear anything. Tap the button and talk to me."
            return
        }
        ask(words)
    }

    /// Stops listening and talking (leaving the screen, "New conversation").
    func stopAll() {
        finishListening(send: false)
        stopSpeaking()
    }

    private func heard(_ text: String?, isFinal: Bool, failed: Bool, id: UUID) {
        guard isListening, id == listenID else { return }
        if let text, !text.isEmpty, text != liveWords {
            liveWords = text
            armTimer(silenceSeconds, id: id)
        }
        if isFinal || failed { finishListening(send: true) }
    }

    private func armTimer(_ seconds: Double, id: UUID) {
        silenceTimer?.cancel()
        let left = longestListen - Date().timeIntervalSince(listenStarted)
        let wait = max(0.3, min(seconds, left))
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isListening, self.listenID == id else { return }
            self.finishListening(send: true)
        }
    }

    private func interrupted() {
        if isListening {
            finishListening(send: false)
            notice = "Something else needed the microphone, so I stopped listening. Tap the button to try again."
        }
        if isSpeaking {
            currentUtterance = nil
            isSpeaking = false
            synth.stopSpeaking(at: .immediate)
        }
    }

    // MARK: - Asking Kairos

    /// Sends words (and photos) to Kairos, then reads the answer out loud.
    func ask(_ words: String, images: [Data] = []) {
        Task { await askAndSpeak(words, images: images) }
    }

    @discardableResult
    func askAndSpeak(_ words: String, images: [Data] = []) async -> AgentOutcome {
        notice = nil
        isAsking = true
        // One request at a time: the camera can open while the request that asked for it is finishing.
        var waited = 0
        while KairosAgent.shared.working, waited < 150 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            waited += 1
        }
        let outcome = await KairosAgent.shared.handle(words, source: .app, images: images)
        isAsking = false
        speak(outcome.say)
        return outcome
    }

    // MARK: - Speaking

    /// Reads words out loud in the person's language, or in English when the words are English.
    func speak(_ text: String) {
        let words = Self.speakable(text)
        guard !words.isEmpty, Self.speakReplies, !otherCallActive() else { return }
        if isListening { finishListening(send: false) }
        stopSpeaking(release: false)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(string: words)
        utterance.voice = Self.voice(for: words, chosen: AgentLanguage.current)
        utterance.rate = rate
        utterance.preUtteranceDelay = 0.05
        currentUtterance = utterance
        isSpeaking = true
        synth.speak(utterance)
    }

    func stopSpeaking() { stopSpeaking(release: true) }

    private func stopSpeaking(release: Bool) {
        guard isSpeaking || synth.isSpeaking else { return }
        currentUtterance = nil
        isSpeaking = false
        synth.stopSpeaking(at: .immediate)
        if release { releaseAudio() }
    }

    fileprivate func finishedSpeaking(_ id: ObjectIdentifier) {
        guard let current = currentUtterance, ObjectIdentifier(current) == id else { return }
        currentUtterance = nil
        isSpeaking = false
        releaseAudio()
    }

    // MARK: - Audio session

    private func activate(_ session: AVAudioSession) async throws {
        do {
            try session.setActive(true)
        } catch {
            // Siri or a call may still be letting go of the microphone.
            try await Task.sleep(nanoseconds: 500_000_000)
            try session.setActive(true)
        }
    }

    /// Hands the audio back to other apps (and to the ElevenLabs call) once nothing here needs it.
    private func releaseAudio() {
        guard !isListening, !isSpeaking, !otherCallActive() else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Permissions

    /// Asks for speech recognition and the microphone the first time; afterwards it only reports.
    /// When it returns false, `notice` says why in plain words.
    func askPermissions() async -> Bool {
        guard await Self.speechPermission() == .authorized else {
            notice = "Kairos isn't allowed to understand speech yet. Ask your helper to turn on Speech Recognition for Kairos in Settings. You can type instead."
            return false
        }
        guard await Self.microphonePermission() else {
            notice = "Kairos isn't allowed to use the microphone. Ask your helper to turn it on for Kairos in Settings. You can type instead."
            return false
        }
        return true
    }

    /// true: allowed; false: refused in Settings; nil: not asked yet.
    nonisolated static var listeningAllowed: Bool? {
        let speech = SFSpeechRecognizer.authorizationStatus()
        let mic = AVAudioApplication.shared.recordPermission
        if speech == .denied || speech == .restricted || mic == .denied { return false }
        if speech == .authorized && mic == .granted { return true }
        return nil
    }

    nonisolated private static func speechPermission() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
    }

    nonisolated private static func microphonePermission() async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
    }

    // MARK: - Settings and language helpers

    nonisolated static let speakRepliesKey = "kairos.agents.speakReplies"

    /// Read answers out loud (on unless turned off in settings).
    nonisolated static var speakReplies: Bool {
        get { UserDefaults.standard.object(forKey: speakRepliesKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: speakRepliesKey) }
    }

    /// The recogniser for the chosen language, or English (with a note) when this phone can't listen in it.
    nonisolated static func recognizer(for code: String) -> (SFSpeechRecognizer?, String?) {
        if let own = SFSpeechRecognizer(locale: Locale(identifier: code)), own.isAvailable { return (own, nil) }
        guard let english = SFSpeechRecognizer(locale: Locale(identifier: "en-GB")), english.isAvailable else {
            return (nil, nil)
        }
        if code.lowercased().hasPrefix("en") { return (english, nil) }
        return (english, "This phone can't listen in \(languageName(code)) yet, so I'm listening in English.")
    }

    /// "Telugu" for "te-IN".
    nonisolated static func languageName(_ code: String) -> String {
        let base = String(code.prefix { $0 != "-" && $0 != "_" })
        return Locale(identifier: "en-GB").localizedString(forLanguageCode: base) ?? code
    }

    /// Whether Apple's recogniser knows this language.
    nonisolated static func canListen(_ code: String) -> Bool {
        let want = code.replacingOccurrences(of: "_", with: "-").lowercased()
        return SFSpeechRecognizer.supportedLocales().contains {
            $0.identifier.replacingOccurrences(of: "_", with: "-").lowercased() == want
        }
    }

    /// Whether this phone has a voice installed for this language.
    nonisolated static func canSpeak(_ code: String) -> Bool { bestVoice(code) != nil }

    /// The best installed voice for a language: premium, then enhanced, then the language's default voice.
    nonisolated static func bestVoice(_ code: String) -> AVSpeechSynthesisVoice? {
        let want = code.replacingOccurrences(of: "_", with: "-").lowercased()
        let base = String(want.prefix { $0 != "-" })
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        var pool = voices.filter { $0.language.lowercased() == want }
        if pool.isEmpty {
            pool = voices.filter { $0.language.lowercased() == base || $0.language.lowercased().hasPrefix(base + "-") }
        }
        let preferred = AVSpeechSynthesisVoice(language: want)?.identifier
        func rank(_ v: AVSpeechSynthesisVoice) -> Int { v.quality.rawValue * 2 + (v.identifier == preferred ? 1 : 0) }
        return pool.max { rank($0) < rank($1) }
    }

    /// The person's language, unless the words are clearly in another one (simple replies are often English).
    nonisolated static func speechLanguage(for text: String, chosen: String) -> String {
        let base = String(chosen.prefix { $0 != "-" && $0 != "_" }).lowercased()
        let recogniser = NLLanguageRecognizer()
        recogniser.processString(text)
        guard let top = recogniser.languageHypotheses(withMaximum: 2).max(by: { $0.value < $1.value }),
              top.value >= 0.75, top.key != .undetermined,
              !top.key.rawValue.lowercased().hasPrefix(base) else { return chosen }
        return top.key == .english ? "en-GB" : top.key.rawValue
    }

    nonisolated static func voice(for text: String, chosen: String) -> AVSpeechSynthesisVoice? {
        bestVoice(speechLanguage(for: text, chosen: chosen)) ?? bestVoice("en-GB") ?? AVSpeechSynthesisVoice(language: "en-GB")
    }

    /// Without emoji and tick marks, which voices read out as words.
    nonisolated static func speakable(_ text: String) -> String {
        let skip = Set("✓✗•".unicodeScalars)
        let kept = text.unicodeScalars.filter { !$0.properties.isEmojiPresentation && !skip.contains($0) }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: kept)
        return String(view).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Callbacks made off the main actor

    /// The microphone tap: runs on the audio thread, so it is built outside the main actor.
    nonisolated private static func feed(_ request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    nonisolated private static func report(
        _ deliver: @escaping @Sendable (String?, Bool, Bool) -> Void
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            deliver(result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
        }
    }
}

extension AgentVoice: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in AgentVoice.shared.finishedSpeaking(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in AgentVoice.shared.finishedSpeaking(id) }
    }
}
