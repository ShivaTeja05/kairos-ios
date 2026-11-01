import Combine
import Foundation
import os

// kairos-mesh: this iPhone as one of the person's devices, with ONE Kairos across them.
//
// While Kairos is open, the node keeps one request open to the hub on the person's Mac ("anything for me?"). A task
// from another device (the Mac, a browser) runs through KairosAgent here, exactly like something the person typed:
// rules first, then the model, then the SafetyGate. Anything that reaches a person, money or another app shows the
// card and needs Face ID on THIS phone (KairosAgent.remoteAlwaysConfirm), so the hub can route but never approve.
// Progress ("waiting for Face ID") and the answer go back to the hub, where the device that asked can see them.
//
// The other way round, the same hub is Kairos's memory across devices: what is said here is added to the one
// conversation (shareTurn), and a request the phone's rules don't know goes to the hub's brain (ask), which runs
// the Mac's open model with the whole conversation, so "what did I ask on my Mac?" works from here too.
//
// The hub is reached only over the person's private Tailscale network: https://<mac>.<tailnet>.ts.net, shared by
// `tailscale serve` on the Mac. Pairing: `kairos pair` or "Add a device" on the Mac shows a QR code of
//   kairos://mesh?hub=https://<mac>.<tailnet>.ts.net&code=123456
// The iPhone's Camera opens it here; Kairos asks before joining, Face ID confirms it, and the join only counts if
// the connection really went through Tailscale (a 100.x / fd7a:115c:a1e0:: address: a public "Funnel" name with
// the same .ts.net ending is refused). Settings › Your Mac takes the same two things by hand. The login is kept
// in this phone's Keychain.
// Logs carry only task ids and HTTP statuses: never what was asked or answered.

private let meshLog = Logger(subsystem: "uk.oxhack.tempo", category: "mesh")

@MainActor
final class MeshNode: ObservableObject {
    static let shared = MeshNode()

    enum Status: Equatable {
        case notPaired
        case connecting
        case ready
        case working(String)
        /// One plain sentence: what is wrong and what to do.
        case offline(String)

        var line: String {
            switch self {
            case .notPaired: return "Not joined to your Mac yet"
            case .connecting: return "Connecting to your Mac…"
            case .ready: return "Connected to your Mac"
            case .working(let from): return "Working on a request from \(from)"
            case .offline(let why): return why
            }
        }
    }

    /// A pairing link that is waiting for the person's OK.
    struct PendingLink: Identifiable, Equatable {
        let id = UUID()
        let hub: URL
        let code: String
        var host: String { hub.host ?? hub.absoluteString }
    }

    @Published private(set) var status: Status
    @Published private(set) var lastTask: String?
    @Published var pendingLink: PendingLink?
    /// The result of the last pairing (shown under the connection line), e.g. why a link was refused.
    @Published var note: String?

