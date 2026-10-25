import CryptoKit
import Foundation
import os

// Kairos Communications Bridge, network side.
//  * LiveBridgeAPI talks to the hub on the person's Mac (research/Kairos-Server-Architecture.md, "Our server's API").
//  * MockBridgeAPI is "practice mode": the same contract, made-up drafts, nothing leaves the phone.
//  * FallbackBridgeAPI tries the Mac first and drops to practice mode only while this phone has never reached a Bridge.
// Logs carry only the step name and the HTTP status: never message text, transcripts, aliases, numbers or emails.

private let bridgeLog = Logger(subsystem: "uk.oxhack.tempo", category: "bridge")

// MARK: - Live (the Mac hub)

final class LiveBridgeAPI: BridgeAPI {
    let isPractice = false

    private let baseURL: URL
    private let deviceToken: String?
    private let phoneKey: String?

    /// Ephemeral with no URL cache: draft text and read-back audio must never be written to the app's cache folder.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Only RFC 3986 "unreserved" characters stay as they are, so a draft id can never add a "/" or "?" to the path.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    init(baseURL: URL, deviceToken: String?, phoneKey: String?) {
        self.baseURL = baseURL
        self.deviceToken = deviceToken.flatMap { $0.isEmpty ? nil : $0 }
        self.phoneKey = phoneKey.flatMap { $0.isEmpty ? nil : $0 }
    }

    func draft(audio: Data?, meta: BridgeDraftMeta) async throws -> BridgeDraft {
        // 45 s: speech-to-text, compose and back-translation all run before the server answers.
        var req = try request("api/bridge/draft", method: "POST", timeout: 45)
        let metaJSON = try Self.json(meta)
        if let audio {
            let boundary = "kairos-" + UUID().uuidString
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.httpBody = Self.multipart(boundary: boundary, meta: metaJSON, audio: audio)
        } else {
            // In-call path: the person's own transcript turns are inside meta, so there's nothing else to send.
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = metaJSON
        }
        return try await send(req, step: "draft")
    }

    func revise(draftId: String, request body: BridgeReviseRequest) async throws -> BridgeDraft {
        var req = try request(draftPath(draftId, "revise"), method: "POST", timeout: 45)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Self.json(body)
        return try await send(req, step: "revise")
    }

    func approve(draftId: String, request body: BridgeApproveRequest) async throws -> BridgeApproval {
        var req = try request(draftPath(draftId, "approve"), method: "POST", timeout: 20)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Self.json(body)
        return try await send(req, step: "approve")
    }

    func readback(draftId: String) async throws -> Data? {
        var req = try request(draftPath(draftId, "readback"), method: "GET", timeout: 30)
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        let reply = try await Self.perform(req, step: "readback")
        if reply.code == 404 { return nil }   // no voice for this draft: the card speaks with the phone's own voice
        try Self.check(reply.data, reply.code)
        // A tunnel error page or JSON is not audio; playing it would fail, so treat it as "no read-back".
        if let mime = reply.mime, mime.hasPrefix("text/") || mime.contains("json") { return nil }
        return reply.data.isEmpty ? nil : reply.data
    }

    func outcome(draftId: String, nonce: String?, outcome: BridgeOutcome) async {
        guard let nonce else { return }   // the hub only takes an outcome with the approval's nonce
        guard var req = try? request(draftPath(draftId, "outcome"), method: "POST", timeout: 15) else { return }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The hub knows handed_off | cancelled | failed; a compose sheet's "sent" is still a hand-off to Messages/Mail.
        let wire = outcome == .sent ? BridgeOutcome.handedOff.rawValue : outcome.rawValue
        req.httpBody = try? JSONEncoder().encode(["nonce": nonce, "outcome": wire])
        Self.fireAndForget(req, step: "outcome")
    }

    func cancel(draftId: String) async {
        guard var req = try? request(draftPath(draftId, "cancel"), method: "POST", timeout: 15) else { return }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        Self.fireAndForget(req, step: "cancel")
    }

    // MARK: building requests

    private func request(_ path: String, method: String, timeout: TimeInterval) throws -> URLRequest {
        var root = baseURL.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        // Joined as a string, not appendingPathComponent: that would encode the "%" of an already encoded draft id again.
        guard let url = URL(string: root + "/" + path) else { throw BridgeError.notConfigured }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        // Credentials go in headers, never in the URL (URLs end up in proxy and tunnel logs).
        if let deviceToken {
            req.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        } else if let phoneKey {
            // Until this phone has registered for a device token, the shared phone key still works.
            req.setValue(phoneKey, forHTTPHeaderField: "X-Tempo-Phone-Key")
        }
        req.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    private func draftPath(_ draftId: String, _ action: String) throws -> String {
        let id = draftId.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? ""
        guard !id.isEmpty else { throw BridgeError.server(404, "") }
        return "api/bridge/drafts/\(id)/\(action)"
    }

    private static func json<T: Encodable>(_ value: T) throws -> Data {
        do { return try JSONEncoder().encode(value) } catch { throw BridgeError.server(0, "") }
    }

    /// meta first, so the server can turn a bad request away before it reads the audio.
    private static func multipart(boundary: String, meta: Data, audio: Data) -> Data {
        var body = Data()
        func add(_ text: String) { body.append(Data(text.utf8)) }
        add("--\(boundary)\r\n")
        add("Content-Disposition: form-data; name=\"meta\"\r\n")
        add("Content-Type: application/json\r\n\r\n")
        body.append(meta)
        add("\r\n--\(boundary)\r\n")
        add("Content-Disposition: form-data; name=\"audio\"; filename=\"clip.m4a\"\r\n")
        add("Content-Type: audio/mp4\r\n\r\n")
        body.append(audio)
        add("\r\n--\(boundary)--\r\n")
        return body
    }

    // MARK: sending

    private struct Reply { let data: Data; let code: Int; let mime: String? }

    private static func perform(_ req: URLRequest, step: String) async throws -> Reply {
        do {
            let (data, response) = try await session.data(for: req)
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            bridgeLog.info("bridge \(step, privacy: .public) -> \(code, privacy: .public)")
            return Reply(data: data, code: code, mime: http?.mimeType?.lowercased())
        } catch let error as URLError where error.code == .cancelled {
            // The person closed the card: not a network fault, so never a reason to fall back to practice mode.
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where couldNotConnect(error.code) {
            // Failed before any of the request left the phone, so "Nothing was sent" is true.
            bridgeLog.error("bridge \(step, privacy: .public) -> could not connect")
            throw BridgeError.unreachable
        } catch {
            // Timed out or dropped mid-way: the Mac may already have the clip, so this is not "unreachable".
            bridgeLog.error("bridge \(step, privacy: .public) -> connection failed")
            throw BridgeError.network(error.localizedDescription)
        }
    }

    /// Connection-setup failures only (no Wi-Fi, no DNS, Mac or tunnel down, captive-portal TLS).
    /// .timedOut and .networkConnectionLost stay .network: they can happen after the whole clip was uploaded.
    private static func couldNotConnect(_ code: URLError.Code) -> Bool {
        switch code {
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet,
             .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return true
        default:
            return false
        }
    }

    private func send<T: Decodable>(_ req: URLRequest, step: String) async throws -> T {
        let reply = try await Self.perform(req, step: step)
        try Self.check(reply.data, reply.code)
        do {
            return try JSONDecoder().decode(T.self, from: reply.data)
        } catch {
            bridgeLog.error("bridge \(step, privacy: .public): reply was not in the expected shape")
            throw BridgeError.server(reply.code, "")
        }
    }

    /// Turns a non-2xx status into the BridgeError the cards know how to say out loud.
    private static func check(_ data: Data, _ code: Int) throws {
        guard !(200..<300).contains(code) else { return }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = obj?["error"] as? String
        if code == 422, error == "unclear" {
            let ask = (obj?["ask_user"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw BridgeError.unclear(askUser: ask.isEmpty ? "Sorry, I didn't catch that. Please say it again." : ask)
        }
        if code == 409 { throw BridgeError.staleOrMismatch }
        // BridgeError.spoken reads this message aloud. A bare code like "too_large" isn't plain words,
        // so only a sentence is kept; otherwise the card says its own plain sentence.
        let message = [error, obj?["message"] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.contains(" ") } ?? ""
        throw BridgeError.server(code, message.isEmpty ? plainSentence(for: code) : message)
    }

    /// Tunnels and proxies answer these with no JSON; "Something went wrong" would give the person nothing to do.
    private static func plainSentence(for code: Int) -> String {
        switch code {
        case 401, 403: return "Your Mac didn't recognise this phone, so nothing was sent. Kairos needs to be connected to your Mac again."
        case 413: return "That recording was too long to send, so nothing was sent. Please say it again in fewer words."
        case 429: return "Your Mac is busy, so nothing was sent. Please wait a minute and try again."
        default: return ""
        }
    }

    /// Outcome and cancel only feed the audit log, so the hand-off to WhatsApp or closing the card never waits on them.
    private static func fireAndForget(_ req: URLRequest, step: String) {
        Task.detached(priority: .utility) {
            _ = try? await perform(req, step: step)
        }
    }
}

// MARK: - Practice mode

/// Behaves like the server contract with made-up but realistic drafts, so the whole card can be tried without a Mac.
/// It never hears the audio: a recording turns into a sample sentence, which is why the UI shows "Practice mode".
final class MockBridgeAPI: BridgeAPI {
    let isPractice = true

    /// What the mock "hears" when it gets a recording (it can't transcribe one).
    static let sampleHeard = "tell her I will come at 8 tonight and she should eat her dinner"
    /// What "I heard" shows instead: the person must never be told they said words they didn't.
    static let sampleShown = "Practice example. Without your Mac I can't hear your recording, so I used this sentence instead: \""
        + sampleHeard + "\""
    /// Not "handoff": HandOffCoordinator.begin refuses any other delivery, so a practice approval that slipped
    /// past the UI still can't open WhatsApp, Messages or Mail for a real person.
    static let practiceDelivery = "practice"

    private struct Entry {
        var draft: BridgeDraft      // always the latest version: older versions can't be approved
        let meta: BridgeDraftMeta
        let fromSample: Bool        // heard text is the sample sentence, not the person's own words
    }

    private let lock = NSLock()
    private var drafts: [String: Entry] = [:]

    init() {}

    func draft(audio: Data?, meta: BridgeDraftMeta) async throws -> BridgeDraft {
        try await Self.pause()
        let spoken = (meta.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Same 422s as the server, so practice mode also shows the "I didn't catch that" path.
        if spoken.isEmpty, audio?.isEmpty ?? true {
            throw BridgeError.unclear(askUser: "I didn't hear a message. What would you like to say?")
        }
        if meta.recipient.alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw BridgeError.unclear(askUser: "Who should I send this to?")
        }
        let fromSample = spoken.isEmpty
        let id = "d_" + Self.hex(12)
        let draft = Self.make(id: id, version: 1, heard: fromSample ? Self.sampleHeard : spoken,
                              fromSample: fromSample, meta: meta, style: Style(tone: meta.tone))
        lock.withLock { drafts[id] = Entry(draft: draft, meta: meta, fromSample: fromSample) }
        return draft
    }

    func revise(draftId: String, request: BridgeReviseRequest) async throws -> BridgeDraft {
        try await Self.pause()
        let style = Style(revise: request)
        return try lock.withLock {
            guard var entry = drafts[draftId] else { throw Self.gone }
            // Always latest + 1, so a double tap on a chip can't make two drafts share a version number.
            // From the sample, not heard.text: that carries the "Practice example" label, which isn't message text.
            let heard = entry.fromSample ? Self.sampleHeard : entry.draft.heard.text
            let next = Self.make(id: draftId, version: entry.draft.version + 1, heard: heard,
                                 fromSample: entry.fromSample, meta: entry.meta, style: style)
            entry.draft = next
            drafts[draftId] = entry
            return next
        }
    }

    func approve(draftId: String, request: BridgeApproveRequest) async throws -> BridgeApproval {
        try await Self.pause()
        return try lock.withLock {
            guard let entry = drafts[draftId] else { throw Self.gone }
            let latest = entry.draft
            // The lock: only the exact latest text, for the person it was written for, can be approved.
            guard request.version == latest.version, request.text_hash == latest.text_hash,
                  request.recipient_ref == entry.meta.recipient.ref else { throw BridgeError.staleOrMismatch }
            if latest.isBlocked { throw BridgeError.blocked(latest.checks.blocked) }
            return BridgeApproval(nonce: "n_" + Self.hex(24), expires_in: 120, delivery: Self.practiceDelivery,
                                  text: latest.text)
        }
    }

    /// No voice from a Mac in practice mode; nil tells the card to use the phone's own voice.
    func readback(draftId: String) async throws -> Data? { nil }

    func outcome(draftId: String, nonce: String?, outcome: BridgeOutcome) async {}

    func cancel(draftId: String) async {
        lock.withLock { _ = drafts.removeValue(forKey: draftId) }
    }

    /// "sha256:" + lowercase hex of the UTF-8 text, the same shape as the server's text_hash.
    static func textHash(_ text: String) -> String {
        "sha256:" + SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: helpers

    private static let gone = BridgeError.server(404, "That message has gone. Please start it again.")

    /// 0.8 to 1.4 s, so practice feels like the real thing (spinners and disabled buttons get exercised).
    private static func pause() async throws {
        try await Task.sleep(nanoseconds: UInt64(Double.random(in: 0.8...1.4) * 1_000_000_000))
    }

    private static func hex(_ count: Int) -> String {
        (0..<count).map { _ in String(Int.random(in: 0..<16), radix: 16) }.joined()
    }

    private static func make(id: String, version: Int, heard: String, fromSample: Bool,
                             meta: BridgeDraftMeta, style: Style) -> BridgeDraft {
        let alias = meta.recipient.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let signOff = meta.user?["sign_off"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let written = compose(style, lang: Lang(meta.target_lang), alias: alias,
                              signOff: (signOff?.isEmpty ?? true) ? nil : signOff, heard: heard, fromSample: fromSample)
        return BridgeDraft(draft_id: id, version: version,
                           heard: BridgeHeard(text: fromSample ? sampleShown : heard, lang: "en"),
                           text: written.text, back_translation: written.back,
                           checks: BridgeChecks(blocked: [], flags: flags(text: written.text, heard: heard)),
                           changes_made: style.changes, missing: [], text_hash: textHash(written.text))
    }

    // MARK: writing the draft

    private enum Style {
        case calm, warmer, formal, shorter, ownWords

        /// First version, from the person's default tone for this recipient.
        init(tone: String) {
            switch tone {
            case "formal": self = .formal
            case "brief": self = .shorter
            case "keep_my_words", "keep-my-words": self = .ownWords
            default: self = .calm
            }
        }

        /// A chip on the card. The instruction wins over the tone when both are sent.
        init(revise request: BridgeReviseRequest) {
            switch request.chip ?? "" {
            case "more_formal", "formal", "polite": self = .formal
            case "shorter", "brief": self = .shorter
            case "keep_my_words": self = .ownWords
            default: self = .warmer
            }
        }

        var changes: [String] {
            switch self {
            case .calm: return ["calmer tone"]
            case .warmer: return ["warmer"]
            case .formal: return ["more formal"]
            case .shorter: return ["shorter"]
            case .ownWords: return []
            }
        }
    }

    private enum Lang {
        case teTelu, teLatn, hi, cy, en
        init(_ tag: String) {
            let t = tag.lowercased()
            if t.hasPrefix("te") { self = t.contains("latn") ? .teLatn : .teTelu }
            else if t.hasPrefix("hi") { self = .hi }
            else if t.hasPrefix("cy") { self = .cy }
            else { self = .en }
        }
    }

    /// What the person calls them, as a native speaker would write it ("Amma" -> "అమ్మా"); other names stay as typed.
    private static func vocative(_ alias: String, _ lang: Lang) -> String {
        let key = alias.lowercased()
        switch lang {
        case .teTelu:
            return ["amma": "అమ్మా", "nanna": "నాన్నా", "akka": "అక్కా", "ammamma": "అమ్మమ్మా", "thatha": "తాతయ్యా"][key] ?? alias
        case .hi:
            return ["amma": "अम्मा", "maa": "माँ", "mummy": "मम्मी", "papa": "पापा", "nani": "नानी", "dadi": "दादी"][key] ?? alias
        default:
            return alias
        }
    }

    private static func compose(_ style: Style, lang: Lang, alias a: String, signOff: String?,
                                heard: String, fromSample: Bool) -> (text: String, back: String?) {
        // Keep my words: exactly what was heard, nothing translated or tidied.
        if case .ownWords = style { return (heard, nil) }
        let v = vocative(a, lang)
        func close(_ phrase: String) -> String { signOff.map { " \(phrase), \($0)" } ?? "" }
        let short = signOff.map { " – \($0)" } ?? ""

        switch (lang, style) {
        case (.en, _) where !fromSample:
            return (ownEnglish(style, alias: a, core: tidy(heard, alias: a), close: close, short: short), nil)
        case (.en, .warmer):
            return ("Hello \(a), I'll be with you at 8 tonight and I can't wait to see you. Please don't forget to eat your dinner.\(close("Lots of love"))", nil)
        case (.en, .formal):
            return ("Dear \(a), I will arrive at 8 o'clock this evening. Please do have your dinner.\(close("Kind regards"))", nil)
        case (.en, .shorter):
            return ("Coming at 8 tonight. Eat your dinner.\(short)", nil)
        case (.en, _):
            return ("Hi \(a), I'll come at 8 tonight. Please make sure you eat your dinner.\(close("Love"))", nil)

        case (.teTelu, .warmer):
            return ("\(v), నేను ఈ రాత్రి 8 గంటలకు వస్తాను, మిమ్మల్ని చూడాలని ఎదురుచూస్తున్నాను. దయచేసి సమయానికి భోజనం చేయండి.\(close("చాలా ప్రేమతో"))",
                    "\(a), I will come at 8 tonight, I'm looking forward to seeing you. Please have your dinner on time.\(close("With lots of love"))")
        case (.teTelu, .formal):
            return ("నమస్కారం \(v). నేను ఈ రోజు రాత్రి 8 గంటలకు వస్తాను. దయచేసి మీరు భోజనం చేయండి.\(close("నమస్కారాలతో"))",
                    "Greetings, \(a). I will come tonight at 8 o'clock. Please do have your dinner.\(close("With regards"))")
        case (.teTelu, .shorter):
            return ("రాత్రి 8 కి వస్తాను. భోజనం చేయండి.\(short)", "Coming at 8 tonight. Please eat.\(short)")
        case (.teTelu, _):
            return ("\(v), నేను ఈ రాత్రి 8 గంటలకు వస్తాను. మీరు భోజనం చేయండి.\(close("ప్రేమతో"))",
                    "\(a), I will come at 8 tonight. Please have your dinner.\(close("With love"))")

        case (.teLatn, .warmer):
            return ("\(a), nenu ee raatri 8 gantalaki vastaanu, mimmalni choodaalani eduruchoostunnaanu. Dayachesi samayaaniki bhojanam cheyyandi.\(close("Chaalaa prematho"))",
                    "\(a), I will come at 8 tonight, I'm looking forward to seeing you. Please have your dinner on time.\(close("With lots of love"))")
        case (.teLatn, .formal):
            return ("Namaskaaram \(a). Nenu ee roju raatri 8 gantalaki vastaanu. Dayachesi meeru bhojanam cheyyandi.\(close("Namaskaaraalatho"))",
                    "Greetings, \(a). I will come tonight at 8 o'clock. Please do have your dinner.\(close("With regards"))")
        case (.teLatn, .shorter):
            return ("Raatri 8 ki vastaanu. Bhojanam cheyyandi.\(short)", "Coming at 8 tonight. Please eat.\(short)")
        case (.teLatn, _):
            return ("\(a), nenu ee raatri 8 gantalaki vastaanu. Meeru bhojanam cheyyandi.\(close("Prematho"))",
                    "\(a), I will come at 8 tonight. Please have your dinner.\(close("With love"))")

        case (.hi, .warmer):
            return ("\(v), मैं आज रात 8 बजे आऊँगा, आपसे मिलने का इंतज़ार है। समय पर खाना खा लीजिए।\(close("ढेर सारा प्यार"))",
                    "\(a), I will come at 8 tonight, I'm looking forward to seeing you. Have your dinner on time.\(close("Lots of love"))")
        case (.hi, .formal):
            return ("नमस्ते \(v)। मैं आज रात 8 बजे पहुँचूँगा। कृपया भोजन कर लीजिए।\(close("सादर"))",
                    "Namaste, \(a). I will arrive at 8 tonight. Please do have your meal.\(close("Respectfully"))")
        case (.hi, .shorter):
            return ("रात 8 बजे आऊँगा। खाना खा लीजिए।\(short)", "Coming at 8 tonight. Please eat.\(short)")
        case (.hi, _):
            return ("\(v), मैं आज रात 8 बजे आऊँगा। आप खाना खा लीजिए।\(close("प्यार से"))",
                    "\(a), I will come at 8 tonight. Please have your dinner.\(close("With love"))")

        case (.cy, .warmer):
            return ("\(a) annwyl, dof i draw am 8 heno, alla i ddim aros i dy weld di. Cofia fwyta dy swper.\(close("Cariad mawr"))",
                    "Dear \(a), I'll come over at 8 tonight, I can't wait to see you. Remember to eat your supper.\(close("Lots of love"))")
        case (.cy, .formal):
            return ("Annwyl \(a), byddaf yn cyrraedd am 8 o'r gloch heno. Cofiwch fwyta eich swper, os gwelwch yn dda.\(close("Cofion"))",
                    "Dear \(a), I will arrive at 8 o'clock tonight. Please remember to eat your supper.\(close("Regards"))")
        case (.cy, .shorter):
            return ("Dof i am 8 heno. Bwyta dy swper.\(short)", "Coming at 8 tonight. Eat your supper.\(short)")
        case (.cy, _):
            return ("Helo \(a), dof i draw am 8 heno. Cofia fwyta dy swper.\(close("Cariad"))",
                    "Hello \(a), I'll come over at 8 tonight. Remember to eat your supper.\(close("Love"))")
        }
    }

    /// English built from the person's own transcript. It only reshapes the words, so every name, number and time stays.
    private static func ownEnglish(_ style: Style, alias a: String, core: String,
                                   close: (String) -> String, short: String) -> String {
        switch style {
        case .warmer: return "Hello \(a), I hope you're keeping well.\n\(core) Take care of yourself.\(close("Lots of love"))"
        case .formal: return "Dear \(a),\n\(swap(core, formal: true))\(close("Kind regards"))"
        case .shorter: return swap(core, formal: false) + short
        default: return "Hi \(a),\n\(core)\(close("Love"))"
        }
    }

    /// "tell her I will come and she should eat" -> "I will come and you should eat.": the person was talking to
    /// Kairos about them, and the message talks to them.
    private static func tidy(_ heard: String, alias: String) -> String {
        let opts: String.CompareOptions = [.regularExpression, .caseInsensitive]
        var s = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = "her|him|them" + (alias.isEmpty ? "" : "|" + NSRegularExpression.escapedPattern(for: alias))
        s = s.replacingOccurrences(of: "^(please\\s+)?((can|could|would) you\\s+)?(tell|ask|let)\\s+(\(who))\\s+(know\\s+)?(that\\s+)?",
                                   with: "", options: opts)
        s = s.replacingOccurrences(of: "\\b(she|he|they)\\s+(should|must|can|could|will|would|needs? to|has to|have to)\\b",
                                   with: "you $2", options: opts)
        s = s.replacingOccurrences(of: "\\byou needs to\\b", with: "you need to", options: opts)
        s = s.replacingOccurrences(of: "\\byou has to\\b", with: "you have to", options: opts)
        s = s.replacingOccurrences(of: "\\b(eat|take|have|finish|drink|bring)\\s+(her|his|their)\\b", with: "$1 your", options: opts)
        guard let first = s.first else { return heard }
        s = first.uppercased() + s.dropFirst()
        if let last = s.last, !".!?".contains(last) { s += "." }
        return s
    }

    /// Formal spells contractions out; shorter folds them in. Words are only rejoined, never dropped.
    /// Case-sensitive on purpose: a case-blind match would turn a sentence-opening "It is" into "it's".
    private static func swap(_ text: String, formal: Bool) -> String {
        let pairs = [("I'll", "I will"), ("I'm", "I am"), ("don't", "do not"), ("can't", "cannot"),
                     ("won't", "will not"), ("it's", "it is"), ("you're", "you are")]
        return pairs.reduce(text) { s, pair in
            let (from, to) = formal ? pair : (pair.1, pair.0)
            return s.replacingOccurrences(of: "\\b\(NSRegularExpression.escapedPattern(for: from))\\b", with: to,
                                          options: .regularExpression)
        }
    }

    // MARK: checks (the same kinds the server reports)

    private static let timeBefore: Set<String> = ["at", "by", "around", "until", "till", "before", "after", "from", "am"]
    private static let timeAfter: Set<String> = ["o'clock", "am", "pm", "a.m", "p.m", "tonight", "gantalaki", "ki",
                                                 "గంటలకు", "కి", "बजे", "o'r"]
    private static let numberWords = ["one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
                                      "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12"]
    private static let topics: [(kind: String, words: Set<String>)] = [
        ("money", ["money", "pay", "paid", "bank", "pension", "rupees", "pounds", "loan", "transfer", "rent"]),
        ("health", ["doctor", "hospital", "medicine", "tablets", "pills", "gp", "nurse", "prescription"]),
        ("legal", ["solicitor", "lawyer", "court", "police", "contract"]),
        ("work", ["work", "office", "boss", "manager", "job"]),
    ]

    private static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols)) }
            .filter { !$0.isEmpty }
    }

    /// Every number in the draft becomes a note saying whether the person actually said it, plus topic notes
    /// (money, health, legal, work) so the extra-tap path can be practised too.
    private static func flags(text: String, heard: String) -> [BridgeFlag] {
        let heardWords = words(heard)
        let said = Set(heardWords.compactMap { w -> String? in
            if let n = numberWords[w] { return n }
            return w.range(of: "^\\d+(:\\d{2})?", options: .regularExpression).map { String(w[$0]) }
        })
        let tokens = words(text)
        var seen = Set<String>()
        var out: [BridgeFlag] = []
        for (i, w) in tokens.enumerated() {
            guard let r = w.range(of: "^\\d+(:\\d{2})?", options: .regularExpression) else { continue }
            let value = String(w[r])
            guard seen.insert(value).inserted else { continue }
            let suffix = String(w[r.upperBound...])
            let prev = i > 0 ? tokens[i - 1] : ""
            let next = i + 1 < tokens.count ? tokens[i + 1] : ""
            let isTime = value.contains(":") || suffix == "am" || suffix == "pm"
                || timeBefore.contains(prev) || timeAfter.contains(next)
            out.append(BridgeFlag(kind: isTime ? "time" : "number", value: value, in_transcript: said.contains(value)))
        }
        let heardSet = Set(heardWords)
        for topic in topics where !heardSet.isDisjoint(with: topic.words)
            || (topic.kind == "money" && heard.contains(where: { "£$€₹".contains($0) })) {
            out.append(BridgeFlag(kind: topic.kind, value: nil, in_transcript: true))
        }
        return out
    }
}

// MARK: - Live first, practice only while this phone has never reached a Bridge

/// Tries the Mac for every new draft. Only when the Mac answers that it has no Bridge (404 / 501), or the address isn't
/// usable, AND this phone has never had a live draft, is that draft made in practice mode. A Wi-Fi blip, a timeout or a
/// Mac that can't be reached is never turned into practice: the person's real recording would be swapped for invented
/// text without warning. Every later call for a draft goes where the draft was made: a practice id means nothing to
/// the Mac (and must never reach it), and a real one must never be approved by the mock.
final class FallbackBridgeAPI: BridgeAPI {
    /// Set after the first live draft. From then on the Bridge is known to exist, so a failure is an outage to show.
    static let liveSeenKey = "kairos.bridge.liveSeen"

    private let live: any BridgeAPI
    private let mock: any BridgeAPI
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var practiceIds: Set<String> = []
    private var lastWasPractice = false

    init(live: any BridgeAPI, mock: any BridgeAPI, defaults: UserDefaults = .standard) {
        self.live = live
        self.mock = mock
        self.defaults = defaults
    }

    /// Follows the most recent draft, so the "Practice mode" badge matches the card on screen.
    /// For a decision about one draft (hand-off or not), prefer `isPracticeDraft(_:)`.
    var isPractice: Bool { lock.withLock { lastWasPractice } }

    /// Whether this exact draft was made in practice mode. Never wrong for an older draft, unlike `isPractice`.
    func madeInPractice(_ draftId: String) -> Bool {
        lock.withLock { practiceIds.contains(draftId) }
    }

    private var liveSeen: Bool { defaults.bool(forKey: Self.liveSeenKey) }

    private func markLiveSeen() {
        if !liveSeen { defaults.set(true, forKey: Self.liveSeenKey) }
    }

    func draft(audio: Data?, meta: BridgeDraftMeta) async throws -> BridgeDraft {
        do {
            let draft = try await live.draft(audio: audio, meta: meta)
            markLiveSeen()
            lock.withLock { lastWasPractice = false }
            return draft
        } catch let error as BridgeError {
            // A 422 question is the Bridge's own answer, so the Bridge exists even though there's no draft yet.
            if case .unclear = error { markLiveSeen() }
            guard !liveSeen, Self.bridgeMissing(error) else {
                // Once the Bridge is known, a bare 404 is the tunnel saying the Mac is offline, not "no Bridge".
                if liveSeen, case .server(404, "") = error { throw BridgeError.unreachable }
                throw error
            }
            bridgeLog.notice("bridge draft: this Mac has no Bridge yet, using practice mode")
            let draft = try await mock.draft(audio: audio, meta: meta)
            lock.withLock {
                practiceIds.insert(draft.draft_id)
                lastWasPractice = true
            }
            return draft
        }
    }

    func revise(draftId: String, request: BridgeReviseRequest) async throws -> BridgeDraft {
        try await backend(for: draftId).revise(draftId: draftId, request: request)
    }

    func approve(draftId: String, request: BridgeApproveRequest) async throws -> BridgeApproval {
        try await backend(for: draftId).approve(draftId: draftId, request: request)
    }

    func readback(draftId: String) async throws -> Data? {
        try await backend(for: draftId).readback(draftId: draftId)
    }

    func outcome(draftId: String, nonce: String?, outcome: BridgeOutcome) async {
        await backend(for: draftId).outcome(draftId: draftId, nonce: nonce, outcome: outcome)
    }

    func cancel(draftId: String) async {
        await backend(for: draftId).cancel(draftId: draftId)
    }

    private func backend(for draftId: String) -> any BridgeAPI {
        madeInPractice(draftId) ? mock : live
    }

    /// Only "the Bridge isn't there" may fall back. .network and .unreachable never do (see the class comment);
    /// a 409, a 422 question or any other server answer is real and is shown.
    private static func bridgeMissing(_ error: BridgeError) -> Bool {
        switch error {
        case .server(404, _), .server(501, _), .notConfigured: return true
        default: return false
        }
    }
}

extension BridgeAPI {
    /// Per-draft practice check for the hand-off decision: true means this draft must go to the practice result,
    /// never to WhatsApp, Messages or Mail.
    func isPracticeDraft(_ draftId: String) -> Bool {
        if let fallback = self as? FallbackBridgeAPI { return fallback.madeInPractice(draftId) }
        return isPractice
    }
}

// MARK: - Factory

enum BridgeAPIFactory {
    /// Practice mode until this phone has the Mac's address and a credential; otherwise the Mac, with practice only
    /// until that Mac's Bridge has answered once (see FallbackBridgeAPI).
    static func make() -> any BridgeAPI {
        func stored(_ name: String) -> String? {
            let value = KeyStore.get(name)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
        // https only, like the setup link: the device token must never travel unencrypted.
        guard let base = stored("base").flatMap(URL.init(string:)), base.scheme?.lowercased() == "https" else {
            return MockBridgeAPI()
        }
        let token = stored("device_token")
        let key = stored("key")
        guard token != nil || key != nil else { return MockBridgeAPI() }
        return FallbackBridgeAPI(live: LiveBridgeAPI(baseURL: base, deviceToken: token, phoneKey: key),
                                 mock: MockBridgeAPI())
    }
}
