import AVFoundation
import os
import SwiftUI
import UIKit

// Kairos Communications Bridge: the "Write for me" screen and the draft card.
// The rules this file keeps (research/Kairos-Server-Architecture.md, "The Communications Bridge"):
//  * Only ref, alias, relation and language go to the server. Numbers and emails stay in PeopleStore.
//  * The text on the card is the text approved: Send approves exactly this version and its text_hash,
//    and the hand-off is refused if the server's stored text is not the text on screen.
//  * Nothing is sent from here. HandOffCoordinator opens WhatsApp / Messages / Mail and the person taps Send there.
//  * A practice draft is made up on the phone, not from what they said, so it never opens a real person's chat.
//  * The ElevenLabs call ends before we record, before we read aloud and before another app opens (endCall).
//  * Logs carry step names, versions and error kinds only: never message text, names or numbers.

private let cardLog = Logger(subsystem: "uk.oxhack.tempo", category: "bridge.card")

// MARK: - look

/// The app's calm palette (ContentView), with fixed text colours so nothing turns white-on-white in dark mode.
private enum WriteLook {
    static let background = Color(red: 0.96, green: 0.95, blue: 0.92)
    static let green = Color(red: 0.18, green: 0.44, blue: 0.37)
    static let ink = Color(red: 0.11, green: 0.11, blue: 0.10)
    static let body = Color(red: 0.25, green: 0.25, blue: 0.23)
    static let muted = Color(red: 0.33, green: 0.33, blue: 0.31)       // still above 4.5:1 on the background
    static let grey = Color(red: 0.85, green: 0.85, blue: 0.82)
    static let border = Color(red: 0.78, green: 0.77, blue: 0.73)
    static let stop = Color(red: 0.66, green: 0.15, blue: 0.11)        // white on this is well above 4.5:1
    static let amber = Color(red: 0.60, green: 0.35, blue: 0.0)
    static let noteFill = Color(red: 1.0, green: 0.95, blue: 0.74)
    static let noteEdge = Color(red: 0.80, green: 0.62, blue: 0.10)
    static let noteInk = Color(red: 0.33, green: 0.24, blue: 0.0)
    static let problemFill = Color(red: 0.99, green: 0.91, blue: 0.90)
    static let problemInk = Color(red: 0.62, green: 0.13, blue: 0.10)
    static let practiceFill = Color(red: 0.88, green: 0.91, blue: 0.99)
    static let practiceInk = Color(red: 0.13, green: 0.22, blue: 0.52)

    /// Never smaller than these sizes (already the floor for older eyes), but they grow with Larger Text.
    /// Capped at 1.3x so the pinned Send bar can't take over a small phone's screen.
    @MainActor static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let traits = UITraitCollection(preferredContentSizeCategory: UIApplication.shared.preferredContentSizeCategory)
        let grown = UIFontMetrics(forTextStyle: .body).scaledValue(for: size, compatibleWith: traits)
        return .system(size: min(max(grown, size), size * 1.3), weight: weight, design: .rounded)
    }

    /// Generic symbols, not brand logos (same as the People screens).
    static func icon(_ channel: BridgeChannel) -> String {
        switch channel {
        case .whatsapp: return "phone.bubble.fill"
        case .sms: return "message.fill"
        case .email: return "envelope.fill"
        case .telegram: return "paperplane.fill"
        case .signal: return "bubble.left.and.bubble.right.fill"
        }
    }

    /// VoiceOver users can't see a new step or a problem appear, so say it.
    @MainActor static func announce(_ sentence: String) {
        guard !sentence.isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: sentence)
    }
}

/// One big, full-width button face. Every target is at least 64 pt tall.
private struct WriteButtonLabel: View {
    let title: String
    var systemImage: String?
    var fill: Color = WriteLook.green
    var ink: Color = .white
    var size: CGFloat = 28
    var height: CGFloat = 76
    var outlined = false

    var body: some View {
        Group {
            if let systemImage { Label(title, systemImage: systemImage) } else { Text(verbatim: title) }
        }
        .font(WriteLook.font(size, .bold))
        .multilineTextAlignment(.center)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: height)
        .background(fill, in: RoundedRectangle(cornerRadius: 22))
        .foregroundStyle(ink)
        .overlay {
            if outlined { RoundedRectangle(cornerRadius: 22).stroke(ink, lineWidth: 2) }
        }
        .contentShape(RoundedRectangle(cornerRadius: 22))
    }
}

// MARK: - words on the card

