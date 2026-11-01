import Combine
import MessageUI
import os
import SwiftUI
import UIKit

// Kairos Communications Bridge: the hand-off after the person approved a draft.
// The rules this file keeps (research/Kairos-Server-Architecture.md, "The Communications Bridge"):
//  * Only `approval.text` (the server's exact stored text) is handed off: never a model's text or the card's copy.
//  * Numbers and emails come from the phone (KairosPerson) and never go to the server or the log.
//  * Nothing is sent automatically: the person taps Send in WhatsApp, Messages or Mail.
//  * A practice draft (the mock invents its text) never reaches a real person: it gets the practice card instead.
//  * The ElevenLabs call has ended before another app opens (UIBackgroundModes: audio would keep the mic live).
//  * A 5-second "Opening WhatsApp – tap to stop" countdown gives a last chance to change their mind. With
//    VoiceOver on nothing opens by itself: a spoken countdown can't be heard, found and stopped in time.
//  * The share menu is never a surprise: a step card first says which app to tap and which person to pick.

/// Status only. Message text, numbers, emails and names are never logged.
private let log = Logger(subsystem: "uk.oxhack.tempo", category: "bridge.handoff")

@MainActor
final class HandOffCoordinator: ObservableObject {
    enum State: Equatable {
        case idle
        /// The last chance to stop. With VoiceOver (`waitsForTap`) the number doesn't run: nothing opens until
        /// "Open WhatsApp now" is double-tapped.
        case countingDown(secondsLeft: Int, channel: BridgeChannel)
        /// Before the share menu: "Next, tap WhatsApp. Then find and tap Amma, your mother." Waits for a tap.
        case shareSteps(channel: BridgeChannel)
        case presentingMessage, presentingMail, presentingShare
        /// A practice draft: says what would have opened, and for whom. Nothing is opened or sent.
        case practice(recipient: String, channel: BridgeChannel)
        case done(BridgeOutcome)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// What the compose and share sheets show. Read-only outside, so nothing can swap in other text after approval.
    @Published private(set) var pendingText = ""
    @Published private(set) var recipients: [String] = []
    /// What the person calls the recipient ("Amma").
    @Published private(set) var alias = ""
    /// "Amma, your mother": shown on every card, because Amma and Anna are easy to confuse.
    @Published private(set) var recipientLine = ""
    /// VoiceOver was on at Send: the countdown card shows "Open WhatsApp now" and "Stop" instead of a timer.
    @Published private(set) var waitsForTap = false
    /// The share menu is there because the app didn't open by itself (the step card says so).
    @Published private(set) var appDidNotOpen = false

    static let mailSubject = "A message for you"
    /// wa.me's length limit is UNVERIFIED (architecture doc), so longer messages go through the share menu.
    static let waMeMaxCharacters = 1000
    /// Hand off a little before the nonce expires, so the server never sees a hand-off with an expired nonce.
    static let expiryMargin: TimeInterval = 5
    /// Long enough for a 75-90 year old to read the card, recognise the name and lift a finger.
    static let countdownSeconds = 5

    /// One approved hand-off waiting to go. Consumed by the first go-ahead, so a double tap can't open two apps.
    private struct Pending {
        let generation: Int
        let route: Route
        let text: String
        let channel: BridgeChannel
        let deadline: Date
    }

    private var api: BridgeAPI?
    private var draftId: String?
    private var pending: Pending?
    private var nonce: String?
    /// Bumped by every begin / showPractice, so a late step from an earlier hand-off can't act on a newer one.
    private var generation = 0
    private var countdownTask: Task<Bool, Never>?
    /// Ending the ElevenLabs call. Runs while the person reads the card; nothing opens until it has finished.
    private var callEnding: Task<Void, Never>?
    /// True once iOS has been asked to open the app: Stop can't undo that, and must not report "cancelled".
    private var committed = false
    /// The app we opened, for "Your message is waiting in WhatsApp…". nil when the share menu was used.
    private var handedOffTo: BridgeChannel?
    /// They tapped Copy in the share menu: the text is on the clipboard, but nothing went to anyone.
    private var copiedOnly = false
    /// Why nothing was sent, when it's more than "Not sent." (Stop, or leaving Kairos mid-countdown).
    private var notSentReason: String?
    private var resignWatch: AnyCancellable?

