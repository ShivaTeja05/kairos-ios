import ElevenLabs
import SwiftUI

// The Bridge inside a voice call: the ElevenLabs agent's client tools (names and params are fixed in
// tempo-hub/voice/agent/tools_config.json) drive the same draft card as Write for me.
//   draft_message  {alias, channel?, tone?, language?}  -> the phone resolves the person, who must be someone the
//                   person NAMED in this call; the hub drafts from the person's own recent words (never the model's).
//   deliver_message {draft_id}                          -> never sends: it only asks the person to read the card and tap
//                   Send. The tap is the consent (Face ID would only prove a face was looking at the phone).
//   cancel_message  {draft_id?}                         -> drop the draft on screen and stop any hand-off.
// The model never supplies the text or the recipient, and its word is never consent. Nothing is handed off unless
// the card is actually on screen (another sheet can hide it) and the person tapped Send on it.

@MainActor
final class InCallBridge: ObservableObject {
    let people = PeopleStore()
    private(set) var api: any BridgeAPI = BridgeAPIFactory.make()
    let handOff = HandOffCoordinator()

    @Published var draft: BridgeDraft?
    @Published var person: KairosPerson?
    @Published var isPractice = false
    @Published var isWorking = false
    @Published var isStale = false
    @Published var problem: String?
    @Published var showCard = false
    /// True only while the card's sheet is really visible (set by the sheet itself).
    @Published private(set) var cardOnScreen = false
    /// The agent asked to send: highlight the card and wait for the person's tap.
    @Published var awaitingSendTap = false
    /// A flagged draft: show "Before you send" with the reasons before approving.
    @Published var confirmingSend = false

    /// Bumped whenever the card changes or closes, so slow replies for an old card are ignored.
    private var generation = 0

    /// Call after setup or once a device token arrives: the factory reads the Keychain when it is called.
    func refreshAPI() { api = BridgeAPIFactory.make() }

    func cardAppeared() { cardOnScreen = true }
    func cardDisappeared() { cardOnScreen = false }

    // MARK: - client tools

    struct ToolReply { let json: String; let isError: Bool; var spendsWords = false }

    /// `transcript`: the person's own words since the last Bridge step (user turns only), newest last.
    func handle(_ call: ClientToolCallEvent, transcript: [String]) async -> ToolReply {
        let params = (try? call.getParameters()) ?? [:]
        switch call.toolName {
        case "draft_message":
            return await draftMessage(params, transcript: transcript)
        case "deliver_message":
            return deliverMessage(params)
        case "cancel_message":
            await cancel()
            var r = reply(["status": "cancelled"]); r.spendsWords = true
            return r
        default:
            return reply(["error": "unknown_tool"], isError: true)
        }
    }