/// Plain sentences for what the server's checks found. Kinds are fixed codes; values are shown, never logged.
/// Card wording, shared by Write for me and the in-call card (InCallBridge), so both say the same thing.
enum CardWords {
    static func kindName(_ kind: String) -> String {
        switch kind.lowercased() {
        case "time": return "Time"
        case "date": return "Date"
        case "number": return "Number"
        case "money": return "Money"
        case "url", "link": return "Web link"
        case "phone": return "Phone number"
        case "email": return "Email address"
        case "iban", "account": return "Bank account number"
        case "sort_code", "sortcode": return "Sort code"
        case "health": return "Health"
        case "legal": return "Legal"
        case "work": return "Work"
        case "name": return "Name"
        case "upi_id", "upi": return "UPI ID"
        case "card_number": return "Card number"
        case "possible_link": return "Possible link"
        case "compose_failed": return "Not rewritten"
        default:
            let words = kind.replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }

    /// The topics that need an extra tap, as they'd be said in a sentence ("about money").
    static func topicPhrase(_ kind: String) -> String? {
        switch kind.lowercased() {
        case "money": return "money"
        case "health": return "health"
        case "legal": return "a legal matter"
        case "work": return "work"
        default: return nil
        }
    }

    static func flagSentence(_ flag: BridgeFlag) -> String {
        if let special = specialSentence(flag) { return special }
        let value = flag.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.isEmpty {
            if let topic = topicPhrase(flag.kind) { return "This message is about \(topic)." }
            return "Please check the \(kindName(flag.kind).lowercased()) in this message."
        }
        let what = kindName(flag.kind)
        switch flag.in_transcript {
        case true?: return "\(what): \(value) – you said this."
        case false?: return "\(what): \(value) – please check it. I didn't hear you say this."
        case nil: return "\(what): \(value) – please check it."
        }
    }

    /// One line of the "Before you send" question for a value they never said ("The time 6 – you didn't say this.").
    static func unheardSentence(_ flag: BridgeFlag) -> String {
        if let special = specialSentence(flag) { return special }
        let value = flag.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let what = kindName(flag.kind).lowercased()
        return value.isEmpty ? "Please check the \(what). You didn't say it." : "The \(what) \(value) – you didn't say this."
    }

    /// Flags that aren't "a value you didn't say" and need their own plain sentence.
    static func specialSentence(_ flag: BridgeFlag) -> String? {
        let value = flag.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch flag.kind.lowercased() {
        case "possible_link":
            return value.isEmpty ? "Check this before sending: it may be a link you didn't say."
                                 : "Check this before sending: \"\(value)\" may be a link you didn't say."
        case "compose_failed":
            return "This is what you said, not rewritten or translated."
        default: return nil
        }
    }

    /// The sensitive topics, from the hub's risk list (and any topic flags): "money and health".
    static func topics(_ d: BridgeDraft) -> [String] {
        let kinds = (d.checks.risk ?? []) + d.checks.flags.map(\.kind)
        return Array(Set(kinds.compactMap { topicPhrase($0) })).sorted()
    }

    /// Every line of "Before you send", for both cards (the recipient question is added by the caller).
    static func beforeSendLines(_ d: BridgeDraft) -> [String] {
        var lines: [String] = []
        let t = topics(d)
        if !t.isEmpty { lines.append("This message is about \(joined(t)).") }
        // Each value they never said, and each special flag, gets its own line.
        lines += d.checks.flags.filter { $0.in_transcript == false || specialSentence($0) != nil }.map(unheardSentence)
        let missing = cleaned(d.missing)
        if !missing.isEmpty { lines.append("You didn't say: \(missing.joined(separator: ", ")).") }
        return lines
    }

    static func blockedSentence(_ flag: BridgeFlag) -> String {
        // The practice server marks its made-up sample this way: say what it is, not "Practice".
        if ["practice", "sample"].contains(flag.kind.lowercased()) {
            return "This is a made-up practice message, not what you said"
        }
        let value = flag.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? kindName(flag.kind) : "\(kindName(flag.kind)): \(value)"
    }

    /// "money and health", "money, health and work".
    static func joined(_ parts: [String]) -> String {
        guard parts.count > 1, let last = parts.last else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + last
    }

    /// The language they spoke (the back-translation is in it), or nil when the code isn't one we name.
    static func spokenLanguage(_ code: String?) -> String? {
        guard let c = code?.lowercased(), !c.isEmpty else { return nil }
        func isLang(_ l: String) -> Bool { c == l || c.hasPrefix(l + "-") || c.hasPrefix(l + "_") }
        if isLang("en") { return "English" }
        if isLang("te") { return "Telugu" }
        if isLang("hi") { return "Hindi" }
        if isLang("cy") { return "Welsh" }
        return nil
    }

    static func cleaned(_ items: [String]) -> [String] {
        items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

// MARK: - reading the message aloud

/// "Say it again": the Mac's recording of the exact text when there is one, otherwise the phone's own voice
/// speaking exactly `draft.text`. Use it only when no ElevenLabs call owns the audio session (end the call first).
@MainActor
final class DraftSpeaker: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    /// Waiting for the Mac's recording.
    @Published private(set) var isFetching = false

    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()
    private var utterance: AVSpeechUtterance?
    /// One recording per exact version, in memory only, so "Say it again" twice doesn't ask the Mac twice.
    private var cached: (key: String, audio: Data)?
    private var fetches = 0

    override init() {
        super.init()
        synth.delegate = self
    }

    /// The phone voice for a person's language code: te-* -> te-IN, hi-* -> hi-IN, cy -> cy-GB, else en-GB.
    nonisolated static func voiceLanguage(_ code: String) -> String {
        let c = code.lowercased()
        func isLang(_ l: String) -> Bool { c == l || c.hasPrefix(l + "-") || c.hasPrefix(l + "_") }
        if isLang("te") { return "te-IN" }
        if isLang("hi") { return "hi-IN" }
        if isLang("cy") { return "cy-GB" }
        return "en-GB"
    }

    /// Reads this exact version. Returns a sentence to show (can't read it, or the volume is low), else nil.
    func read(_ draft: BridgeDraft, language: String, api: any BridgeAPI) async -> String? {
        stop()
        var audio = cached?.key == draft.id ? cached?.audio : nil
        if audio == nil {
            fetches += 1
            let mine = fetches
            isFetching = true
            // Any failure (no Mac, no voice for this draft) just means the phone's own voice reads it.
            audio = try? await api.readback(draftId: draft.draft_id)
            // A newer "Say it again" may have started meanwhile; only the latest one owns the flag.
            if fetches == mine { isFetching = false }
            if Task.isCancelled { return nil }
            if let audio { cached = (draft.id, audio) }
        }
        if let audio, play(audio) { return volumeNote() }
        return speak(draft.text, language: language, meaning: draft.back_translation)
    }

    func stop() {
        player?.stop()
        player = nil
        utterance = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        if isSpeaking {
            isSpeaking = false
            releaseSession()
        }
    }

    /// Stops and drops the cached recording (the card is closing).
    func forget() {
        stop()
        cached = nil
    }

    private func play(_ audio: Data) -> Bool {
        guard let p = try? AVAudioPlayer(data: audio, fileTypeHint: AVFileType.mp3.rawValue) else { return false }
        activateSession()
        p.delegate = self
        player = p
        guard p.play() else {
            player = nil
            releaseSession()
            return false
        }
        isSpeaking = true
        return true
    }

    private func speak(_ text: String, language: String, meaning: String?) -> String? {
        let wanted = Self.voiceLanguage(language)
        var voice = AVSpeechSynthesisVoice(language: wanted)
        var spoken = text
        var note: String?
        if voice == nil {
            // An English voice can still read Welsh, or Telugu in English letters, well enough to check it.
            // It can't read Telugu or Devanagari letters at all. For someone who can't easily read the screen,
            // the meaning in their own words is far better than silence.
            if Self.usesIndicLetters(text) {
                let word = Self.languageWord(wanted)
                let meaning = meaning?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !meaning.isEmpty, !Self.usesIndicLetters(meaning) else {
                    return "This iPhone has no \(word) voice yet, so I can't read it out loud. Please read it on the screen, or ask someone to read it with you."
                }
                spoken = "I can't read \(word) out loud. Here is what it means. " + meaning
                note = "This iPhone has no \(word) voice, so I read out what the message means instead. The \(word) message on the screen is the one that will be sent."
            }
            voice = AVSpeechSynthesisVoice(language: "en-GB")
        }
        activateSession()
        let u = AVSpeechUtterance(string: spoken)
        u.voice = voice
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9   // a little slower for older ears
        utterance = u
        isSpeaking = true
        synth.speak(u)
        return note ?? volumeNote()
    }

    /// Media volume is separate from the ringer and often near zero: with mild hearing loss they would hear
    /// nothing and think there was nothing to check.
    private func volumeNote() -> String? {
        guard AVAudioSession.sharedInstance().outputVolume < 0.4 else { return nil }
        return "Your sound is turned down. Press the volume up button on the left side of the phone a few times, then tap Say it again."
    }

    private static func usesIndicLetters(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0900...0x0DFF).contains($0.value) }
    }

    private static func languageWord(_ voice: String) -> String {
        switch voice {
        case "te-IN": return "Telugu"
        case "hi-IN": return "Hindi"
        case "cy-GB": return "Welsh"
        default: return "English"
        }
    }

    /// .playback ignores the silent switch: many older people leave it on by accident.
    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        // As in VoiceClipRecorder.start(): never change category and mode under another engine's running I/O
        // (LiveKit's prepared microphone); release the session first. A no-op when it isn't active.
        try? session.setActive(false)
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
    }

    private func releaseSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // Callbacks carry the identity of what finished, so a late "cancelled" from a stopped reading
    // can't switch off a new one that has just started.
    fileprivate func playerFinished(_ id: ObjectIdentifier) {
        guard let p = player, ObjectIdentifier(p) == id else { return }
        player = nil
        isSpeaking = false
        releaseSession()
    }

    fileprivate func utteranceFinished(_ id: ObjectIdentifier) {
        guard let u = utterance, ObjectIdentifier(u) == id else { return }
        utterance = nil
        isSpeaking = false
        releaseSession()
    }
}

extension DraftSpeaker: AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in self.playerFinished(id) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in self.playerFinished(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceFinished(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceFinished(id) }
    }
}

// MARK: - Write for me

/// Pick a person, say the message, check the card, send it from their own app.
/// Present it as a sheet or full-screen cover; it needs `.environmentObject(PeopleStore)`.
/// `endCall` must not return until the ElevenLabs session has really ended (it is called before recording).
struct WriteForMeView: View {
    let api: any BridgeAPI
    let endCall: () async -> Void
    let onClose: () -> Void

    @EnvironmentObject var people: PeopleStore
    @StateObject private var recorder = VoiceClipRecorder()
    @StateObject private var handOff = HandOffCoordinator()
    @StateObject private var speaker = DraftSpeaker()