    init() {
        // iOS opens nothing from the background, so a countdown that ran out there would fall back to the
        // share menu and surprise them with it later. UIKit posts this on the main thread.
        resignWatch = NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.appWillResign() } }
    }

    /// True while a hand-off is under way (or the practice card is up), so a second Send tap is ignored.
    var isBusy: Bool {
        switch state {
        case .countingDown, .shareSteps, .presentingMessage, .presentingMail, .presentingShare, .practice: return true
        case .idle, .done, .failed: return false
        }
    }

    /// The large sentence for the end of it. Never claims more than we know: after wa.me or the share menu,
    /// only the person knows whether they tapped Send.
    var resultText: String {
        switch state {
        case .done(.handedOff):
            if let channel = handedOffTo {
                return "Your message is waiting in \(channel.appName). It is only sent when you \(Self.sendStep(channel))."
            }
            return recipientLine.isEmpty ? "If you sent it, you're all done."
                : "If you sent it to \(recipientLine), you're all done."
        case .done(.sent): return "Sent."
        case .done(.cancelled):
            if copiedOnly { return "You copied the message, but it hasn't been sent." }
            return notSentReason ?? "Not sent."
        case .done(.failed): return "Not sent."
        case .failed(let message): return message
        case .practice(let recipient, let channel): return Self.practiceText(recipient: recipient, channel: channel)
        default: return ""
        }
    }

    private enum Route {
        case open(URL, appName: String)   // wa.me, tg://, mailto:
        case message(to: String)
        case mail(to: String)
        case share
        case missing(String)              // can't go this way at all (no number, no app): the sentence to show
    }

    // MARK: - wording shared with BridgeView

    /// The last tap in the other app, in words an older person can follow on screen.
    static func sendStep(_ channel: BridgeChannel) -> String {
        switch channel {
        case .whatsapp: return "tap the green arrow at the bottom"
        case .telegram: return "tap the blue arrow at the bottom"
        case .sms: return "tap the blue arrow"
        case .email: return "tap Send at the top"
        case .signal: return "tap the blue arrow"
        }
    }

    /// Under the name on the countdown: the button says Send, but they still have to send it in the other app.
    static func opensWithMessage(_ channel: BridgeChannel) -> String {
        "\(channel.appName) will open with your message. Then \(sendStep(channel)) to send it."
    }

    static func practiceText(recipient: String, channel: BridgeChannel) -> String {
        "Practice only. In real use, \(channel.appName) would open for \(recipient). Nothing was sent."
    }

    /// Spoken by VoiceOver, which can't see a card appear. `queued` waits for what VoiceOver is already saying.
    static func announce(_ sentence: String, queued: Bool = false) {
        guard !sentence.isEmpty else { return }
        let spoken = NSAttributedString(string: sentence, attributes: [.accessibilitySpeechQueueAnnouncement: queued])
        UIAccessibility.post(notification: .announcement, argument: spoken)
    }

    // MARK: - the hand-off

    /// Call right after `api.approve` succeeds. `approvedAt` is when the approve request was sent, so the phone's
    /// deadline can never be later than the server's nonce clock.
    func begin(approval: BridgeApproval, approvedAt: Date, person: KairosPerson, channel: BridgeChannel,
               draftId: String, api: BridgeAPI, endCall: @escaping () async -> Void) async {
        guard !isBusy else { return }   // a double tap on Send must not open two apps
        // The mock makes up its text, so whatever the caller does, a practice draft never reaches a real person.
        if api.isPractice || api.isPracticeDraft(draftId) { showPractice(person: person, channel: channel); return }

        generation &+= 1
        let gen = generation
        self.api = api
        self.draftId = draftId
        prepare(for: person)

        // Checks before anything happens. None of these report an outcome: nothing was handed off, and the
        // draft stays open on the server so the person can simply tap Send again.
        let deadline = approvedAt.addingTimeInterval(TimeInterval(approval.expires_in) - Self.expiryMargin)
        guard Date() <= deadline else { fail(BridgeError.expired.spoken, reason: "expired"); return }
        // Any other delivery (e.g. a later server-side email) is sent by the server; handing off too would send twice.
        guard approval.delivery == "handoff" else {
            fail("I can't send this one from here.", reason: "delivery_not_handoff"); return
        }
        let text = approval.text
        nonce = approval.nonce   // the hub needs it with the outcome (single use, 120 s)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail("This message is empty, so I didn't send it.", reason: "empty_text"); return
        }
        // Worked out before the call ends, so a missing number doesn't cut the call off for nothing.
        let route = route(channel, person, text)
        if case .missing(let sentence) = route { fail(sentence, reason: "missing_contact"); return }

        pending = Pending(generation: gen, route: route, text: text, channel: channel, deadline: deadline)
        // Started now, so the call ends while they read the card; chained so two endings never overlap.
        let previous = callEnding
        callEnding = Task { await previous?.value; await endCall() }

        if case .share = route { showShareSteps(channel); return }

        // Set before the state, so the very first render of the card already shows the right buttons.
        waitsForTap = UIAccessibility.isVoiceOverRunning
        state = .countingDown(secondsLeft: Self.countdownSeconds, channel: channel)
        log.info("hand-off countdown, channel \(channel.rawValue, privacy: .public)")
        // VoiceOver: the overlay moves focus to Stop and reads the card; nothing opens until "Open … now".
        if waitsForTap { return }

        let countdown = Task { () -> Bool in
            for left in stride(from: Self.countdownSeconds, through: 1, by: -1) {
                guard !Task.isCancelled, gen == self.generation, case .countingDown = self.state else { return false }
                self.state = .countingDown(secondsLeft: left, channel: channel)
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return false }
            }
            return !Task.isCancelled
        }
        countdownTask = countdown
        let go = await countdown.value
        if gen == generation { countdownTask = nil }
        guard go else { return }   // Stop already reported the outcome
        await proceed(gen)
    }

    /// "Open WhatsApp now" on the VoiceOver countdown card.
    func openNow() {
        guard case .countingDown = state, let gen = pending?.generation else { return }
        Task { await proceed(gen) }
    }

    /// "Show me the apps" on the step card.
    func showApps() {
        guard case .shareSteps = state, let gen = pending?.generation else { return }
        Task { await proceed(gen) }
    }

    /// The Stop button (or a tap anywhere on the countdown). Takes effect at once, even while the call is
    /// still ending, so Stop never looks broken.
    func stop() {
        cancelPending(reason: "Stopped. Nothing was sent.")
    }

    /// Practice mode: show what would have happened. Nothing is opened, and no outcome is reported.
    func showPractice(person: KairosPerson, channel: BridgeChannel) {
        guard !isBusy else { return }
        generation &+= 1   // anything still pending from an earlier hand-off must not act on this card
        pending = nil
        prepare(for: person)
        state = .practice(recipient: person.recipientLine, channel: channel)
        log.info("practice hand-off shown, channel \(channel.rawValue, privacy: .public)")
        Self.announce(resultText)
    }

    /// The OK / Done button on the result or practice card.
    func reset() {
        switch state {
        case .done, .failed, .practice:
            state = .idle
            alias = ""
            recipientLine = ""
        default: break
        }
    }

    private func prepare(for person: KairosPerson) {
        countdownTask?.cancel()
        countdownTask = nil
        committed = false
        handedOffTo = nil
        copiedOnly = false
        notSentReason = nil
        waitsForTap = false
        appDidNotOpen = false
        pendingText = ""
        recipients = []
        alias = person.alias
        recipientLine = person.recipientLine
    }

    private var isWaitingToOpen: Bool {
        switch state {
        case .countingDown, .shareSteps: return true
        default: return false
        }
    }

    private func cancelPending(reason: String) {
        guard isWaitingToOpen, !committed else { return }
        countdownTask?.cancel()
        countdownTask = nil
        pending = nil
        notSentReason = reason
        finish(.cancelled)
    }

    private func appWillResign() {
        // Only a running countdown would open something by itself; the VoiceOver card and the step card wait.
        guard countdownTask != nil, case .countingDown(_, let channel) = state else { return }
        cancelPending(reason: "You left Kairos before \(channel.appName) opened, so nothing was sent.")
    }

    /// The go-ahead: the countdown ran out, or "Open … now" / "Show me the apps" was tapped.
    private func proceed(_ gen: Int) async {
        guard let p = pending, p.generation == gen else { return }
        pending = nil   // one hand-off per approval, however many taps arrive
        // The mic must not stay live behind another app.
        await callEnding?.value
        // Stop, Close or a newer hand-off may have come in while the call was ending.
        guard gen == generation, isWaitingToOpen else { return }
        guard UIApplication.shared.applicationState == .active else {
            notSentReason = "You left Kairos before \(p.channel.appName) opened, so nothing was sent."
            finish(.cancelled)
            return
        }
        // Ending the call and the countdown take time; never hand off on a nonce that has run out meanwhile.
        guard Date() <= p.deadline else { fail(BridgeError.expired.spoken, reason: "expired"); return }
        await handOff(p, gen: gen)
    }

    private func handOff(_ p: Pending, gen: Int) async {
        switch p.route {
        case .open(let url, _):
            log.info("hand-off opening app, channel \(p.channel.rawValue, privacy: .public)")
            committed = true
            let opened = await UIApplication.shared.open(url, options: [:])
            guard gen == generation else { return }
            committed = false
            if opened {
                handedOffTo = p.channel
                finish(.handedOff)
            } else {
                // e.g. Telegram isn't on this iPhone: explain the share menu first, then wait for their tap.
                pending = Pending(generation: gen, route: .share, text: p.text, channel: p.channel, deadline: p.deadline)
                appDidNotOpen = true
                showShareSteps(p.channel)
            }
        case .message(let to):
            pendingText = p.text
            recipients = [to]
            state = .presentingMessage
        case .mail(let to):
            pendingText = p.text
            recipients = [to]
            state = .presentingMail
        case .share:
            log.info("hand-off via share sheet")
            pendingText = p.text
            recipients = []
            state = .presentingShare
        case .missing(let sentence):
            fail(sentence, reason: "missing_contact")
        }
    }

    private func showShareSteps(_ channel: BridgeChannel) {
        state = .shareSteps(channel: channel)
        log.info("hand-off share steps, channel \(channel.rawValue, privacy: .public)")
        Self.announce(shareStepsSentence(channel))
    }

    func shareStepsSentence(_ channel: BridgeChannel) -> String {
        let who = recipientLine.isEmpty ? "the person you want" : recipientLine
        let lead = appDidNotOpen ? "\(channel.appName) didn't open by itself, so you'll pick it from a list. " : ""
        return lead + "Next, tap \(channel.appName). Then find and tap \(who). Then tap Send there."
    }

    // MARK: - results from the sheets

    func messageFinished(_ result: MessageComposeResult) {
        guard state == .presentingMessage else { return }
        switch result {
        case .sent: finish(.sent)
        case .cancelled: finish(.cancelled)
        case .failed: finish(.failed)
        @unknown default: finish(.failed)
        }
    }

    func mailFinished(_ result: MFMailComposeResult) {
        guard state == .presentingMail else { return }
        switch result {
        case .sent: finish(.sent)                       // queued in Mail's outbox
        case .saved, .cancelled: finish(.cancelled)     // a saved draft hasn't gone anywhere
        case .failed: finish(.failed)
        @unknown default: finish(.failed)
        }
    }

    /// `activity` tells Copy apart from a real app: copying sends nothing, so it is reported as not sent.
    func shareFinished(completed: Bool, activity: UIActivity.ActivityType? = nil) {
        guard state == .presentingShare else { return }
        if completed && activity == .copyToPasteboard {
            copiedOnly = true
            finish(.cancelled)
            return
        }
        finish(completed ? .handedOff : .cancelled)
    }

    /// A sheet was swiped away. Its own result can arrive just after, so wait a moment before calling it
    /// "cancelled"; otherwise a real "sent" could be recorded as "not sent".
    func sheetDismissed(_ sheet: State) {
        guard state == sheet else { return }
        let gen = generation
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if gen == generation, state == sheet { finish(.cancelled) }
        }
    }

    // MARK: - helpers

    private func finish(_ outcome: BridgeOutcome) {
        state = .done(outcome)
        pending = nil
        committed = false
        waitsForTap = false
        pendingText = ""   // don't keep the message in memory longer than the sheet needs it
        recipients = []
        log.info("hand-off finished: \(outcome.rawValue, privacy: .public)")
        Self.announce(resultText)
        if let api, let draftId {
            let nonce = self.nonce
            Task { await api.outcome(draftId: draftId, nonce: nonce, outcome: outcome) }
        }
    }

    /// `reason` is a fixed code for the log; the sentence may contain the person's name, so it isn't logged.
    private func fail(_ sentence: String, reason: StaticString) {
        countdownTask?.cancel()
        countdownTask = nil
        pending = nil
        committed = false
        waitsForTap = false
        state = .failed(sentence)
        pendingText = ""
        recipients = []
        log.notice("hand-off not started: \(String(describing: reason), privacy: .public)")
        Self.announce(sentence)
    }

    /// canOpenURL only answers for schemes in LSApplicationQueriesSchemes (otherwise it always says no), so the
    /// "is WhatsApp installed?" check runs only once the integrator has declared the scheme.
    private static func mayQuery(_ scheme: String) -> Bool {
        (Bundle.main.object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String])?.contains(scheme) == true
    }

    /// Where this text goes for this person, using only the number or email stored on the phone.
    private func route(_ channel: BridgeChannel, _ person: KairosPerson, _ text: String) -> Route {
        let noNumber = Route.missing("I don't have a number for \(person.alias).")
        // wa.me and tg:// need the country code; a local "07700…" would open a chat with nobody.
        let noCountryCode = Route.missing("I need \(person.alias)'s number with the country code, like +44, to use \(channel.appName). Please fix it in People.")
        switch channel {
        case .whatsapp:
            guard let digits = internationalDigits(person.phone) else { return noNumber }
            guard !digits.hasPrefix("0") else { return noCountryCode }
            // Without WhatsApp, wa.me opens a web page in Safari and looks as if WhatsApp had opened.
            if Self.mayQuery("whatsapp"), let probe = URL(string: "whatsapp://"), !UIApplication.shared.canOpenURL(probe) {
                return .missing("WhatsApp isn't on this iPhone, so I can't send it there.")
            }
            if text.count > Self.waMeMaxCharacters { return .share }
            guard let url = Self.handOffURL(scheme: "https", host: "wa.me", path: "/" + digits,
                                            query: [("text", text)]) else { return .share }
            return .open(url, appName: channel.appName)
        case .telegram:
            guard let digits = internationalDigits(person.phone) else { return noNumber }
            guard !digits.hasPrefix("0") else { return noCountryCode }
            // No canOpenURL here ("tg" isn't a declared query scheme, so it would always say no):
            // if Telegram isn't installed, open() returns false and the step card leads to the share menu.
            guard let url = Self.handOffURL(scheme: "tg", host: "resolve", path: "",
                                            query: [("phone", digits), ("text", text)]) else { return .share }
            return .open(url, appName: channel.appName)
        case .sms:
            guard let to = smsRecipient(person.phone) else { return noNumber }
            return MFMessageComposeViewController.canSendText() ? .message(to: to) : .share
        case .email:
            guard let email = person.email?.trimmingCharacters(in: .whitespacesAndNewlines), email.contains("@") else {
                return .missing("I don't have an email address for \(person.alias).")
            }
            if MFMailComposeViewController.canSendMail() { return .mail(to: email) }
            guard let url = Self.handOffURL(scheme: "mailto", host: nil, path: email,
                                            query: [("subject", Self.mailSubject), ("body", text)]) else { return .share }
            return .open(url, appName: channel.appName)
        case .signal:
            return .share   // Signal has no link that fills in a message; the person picks Signal in the share menu
        }
    }

    /// Only A-Z a-z 0-9 - . _ ~ are left as they are; everything else is UTF-8 percent-encoded. That keeps Telugu and
    /// Devanagari intact, and a "+", "&" or "=" in the message can't turn into a space or a new field (URLComponents'
    /// own queryItems encoding leaves "+" alone, and WhatsApp reads it as a space). Not CharacterSet.alphanumerics:
    /// that set includes Telugu letters.
    private static let queryValueAllowed =
        CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func handOffURL(scheme: String, host: String?, path: String, query: [(String, String)]) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        c.path = path
        var items: [URLQueryItem] = []
        for (name, value) in query {
            guard let encoded = value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) else { return nil }
            items.append(URLQueryItem(name: name, value: encoded))
        }
        c.percentEncodedQueryItems = items
        return c.url
    }
}