    private var loop: Task<Void, Never>?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = 40   // a long-poll is held for up to 25 s
        return URLSession(configuration: config)
    }()

    /// The login also lives in memory, so a Keychain that refuses to save (an unsigned build) can't silently lose it.
    private var hubNow: URL?
    private var tokenNow: String?

    private init() {
        status = .notPaired
        if isPaired { status = .connecting }
    }

    var hub: URL? {
        hubNow ?? KeyStore.get("mesh_hub").flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }
    private var token: String? {
        tokenNow ?? KeyStore.get("mesh_token").flatMap { $0.isEmpty ? nil : $0 }
    }
    var isPaired: Bool { hub != nil && token != nil }
    /// Reached over the person's Tailscale network (the Mac's *.ts.net name).
    var overTailscale: Bool { hub.map(Self.isTailnet) ?? false }

    static func isTailnet(_ url: URL) -> Bool { (url.host ?? "").lowercased().hasSuffix(".ts.net") }

    // MARK: - Pairing

    /// kairos://mesh?hub=https://mac.tail1234.ts.net&code=123456 — never joins silently: a link can come from a
    /// web page or a message, and the Mac it names could send this phone tasks. Only the person's own tailnet
    /// address (https, *.ts.net) is accepted from a link; anything else can still be typed in Settings.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme == "kairos" || url.scheme == "tempo", url.host == "mesh" else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let hubText = items.first(where: { $0.name == "hub" })?.value,
              let code = items.first(where: { $0.name == "code" })?.value else {
            note = "That pairing link is incomplete. Make a new code on your Mac."
            return true
        }
        guard let hub = Self.hubURL(hubText), hub.scheme == "https", Self.isTailnet(hub) else {
            note = "That link isn't for a Mac on your Tailscale network, so Kairos ignored it."
            meshLog.notice("pairing link refused: not an https tailnet address")
            return true
        }
        pendingLink = PendingLink(hub: hub, code: code)
        return true
    }

    /// The person said yes to this pairing link (passed in: the alert has already cleared `pendingLink`).
    /// Face ID / passcode confirms it's the owner, since the Mac it names can then ask this phone for things.
    func confirmLink(_ link: PendingLink) async {
        if pendingLink?.id == link.id { pendingLink = nil }
        let replacing = isPaired && hub != link.hub
        guard await OwnerCheck.verify(reason: replacing ? "Join a different Mac" : "Join your Mac") else {
            note = replacing ? "Kept your current Mac." : "Not joined."
            return
        }
        do {
            try await pair(hub: link.hub.absoluteString, code: link.code)
            note = "Joined your Mac. Kairos on this iPhone and your Mac now share one conversation."
        } catch {
            note = Self.problem(error, hub: link.hub)
        }
    }

    func cancelLink() { pendingLink = nil }

    /// Join the person's devices with a one-time code from a device that already joined.
    func pair(hub hubText: String, code: String) async throws {
        guard let hub = Self.hubURL(hubText) else { throw MeshError.badHub }
        let clean = code.filter(\.isNumber)
        guard clean.count == 6 else { throw MeshError.badCode }
        let wasPaired = isPaired
        stop()
        status = .connecting
        note = nil
        do {
            // A *.ts.net name is only private when it is reached through Tailscale itself: a public "Funnel" name
            // with the same ending resolves to a public address. Check first, so the code never goes to one.
            if Self.isTailnet(hub) {
                let peer = PeerAddress()
                let hello = URLRequest(url: hub.appendingPathComponent("api/hello"), timeoutInterval: 45)  // a first certificate can take ~30 s
                _ = try await session.data(for: hello, delegate: peer)
                if let address = peer.address, !Self.isTailscaleAddress(address) {
                    meshLog.error("join refused: the .ts.net name was not reached through Tailscale")
                    throw MeshError.notTailnet
                }
            }
            var req = URLRequest(url: hub.appendingPathComponent("api/join"), timeoutInterval: 45)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["name": "iPhone", "platform": "ios", "code": clean])
            let peer = PeerAddress()
            let (data, response) = try await session.data(for: req, delegate: peer)
            let http = (response as? HTTPURLResponse)?.statusCode ?? 0
            meshLog.notice("join: HTTP \(http)")
            // The same check on the join itself (the name could have changed address in between): nothing is saved.
            if Self.isTailnet(hub), let address = peer.address, !Self.isTailscaleAddress(address) {
                meshLog.error("join refused: the .ts.net name was not reached through Tailscale")
                throw MeshError.notTailnet
            }
            guard http == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["token"] as? String else {
                throw http == 403 ? MeshError.codeRefused : (http == 429 ? MeshError.tooManyCodes : MeshError.http(http))
            }
            hubNow = hub
            tokenNow = token
            KeyStore.set("mesh_hub", hub.absoluteString)
            KeyStore.set("mesh_token", token)
            if KeyStore.get("mesh_token") != token {
                meshLog.error("keychain refused the login: joined until Kairos closes, then pair again")
            }
            start()
        } catch {
            // The old login (if any) still works: carry on with it.
            status = wasPaired ? .connecting : .notPaired
            if wasPaired { start() }
            throw error
        }
    }

    /// Leave: forget the login. The Mac can also remove this iPhone.
    func leave() {
        stop()
        hubNow = nil
        tokenNow = nil
        note = nil
        KeyStore.set("mesh_hub", "")
        KeyStore.set("mesh_token", "")
        status = .notPaired
    }

    /// "mac.tail1234.ts.net" -> https (Tailscale serve); "192.168.1.20:8778" or "mac.local:8778" -> http (local only).
    static func hubURL(_ text: String) -> URL? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.contains("://") {
            let host = t.split(separator: "/").first.flatMap { $0.split(separator: ":").first }.map(String.init) ?? t
            t = (host.lowercased().hasSuffix(".ts.net") ? "https://" : "http://") + t
        }
        guard let url = URL(string: t), let host = url.host, !host.isEmpty,
              url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }

    // MARK: - The loop

    /// When Kairos comes to the front.
    func start() {
        // Not during the self-test: a task from the Mac would run as a dry run (nothing done). The test starts
        // the loop again when it ends.
        guard isPaired, loop == nil, !KairosSelfTestProgress.shared.running else { return }
        status = .connecting
        loop = Task { [weak self] in await self?.run() }
    }

    /// When Kairos goes to the background (iOS would suspend the request anyway).
    func stop() {
        loop?.cancel()
        loop = nil
        if isPaired { status = .connecting }
    }

    /// "Try again now" (the connection line on the main screen). Only while the Mac can't be reached: restarting
    /// the loop would cancel a task from the Mac that is running.
    func retry() {
        switch status {
        case .offline, .connecting: stop(); start()
        default: break
        }
    }

    private func run() async {
        var cardSent = Date.distantPast
        while !Task.isCancelled, isPaired {
            do {
                if Date().timeIntervalSince(cardSent) > 300 {
                    try await sendCard()
                    cardSent = Date()
                    markReady()
                }
                let (json, code) = try await call("api/tasks/next?wait=25", timeout: 35)
                if code == 200 || code == 204 { markReady() }   // "Connected" only once the Mac has answered
                if code == 401 {
                    meshLog.notice("hub forgot this phone")
                    leave()
                    status = .offline(MeshError.http(401).spoken)
                    return
                }
                if code == 409 { cardSent = .distantPast; continue }
                guard code == 200 else { throw MeshError.http(code) }
                guard let task = json["task"] as? [String: Any], let id = task["id"] as? String,
                      let words = task["words"] as? String else { continue }
                let from = ((task["from"] as? [String: Any])?["name"] as? String) ?? "another device"
                await work(id: id, words: words, from: from)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                status = .offline(Self.problem(error, hub: hub))
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// One task: run it through Kairos here, report "waiting for Face ID" while a card is up, then the answer.
    private func work(id: String, words: String, from: String) async {
        meshLog.notice("task \(id, privacy: .public)")
        status = .working(from)
        lastTask = "\(from): \(words)"
        _ = try? await call("api/tasks/\(id)/update", body: ["progress": "Asked from \(from); the iPhone is on it"])

        let agent = KairosAgent.shared
        let startCount = agent.lines.count
        // While the card is up, the device that asked sees "waiting for owner" on the task board.
        let watcher = agent.$confirmation.dropFirst().sink { [weak self] card in
            Task { @MainActor in
                _ = try? await self?.call("api/tasks/\(id)/update", body: card == nil
                    ? ["status": "working", "progress": "Owner answered the card"]
                    : ["status": "input-required", "progress": "Waiting for the owner on the iPhone: \(card!.detail)"])
            }
        }
        let outcome = await agent.handle(words, source: .remote)
        watcher.cancel()

        let lines = agent.lines.count > startCount ? Array(agent.lines[startCount...]) : []
        let status: String
        if lines.contains(where: { $0.kind == .refused }) {
            status = "rejected"
        } else if lines.contains(where: { $0.kind == .failed }) && !lines.contains(where: { $0.kind == .done }) {
            status = "failed"
        } else {
            status = "completed"
        }
        let steps = lines.filter { $0.kind == .done }.map { "\($0.helper.map { $0 + ": " } ?? "")\($0.text)" }
        for step in steps.prefix(5) { _ = try? await call("api/tasks/\(id)/update", body: ["progress": step]) }
        if !lines.contains(where: { [.done, .failed, .refused].contains($0.kind) }) {
            // An answer with nothing done (a question answered, or "I need a key"): say so, so the asker's board
            // never reads "completed" as "it happened".
            _ = try? await call("api/tasks/\(id)/update", body: ["progress": "Answered without using any of the iPhone's tools"])
        }
        // The answer matters most: try it a few times (a relay hiccup must not leave the Mac waiting), in a task of
        // its own so the loop stopping (Kairos going to the background) doesn't cancel it.
        let say = outcome.say
        await Task { [weak self] in
            for attempt in 0..<3 {
                if let sent = try? await self?.call("api/tasks/\(id)/update", body: ["status": status, "answer": say]),
                   sent.1 == 200 || sent.1 == 409 { return }
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
            }
        }.value
        meshLog.notice("task \(id, privacy: .public) \(status, privacy: .public)")
        if !Task.isCancelled { self.status = .ready }
    }

    private func markReady() {
        if case .working = status { return }
        status = .ready
        note = nil
    }

    /// From this iPhone to the person's other devices: the request goes to the hub's Jarvis, so it joins the one
    /// conversation (the Mac will know what was asked here), and the device that holds what's needed does it.
    /// Waits up to `wait` seconds for the answer; after that the work carries on and shows on the task board.
    /// `timeout`: how long to wait for the hub at all (Siri in the background has about 12 s).
    func ask(_ text: String, wait: Double = 20, timeout: TimeInterval? = nil) async throws -> (answer: String, stillRunning: Bool) {
        do {
            let (json, code) = try await call("api/ask", body: ["text": text, "wait": wait], timeout: timeout ?? wait + 30)
            guard code == 200, let answer = json["answer"] as? String else { throw MeshError.http(code) }
            if case .offline = status { markReady() }
            let tasks = json["tasks"] as? [[String: Any]] ?? []
            let finished: Set<String> = ["completed", "failed", "rejected", "canceled", "expired"]
            let running = tasks.contains { !finished.contains(($0["status"] as? String) ?? "") }
            return (answer, running)
        } catch {
            if !(error is CancellationError) { status = .offline(Self.problem(error, hub: hub)) }
            throw error
        }
    }

    // MARK: - One conversation across devices

    /// What this phone's Kairos just said and did goes into the shared conversation, so the Mac can answer
    /// "what did I ask on my phone?". Fire and forget: a turn that can't be sent is dropped (no outbox yet).
    func shareTurn(user: String, assistant: String) {
        guard isPaired else { return }
        let turns = [["role": "user", "text": String(user.prefix(2000))],
                     ["role": "assistant", "text": String(assistant.prefix(2000))]]
            .filter { !($0["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        Task { [weak self] in
            for turn in turns {
                guard let sent = try? await self?.call("api/turns", body: turn, timeout: 8) else { return }
                if sent.1 != 200 { meshLog.notice("turn not shared: HTTP \(sent.1)"); return }
            }
        }
    }

    /// Tools other devices never get to use on this iPhone (and so aren't on its card).
    static let notForOtherDevices = KairosAgent.remoteDenied.union(["ask_my_mac"])

    /// What this iPhone's agent can do, so the brain knows to send calendar, contacts and messages here.
    private func sendCard() async throws {
        let tools = KairosAgent.shared.offeredTools(for: .remote)
            .filter { !Self.notForOtherDevices.contains($0.name) }
            .map { ["name": $0.name, "summary": String($0.summary.prefix(200))] }
        let (_, code) = try await call("api/card", body: [
            "agent": "Kairos for iPhone", "skills": tools,
            "state": ["awake": true, "app": "Kairos " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")],
        ])
        guard code == 200 else { throw MeshError.http(code) }
    }

    // MARK: - HTTP

    private func call(_ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 15) async throws
        -> ([String: Any], Int) {
        guard let hub, let token, let url = URL(string: path, relativeTo: hub.appendingPathComponent("/")) else {
            throw MeshError.notPaired
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (json, code)
    }

    /// Tailscale's own addresses: 100.64.0.0/10 and fd7a:115c:a1e0::/48.
    static func isTailscaleAddress(_ address: String) -> Bool {
        let a = address.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if a.hasPrefix("fd7a:115c:a1e0:") { return true }
        let parts = a.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    /// Why the Mac can't be reached, as one plain sentence that says what to do.
    static func problem(_ error: Error, hub: URL? = nil) -> String {
        if let e = error as? MeshError { return e.spoken }
        guard let code = (error as? URLError)?.code else { return "Something went wrong reaching your Mac. Try again." }
        let tailnet = hub.map(isTailnet) ?? MeshNode.shared.overTailscale
        switch code {
        case .cannotFindHost, .dnsLookupFailed:
            return tailnet ? "Tailscale is off on this iPhone. Open the Tailscale app and switch it on."
                           : "This iPhone can't find your Mac's address."
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return "This iPhone has no internet right now."
        case .timedOut, .cannotConnectToHost, .networkConnectionLost:
            return "Your Mac isn't answering. It may be asleep, or its lid closed."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return "Your Mac's secure address isn't ready. Run kairos up on the Mac."
        case .appTransportSecurityRequiresSecureConnection:
            return "That Mac address needs https. Scan the code from your Mac again."
        default:
            return "Something went wrong reaching your Mac. Try again."
        }
    }
}

/// Where the connection for one request really went (its remote IP), from the task's metrics.
private final class PeerAddress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    var address: String? { lock.lock(); defer { lock.unlock() }; return value }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let remote = metrics.transactionMetrics.last(where: { $0.remoteAddress != nil })?.remoteAddress
        lock.lock(); value = remote; lock.unlock()
    }
}

enum MeshError: Error {
    case badHub, badCode, codeRefused, tooManyCodes, notPaired, notTailnet, http(Int)

    var spoken: String {
        switch self {
        case .badHub: return "That Mac address doesn't look right."
        case .badCode: return "The code is 6 digits."
        case .codeRefused: return "That code is wrong, used or expired. Make a new one on your Mac."
        case .tooManyCodes: return "Too many wrong codes. Wait 10 minutes, then make a new code on your Mac."
        case .notPaired: return "This iPhone hasn't joined your Mac yet."
        case .notTailnet: return "That Mac isn't on your private Tailscale network, so Kairos didn't join it. Turn Tailscale on and scan again."
        case .http(401): return "Your Mac doesn't know this iPhone any more. Join again in Settings, Your Mac."
        case .http(let code) where (502...504).contains(code): return "Kairos isn't running on your Mac. Run kairos up on the Mac."
        case .http(let code): return "Your Mac said \(code). Try again."
        }
    }
}