    private enum Step: Equatable {
        case pickPerson, record, drafting, card
        case problem(message: String, unclear: Bool)
    }

    /// What the contact picker returned, held until its sheet has gone so the editor sheet can open.
    private struct PickedContact: Identifiable {
        let id = UUID()
        let name: String
        let phones: [LabeledPhone]
        let emails: [String]
    }

    /// The big question on top of the card.
    private enum Ask: Equatable { case send, throwAway }

    /// Why a recording waits on the record screen instead of being written up straight away.
    private enum Held: Equatable {
        case short(seconds: Int)   // under 3 s: often a slip of the finger, so ask first
        case cancelled             // they tapped Cancel while it was being written
    }

    @State private var step: Step = .pickPerson
    @State private var person: KairosPerson?
    @State private var draft: BridgeDraft?
    @State private var practice = false
    /// The recording, kept in memory only until a draft arrives, so "Try again" after a network error
    /// doesn't make them say it all again.
    @State private var clip: Data?
    @State private var held: Held?
    @State private var working = false
    @State private var starting = false
    /// Information at the top of the card (no voice for this language, volume low).
    @State private var notice: String?
    /// Send or a change failed: shown right above Send, where the person is looking, not at the top.
    @State private var problem: String?
    /// The Mac holds something other than this card (409, or different stored text) and we have no newer
    /// copy to show, so Send becomes "Start again".
    @State private var stale = false
    @State private var asking: Ask?
    @State private var showPicker = false
    @State private var picked: PickedContact?
    @State private var newContact: PickedContact?
    @State private var showPeople = false
    @State private var work: Task<Void, Never>?
    @State private var reading: Task<Void, Never>?
    @State private var starter: Task<Void, Never>?
    /// Handed off or sent: the draft must not be cancelled (purged) on the Mac after that.
    @State private var delivered = false
    @State private var closed = false