// MARK: - phone numbers (on the phone only)

/// 0-9 only. `bridgeDigits` keeps any Unicode digit, so Telugu or Devanagari digits typed into a number
/// (౯, ९) are turned into 0-9 here, which is what wa.me, tg:// and Messages read.
private func asciiDigits(_ s: String) -> String {
    String(s.compactMap { c -> Character? in
        guard let v = c.wholeNumberValue, (0...9).contains(v) else { return nil }
        return Character(String(v))
    })
}

/// International digits with no "+" or "00" (what wa.me and tg:// want), or nil when there's no number.
/// A result starting with "0" is a local number: no country code begins with 0.
private func internationalDigits(_ phone: String?) -> String? {
    guard let phone else { return nil }
    var digits = asciiDigits(phone)
    if digits.hasPrefix("00") { digits.removeFirst(2) }
    return digits.isEmpty ? nil : digits
}

/// The number for Messages: "+" and the international digits, unless it was stored as a local number ("07700…").
private func smsRecipient(_ phone: String?) -> String? {
    guard let phone else { return nil }
    let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
    let digits = asciiDigits(trimmed)
    guard !digits.isEmpty else { return nil }
    if trimmed.hasPrefix("+") { return "+" + digits }
    if digits.hasPrefix("00") { return "+" + digits.dropFirst(2) }
    if digits.hasPrefix("0") { return digits }   // local number: Messages dials it as written
    return "+" + digits                          // E.164 stored without its "+"
}

