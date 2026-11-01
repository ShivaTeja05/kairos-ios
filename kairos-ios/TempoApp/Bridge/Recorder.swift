import AudioToolbox
import AVFoundation
import Foundation
import UIKit
import os

// "Write for me" voice clip: tap to start, speak for up to 60 s, tap to stop.
// The bytes go to POST /api/bridge/draft as `audio=<m4a>`; the clip never stays on this phone.
//
// IMPORTANT for the caller: end any ElevenLabs call BEFORE start(), and make that also release LiveKit's
// always-prepared microphone. Both want the one shared AVAudioSession (different categories and modes), and
// two owners would fight over the microphone and the speaker. start() deactivates the session first anyway.

/// Records one short voice message for the Bridge, in memory as far as possible.
/// Never stops on silence (older people pause to think). The only automatic stop is the 60 s cap; a phone call,
/// locking the phone or leaving Kairos also ends it early, and the clip so far is kept so nothing they said is lost.
@MainActor
final class VoiceClipRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    /// Seconds recorded so far. Stays at the final value after stopping ("You spoke for 23 seconds").
    @Published private(set) var elapsed: TimeInterval = 0
    /// 0...1, smoothed, for a simple calm meter. 0 when not recording.
    @Published private(set) var level: Float = 0
    /// Plain words, safe to show or speak. Never contains message text.
    @Published private(set) var lastError: String?
    /// True when the microphone permission is off, so the screen can offer one "Open Settings" button
    /// (see openSettings()) instead of a trip through Settings that many 80-year-olds won't finish.
    @Published private(set) var permissionDenied = false
    /// True when the 60 s cap ended the recording. The clip is kept: call stop() to collect it.
    @Published private(set) var reachedLimit = false
    /// True when a phone call, locking the phone or leaving Kairos ended the recording early. The clip is kept.
    @Published private(set) var wasInterrupted = false

    let maxDuration: TimeInterval = 60
    /// Shorter than this is an accidental tap, not a message: nothing is kept.
    let minDuration: TimeInterval = 1.0
    /// Stop taps this soon after the start are ignored. With a tremor one press often lands as two taps,
    /// and the bounce would end the recording before they've said a word.
    let stopTapGrace: TimeInterval = 1.5
    /// A clip shorter than this shouldn't be drafted straight away: ask
    /// "You spoke for 2 seconds. Write my message from that?" (Yes / Say it again) first.
    let confirmBelow: TimeInterval = 3

    /// Seconds left before the cap, for "45 seconds left".
    var remaining: TimeInterval { max(0, maxDuration - elapsed) }
    /// True when recording stopped on its own and stop() will hand back the kept clip.
    var hasKeptClip: Bool { keptClip != nil }
    /// True while a stop tap would be ignored (see stopTapGrace).
    var ignoresStopTap: Bool {
        isRecording && ProcessInfo.processInfo.systemUptime - startedAt < stopTapGrace
    }
    /// Right after stop() handed back a clip (or with a kept clip): true when it is under `confirmBelow`
    /// seconds, so the screen should ask before drafting.
    var isShortClip: Bool { !isRecording && elapsed < confirmBelow }

    private var active: ActiveClip?
    @Published private var keptClip: Data?   // published so `hasKeptClip` refreshes the UI
    private var ticker: Task<Void, Never>?
    /// Bumped by start() and cancel(), so a start() still waiting on the permission pop-up can't begin
    /// recording after the person has already cancelled or tapped again.
    private var attempt = 0
    /// systemUptime when recording really began, for the stop-tap grace (elapsed lags by up to a tick).
    private var startedAt: TimeInterval = 0
    /// Ticks in a row where our recorder had stopped without any notification saying why.
    private var stalledTicks = 0
    private let log = Logger(subsystem: "uk.oxhack.tempo", category: "bridge.recorder")

    // AAC mono at 16 kHz, ~32 kbps: plenty for speech-to-text, and 60 s is about 240 KB (the server takes <= 2 MB).
    private static let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]

    /// Lets hearing aids and Bluetooth headsets be the microphone. Same bit (0x4) either way; the iOS 26 SDK
    /// renamed `.allowBluetooth` to `.allowBluetoothHFP` and deprecated the old name.
    private static var bluetoothInput: AVAudioSession.CategoryOptions {
        #if compiler(>=6.2)
        return .allowBluetoothHFP
        #else
        return .allowBluetooth
        #endif
    }

    override init() {
        super.init()
        // A crash or force-quit mid-recording skips every cleanup path below; don't wait for the next recording.
        Self.removeLeftoverClips()
    }

    deinit {
        // The temp file, recorder and observers live in ActiveClip, whose own deinit deletes the file and
        // gives the audio session back, so nothing is left behind even if we're released mid-recording.
        ticker?.cancel()
    }

    // MARK: - Start / stop

    /// Asks for the microphone (once), then starts recording. Returns false with `lastError` set if it can't.
    /// The caller must have ended any ElevenLabs call first (see the note at the top of this file).
    func start() async -> Bool {
        guard !isRecording else { return true }
        discardKeptClip()
        attempt += 1
        let myAttempt = attempt
        lastError = nil
        permissionDenied = false
        reachedLimit = false
        wasInterrupted = false
        elapsed = 0
        level = 0
        stalledTicks = 0
        Self.removeLeftoverClips()

        // Ask before touching the session, so the pop-up never appears halfway through a recording.
        guard await AVAudioApplication.requestRecordPermission() else {
            permissionDenied = true
            lastError = "Kairos can't hear you. Please allow the microphone: Settings, then Kairos, then Microphone."
            log.notice("record permission denied")
            return false
        }
        // The person may have cancelled, or tapped again, while the pop-up was showing.
        guard myAttempt == attempt, !isRecording else { return false }

        let session = AVAudioSession.sharedInstance()
        if session.mode == .voiceChat {
            // LiveKit set this; if its engine were still running, the call didn't fully let go of the mic.
            log.notice("session still in voiceChat mode before recording")
        }
        // Start from a released session rather than changing category and mode under another engine's running I/O.
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // isBusy: something still had I/O running. iOS has stopped it and deactivated anyway, so carry on;
            // if the mic really can't be had, activating below fails and says so in plain words.
            log.notice("session busy before recording: \((error as NSError).code, privacy: .public)")
        }
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, Self.bluetoothInput])
            // So the start buzz can still be felt (and the VoiceOver beep heard) once the microphone is live.
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true)
        } catch {
            Self.releaseSession()
            lastError = Self.sessionErrorMessage(error)
            log.error("audio session failed to activate: \((error as NSError).code, privacy: .public)")
            return false
        }
        guard session.isInputAvailable else {
            Self.releaseSession()
            lastError = "I can't find a microphone. Please unplug any headphones and tap the button again."
            log.error("no audio input available")
            return false
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(ActiveClip.prefix + UUID().uuidString)
            .appendingPathExtension(ActiveClip.ext)
        let clip = ActiveClip(url: url)
        // .complete: unreadable while the phone is locked. AVAudioRecorder may recreate the file, so set it again below.
        FileManager.default.createFile(atPath: url.path, contents: nil,
                                       attributes: [.protectionKey: FileProtectionType.complete])
        do {
            let recorder = try AVAudioRecorder(url: url, settings: Self.settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            clip.recorder = recorder
            guard recorder.prepareToRecord() else { throw RecorderFailure.prepare }
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            // VoiceOver users can't see the button change, and older hands often miss a buzz: a short beep says
            // "speak now". Played just before recording so their first words aren't lost while they wait.
            if UIAccessibility.isVoiceOverRunning { AudioServicesPlaySystemSound(Self.beginRecordingSound) }
            // record(forDuration:) is the hard 60 s cap: the recorder stops itself even if our ticker is late.
            guard recorder.record(forDuration: maxDuration) else { throw RecorderFailure.record }
        } catch {
            clip.release()
            Self.releaseSession()
            lastError = "Recording didn't start. Please tap the button again."
            log.error("recorder failed to start")
            return false
        }
        startedAt = ProcessInfo.processInfo.systemUptime
        // Only now that it's really recording, and strong enough to feel (a light tap often isn't).
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        // Keep the screen awake while they talk: auto-lock (often 30 s) would lock the phone mid-message,
        // and a locked phone can't write to a .complete-protected file.
        clip.idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        observeEarlyStops(clip)
        active = clip
        isRecording = true
        startTicker()
        log.info("recording started")
        return true
    }

    /// Stops and hands back the m4a bytes. The file is deleted before this returns.
    /// If recording already stopped on its own (60 s, a call), returns that kept clip.
    /// nil when nothing usable was recorded (under 1 s, or empty; `lastError` says so), and also nil with
    /// recording carrying on when the tap comes within `stopTapGrace` of the start (check `isRecording`).
    func stop() -> Data? {
        if let kept = keptClip {
            keptClip = nil
            log.info("kept clip collected")
            return kept
        }
        guard isRecording, let clip = active else { return nil }
        // A tremor's second tap, not a real stop: keep listening, and don't say anything went wrong.
        guard !ignoresStopTap else {
            log.info("stop tap ignored: too soon after start")
            return nil
        }
        let duration = recordedLength(clip)
        let data = finish(clip)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        guard duration >= minDuration, let data else {
            lastError = "I didn't catch that. Tap the button, speak, then tap it again when you've finished."
            log.notice("clip too short or empty")
            return nil
        }
        elapsed = min(duration, maxDuration)
        log.info("recording stopped: \(Int(duration.rounded()), privacy: .public) s, \(data.count, privacy: .public) bytes")
        return data
    }

    /// Stops (if needed) and throws the recording away. Also stops a start() that is still waiting on permission.
    func cancel() {
        attempt += 1
        if let clip = active { _ = finish(clip) }
        discardKeptClip()
        lastError = nil
        permissionDenied = false
        reachedLimit = false
        wasInterrupted = false
        elapsed = 0
        log.info("recording cancelled")
    }

    /// Opens Kairos's own page in Settings, where the Microphone switch is. For the button next to the
    /// permission error (`permissionDenied`).
    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Stopping on its own

    private enum EarlyStop { case limit, interrupted }

    /// The 60 s cap or an interruption: stop, keep the clip in memory, delete the file, let the UI decide.
    private func stopOnItsOwn(_ reason: EarlyStop) {
        guard isRecording, let clip = active else { return }
        let duration = reason == .limit ? maxDuration : recordedLength(clip)
        let data = finish(clip)
        keptClip = duration >= minDuration ? data : nil
        elapsed = min(duration, maxDuration)
        reachedLimit = reason == .limit
        wasInterrupted = reason == .interrupted
        if keptClip == nil {
            lastError = "The recording stopped before I heard anything. Please tap the button and try again."
        }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        log.info("recording stopped on its own: \(reason == .limit ? "limit" : "interrupted", privacy: .public)")
    }

    /// Phone calls, Siri and alarms (interruption), the audio system restarting (our recorder is dead after it),
    /// the phone locking (the file key is about to go) and leaving Kairos (the mic must not stay live in the
    /// background: UIBackgroundModes includes audio).
    private func observeEarlyStops(_ clip: ActiveClip) {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        clip.observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                                 object: session, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            // The system has already paused the recorder; keep what was said rather than lose it.
            MainActor.assumeIsolated { self?.stopOnItsOwn(.interrupted) }
        })
        clip.observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                                 object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopOnItsOwn(.interrupted) }
        })
        for name in [UIApplication.protectedDataWillBecomeUnavailableNotification,
                     UIApplication.didEnterBackgroundNotification] {
            // queue: .main, so handle it now: after a lock the file key is gone within seconds.
            clip.observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopOnItsOwn(.interrupted) }
            })
        }
    }

    // MARK: - Shared teardown

    /// Stops the recorder, reads the bytes, deletes the file, gives the audio session and auto-lock back.
    private func finish(_ clip: ActiveClip) -> Data? {
        ticker?.cancel()
        ticker = nil
        // No delegate callback for a stop we asked for; it would only race with this teardown.
        clip.recorder?.delegate = nil
        clip.recorder?.stop()
        clip.recorder = nil
        let data = try? Data(contentsOf: clip.url)
        clip.release()   // deletes the file now, not at some later cleanup
        active = nil
        Self.releaseSession()
        UIApplication.shared.isIdleTimerDisabled = clip.idleTimerWasDisabled
        isRecording = false
        level = 0
        guard let data, !data.isEmpty else { return nil }
        return data
    }

    private func discardKeptClip() {
        keptClip = nil
    }

    /// A recorder that stopped itself at the cap resets currentTime to 0, so also trust the last tick's
    /// `elapsed`. Without this, tapping Stop right at 60 s would throw away the whole minute as "too short".
    private func recordedLength(_ clip: ActiveClip) -> TimeInterval {
        max(clip.recorder?.currentTime ?? 0, elapsed)
    }

    /// Lets music, VoiceOver and the next ElevenLabs call have the audio back, with the default haptics rule.
    private static func releaseSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(false)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// "begin_record": the short rising beep iOS's own camera plays when it starts recording.
    private static let beginRecordingSound: SystemSoundID = 1113

    /// Plain words for a session that wouldn't start. A call or Siri holding the mic is the usual reason.
    private static func sessionErrorMessage(_ error: Error) -> String {
        switch AVAudioSession.ErrorCode(rawValue: (error as NSError).code) {
        case .insufficientPriority, .cannotInterruptOthers, .siriIsRecording:
            return "I can't use the microphone while a phone call or Siri is using it. Please end it and tap the button again."
        default:
            return "I can't use the microphone right now. Please wait a moment, then tap the button again."
        }
    }

    /// Deletes clips a crash, jetsam or force-quit left in tmp (none of those runs our cleanup), but never one
    /// that is recording now. Called by init and start(); also safe to call once at app launch.
    nonisolated static func removeLeftoverClips() {
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path) else { return }
        let leftovers = names.filter { $0.hasPrefix(ActiveClip.prefix) && $0.hasSuffix("." + ActiveClip.ext) }
        guard !leftovers.isEmpty else { return }
        // Under the lock, so a clip being created right now can't be mistaken for a leftover.
        ActiveClip.inUse.withLock { live in
            let dir = FileManager.default.temporaryDirectory
            for name in leftovers where !live.contains(name) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    // MARK: - Meter and clock (~10x a second)

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard self?.tick() == true else { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Returns false when there is nothing left to watch.
    private func tick() -> Bool {
        guard isRecording, let recorder = active?.recorder else { return false }
        guard recorder.isRecording else {
            // Paused by a call, or just hit the cap: the notification or delegate normally arrives within a tick.
            // If neither has after about a second (something else deactivated the session), stop here and keep
            // the clip, so the screen can't sit on "Tap to stop" with a frozen clock and no 60 s cap.
            stalledTicks += 1
            guard stalledTicks >= 10 else { return true }
            log.notice("recorder stopped without a notification")
            stopOnItsOwn(elapsed >= maxDuration - 0.5 ? .limit : .interrupted)
            return false
        }
        stalledTicks = 0
        recorder.updateMeters()
        // averagePower is -160...0 dB; speech sits roughly in -50...0, so map that range to 0...1.
        let db = max(-50, min(0, recorder.averagePower(forChannel: 0)))
        let target = (db + 50) / 50
        // Smoothed so the meter moves calmly instead of flickering.
        level = level * 0.6 + target * 0.4
        elapsed = min(recorder.currentTime, maxDuration)
        return true
    }

    // MARK: - AVAudioRecorderDelegate

    // finish() clears the delegate before any stop we ask for, so a finish here is the recorder stopping
    // itself at the 60 s cap (record(forDuration:)).
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor in self.recorderFinished(id: id, ok: flag) }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor in self.recorderFailed(id: id) }
    }

    private func recorderFinished(id: ObjectIdentifier, ok: Bool) {
        guard let current = active?.recorder, ObjectIdentifier(current) == id else { return }
        if ok {
            stopOnItsOwn(.limit)
        } else {
            recorderFailed(id: id)
        }
    }

    private func recorderFailed(id: ObjectIdentifier) {
        guard let clip = active, let current = clip.recorder, ObjectIdentifier(current) == id else { return }
        _ = finish(clip)   // a broken file isn't worth sending
        lastError = "Something went wrong with the recording. Please tap the button and try again."
        log.error("recorder encode error")
    }
}