    private func draftMessage(_ params: [String: Any], transcript: [String]) async -> ToolReply {
        let alias = (params["alias"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty else { return reply(["status": "ask", "ask_user": "Who should I write to?"]) }
        let words = transcript.suffix(3).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return reply(["status": "ask", "ask_user": "What would you like to say?"]) }

        let resolved: KairosPerson
        switch resolve(alias) {
        case .one(let p): resolved = p
        case .ask(let question): return reply(["status": "ask", "ask_user": question])
        }
        // The recipient must be someone the person named themselves, not just a name the model picked.
        guard named(resolved, in: transcript) else {
            return reply(["status": "ask", "ask_user": "Who is this message for? Please say their name."])
        }
        var p = resolved
        // A different app only if the person said so; otherwise their saved way of reaching this person.
        if let c = (params["channel"] as? String).flatMap(BridgeChannel.init(rawValue:)), c != p.channel,
           said(c, in: transcript) { p.channel = c }
        if let t = (params["tone"] as? String).flatMap({ BridgeTone(rawValue: $0) ?? ($0 == "keep_my_words" ? .keepMyWords : nil) }) {
            p.tone = t
        }
        if let l = params["language"] as? String, Self.languages.contains(l) { p.language = l }

        let meta = BridgeDraftMeta(
            recipient: BridgeRecipient(ref: p.ref, alias: p.alias, relation: p.relation, lang: p.language),
            channel: p.channel.rawValue, tone: p.tone.rawValue, target_lang: p.language,
            user: UserDefaults.standard.string(forKey: "kairos.signoff").map { ["sign_off": $0] },
            transcript: words)
        isWorking = true
        defer { isWorking = false }
        do {
            let d = try await api.draft(audio: nil, meta: meta)
            show(d, for: p)
            // The agent reads this back; the text on the screen is what counts.
            var r = reply(["draft_id": d.draft_id,
                          "summary": d.back_translation ?? d.text,
                          "on_screen": cardOnScreen ? "yes" : "opening",
                          "next": "Ask them to read the message on their screen and tap Send if it is right.",
                          "practice": isPractice ? "yes: nothing can be sent" : "no"])
            r.spendsWords = true
            return r
        } catch BridgeError.unclear(let ask) {
            return reply(["status": "ask", "ask_user": ask])
        } catch let e as BridgeError {
            return reply(["status": "error", "say": e.spoken], isError: true)
        } catch {
            return reply(["status": "error", "say": BridgeError.network("").spoken], isError: true)
        }
    }

    /// Never sends. Highlights the card and asks for the person's tap (the only consent).
    private func deliverMessage(_ params: [String: Any]) -> ToolReply {
        guard let d = draft, let p = person, (params["draft_id"] as? String) == d.draft_id else {
            return reply(["status": "no_such_draft", "say": "There's no message on the screen to send."], isError: true)
        }
        guard cardOnScreen else {
            return reply(["status": "needs_screen", "say": "Please close the other screen so you can see your message first."])
        }
        if d.isBlocked { return reply(["status": "blocked", "say": BridgeError.blocked(d.checks.blocked).spoken]) }
        if isPractice || api.isPracticeDraft(d.draft_id) {
            return reply(["status": "practice", "say": "This is practice only, so nothing will be sent."])
        }
        awaitingSendTap = true
        return reply(["status": "needs_tap",
                      "say": "Please read the message on your screen. If it's right, tap the big button: Send to \(p.alias) on \(p.channel.appName)."])
    }

    // MARK: - card actions

    func show(_ d: BridgeDraft, for p: KairosPerson) {
        generation &+= 1
        draft = d
        person = p
        isPractice = api.isPracticeDraft(d.draft_id)
        isStale = false
        problem = nil
        awaitingSendTap = false
        confirmingSend = false
        handOff.reset()
        showCard = true
    }

    func revise(_ chip: String) async {
        guard let d = draft, let p = person, !isWorking else { return }
        let gen = generation
        isWorking = true
        defer { isWorking = false }
        do {
            let next = try await api.revise(draftId: d.draft_id, request: BridgeReviseRequest(version: d.version, chip: chip))
            guard gen == generation else { return }   // the card closed or changed meanwhile
            show(next, for: p)
        } catch BridgeError.staleOrMismatch {
            guard gen == generation else { return }
            isStale = true
            problem = BridgeError.staleOrMismatch.spoken
        } catch let e as BridgeError {
            if gen == generation { problem = e.spoken }
        } catch {}
    }

    /// The Send button on the card. A flagged draft first shows "Before you send" (confirmingSend).
    func sendTapped() {
        guard let d = draft, !d.isBlocked, !isStale, !isWorking, cardOnScreen else { return }
        awaitingSendTap = false
        if d.needsCheck { confirmingSend = true; return }
        Task { await approveAndHandOff(endCall: endCall) }
    }

    func confirmSend() {
        confirmingSend = false
        Task { await approveAndHandOff(endCall: endCall) }
    }

    /// Set by the presenter: ends the ElevenLabs call (and releases the mic) before another app opens.
    var endCall: () async -> Void = {}

    private func approveAndHandOff(endCall: @escaping () async -> Void) async {
        guard let d = draft, let p = person, !d.isBlocked, !isStale, cardOnScreen else { return }
        if isPractice || api.isPracticeDraft(d.draft_id) {   // practice never reaches a real person
            handOff.showPractice(person: p, channel: p.channel)
            return
        }
        let gen = generation
        isWorking = true
        defer { isWorking = false }
        let approvedAt = Date()
        do {
            let approval = try await api.approve(draftId: d.draft_id, request: BridgeApproveRequest(
                version: d.version, text_hash: d.text_hash, recipient_ref: p.ref, channel: p.channel.rawValue, method: "tap"))
            // Cancelled, closed or hidden while approving: tell the hub and stop here (no countdown, no app switch).
            guard gen == generation, cardOnScreen, draft?.id == d.id else {
                await api.outcome(draftId: d.draft_id, nonce: approval.nonce, outcome: .cancelled)
                return
            }
            // What gets handed off must be exactly what the person read on the card.
            guard approval.text == d.text else {
                await api.outcome(draftId: d.draft_id, nonce: approval.nonce, outcome: .cancelled)
                isStale = true
                problem = BridgeError.staleOrMismatch.spoken
                return
            }
            await handOff.begin(approval: approval, approvedAt: approvedAt, person: p, channel: p.channel,
                                draftId: d.draft_id, api: api, endCall: endCall)
        } catch BridgeError.staleOrMismatch {
            guard gen == generation else { return }
            isStale = true
            problem = BridgeError.staleOrMismatch.spoken
        } catch let e as BridgeError {
            if gen == generation { problem = e.spoken }
        } catch {}
    }

    func cancel() async {
        if let d = draft { await api.cancel(draftId: d.draft_id) }
        close()
    }

    func close() {
        generation &+= 1
        handOff.stop()    // a countdown or share step in progress must not carry on without its card
        handOff.reset()
        draft = nil
        person = nil
        showCard = false
        problem = nil
        isStale = false
        awaitingSendTap = false
        confirmingSend = false
    }

    /// The reasons to look again, in plain words, for "Before you send".
    var checkLines: [String] {
        guard let d = draft else { return [] }
        var lines = CardWords.beforeSendLines(d)
        if let p = person { lines.append("Send it to \(p.recipientLine) on \(p.channel.appName)?") }
        return lines
    }

    // MARK: - helpers

    private static let languages: Set<String> = ["en-GB", "te-Telu", "te-Latn", "hi-Deva", "cy"]

    private enum Resolution { case one(KairosPerson), ask(String) }

    /// Only an exact, unambiguous alias resolves on its own (Amma vs Anna always asks). The answer to that question
    /// ("Amma, your mother") resolves by the full line shown and spoken, which can't be confused.
    private func resolve(_ alias: String) -> Resolution {
        let said = PeopleStore.normaliseName(alias)
        let byLine = people.people.filter { PeopleStore.normaliseName($0.recipientLine) == said }
        if byLine.count == 1 { return .one(byLine[0]) }
        let saidWords = Set(said.split(separator: " ").map(String.init))
        let saidRelations = PeopleStore.relationGroups(of: said)
        let byNameAndRelation = people.people.filter { p in
            saidWords.contains(PeopleStore.normaliseName(p.alias)) &&
            !PeopleStore.relationGroups(of: PeopleStore.normaliseName(p.relation ?? "")).isDisjoint(with: saidRelations)
        }
        if byNameAndRelation.count == 1 { return .one(byNameAndRelation[0]) }
        switch people.match(alias) {
        case .exact(let p): return .one(p)
        case .ambiguous(let options):
            let names = options.prefix(3).map(\.recipientLine).joined(separator: ", or ")
            return .ask("Do you mean \(names)?")
        case .none:
            return .ask("I don't have \(alias) yet. Tap Stop, then Write for me, to add them. Then we can write it together.")
        }
    }

    /// The person said this recipient's name, or their relation word (mum, amma, అమ్మ…), in their own words.
    private func named(_ p: KairosPerson, in transcript: [String]) -> Bool {
        let said = transcript.map(PeopleStore.normaliseName).joined(separator: " ")
        let words = said.split(separator: " ").map(String.init)
        let alias = PeopleStore.normaliseName(p.alias)
        let aliasWords = alias.split(separator: " ").count
        for n in 1...max(1, min(3, aliasWords)) where words.count >= n {
            for i in 0...(words.count - n) where words[i..<(i + n)].joined(separator: " ") == alias { return true }
        }
        let theirs = PeopleStore.relationGroups(of: alias).union(PeopleStore.relationGroups(of: PeopleStore.normaliseName(p.relation ?? "")))
        guard !theirs.isEmpty else { return false }
        let otherNames = Set(people.people.filter { $0.ref != p.ref }.map { PeopleStore.normaliseName($0.alias) })
        let relationWords = words.filter { !otherNames.contains($0) }.joined(separator: " ")
        return !PeopleStore.relationGroups(of: relationWords).isDisjoint(with: theirs)
    }

    /// Whole words only ("signal box" is not Signal); the person must have named the app themselves.
    private func said(_ channel: BridgeChannel, in transcript: [String]) -> Bool {
        let words = Set(transcript.joined(separator: " ").lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        let joined = " " + words.sorted().joined(separator: " ") + " "
        switch channel {
        case .whatsapp: return words.contains("whatsapp") || (words.contains("whats") && words.contains("app"))
        case .sms: return words.contains("text") || words.contains("sms") || words.contains("imessage")
        case .email: return words.contains("email") || words.contains("e") && joined.contains(" mail ")
        case .telegram: return words.contains("telegram")
        case .signal: return words.contains("signal") && !words.contains("box") && !words.contains("phone")
        }
    }

    private func reply(_ obj: [String: String], isError: Bool = false) -> ToolReply {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        return ToolReply(json: String(decoding: data, as: UTF8.self), isError: isError)
    }
}

/// The draft card during a call. "Say it again" asks Kairos to read it, because the phone's own speaker would fight
/// the live call for the audio session; what is on the screen is what gets approved either way.
struct InCallDraftSheet: View {
    @ObservedObject var bridge: InCallBridge
    @ObservedObject var handOff: HandOffCoordinator
    let askKairosToRead: (String) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Color(red: 0.96, green: 0.95, blue: 0.92).ignoresSafeArea()
            if let d = bridge.draft, let p = bridge.person {
                DraftCardView(
                    draft: d, person: p, isPractice: bridge.isPractice, isWorking: bridge.isWorking,
                    isStale: bridge.isStale, problem: bridge.problem,
                    onRevise: { chip in Task { await bridge.revise(chip) } },
                    onSayAgain: { askKairosToRead(d.text) },
                    onSend: { bridge.sendTapped() },
                    onStartAgain: { bridge.close() },
                    onCancel: { Task { await bridge.cancel() } })
            }
            if bridge.awaitingSendTap {
                Text("Kairos is waiting for you. Read your message, then tap Send if it's right.")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(Color(red: 1.0, green: 0.93, blue: 0.75), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 12)
                    .accessibilityAddTraits(.isHeader)
            }
            HandOffOverlay(coordinator: handOff, onPracticeDone: { bridge.close() }, onResultDone: { bridge.close() })
        }
        .onAppear { bridge.cardAppeared() }
        .onDisappear { bridge.cardDisappeared() }
        // While approving or handing off, the sheet can't be swiped away (its Stop button must stay reachable).
        .interactiveDismissDisabled(handOff.isBusy || bridge.isWorking)
        .alert("Before you send", isPresented: $bridge.confirmingSend) {
            Button("Yes, send it") { bridge.confirmSend() }
            Button("No, go back", role: .cancel) {}
        } message: {
            Text(bridge.checkLines.joined(separator: "\n"))
        }
    }
}

/// One line in ContentView: shows the in-call draft card whenever the agent drafts a message.
struct InCallBridgePresenter: ViewModifier {
    @ObservedObject var bridge: InCallBridge
    let endCall: () async -> Void
    let askKairosToRead: (String) -> Void

    func body(content: Content) -> some View {
        content
            .onAppear { bridge.endCall = endCall }
            .sheet(isPresented: $bridge.showCard, onDismiss: { if bridge.draft != nil { bridge.close() } }) {
                InCallDraftSheet(bridge: bridge, handOff: bridge.handOff, askKairosToRead: askKairosToRead)
                    .environmentObject(bridge.people)
            }
    }
}