// MARK: - the system sheets, for SwiftUI

/// Messages' compose screen, filled in. The person taps Send there; we only learn sent / cancelled / failed.
struct MessageComposeSheet: UIViewControllerRepresentable {
    let recipients: [String]
    let body: String
    let onFinish: (MessageComposeResult) -> Void

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.recipients = recipients
        vc.body = body
        vc.messageComposeDelegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: (MessageComposeResult) -> Void
        init(onFinish: @escaping (MessageComposeResult) -> Void) { self.onFinish = onFinish }
        // No dismiss here: the coordinator's state change closes the SwiftUI sheet.
        func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                          didFinishWith result: MessageComposeResult) {
            onFinish(result)
        }
    }
}

/// Mail's compose screen, filled in (plain text, not HTML, so nothing in the message can become a link we didn't show).
struct MailComposeSheet: UIViewControllerRepresentable {
    let recipients: [String]
    let subject: String
    let body: String
    let onFinish: (MFMailComposeResult) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.setToRecipients(recipients)
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: false)
        vc.mailComposeDelegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: (MFMailComposeResult) -> Void
        init(onFinish: @escaping (MFMailComposeResult) -> Void) { self.onFinish = onFinish }
        // The error isn't logged: it could echo the address.
        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult, error: Error?) {
            onFinish(result)
        }
    }
}