private enum RecorderFailure: Error { case prepare, record }

/// Everything one recording holds that must be given back: the temp file, the recorder writing it and the
/// notification observers. Its own class so its deinit still deletes the file if VoiceClipRecorder is released
/// mid-recording (a @MainActor class's deinit can't safely reach its main-actor state).
private final class ActiveClip {
    static let prefix = "kairos-clip-"
    static let ext = "m4a"
    /// File names of clips this process is recording, so leftover cleanup never deletes a live one.
    /// A lock, not the main actor: release() can run from deinit on any thread.
    static let inUse = OSAllocatedUnfairLock(initialState: Set<String>())

    let url: URL
    var recorder: AVAudioRecorder?
    var observers: [NSObjectProtocol] = []
    var idleTimerWasDisabled = false
    private var released = false

    init(url: URL) {
        self.url = url
        let name = url.lastPathComponent
        Self.inUse.withLock { _ = $0.insert(name) }
    }

    /// Stops the recorder, drops the observers and deletes the file. Safe to call more than once.
    func release() {
        guard !released else { return }
        released = true
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        try? FileManager.default.removeItem(at: url)
        let name = url.lastPathComponent
        Self.inUse.withLock { _ = $0.remove(name) }
    }

    deinit {
        guard !released else { return }
        release()
        // Only reached if the owner vanished mid-recording: hand the audio and auto-lock back to the system.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let restore = idleTimerWasDisabled
        Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = restore }
    }
}