    init(api: any BridgeAPI, endCall: @escaping () async -> Void, onClose: @escaping () -> Void) {
        self.api = api
        self.endCall = endCall
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            WriteLook.background.ignoresSafeArea()
            content
                // A VoiceOver swipe must never get from a question or result onto the old card's Send.
                .accessibilityHidden(asking != nil || handOffOver || handOff.isBusy)
            if let asking { askPanel(asking).zIndex(2) }
            // Always in the tree so the Messages / Mail / share sheets have a view to hang from.
            // Its own result card is replaced by ours (with Done), so hide it from VoiceOver then.
            HandOffOverlay(coordinator: handOff)
                .accessibilityHidden(handOffOver)
                .zIndex(3)
            if handOffOver { resultPanel.zIndex(4) }
        }
        .environment(\.colorScheme, .light)
        // A stray swipe mustn't throw away a recording or a message being checked.
        .interactiveDismissDisabled(step != .pickPerson)
        .sheet(isPresented: $showPeople) { managePeople }
        .sheet(isPresented: $showPicker, onDismiss: {
            // Only now: SwiftUI can't open the editor while the picker sheet is still going away.
            if let c = picked { picked = nil; newContact = c }
        }) {
            ContactPicker(onPick: { name, phones, emails in
                picked = PickedContact(name: name, phones: phones, emails: emails)
                showPicker = false
            }, onCancel: { showPicker = false })
            .ignoresSafeArea()
        }
        .sheet(item: $newContact) { c in
            // Labelled numbers ("Mobile: 07700 900123"), so the editor can show which is which and pick the
            // mobile for WhatsApp / texts. `existing` lets it warn about a name like someone already saved.
            PersonEditor(contactName: c.name, phones: c.phones, emails: c.emails, existing: people.people, onSave: { p in
                people.add(p)
                choose(p)
            })
        }
        .onChange(of: recorder.lastError) { _, message in
            if let message { WriteLook.announce(message) }
        }
        .onChange(of: recorder.hasKeptClip) { _, kept in
            if kept { WriteLook.announce(autoStopSentence + " Tap Write my message, or Record it again.") }
        }
        .onChange(of: handOff.state) { _, state in
            switch state {
            case .countingDown: stopReading()   // nothing may keep talking once another app is opening
            case .done(let outcome): if outcome == .handedOff || outcome == .sent { delivered = true }
            default: break
            }
        }
        // UIBackgroundModes includes audio, so a reading would otherwise carry on behind WhatsApp.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            stopReading()
        }
        .onDisappear { shutDown() }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .pickPerson: screen(pickPersonStep)
        case .record: screen(recordStep)
        case .drafting: draftingStep
        case .card: cardStep
        case .problem(let message, let unclear): screen(problemStep(message, unclear: unclear))
        }
    }

    private func screen<Inner: View>(_ inner: Inner) -> some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                inner
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)
            }
        }
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Write for me")
                .font(WriteLook.font(32, .bold))
                .foregroundStyle(WriteLook.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button { closeTapped() } label: {
                Text("Close")
                    .font(WriteLook.font(24, .bold))
                    .foregroundStyle(WriteLook.ink)
                    .padding(.horizontal, 20)
                    .frame(minWidth: 96, minHeight: 60)
                    .background(WriteLook.grey, in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Closes Write for me. Nothing is sent.")
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: step 1: who is it for?

    private var sortedPeople: [KairosPerson] {
        people.people.sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
    }

    private var pickPersonStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Who is it for?")
                .font(WriteLook.font(30, .bold))
                .foregroundStyle(WriteLook.ink)
                .accessibilityAddTraits(.isHeader)
            if api.isPractice { practiceNote }
            if sortedPeople.isEmpty {
                Text("You haven't added anyone yet. Tap Choose from Contacts to pick the person you want to write to.")
                    .font(WriteLook.font(22))
                    .foregroundStyle(WriteLook.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(sortedPeople) { p in personButton(p) }
            Button { showPicker = true } label: {
                WriteButtonLabel(title: sortedPeople.isEmpty ? "Choose from Contacts" : "Someone else",
                                 systemImage: "person.crop.circle.badge.plus",
                                 fill: .white, ink: WriteLook.green, size: 26, outlined: true)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Pick them from your contacts")
            Button { showPeople = true } label: {
                Label("Manage people", systemImage: "person.2.fill")
                    .font(WriteLook.font(22, .semibold))
                    .foregroundStyle(WriteLook.green)
                    .underline()
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Add, change or remove the people Kairos writes to")
        }
        .padding(.top, 4)
    }

    private func subtitle(_ p: KairosPerson) -> String {
        let relation = (p.relation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !relation.isEmpty else { return p.channel.appName }
        return relation.prefix(1).uppercased() + relation.dropFirst() + " · " + p.channel.appName
    }

    /// Names a tired eye can mix up (Amma and Anna sort next to each other): their relation is then shown as
    /// large as the name, so the name isn't the only thing telling them apart.
    private func looksLikeSomeoneElse(_ p: KairosPerson) -> Bool {
        let mine = PeopleStore.normaliseName(p.alias)
        return people.people.contains {
            $0.ref != p.ref && PeopleStore.levenshtein(mine, PeopleStore.normaliseName($0.alias)) <= 2
        }
    }

    private func personButton(_ p: KairosPerson) -> some View {
        let confusable = looksLikeSomeoneElse(p)
        return Button { choose(p) } label: {
            HStack(spacing: 16) {
                Image(systemName: WriteLook.icon(p.channel))
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(WriteLook.green)
                    .frame(width: 46)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: p.alias)
                        .font(WriteLook.font(30, .bold))
                        .foregroundStyle(WriteLook.ink)
                    Text(verbatim: subtitle(p))
                        .font(confusable ? WriteLook.font(30, .bold) : WriteLook.font(22))
                        .foregroundStyle(confusable ? WriteLook.ink : WriteLook.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(WriteLook.body)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(WriteLook.border, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(p.alias), \(subtitle(p))"))
        .accessibilityHint(Text(verbatim: "Write a message to \(p.recipientLine)"))
    }

    private var managePeople: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { showPeople = false } label: {
                    Text("Done")
                        .font(WriteLook.font(24, .bold))
                        .foregroundStyle(WriteLook.green)
                        .frame(minWidth: 100, minHeight: 60)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Goes back to choosing who to write to")
            }
            .padding(.horizontal, 12)
            PeopleListView()
        }
        .background(WriteLook.background.ignoresSafeArea())
        .environmentObject(people)
        .environment(\.colorScheme, .light)
    }

    private var practiceNote: some View {
        Label {
            Text("Practice mode. Kairos isn't connected to your Mac, so nothing you write here is sent to anyone.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "graduationcap.fill")
        }
        .font(WriteLook.font(22, .semibold))
        .foregroundStyle(WriteLook.practiceInk)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WriteLook.practiceFill, in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: step 2: say it

    private var recordStep: some View {
        VStack(spacing: 22) {
            if let p = person {
                Text(verbatim: "Your message for \(p.recipientLine)")
                    .font(WriteLook.font(30, .bold))
                    .foregroundStyle(WriteLook.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            // Honest about the 60 s cap: a promise not to cut them off would be broken at one minute.
            Text("Take your time. It's fine to pause. You can talk for up to one minute.")
                .font(WriteLook.font(24, .semibold))
                .foregroundStyle(WriteLook.body)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if recorder.hasKeptClip {
                keptClipPanel
            } else if let held, clip != nil {
                heldClipPanel(held)
            } else {
                recordButton
                clockAndMeter
            }
            if let error = recorder.lastError, !recorder.hasKeptClip, held == nil {
                problemBox(error)
                if recorder.permissionDenied {
                    Button { recorder.openSettings() } label: {
                        WriteButtonLabel(title: "Open Settings", systemImage: "gearshape.fill", fill: .white,
                                         ink: WriteLook.green, size: 26, height: 72, outlined: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens Kairos in Settings. Turn on Microphone, then come back.")
                }
            }
            if api.isPractice && !recorder.isRecording { practiceNote }
            if !recorder.isRecording && !starting && !recorder.hasKeptClip && held == nil {
                Button {
                    recorder.cancel()
                    clip = nil
                    person = nil
                    step = .pickPerson
                } label: {
                    WriteButtonLabel(title: "Choose someone else", fill: .white, ink: WriteLook.ink, size: 24,
                                     height: 64, outlined: true)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }

    private var recordButton: some View {
        let live = recorder.isRecording
        return Button { toggleRecording() } label: {
            ZStack {
                Circle()
                    .fill(live ? WriteLook.stop : WriteLook.green)
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                VStack(spacing: 10) {
                    Image(systemName: live ? "stop.fill" : "mic.fill")
                        .font(.system(size: 64, weight: .bold))
                    Text(live ? "Tap to stop" : (starting ? "Getting ready…" : "Tap to start"))
                        .font(WriteLook.font(28, .bold))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 20)
                }
                .foregroundStyle(.white)
            }
            .frame(width: 250, height: 250)
            .opacity(starting ? 0.7 : 1)
        }
        .buttonStyle(.plain)
        .disabled(starting)
        .accessibilityLabel(live ? "Stop recording" : "Start recording")
        .accessibilityHint(live ? "Kairos will write your message from what you said" : "Then say your message")
    }

    private var clockAndMeter: some View {
        VStack(spacing: 12) {
            Text(verbatim: "\(Self.clock(recorder.elapsed)) / \(Self.clock(recorder.maxDuration))")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(WriteLook.ink)
                .accessibilityLabel(Text(verbatim: "\(Self.spokenDuration(recorder.elapsed)) so far, of up to one minute"))
                .accessibilityAddTraits(.updatesFrequently)
            LevelMeter(level: recorder.isRecording ? recorder.level : 0)
                .frame(height: 22)
                .padding(.horizontal, 30)
                .accessibilityHidden(true)
            if recorder.isRecording && recorder.remaining <= 10 {
                Text(verbatim: "\(Int(recorder.remaining.rounded(.up))) seconds left")
                    .font(WriteLook.font(24, .bold))
                    .foregroundStyle(WriteLook.amber)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    private var autoStopSentence: String {
        recorder.reachedLimit ? "That's the full minute." : "The recording stopped."
    }

    /// The 60 s cap or a phone call stopped it. Nothing goes anywhere until they choose.
    private var keptClipPanel: some View {
        VStack(spacing: 16) {
            Image(systemName: recorder.reachedLimit ? "hourglass" : "pause.circle.fill")
                .font(.system(size: 54, weight: .bold))
                .foregroundStyle(WriteLook.green)
                .accessibilityHidden(true)
            Text(verbatim: autoStopSentence)
                .font(WriteLook.font(30, .bold))
                .foregroundStyle(WriteLook.ink)
                .multilineTextAlignment(.center)
            Text(verbatim: "You spoke for \(Self.spokenDuration(recorder.elapsed)). I kept what you said.")
                .font(WriteLook.font(22))
                .foregroundStyle(WriteLook.body)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { useKeptClip() } label: {
                WriteButtonLabel(title: "Write my message", systemImage: "pencil")
            }
            .buttonStyle(.plain)
            Button { recordAgain() } label: {
                WriteButtonLabel(title: "Record it again", fill: .white, ink: WriteLook.ink, size: 24, height: 64,
                                 outlined: true)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .background(.white, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .contain)
    }

    private func heldWords(_ held: Held) -> (question: String, yes: String, no: String) {
        switch held {
        case .short(let seconds):
            let said = seconds == 1 ? "1 second" : "\(seconds) seconds"
            return ("You spoke for \(said). Write my message from that?", "Yes, write my message", "Say it again")
        case .cancelled:
            return ("I stopped writing. Nothing was sent, and I kept what you said.", "Write my message",
                    "Record it again")
        }
    }

    /// A clip we are holding (very short, or writing was cancelled): nothing is written until they choose.
    private func heldClipPanel(_ held: Held) -> some View {
        let words = heldWords(held)
        return VStack(spacing: 16) {
            Image(systemName: "questionmark.bubble.fill")
                .font(.system(size: 54, weight: .bold))
                .foregroundStyle(WriteLook.green)
                .accessibilityHidden(true)
            Text(verbatim: words.question)
                .font(WriteLook.font(30, .bold))
                .foregroundStyle(WriteLook.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { useHeldClip() } label: {
                WriteButtonLabel(title: words.yes, systemImage: "pencil")
            }
            .buttonStyle(.plain)
            Button { recordAgain() } label: {
                WriteButtonLabel(title: words.no, fill: .white, ink: WriteLook.ink, size: 24, height: 64,
                                 outlined: true)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .background(.white, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .contain)
    }

    private func problemBox(_ message: String) -> some View {
        Label {
            Text(verbatim: message).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.circle.fill")
        }
        .font(WriteLook.font(22, .semibold))
        .foregroundStyle(WriteLook.problemInk)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WriteLook.problemFill, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: step 3: writing it

    private var draftingStep: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            ProgressView()
                .controlSize(.large)
                .tint(WriteLook.green)
                .scaleEffect(1.5)
                .accessibilityHidden(true)
            Text(verbatim: "Writing your message for \(person?.recipientLine ?? "them")…")
                .font(WriteLook.font(30, .bold))
                .foregroundStyle(WriteLook.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("This can take a little while.")
                .font(WriteLook.font(22))
                .foregroundStyle(WriteLook.body)
            Spacer(minLength: 0)
            Button { cancelDrafting() } label: {
                WriteButtonLabel(title: "Cancel", fill: WriteLook.grey, ink: WriteLook.ink, size: 26, height: 68)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Stops writing. Nothing is sent, and what you said is kept.")
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func problemStep(_ message: String, unclear: Bool) -> some View {
        VStack(spacing: 20) {
            Image(systemName: unclear ? "questionmark.bubble.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 60, weight: .bold))
                .foregroundStyle(unclear ? WriteLook.green : WriteLook.amber)
                .padding(.top, 24)
                .accessibilityHidden(true)
            Text(verbatim: message)
                .font(WriteLook.font(30, .bold))
                .foregroundStyle(WriteLook.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if unclear {
                Text("Tap Try again and say your message once more.")
                    .font(WriteLook.font(22))
                    .foregroundStyle(WriteLook.body)
                    .multilineTextAlignment(.center)
            }
            Button { tryAgain(unclear: unclear) } label: {
                WriteButtonLabel(title: "Try again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            if !unclear && clip != nil {
                Button { recordAgain() } label: {
                    WriteButtonLabel(title: "Record it again", fill: .white, ink: WriteLook.ink, size: 24, height: 64,
                                     outlined: true)
                }
                .buttonStyle(.plain)
            }
            Button { close() } label: {
                WriteButtonLabel(title: "Close", fill: WriteLook.grey, ink: WriteLook.ink, size: 26, height: 68)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Nothing is sent")
        }
    }

    // MARK: step 4: the card

    @ViewBuilder private var cardStep: some View {
        if let d = draft, let p = person {
            DraftCardView(draft: d, person: currentTarget(p), isPractice: practice, isWorking: working,
                          isStale: stale, isSpeaking: speaker.isSpeaking || speaker.isFetching,
                          notice: notice, problem: problem,
                          onRevise: { revise($0) },
                          onSayAgain: { readAloud(auto: false) },
                          onStopReading: { stopReading() },
                          onSend: { send() },
                          onStartAgain: { startAgain() },
                          onCancel: { stopReading(); asking = .throwAway })
        }
    }

    // MARK: the big questions and the result

    private func askPanel(_ ask: Ask) -> some View {
        let title: String
        var lines: [String] = []
        let yes: String
        let no: String
        switch ask {
        case .send:
            title = "Before you send"
            if let d = draft { lines += CardWords.beforeSendLines(d) }
            if practice {
                lines.append("This is practice, so nothing will be sent.")
                yes = "Yes, try it"
            } else {
                lines.append("Send it\(person.map { " to \($0.recipientLine)" } ?? "")?")
                yes = "Yes, send it"
            }
            no = "No, go back"
        case .throwAway:
            title = "Throw this message away?"
            lines = ["Nothing will be sent."]
            yes = "Yes, throw it away"
            no = "No, keep it"
        }
        return ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}   // nothing behind the question can be pressed by accident
                .accessibilityHidden(true)
            GeometryReader { g in
                ScrollView {
                    VStack(spacing: 18) {
                        Text(verbatim: title)
                            .font(WriteLook.font(30, .bold))
                            .foregroundStyle(WriteLook.ink)
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(verbatim: line)
                                .font(WriteLook.font(24, .semibold))
                                .foregroundStyle(WriteLook.body)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button {
                            asking = nil
                            switch ask {
                            case .send: approveAndHandOff()
                            case .throwAway: close()
                            }
                        } label: {
                            WriteButtonLabel(title: yes, fill: ask == .throwAway ? WriteLook.stop : WriteLook.green,
                                             size: 28, height: 84)
                        }
                        .buttonStyle(.plain)
                        Button { asking = nil } label: {
                            WriteButtonLabel(title: no, fill: WriteLook.grey, ink: WriteLook.ink, size: 28, height: 84)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(24)
                    .background(.white, in: RoundedRectangle(cornerRadius: 28))
                    .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
                    .padding(18)
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(.isModal)
                    // Centred when it fits; scrolls when several unheard values make it taller than the screen.
                    .frame(maxWidth: .infinity, minHeight: g.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .onAppear { WriteLook.announce(([title] + lines).joined(separator: " ")) }
    }

    private var handOffOver: Bool {
        switch handOff.state {
        case .done, .failed, .practice: return true
        default: return false
        }
    }

    /// Replaces the overlay's own result and practice cards: same sentence, but with Done (closes Write for me)
    /// and, when nothing went out, a way back to the message.
    private var resultPanel: some View {
        var outcome: BridgeOutcome?
        var isPracticeResult = false
        switch handOff.state {
        case .done(let o): outcome = o
        case .practice: isPracticeResult = true
        default: break
        }
        let wentOut = outcome == .handedOff || outcome == .sent
        let icon = isPracticeResult ? "graduationcap.fill"
            : outcome == .sent ? "checkmark.circle.fill"
            : outcome == .handedOff ? "arrow.up.forward.app.fill" : "exclamationmark.circle.fill"
        let tint = isPracticeResult ? WriteLook.practiceInk : (wentOut ? WriteLook.green : WriteLook.amber)
        return VStack(spacing: 24) {
            Spacer(minLength: 0)
            Image(systemName: icon)
                .font(.system(size: 80, weight: .bold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(verbatim: handOff.resultText)
                .font(WriteLook.font(32, .bold))
                .foregroundStyle(WriteLook.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            // Practice too: nothing went anywhere, so going back to try a change is safe.
            if !wentOut && draft != nil {
                Button { handOff.reset() } label: {
                    WriteButtonLabel(title: "Back to my message", fill: .white, ink: WriteLook.green, size: 26,
                                     height: 72, outlined: true)
                }
                .buttonStyle(.plain)
            }
            Button { finish() } label: {
                WriteButtonLabel(title: "Done", fill: WriteLook.green, size: 32, height: 92)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Closes Write for me")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WriteLook.background.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    // MARK: actions

    private func choose(_ p: KairosPerson) {
        recorder.cancel()
        clip = nil
        held = nil
        notice = nil
        problem = nil
        stale = false
        person = p
        step = .record
    }

    /// The number and email as stored now (they may have changed in Manage people), with the channel
    /// this draft was written and approved for.
    private func currentTarget(_ p: KairosPerson) -> KairosPerson {
        var target = people.person(ref: p.ref) ?? p
        target.channel = p.channel
        return target
    }

    private func toggleRecording() {
        if recorder.isRecording {
            // A tremor's second tap lands inside the grace period: keep listening (the recorder ignores it too).
            if recorder.ignoresStopTap { return }
            guard let data = recorder.stop() else { return }   // nil: lastError says why
            if recorder.isShortClip {
                // A couple of seconds is often a slip of the finger: ask before writing anything from it.
                let short = Held.short(seconds: max(1, Int(recorder.elapsed)))
                clip = data
                held = short
                WriteLook.announce(heldWords(short).question)
                return
            }
            startDrafting(data)
            return
        }
        guard !starting else { return }
        starting = true
        stopReading()
        starter?.cancel()
        starter = Task {
            // No live ElevenLabs microphone while we record: it would hear the message, and the two would
            // fight over the one audio session.
            await endCall()
            if UIAccessibility.isVoiceOverRunning {
                // Said, and given time to finish, BEFORE recording, so VoiceOver's voice isn't in the message.
                WriteLook.announce("Recording in a moment. Start speaking after the beep.")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            // Closed while the call was ending: never switch the microphone on behind a screen that has gone.
            guard !Task.isCancelled else { starting = false; return }
            let started = await recorder.start()
            if started && Task.isCancelled { recorder.cancel() }
            starting = false
        }
    }

    private func useKeptClip() {
        guard let data = recorder.stop() else { return }
        startDrafting(data)
    }

    private func useHeldClip() {
        guard let clip else { held = nil; return }
        startDrafting(clip)
    }

    private func recordAgain() {
        work?.cancel()
        recorder.cancel()
        clip = nil
        held = nil
        notice = nil
        problem = nil
        step = person == nil ? .pickPerson : .record
    }

    private func tryAgain(unclear: Bool) {
        if !unclear, let clip { startDrafting(clip) } else { recordAgain() }
    }

    private func cancelDrafting() {
        work?.cancel()
        work = nil
        // Keep what they said: a mis-tapped Cancel shouldn't mean saying the whole message again.
        held = clip == nil ? nil : .cancelled
        step = .record
        if let held { WriteLook.announce(heldWords(held).question) }
    }

    /// Close from the record screen: a mis-tap mustn't throw away what they've just said without asking.
    private func closeTapped() {
        if recorder.isRecording || recorder.hasKeptClip || (step == .record && clip != nil) {
            asking = .throwAway
        } else {
            close()
        }
    }

    /// Only what the server may see: the ref, alias, relation and language, never the number or email.
    private static func meta(for p: KairosPerson) -> BridgeDraftMeta {
        let signOff = UserDefaults.standard.string(forKey: "kairos.signoff")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return BridgeDraftMeta(
            recipient: BridgeRecipient(ref: p.ref, alias: p.alias, relation: p.relation, lang: p.language),
            channel: p.channel.rawValue,
            tone: p.tone.rawValue,
            target_lang: p.language,
            user: signOff.isEmpty ? nil : ["sign_off": signOff],
            transcript: nil)
    }

    private func startDrafting(_ data: Data) {
        guard let p = person else { return }
        clip = data
        held = nil
        notice = nil
        problem = nil
        stale = false
        draft = nil
        step = .drafting
        WriteLook.announce("Writing your message for \(p.recipientLine).")
        let meta = Self.meta(for: p)
        work?.cancel()
        work = Task {
            do {
                let d = try await api.draft(audio: data, meta: meta)
                if Task.isCancelled { return }
                clip = nil   // not needed any more; don't keep their voice in memory
                // Per draft (FallbackBridgeAPI: true only if this one came from practice mode); either flag counts.
                practice = api.isPractice || api.isPracticeDraft(d.draft_id)
                show(d)
                step = .card
                cardLog.info("draft ready, version \(d.version, privacy: .public)")
                WriteLook.announce("Your message for \(p.recipientLine) is ready. Please read it before you send it.")
                readAloud(auto: true)
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                draftFailed(error)
            }
        }
    }

    private func draftFailed(_ error: Error) {
        cardLog.notice("draft failed: \(Self.code(error), privacy: .public)")
        let message: String
        switch error as? BridgeError {
        case .unclear(let ask)?:
            clip = nil   // they need to say it again, so the old recording is no use
            message = ask
            step = .problem(message: ask, unclear: true)
        case let bridgeError?:
            message = bridgeError.spoken
            step = .problem(message: message, unclear: false)
        case nil:
            message = "Something went wrong. Please try again."
            step = .problem(message: message, unclear: false)
        }
        WriteLook.announce(message)
    }

    /// Never step back to an older version than the one on screen (a slow answer arriving late).
    private func show(_ next: BridgeDraft) {
        if let current = draft, current.draft_id == next.draft_id, next.version < current.version { return }
        draft = next
    }

    private func revise(_ instruction: String) {
        guard let d = draft, let p = person, !working, !stale, !delivered, !handOff.isBusy else { return }
        stopReading()
        working = true
        notice = nil
        problem = nil
        let request = BridgeReviseRequest(version: d.version, chip: instruction)
        work = Task {
            defer { working = false }
            do {
                let next = try await api.revise(draftId: d.draft_id, request: request)
                if Task.isCancelled { return }
                show(next)
                cardLog.info("revised to version \(next.version, privacy: .public)")
                // VoiceOver users don't get the automatic reading, so the announcement carries the text itself.
                WriteLook.announce("Here is the new message for \(p.alias): " + next.text)
                readAloud(auto: true)
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                cardLog.notice("revise failed: \(Self.code(error), privacy: .public)")
                if case .staleOrMismatch? = error as? BridgeError { markStale(); return }
                showProblem((error as? BridgeError)?.spoken ?? "I couldn't change it. Please try again.")
            }
        }
    }

    /// Reads the exact text on the card. `auto` is the reading when a new version appears; it is skipped for
    /// VoiceOver users, whose own reader would otherwise talk over it.
    private func readAloud(auto: Bool) {
        guard let d = draft, let p = person else { return }
        if auto && UIAccessibility.isVoiceOverRunning { return }
        reading?.cancel()
        speaker.stop()
        notice = nil
        reading = Task {
            await endCall()   // the speaker and the audio session must be ours, not a live call's
            if Task.isCancelled { return }
            let note = await speaker.read(d, language: p.language, api: api)
            if Task.isCancelled { return }
            if let note {
                notice = note
                // Not over the reading itself: VoiceOver and the message would talk at once.
                if !speaker.isSpeaking { WriteLook.announce(note) }
            }
        }
    }

    private func stopReading() {
        reading?.cancel()
        reading = nil
        speaker.stop()
    }

    private func send() {
        guard let d = draft, !d.isBlocked, !working, !stale, !delivered, !handOff.isBusy else { return }
        stopReading()
        // Sensitive topics, a value they never said or a missing fact: one more clear "yes", with each named.
        // Asked BEFORE approve, so the 120 s approval clock isn't running while they think.
        if d.needsCheck {
            asking = .send
            return
        }
        approveAndHandOff()
    }

    private func approveAndHandOff() {
        guard let d = draft, let p = person, !d.isBlocked, !working, !stale, !delivered, !handOff.isBusy else { return }
        stopReading()
        notice = nil
        problem = nil
        // The practice draft is made up on the phone, not from what they said: never open a real person's chat.
        // Either flag counts, so a mixed-up badge can only ever err towards not sending.
        if practice || api.isPractice || api.isPracticeDraft(d.draft_id) {
            cardLog.info("practice draft: showing what would happen, nothing handed off")
            handOff.showPractice(person: currentTarget(p), channel: p.channel)
            return
        }
        working = true
        // Exactly the version and hash on screen: if anything changed, the server answers 409.
        let request = BridgeApproveRequest(version: d.version, text_hash: d.text_hash, recipient_ref: p.ref,
                                           channel: p.channel.rawValue, method: "tap")
        work = Task {
            defer { working = false }
            do {
                // Taken before asking: the server's nonce clock starts when it issues the nonce, so a clock
                // started on arrival could run past the server's and hand off on an expired nonce.
                let sentAt = Date()
                let approval = try await api.approve(draftId: d.draft_id, request: request)
                if Task.isCancelled { return }
                // The server's stored text is what gets handed off; it must be the text they read.
                guard approval.text == d.text else {
                    cardLog.error("approved text differs from the card; not handing off")
                    markStale("The message saved on your Mac is different from the one on your screen, so I didn't send it. Tap Start again and say it once more.")
                    return
                }
                // Number and email are read from the phone now, in case they were changed meanwhile.
                // The channel stays the one this draft was written and approved for.
                cardLog.info("approved; handing off on \(p.channel.rawValue, privacy: .public)")
                await handOff.begin(approval: approval, approvedAt: sentAt, person: currentTarget(p),
                                    channel: p.channel, draftId: d.draft_id, api: api, endCall: endCall)
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                approveFailed(error)
            }
        }
    }

    private func approveFailed(_ error: Error) {
        cardLog.notice("approve failed: \(Self.code(error), privacy: .public)")
        // Approve failed, so nothing was opened. Say so: "did it go?" is the first worry.
        guard let e = error as? BridgeError else {
            showProblem("Something went wrong, so nothing was sent. Please tap Send again.")
            return
        }
        switch e {
        case .staleOrMismatch: markStale()
        case .expired: showProblem("That took too long, so nothing was sent. Please tap Send again.")
        case .unreachable: showProblem(e.spoken)   // already says nothing was sent
        case .blocked: showProblem("Nothing was sent. " + e.spoken)
        default: showProblem(e.spoken + " Nothing was sent.")
        }
    }

    /// No GET for the latest version exists, so we can't show a newer one: don't pretend to. Send becomes
    /// "Start again" instead of a button that would only get the same 409 every time.
    private func markStale(_ message: String = "This message was changed somewhere else, so I can't send it. Tap Start again and say it once more.") {
        stopReading()
        stale = true
        showProblem(message)
    }

    private func showProblem(_ message: String) {
        problem = message
        // Felt as well as seen: they are looking at the Send button, perhaps not at the words.
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        WriteLook.announce(message)
    }

    /// "Start again" on a stale card: drop it (on the Mac too) and go back to recording for the same person.
    private func startAgain() {
        stopReading()
        work?.cancel()
        work = nil
        working = false
        if let d = draft, !delivered {
            let api = api
            let id = d.draft_id
            Task { await api.cancel(draftId: id) }
        }
        draft = nil
        stale = false
        problem = nil
        notice = nil
        clip = nil
        held = nil
        recorder.cancel()
        step = person == nil ? .pickPerson : .record
        if let p = person { WriteLook.announce("Say your message for \(p.recipientLine) once more.") }
    }

    /// Done on the result: the hand-off is over.
    private func finish() {
        handOff.reset()
        close()
    }

    private func close() {
        shutDown()
        onClose()
    }

    /// Stops everything this screen started. Safe to call twice (Close, then onDisappear).
    private func shutDown() {
        guard !closed else { return }
        closed = true
        starter?.cancel()
        work?.cancel()
        reading?.cancel()
        recorder.cancel()
        speaker.forget()
        handOff.stop()   // only acts during the countdown: nothing opens after Close
        clip = nil
        if let d = draft, !delivered {
            // Nothing went out, so ask the Mac to purge it. Returns at once; never holds up closing.
            let api = api
            let id = d.draft_id
            Task { await api.cancel(draftId: id) }
        }
    }

    // MARK: helpers

    private static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.down)))
        return "\(s / 60):" + (s % 60 < 10 ? "0" : "") + "\(s % 60)"
    }

    private static func spokenDuration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        if s >= 60 { return "a full minute" }
        return s == 1 ? "1 second" : "\(s) seconds"
    }

    /// A fixed code for the log. Never the error's message, which can carry server text.
    private static func code(_ error: Error) -> String {
        guard let e = error as? BridgeError else { return "other" }
        switch e {
        case .notConfigured: return "not_configured"
        case .unclear: return "unclear"
        case .staleOrMismatch: return "stale_or_mismatch"
        case .blocked: return "blocked"
        case .expired: return "expired"
        case .server(let status, _): return "server_\(status)"
        case .network: return "network"
        case .unreachable: return "unreachable"
        }
    }
}

/// A calm bar that grows with the voice. Decorative only (hidden from VoiceOver by the caller).
private struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(WriteLook.grey)
                Capsule()
                    .fill(WriteLook.green)
                    .frame(width: CGFloat(max(0, min(1, level))) * g.size.width)
            }
        }
        .animation(.linear(duration: 0.1), value: level)
    }
}

// MARK: - the draft card

/// The message before it goes: what Kairos heard, the draft in large type, the checks, and the person's choices.
/// Used by Write for me and (later) the in-call path. It only shows and reports taps; the caller does the work.
struct DraftCardView: View {
    let draft: BridgeDraft
    let person: KairosPerson
    let isPractice: Bool
    let isWorking: Bool
    let isStale: Bool
    let isSpeaking: Bool
    let notice: String?
    let problem: String?
    let onRevise: (String) -> Void
    let onSayAgain: () -> Void
    let onStopReading: () -> Void
    let onSend: () -> Void
    let onStartAgain: () -> Void
    let onCancel: () -> Void

    /// `onRevise` gets "warmer", "more_formal", "shorter" or "keep_my_words". `problem` is shown right above
    /// Send; `isStale` turns Send into "Start again" (`onStartAgain`).
    init(draft: BridgeDraft, person: KairosPerson, isPractice: Bool, isWorking: Bool, isStale: Bool = false,
         isSpeaking: Bool = false, notice: String? = nil, problem: String? = nil,
         onRevise: @escaping (String) -> Void, onSayAgain: @escaping () -> Void,
         onStopReading: @escaping () -> Void = {}, onSend: @escaping () -> Void,
         onStartAgain: @escaping () -> Void = {}, onCancel: @escaping () -> Void) {
        self.draft = draft
        self.person = person
        self.isPractice = isPractice
        self.isWorking = isWorking
        self.isStale = isStale
        self.isSpeaking = isSpeaking
        self.notice = notice
        self.problem = problem
        self.onRevise = onRevise
        self.onSayAgain = onSayAgain
        self.onStopReading = onStopReading
        self.onSend = onSend
        self.onStartAgain = onStartAgain
        self.onCancel = onCancel
    }

    private static let chips: [(instruction: String, title: String, hint: String)] = [
        ("warmer", "Warmer", "Makes the message warmer and kinder"),
        ("more_formal", "More formal", "Makes the message more polite and formal"),
        ("shorter", "Shorter", "Makes the message shorter"),
        ("keep_my_words", "Keep my words", "Uses your own words, with only small mistakes fixed"),
    ]

    /// A stale card's button is "Start again", which must work even if the old draft was blocked.
    private var sendDisabled: Bool { isWorking || (draft.isBlocked && !isStale) }
    /// Changes would only get a 409 on a stale card.
    private var chipsDisabled: Bool { isWorking || isStale }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if isPractice { practiceBadge }
                if let notice, !notice.isEmpty { noteBox(notice, icon: "info.circle.fill") }
                heardSection
                messageCard
                // Straight under the message, not below the fold: a wrong time or amount is seen before Send.
                if draft.isBlocked { blockedBox }
                if !draft.checks.flags.isEmpty { flagsSection }
                let missing = CardWords.cleaned(draft.missing)
                if !missing.isEmpty {
                    noteBox("You didn't say: " + missing.joined(separator: ", "), icon: "questionmark.circle.fill")
                }
                if let back = draft.back_translation?.trimmingCharacters(in: .whitespacesAndNewlines), !back.isEmpty {
                    // The back-translation is in the language they spoke, which isn't always English.
                    Text(verbatim: (CardWords.spokenLanguage(draft.heard.lang).map { "In \($0), it says: " }
                                    ?? "What it means: ") + back)
                        .font(WriteLook.font(22))
                        .foregroundStyle(WriteLook.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let changes = CardWords.cleaned(draft.changes_made)
                if !changes.isEmpty {
                    Text(verbatim: "I made it: " + changes.joined(separator: ", "))
                        .font(WriteLook.font(22))
                        .foregroundStyle(WriteLook.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                chipsSection
                sayAgainButton
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.visible)
        .background(WriteLook.background.ignoresSafeArea())
        // Send and Cancel are always on screen, however long the message is.
        .safeAreaInset(edge: .bottom) { sendBar }
        .environment(\.colorScheme, .light)
    }

    /// Where it goes, with the last digits of the number on file, so two similar names can't be mixed up.
    private var destination: (shown: String, spoken: String) {
        let app = person.channel.appName
        switch person.channel {
        case .email:
            let email = person.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return email.isEmpty ? (app, app) : ("\(app), to \(email)", "\(app), to \(email)")
        case .signal:
            return (app, app)   // they pick the chat in Signal itself; no number is used
        case .whatsapp, .sms, .telegram:
            let digits = (person.phone ?? "").compactMap { $0.wholeNumberValue }.map(String.init)
            guard digits.count >= 3 else { return (app, app) }
            let last = digits.suffix(3)
            // Spoken digit by digit: "1 2 3", not "one hundred and twenty-three".
            return ("\(app), number ending \(last.joined())", "\(app), number ending \(last.joined(separator: " "))")
        }
    }

    private var header: some View {
        let language = PersonEditor.languageName(person.language)
        return VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "Your message for \(person.recipientLine)")
                .font(WriteLook.font(30, .bold))
                .foregroundStyle(WriteLook.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Label {
                Text(verbatim: "\(destination.shown) · \(language)")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: WriteLook.icon(person.channel))
            }
            .font(WriteLook.font(22))
            .foregroundStyle(WriteLook.body)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(destination.spoken), in \(language)"))
        }
    }

    private var practiceBadge: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("Practice mode").font(WriteLook.font(24, .bold))
                Text("Kairos isn't connected to your Mac, so this is only a practice message and may not be what you said. Nothing will be sent.")
                    .font(WriteLook.font(22))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "graduationcap.fill").font(.system(size: 26, weight: .semibold))
        }
        .foregroundStyle(WriteLook.practiceInk)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WriteLook.practiceFill, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(WriteLook.practiceInk, lineWidth: 2))
        .accessibilityElement(children: .combine)
    }

    /// Exactly what speech-to-text heard, so the person can see if it misheard them. Full-strength body text:
    /// this is what they need to read to catch a mishearing.
    private var heardSection: some View {
        let heard = draft.heard.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 6) {
            Text("I heard")
                .font(WriteLook.font(22, .bold))
                .foregroundStyle(WriteLook.body)
            Text(verbatim: heard.isEmpty ? "Nothing" : draft.heard.text)
                .font(WriteLook.font(24))
                .foregroundStyle(WriteLook.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The text that will be approved and sent, character for character.
    private var messageCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: draft.text)
                .font(WriteLook.font(30, .semibold))
                .foregroundStyle(WriteLook.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Text(verbatim: "Your message: " + draft.text))
            Text(verbatim: "Version \(draft.version)")
                .font(WriteLook.font(22, .semibold))
                .foregroundStyle(WriteLook.muted)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityHidden(true)   // means little when heard; the text itself is what matters
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(WriteLook.border, lineWidth: 2))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }

    private func noteBox(_ text: String, icon: String) -> some View {
        Label {
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
        }
        .font(WriteLook.font(22, .semibold))
        .foregroundStyle(WriteLook.noteInk)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WriteLook.noteFill, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(WriteLook.noteEdge, lineWidth: 2))
        .accessibilityElement(children: .combine)
    }

    private var flagsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Please check")
                .font(WriteLook.font(24, .bold))
                .foregroundStyle(WriteLook.ink)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(draft.checks.flags.enumerated()), id: \.offset) { _, flag in
                noteBox(CardWords.flagSentence(flag),
                        icon: flag.in_transcript == true ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            }
        }
    }

    /// Something (a link, a number, an account) is in the draft that the person never said: Send is off.
    private var blockedBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("I can't send this, because it has something in it you didn't say")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "hand.raised.fill")
            }
            .font(WriteLook.font(24, .bold))
            ForEach(Array(draft.checks.blocked.enumerated()), id: \.offset) { _, flag in
                Text(verbatim: "• " + CardWords.blockedSentence(flag))
                    .font(WriteLook.font(22, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Try Keep my words, or tap Cancel and say it again.")
                .font(WriteLook.font(22))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(WriteLook.problemInk)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WriteLook.problemFill, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(WriteLook.problemInk, lineWidth: 3))
        .accessibilityElement(children: .combine)
    }

    private var chipsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Change it")
                .font(WriteLook.font(24, .bold))
                .foregroundStyle(WriteLook.ink)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(Self.chips, id: \.instruction) { chip in
                    Button { onRevise(chip.instruction) } label: {
                        Text(verbatim: chip.title)
                            .font(WriteLook.font(22, .bold))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .foregroundStyle(WriteLook.green)
                            .background(.white, in: RoundedRectangle(cornerRadius: 18))
                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(WriteLook.green, lineWidth: 2))
                            .contentShape(RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                    .disabled(chipsDisabled)
                    .opacity(chipsDisabled ? 0.5 : 1)
                    .accessibilityHint(Text(verbatim: chip.hint))
                }
            }
        }
    }

    /// While reading, the same button stops it: someone tapping it mid-reading wants it to stop, not restart.
    private var sayAgainButton: some View {
        Button { isSpeaking ? onStopReading() : onSayAgain() } label: {
            WriteButtonLabel(title: isSpeaking ? "Stop reading" : "Say it again",
                             systemImage: isSpeaking ? "stop.fill" : "speaker.wave.2.fill",
                             fill: .white, ink: WriteLook.green, size: 26, height: 68, outlined: true)
        }
        .buttonStyle(.plain)
        // Off while Send is being approved: nothing should start talking as another app opens.
        .disabled(isWorking)
        .opacity(isWorking ? 0.5 : 1)
        .accessibilityLabel(isSpeaking ? "Stop reading" : "Say it again")
        .accessibilityHint(isSpeaking ? "Stops reading the message out loud"
                                      : "Reads the message out loud, exactly as it will be sent")
    }

    private var sendFace: (title: String, icon: String, hint: String) {
        let app = person.channel.appName
        if isStale {
            return ("Start again", "arrow.counterclockwise",
                    "Throws this message away so you can say it again. Nothing is sent.")
        }
        if draft.isBlocked {
            return ("Can't send this one", "nosign", "Turned off, because it has something in it you didn't say.")
        }
        if isPractice {
            return ("Try sending to \(person.alias) (practice)", "graduationcap.fill",
                    "Shows what would happen. Nothing is sent.")
        }
        return ("Send to \(person.alias) on \(app)", "paperplane.fill",
                "Opens \(app) with this message. You tap Send there.")
    }

    /// Errors after Send, where the person's eyes and finger already are.
    private func problemBanner(_ text: String) -> some View {
        Label {
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(WriteLook.font(24, .bold))
        .foregroundStyle(WriteLook.problemInk)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WriteLook.problemFill, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(WriteLook.problemInk, lineWidth: 2))
        .accessibilityElement(children: .combine)
    }

    private var sendBar: some View {
        let face = sendFace
        return VStack(spacing: 10) {
            if let problem, !problem.isEmpty { problemBanner(problem) }
            if isWorking {
                HStack(spacing: 12) {
                    ProgressView().tint(WriteLook.green)
                    Text("Working on it…")
                        .font(WriteLook.font(22, .semibold))
                        .foregroundStyle(WriteLook.ink)
                }
                .accessibilityElement(children: .combine)
            }
            Button { isStale ? onStartAgain() : onSend() } label: {
                Label(face.title, systemImage: face.icon)
                    .font(WriteLook.font(30, .bold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .background(sendDisabled ? WriteLook.grey : WriteLook.green, in: RoundedRectangle(cornerRadius: 26))
                    .foregroundStyle(sendDisabled ? WriteLook.body : .white)
                    .contentShape(RoundedRectangle(cornerRadius: 26))
            }
            .buttonStyle(.plain)
            .disabled(sendDisabled)
            .accessibilityHint(face.hint)
            Button { onCancel() } label: {
                Text("Cancel")
                    .font(WriteLook.font(26, .bold))
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(WriteLook.grey, in: RoundedRectangle(cornerRadius: 20))
                    .foregroundStyle(WriteLook.ink)
                    .contentShape(RoundedRectangle(cornerRadius: 20))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Throws this message away. Nothing is sent.")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background {
            WriteLook.background
                .shadow(color: .black.opacity(0.12), radius: 8, y: -2)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}