/// The iOS share menu. `completed` is true when the person finished in what they picked; `activity` says what
/// that was, so Copy isn't mistaken for sending.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var onFinish: ((_ completed: Bool, _ activity: UIActivity.ActivityType?) -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // Fewer tiles to search through, and none of these sends a message.
        vc.excludedActivityTypes = [.print, .assignToContact, .saveToCameraRoll, .addToReadingList,
                                    .markupAsPDF, .openInIBooks]
        let onFinish = onFinish
        vc.completionWithItemsHandler = { activity, completed, _, _ in onFinish?(completed, activity) }
        return vc
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - what the person sees

private enum HandOffLook {
    static let background = Color(red: 0.96, green: 0.95, blue: 0.92)
    static let green = Color(red: 0.18, green: 0.44, blue: 0.37)
    static let ink = Color(red: 0.11, green: 0.11, blue: 0.10)
    static let body = Color(red: 0.25, green: 0.25, blue: 0.23)
    static let stop = Color(red: 0.66, green: 0.15, blue: 0.11)   // white on this is well above 4.5:1
    /// Grows with Larger Text but never shrinks below the design size, and stops at 1.3x so the
    /// full-screen cards still fit their big buttons.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let scaled = UIFontMetrics(forTextStyle: .body).scaledValue(for: size)
        return .system(size: min(max(scaled, size), size * 1.3), weight: weight, design: .rounded)
    }
}

/// A big full-width button label, the same shape on every card.
private struct HandOffButtonLabel: View {
    let title: String
    let systemImage: String?
    let fill: Color
    let size: CGFloat
    let height: CGFloat

    var body: some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(verbatim: title)
            }
        }
        .font(HandOffLook.font(size, .bold))
        .multilineTextAlignment(.center)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: height)
        .background(fill, in: RoundedRectangle(cornerRadius: 24))
        .foregroundStyle(.white)
    }
}

/// Put this on top of the screen that is showing when Send is tapped (it lets taps through when idle).
/// It shows the countdown, the share steps and the practice card, hosts the Messages / Mail / share sheets,
/// and shows the result in large type.
struct HandOffOverlay: View {
    @ObservedObject var coordinator: HandOffCoordinator
    /// Called after Done on the practice card (e.g. to close Write for me). Without it, Done goes back to the message.
    var onPracticeDone: (() -> Void)?
    /// Called after OK on the result card (opened / sent / not sent). Without it, OK goes back to the message.
    /// The in-call card uses it to close, because a handed-off draft can't be approved again.
    var onResultDone: (() -> Void)?

    @AccessibilityFocusState private var stopFocused: Bool

    init(coordinator: HandOffCoordinator, onPracticeDone: (() -> Void)? = nil, onResultDone: (() -> Void)? = nil) {
        _coordinator = ObservedObject(wrappedValue: coordinator)
        self.onPracticeDone = onPracticeDone
        self.onResultDone = onResultDone
    }

    var body: some View {
        ZStack {
            // Always here, and see-through, so the sheets have a view to hang from when nothing else shows.
            Color.clear.allowsHitTesting(false)
            switch coordinator.state {
            case .countingDown(let left, let channel):
                countdownCard(left, channel)
            case .shareSteps(let channel):
                shareStepsCard(channel)
            case .practice(let recipient, let channel):
                practiceCard(recipient, channel)
            case .done, .failed:
                resultCard
            case .idle, .presentingMessage, .presentingMail, .presentingShare:
                EmptyView()
            }
        }
        .sheet(isPresented: showing(.presentingMessage)) {
            MessageComposeSheet(recipients: coordinator.recipients, body: coordinator.pendingText) {
                coordinator.messageFinished($0)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: showing(.presentingMail)) {
            MailComposeSheet(recipients: coordinator.recipients, subject: HandOffCoordinator.mailSubject,
                             body: coordinator.pendingText) { coordinator.mailFinished($0) }
                .ignoresSafeArea()
        }
        .sheet(isPresented: showing(.presentingShare)) {
            ShareSheet(items: [coordinator.pendingText]) { completed, activity in
                coordinator.shareFinished(completed: completed, activity: activity)
            }
            .presentationDetents([.medium, .large])
            .ignoresSafeArea()
        }
    }

    /// A sheet is up exactly while the coordinator is in that state; a swipe-down tells the coordinator.
    private func showing(_ sheet: HandOffCoordinator.State) -> Binding<Bool> {
        Binding(get: { coordinator.state == sheet },
                set: { if !$0 { coordinator.sheetDismissed(sheet) } })
    }

    /// Centred when it fits; scrolls on a small phone or with Larger Text, so nothing is cut off.
    private func fitting<Content: View>(_ content: Content) -> some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content.padding(.vertical, 8) }
        }
        .frame(maxHeight: .infinity)
    }

    /// Full screen and impossible to miss: who it's for, what to do in the other app, a giant number and a
    /// giant Stop. A tap anywhere also stops. With VoiceOver: no timer, "Open … now" and Stop, focus on Stop.
    private func countdownCard(_ left: Int, _ channel: BridgeChannel) -> some View {
        let manual = coordinator.waitsForTap
        let app = channel.appName
        let title = manual ? "Ready to open \(app)" : "Opening \(app) – tap to stop"
        let details = VStack(spacing: 18) {
            Text(verbatim: title)
                .font(HandOffLook.font(32, .bold))
                .foregroundStyle(HandOffLook.ink)
                .accessibilityAddTraits(.isHeader)
            if !coordinator.recipientLine.isEmpty {
                Text(verbatim: "Message to \(coordinator.recipientLine)")
                    .font(HandOffLook.font(28, .bold))
                    .foregroundStyle(HandOffLook.ink)
            }
            Text(verbatim: HandOffCoordinator.opensWithMessage(channel))
                .font(HandOffLook.font(24, .medium))
                .foregroundStyle(HandOffLook.body)
            if !manual {
                Text(verbatim: "\(left)")
                    .font(.system(size: 130, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(HandOffLook.green)
                    .accessibilityLabel(left == 1 ? "1 second" : "\(left) seconds")
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)

        return VStack(spacing: 16) {
            fitting(details)
            if manual {
                Button { coordinator.openNow() } label: {
                    HandOffButtonLabel(title: "Open \(app) now", systemImage: nil, fill: HandOffLook.green,
                                       size: 30, height: 92)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens \(app) with your message. You send it there.")
            }
            Button { coordinator.stop() } label: {
                HandOffButtonLabel(title: "Stop", systemImage: "hand.raised.fill", fill: HandOffLook.stop,
                                   size: 40, height: manual ? 92 : 104)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop")
            .accessibilityHint("Don't open \(app). Nothing is sent.")
            .accessibilityFocused($stopFocused)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HandOffLook.background.ignoresSafeArea())
        .contentShape(Rectangle())
        // Only while the timer runs: on the VoiceOver card a stray tap mustn't race the Open button.
        .onTapGesture { if !manual { coordinator.stop() } }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .task(id: manual) {
            guard manual else { return }
            // Focus first (VoiceOver reads "Stop"), then the card, queued so the focus change can't cut it off.
            try? await Task.sleep(nanoseconds: 350_000_000)
            stopFocused = true
            let who = coordinator.recipientLine.isEmpty ? "" : " for \(coordinator.recipientLine)"
            HandOffCoordinator.announce("Ready to open \(app)\(who). \(HandOffCoordinator.opensWithMessage(channel)) Swipe left for Open \(app) now, or double-tap Stop.", queued: true)
        }
    }

    /// Before the share menu: which app to tap and which person to pick, in big type, then a deliberate tap.
    private func shareStepsCard(_ channel: BridgeChannel) -> some View {
        let app = channel.appName
        let who = coordinator.recipientLine.isEmpty ? "the person you want" : coordinator.recipientLine
        let details = VStack(spacing: 20) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(HandOffLook.green)
                .accessibilityHidden(true)
            if coordinator.appDidNotOpen {
                Text(verbatim: "\(app) didn't open by itself, so you'll pick it from a list.")
                    .font(HandOffLook.font(24, .medium))
                    .foregroundStyle(HandOffLook.body)
            }
            Text(verbatim: "Next, tap \(app).")
                .font(HandOffLook.font(36, .bold))
                .foregroundStyle(HandOffLook.ink)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: "Then find and tap \(who).")
                .font(HandOffLook.font(32, .bold))
                .foregroundStyle(HandOffLook.ink)
            Text(verbatim: "Then tap Send there.")
                .font(HandOffLook.font(24, .medium))
                .foregroundStyle(HandOffLook.body)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)

        return VStack(spacing: 16) {
            fitting(details)
            Button { coordinator.showApps() } label: {
                HandOffButtonLabel(title: "Show me the apps", systemImage: nil, fill: HandOffLook.green,
                                   size: 32, height: 96)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the list of apps. Nothing is sent until you tap Send.")
            Button { coordinator.stop() } label: {
                HandOffButtonLabel(title: "Stop", systemImage: "hand.raised.fill", fill: HandOffLook.stop,
                                   size: 30, height: 80)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop")
            .accessibilityHint("Nothing is sent.")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HandOffLook.background.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    /// Practice mode: what would have opened, and for whom. Nothing was opened or sent.
    private func practiceCard(_ recipient: String, _ channel: BridgeChannel) -> some View {
        let details = VStack(spacing: 22) {
            Image(systemName: "graduationcap.fill")
                .font(.system(size: 72, weight: .bold))
                .foregroundStyle(HandOffLook.green)
                .accessibilityHidden(true)
            Text(verbatim: "Practice only.")
                .font(HandOffLook.font(36, .bold))
                .foregroundStyle(HandOffLook.ink)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: "In real use, \(channel.appName) would open for \(recipient).")
                .font(HandOffLook.font(28, .semibold))
                .foregroundStyle(HandOffLook.ink)
            Text(verbatim: "Nothing was sent.")
                .font(HandOffLook.font(30, .bold))
                .foregroundStyle(HandOffLook.ink)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)

        return VStack(spacing: 16) {
            fitting(details)
            Button {
                coordinator.reset()
                onPracticeDone?()
            } label: {
                HandOffButtonLabel(title: "Done", systemImage: nil, fill: HandOffLook.green, size: 32, height: 96)
            }
            .buttonStyle(.plain)
            .accessibilityHint(onPracticeDone == nil ? "Back to your message" : "Closes Write for me")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HandOffLook.background.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private var resultIcon: (name: String, color: Color) {
        switch coordinator.state {
        case .done(.handedOff): return ("arrow.up.forward.app.fill", HandOffLook.green)
        case .done(.sent): return ("checkmark.circle.fill", HandOffLook.green)
        case .done(.cancelled): return ("xmark.circle.fill", HandOffLook.body)
        default: return ("exclamationmark.triangle.fill", Color(red: 0.6, green: 0.35, blue: 0.0))
        }
    }

    /// Stays until the person taps OK: nothing here times out on them.
    private var resultCard: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 22) {
                Image(systemName: resultIcon.name)
                    .font(.system(size: 64, weight: .bold))
                    .foregroundStyle(resultIcon.color)
                    .accessibilityHidden(true)
                Text(verbatim: coordinator.resultText)
                    .font(HandOffLook.font(30, .bold))
                    .foregroundStyle(HandOffLook.ink)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                Button { coordinator.reset(); onResultDone?() } label: {
                    HandOffButtonLabel(title: "OK", systemImage: nil, fill: HandOffLook.green, size: 30, height: 84)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Closes this message")
            }
            .padding(24)
            .background(.white, in: RoundedRectangle(cornerRadius: 28))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            .padding(18)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }
}
