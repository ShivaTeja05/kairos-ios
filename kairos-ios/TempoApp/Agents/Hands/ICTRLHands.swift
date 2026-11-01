import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The phone's hands, from inside Kairos: iCTRL's XCUITest runner serves encrypted JSON-RPC 2.0 on
/// 127.0.0.1:8200 on this same iPhone, so the app can see and tap any other app over loopback.
///
/// - Pairing is one Allow tap on the phone (an iCTRL notification: press and hold it, tap Allow). The 32-byte
///   key lands in the Keychain (KeyStore "ictrl_key"); it never appears in logs or in the app's code.
/// - Every call is sealed with ICTRLEnvelope. Plain HTTP is fine: the body is encrypted and MAC'd, and the
///   socket never leaves the phone. Info.plist needs NSAppTransportSecurity › NSAllowsLocalNetworking = YES.
/// - Never retries an action on a timeout: iCTRL may still finish it, and a repeated tap fires twice.
actor ICTRLHands: PhoneHands {
    static let shared = ICTRLHands()

    /// KeyStore names (Keychain, this device only).
    static let keyName = "ictrl_key"
    static let defaultClientName = "Kairos"

    nonisolated let host: String
    nonisolated let port: Int
    private let session: URLSession
    private let keyName: String
    private var nextID = 1
    private var cached: KeyRecord?
    private var cacheLoaded = false
    private var pairing: Task<Void, Error>?

    /// `port`/`keyName` are parameters for tests (a mock server on the Mac); the app uses the defaults.
    init(host: String = "127.0.0.1", port: Int = 8200, keyName: String = ICTRLHands.keyName) {
        self.host = host
        self.port = port
        self.keyName = keyName
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]     // loopback: never through a proxy
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.waitsForConnectivity = false        // refused must fail at once (→ .notRunning), not wait
        cfg.timeoutIntervalForRequest = 95      // ceiling only: each request sets its own (pairing waits 90 s)
        cfg.timeoutIntervalForResource = 120
        cfg.httpMaximumConnectionsPerHost = 4
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - PhoneHands

    /// Cheap: GET /whoami (unauthenticated), then `is_locked`, which iCTRL answers off its UI queue.
    func status() async -> HandsStatus {
        do { _ = try await whoami(timeout: 2.5) } catch { return .notRunning }
        guard record() != nil else { return .notPaired }
        do {
            let r = try await callOnce("is_locked", .object([:]), timeout: 4)
            return r["locked"]?.bool == true ? .locked : .ready
        } catch HandsError.notPaired {
            return .notPaired
        } catch {
            return .notRunning
        }
    }

    /// Asks the phone for a key; the owner taps Allow. Waits up to 90 s (iCTRL gives up after 60 s).
    /// Calls made while a pairing is in flight share it instead of starting a second one (iCTRL would say busy).
    func pair(as name: String) async throws {
        if let running = pairing { return try await running.value }
        let clientName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = Task { try await self.runPairing(clientName.isEmpty ? Self.defaultClientName : clientName) }
        pairing = task
        defer { pairing = nil }
        try await task.value
    }

    /// One JSON-RPC call. Returns the `result` object. Errors: .notRunning (refused), .notPaired (no key or
    /// 401, and the dead key is forgotten), .locked (a failed UI call on a locked phone), .rpc(message), .badReply.
    func call(_ method: String, _ params: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        #if canImport(UIKit)
        let background = await ICTRLBackgroundTime.begin("iCTRL \(method)")
        do {
            let result = try await callChecked(method, params, timeout: timeout)
            await ICTRLBackgroundTime.end(background)
            return result
        } catch {
            await ICTRLBackgroundTime.end(background)
            throw error
        }
        #else
        return try await callChecked(method, params, timeout: timeout)
        #endif
    }

    // MARK: - Extras

    /// True when a key is saved (it may still turn out to be stale; status() checks for real).
    var hasKey: Bool { record() != nil }

    /// GET /whoami: {device_id, protocol_version, server_version}. Throws .notRunning when nothing answers.
    func whoami(timeout: TimeInterval = 3) async throws -> JSONValue {
        let (status, body) = try await send("GET", "/whoami", body: nil, timeout: timeout)
        guard status == 200 else { return .object([:]) }   // an old runner without /whoami is still running
        return JSONValue.decode(body) ?? .object([:])
    }

    /// Drops the saved key (the owner can revoke it in iCTRL too).
    func forget() {
        KeyStore.set(keyName, "")
        cached = nil
        cacheLoaded = true
    }

    // MARK: - Calls

    /// Non-UI methods iCTRL answers on its own lane; no lock check needed after they fail.
    private static let offQueueMethods: Set<String> = ["is_locked", "logs", "recent_logs", "config", "reset",
                                                       "resolve_app", "list_apps", "stream_ticket"]

    /// Methods that act on the phone (iCTRL's uiMutatingMethods, plus settings): never sent twice.
    static let changesScreen: Set<String> = ["tap", "double_tap", "long_press", "swipe", "drag", "drag_up", "drag_down",
                                             "drag_move", "scroll", "scroll_to_element", "tap_element", "find_and_tap",
                                             "page", "collect", "type", "clear_text", "home", "lock", "unlock",
                                             "launch_app", "activate_app", "terminate_app", "open_url", "config", "reset"]

    private func callChecked(_ method: String, _ params: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        do {
            return try await callOnce(method, params, timeout: timeout)
        } catch HandsError.rpc(let message) where !Self.offQueueMethods.contains(method) {
            // A UI call that failed on a locked phone (black screen, taps that do nothing) says so plainly.
            if let r = try? await callOnce("is_locked", .object([:]), timeout: 3), r["locked"]?.bool == true {
                throw HandsError.locked
            }
            throw HandsError.rpc(message)
        }
    }

    private func callOnce(_ method: String, _ params: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        guard let key = record() else { throw HandsError.notPaired }
        let paramsObject: JSONValue
        switch params {
        case .null: paramsObject = .object([:])
        case .object: paramsObject = params
        default: throw HandsError.rpc("\(method) needs its details as named values.")
        }
        let id = nextID
        nextID += 1
        let request: JSONValue = ["jsonrpc": "2.0", "method": .string(method), "params": paramsObject,
                                  "id": .number(Double(id))]
        let plaintext = request.encoded()

        var replayRetried = false
        while true {
            let sealed: ICTRLEnvelope.Sealed
            do { sealed = try ICTRLEnvelope.sealRequest(plaintext, key: key.key) } catch { throw HandsError.notPaired }
            let (status, body) = try await send("POST", "/rpc", body: sealed.body, timeout: timeout, method: method)
            switch status {
            case 200:
                let inner: Data
                do { inner = try ICTRLEnvelope.openResponse(body, key: key.key, nonce: sealed.nonce) } catch {
                    throw HandsError.badReply
                }
                guard let reply = JSONValue.decode(inner), case .object = reply else { throw HandsError.badReply }
                if let rid = reply["id"], rid != .null, rid.int != id { throw HandsError.badReply }
                if let err = reply["error"], err != .null {
                    throw HandsError.rpc(Self.short(err["message"]?.string ?? "\(method) failed."))
                }
                return reply["result"] ?? .object([:])
            case 401:
                let code = Self.errorCode(body)
                if code == "nonce_replayed" {
                    // Our nonces are random, so "already seen" means this very request reached the phone twice (a
                    // resend): the first copy may have run. Resending a tap or a Send would do it twice.
                    if Self.changesScreen.contains(method) {
                        throw HandsError.rpc("That step may still finish on the phone, so look at the screen before trying again.")
                    }
                    if !replayRetried { replayRetried = true; continue }  // a read: safe to ask again with a fresh nonce
                }
                if code == "ts_skew" { throw HandsError.rpc("The phone's clock looks wrong. Please check the date and time in Settings.") }
                if code == "nonce_flood" { throw HandsError.rpc("Too many steps at once. Please wait a moment and try again.") }
                forget()  // auth_failed / auth_required: this key is no longer usable
                throw HandsError.notPaired
            case 400:
                throw HandsError.rpc(Self.short(Self.errorMessage(body) ?? "The phone helper didn't accept that request."))
            case 404:
                throw HandsError.rpc("This version of the phone helper is too old. Please update iCTRL from the Mac.")
            default:
                throw HandsError.rpc("The phone helper answered with an error (\(status)).")
            }
        }
    }

    // MARK: - Pairing

    private func runPairing(_ clientName: String) async throws {
        let info = try await whoami(timeout: 3)
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation
        let request = try JSONSerialization.data(withJSONObject: ["client_name": clientName,
                                                                  "pub": publicKey.base64EncodedString()])
        let (status, body) = try await send("POST", "/pair", body: request, timeout: 90, method: "pair")
        switch status {
        case 200:
            guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  let tok = obj["tok"] as? String, let devicePub = obj["pub"] as? String,
                  let tokenCT = obj["token_ct"] as? String else { throw HandsError.badReply }
            let key: Data
            do {
                key = try ICTRLEnvelope.unwrapPairedKey(tokenCiphertextHex: tokenCT, devicePublicKeyBase64: devicePub,
                                                        clientPrivateKey: privateKey)
            } catch { throw HandsError.badReply }
            // The unwrapped key must hash to the id the phone filed it under, or the unwrap went wrong.
            guard ICTRLEnvelope.tokenID(for: key) == tok.lowercased() else { throw HandsError.badReply }
            let rec = KeyRecord(key: key, tok: tok.lowercased(), deviceID: info["device_id"]?.string,
                                clientName: clientName, pairedAt: Date())
            save(rec)
        case 403:
            throw HandsError.notPaired  // the owner said no, or didn't answer within a minute
        case 429:
            let wait = Self.errorRetryAfter(body).map { " in about \($0) seconds" } ?? " in a minute"
            throw HandsError.rpc("The phone is already waiting for an answer. Please answer it, or try again\(wait).")
        case 400:
            throw HandsError.rpc(Self.short(Self.errorMessage(body) ?? "The phone helper didn't accept the pairing request."))
        default:
            throw HandsError.rpc("The phone helper answered with an error (\(status)).")
        }
    }

    // MARK: - Key storage (Keychain via KeyStore)

    private struct KeyRecord {
        var key: Data
        var tok: String
        var deviceID: String?
        var clientName: String
        var pairedAt: Date
    }

    private func record() -> KeyRecord? {
        if cacheLoaded { return cached }
        cacheLoaded = true
        guard let raw = KeyStore.get(keyName), !raw.isEmpty,
              let obj = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
              let keyHex = obj["key"] as? String, let key = ICTRLEnvelope.data(hex: keyHex), key.count == 32 else {
            cached = nil
            return nil
        }
        cached = KeyRecord(key: key, tok: ICTRLEnvelope.tokenID(for: key), deviceID: obj["device_id"] as? String,
                           clientName: obj["client_name"] as? String ?? Self.defaultClientName,
                           pairedAt: Date(timeIntervalSince1970: obj["paired_at"] as? Double ?? 0))
        return cached
    }

    private func save(_ rec: KeyRecord) {
        var obj: [String: Any] = ["key": ICTRLEnvelope.hex(rec.key), "tok": rec.tok, "client_name": rec.clientName,
                                  "paired_at": rec.pairedAt.timeIntervalSince1970]
        if let d = rec.deviceID { obj["device_id"] = d }
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            KeyStore.set(keyName, text)
        }
        cached = rec
        cacheLoaded = true
    }

    // MARK: - HTTP

    private func send(_ verb: String, _ path: String, body: Data?, timeout: TimeInterval,
                      method: String? = nil) async throws -> (Int, Data) {
        guard let url = URL(string: "http://\(host):\(port)\(path)") else { throw HandsError.notRunning }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: max(timeout, 1))
        req.httpMethod = verb
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: req)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch let e as URLError {
            switch e.code {
            case .cancelled:
                throw CancellationError()
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
                 .resourceUnavailable, .badURL, .unsupportedURL:
                throw HandsError.notRunning
            case .timedOut:
                if method == nil { throw HandsError.notRunning }  // /whoami: nothing answering
                if method == "pair" {
                    throw HandsError.rpc("Nobody answered the pairing request on the phone. Please try again and tap Allow.")
                }
                let secs = max(1, Int(timeout.rounded(.up)))
                throw HandsError.rpc("The phone took too long to answer (\(secs) second\(secs == 1 ? "" : "s")). It may still finish, so look at the screen before trying again.")
            case .networkConnectionLost:
                throw HandsError.rpc("The connection to the phone helper dropped. Look at the screen before trying again.")
            case .appTransportSecurityRequiresSecureConnection:
                throw HandsError.rpc("Kairos isn't allowed to reach the phone helper yet (NSAllowsLocalNetworking is missing).")
            default:
                throw HandsError.rpc(Self.short(e.localizedDescription))
            }
        }
    }

    private static func errorObject(_ body: Data) -> [String: Any]? {
        ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"] as? [String: Any]
    }
    private static func errorCode(_ body: Data) -> String? { errorObject(body)?["code"] as? String }
    private static func errorMessage(_ body: Data) -> String? { errorObject(body)?["message"] as? String }
    private static func errorRetryAfter(_ body: Data) -> Int? { errorObject(body)?["retry_after"] as? Int }

    /// iCTRL's messages are written for agents and can run long; the model gets the first part.
    static func short(_ s: String, limit: Int = 400) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= limit ? t : String(t.prefix(limit)) + "…"
    }
}

// MARK: - Background time

#if canImport(UIKit)
/// Kairos drives OTHER apps, so it is often in the background while it works. A background task assertion keeps
/// it running for each call (iOS allows about 30 s after leaving the screen). A whole multi-step job should hold
/// one too: `await ICTRLBackgroundTime.during("Phone operator") { … }`. An active audio session (the ElevenLabs
/// call; UIBackgroundModes has audio) keeps the app alive regardless.
enum ICTRLBackgroundTime {
    @MainActor private final class Holder {
        var id: UIBackgroundTaskIdentifier = .invalid
    }

    @MainActor static func begin(_ name: String) -> UIBackgroundTaskIdentifier {
        let holder = Holder()
        holder.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            // Out of time: give the assertion back, or iOS ends the app.
            MainActor.assumeIsolated {
                if holder.id != .invalid { UIApplication.shared.endBackgroundTask(holder.id); holder.id = .invalid }
            }
        }
        return holder.id
    }

    @MainActor static func end(_ id: UIBackgroundTaskIdentifier) {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
    }

    static func during<T>(_ name: String, _ work: () async throws -> T) async rethrows -> T {
        let id = await begin(name)
        do {
            let value = try await work()
            await end(id)
            return value
        } catch {
            await end(id)
            throw error
        }
    }
}
#endif

// MARK: - Typed helpers (any PhoneHands: ICTRLHands, or a test double)

/// A screenshot from the phone. Coordinates for taps are points: point = pixel / scale.
struct ICTRLScreenshot: Sendable {
    var image: Data
    var format: String
    var scale: Double
    var pointWidth: Double
    var pointHeight: Double
}

/// One element of a page_source read.
struct ICTRLElement: Sendable, Equatable {
    var index: Int            // 1-based position in this read, for "[3] Button "Chats""
    var kind: String          // Button, Cell, StaticText, TextField, SecureTextField, SearchField, Switch, …
    var label: String
    var value: String
    var identifier: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var depth: Int

    var centerX: Double { x + width / 2 }
    var centerY: Double { y + height / 2 }
    /// Never typed into by Kairos: passwords and PINs belong to the person.
    var isSecure: Bool { kind == "SecureTextField" }
    var isTextInput: Bool { ["TextField", "SecureTextField", "SearchField", "TextView"].contains(kind) }

    var line: String {
        var s = "[\(index)] \(kind) \"\(label)\""
        if !value.isEmpty, value != label { s += " value=\"\(value)\"" }
        return s
    }
}

/// A page_source read, parsed into a compact numbered list for the model.
struct ICTRLScreen: Sendable {
    var app: String
    var elements: [ICTRLElement]
    var keyboardVisible: Bool
    var systemAlert: Bool
    var loading: Bool
    /// iCTRL's advice for this screen: "tree" (use refs) or "ocr" (web views: use screen_text + tap x,y).
    var recommendedChannel: String
    var truncated: Bool
    /// "captcha", "rate_limit", "login" …: never solved by Kairos.
    var blockedBy: String?
    var raw: JSONValue

    /// Kinds that are layout, not content.
    static let layoutKinds: Set<String> = ["Window", "Application", "Group", "Key", "Keyboard",
                                           "ScrollView", "Table", "CollectionView", "WebView"]
    /// Kept only when labelled AND a leaf: React Native / SwiftUI controls often come through as "Other".
    static let leafOnlyKinds: Set<String> = ["Other", "Image"]

    init(result: JSONValue) {
        raw = result
        app = result["bundle_id"]?.string ?? result["foreground_app"]?.string ?? ""
        keyboardVisible = result["keyboard"]?["visible"]?.bool ?? false
        systemAlert = result["system_alert"]?.bool ?? false
        loading = result["loading"]?.bool ?? false
        recommendedChannel = result["channel"]?["recommended"]?.string ?? "tree"
        truncated = result["truncated"]?.bool ?? false
        blockedBy = result["blocked_by"]?.string
        elements = Self.parse(result["source"]?.string ?? "")
    }

    /// Lines look like `<indent>Button, label: 'Chats', value: '2', id: 'tab.chats', {{10, 20}, {50, 44}}`
    /// (iCTRL's ICTRLBuildLine). Labels are not escaped, so fields are cut at the next known marker.
    static func parse(_ source: String, includeLayout: Bool = false) -> [ICTRLElement] {
        struct Row { var kind, label, value, ident: String; var frame: (Double, Double, Double, Double); var depth: Int }
        // A row ends with its frame; a label with a line break in it spills over several lines, so join them.
        var logical: [String] = []
        var pending = ""
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let piece = String(raw)
            pending = pending.isEmpty ? piece : pending + " " + piece.trimmingCharacters(in: .whitespaces)
            let trimmed = pending.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("}}"), pending.contains(", {{") { logical.append(pending); pending = "" }
        }
        if !pending.trimmingCharacters(in: .whitespaces).isEmpty { logical.append(pending) }

        var rows: [Row] = []
        for line in logical {
            let indent = line.prefix { $0 == " " }.count
            let body = line.dropFirst(indent)
            guard let comma = body.firstIndex(of: ",") else { continue }
            let kind = String(body[..<comma])
            var rest = String(body[comma...])           // ", label: '…', value: '…', id: '…', {{x, y}, {w, h}}"

            var frame = (0.0, 0.0, 0.0, 0.0)
            if let open = rest.range(of: ", {{", options: .backwards) {
                let nums = rest[open.upperBound...].split(whereSeparator: { !"-0123456789.".contains($0) })
                    .compactMap { Double($0) }
                if nums.count >= 4 { frame = (nums[0], nums[1], nums[2], nums[3]) }
                rest = String(rest[..<open.lowerBound])  // now ends with the closing quote of the last field
            }
            func field(_ name: String, before following: [String]) -> String {
                guard let start = rest.range(of: ", \(name): '") else { return "" }
                let tail = rest[start.upperBound...]
                var end = tail.endIndex
                for marker in following {
                    if let r = tail.range(of: "', \(marker): '") { end = min(end, r.lowerBound) }
                }
                if end == tail.endIndex, let last = tail.lastIndex(of: "'") { end = last }
                return String(tail[..<end])
            }
            rows.append(Row(kind: kind, label: clean(field("label", before: ["value", "id"])),
                            value: clean(field("value", before: ["id"])), ident: field("id", before: []),
                            frame: frame, depth: indent / 2))
        }

        var out: [ICTRLElement] = []
        var seen = Set<String>()
        for (i, row) in rows.enumerated() {
            let isLeaf = i + 1 >= rows.count || rows[i + 1].depth <= row.depth
            if !includeLayout {
                if layoutKinds.contains(row.kind) { continue }
                if leafOnlyKinds.contains(row.kind), !isLeaf || row.label.isEmpty { continue }
            }
            if row.label.isEmpty, row.value.isEmpty, row.ident.isEmpty { continue }
            if row.label.hasPrefix("Vertical scroll bar") || row.label.hasPrefix("Horizontal scroll bar") { continue }
            let key = "\(row.kind)|\(row.label)|\(row.value)|\(Int(row.frame.0)),\(Int(row.frame.1))"
            guard seen.insert(key).inserted else { continue }
            out.append(ICTRLElement(index: out.count + 1, kind: row.kind, label: row.label, value: row.value,
                                    identifier: row.ident, x: row.frame.0, y: row.frame.1, width: row.frame.2,
                                    height: row.frame.3, depth: row.depth))
        }
        return out
    }

    /// Bidi marks and odd spaces some apps put in labels.
    static func clean(_ s: String) -> String {
        let invisible: Set<Character> = ["\u{200E}", "\u{200F}", "\u{2068}", "\u{2069}", "\u{202A}", "\u{202C}", "\u{00A0}"]
        return String(s.map { invisible.contains($0) ? " " : $0 }).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A compact view for the model: one line per element, numbered.
    func digest(limit: Int = 60) -> String {
        var rows = ["SCREEN app=\(app.isEmpty ? "?" : app) keyboard=\(keyboardVisible ? "yes" : "no") alert=\(systemAlert ? "yes" : "no")"
                    + (loading ? " loading=yes" : "") + (recommendedChannel == "ocr" ? " read=ocr" : "")
                    + (blockedBy.map { " blocked_by=\($0)" } ?? "")]
        rows += elements.prefix(limit).map(\.line)
        if elements.count > limit { rows.append("(\(elements.count - limit) more below)") }
        return rows.joined(separator: "\n")
    }

    func element(_ index: Int) -> ICTRLElement? { elements.first { $0.index == index } }
}

extension PhoneHands {
    /// Default read: on-screen nodes only, ~0.4 s. `filter`: {"label": "…"} / {"type": "button"} / {"text": "…"}.
    func pageSource(visibleOnly: Bool = true, maxChildren: Int = 50, filter: JSONValue? = nil,
                    bundleID: String? = nil) async throws -> JSONValue {
        var p: [String: JSONValue] = ["visible_only": .bool(visibleOnly), "max_children": .number(Double(maxChildren))]
        if let filter { p["filter"] = filter }
        if let bundleID { p["bundle_id"] = .string(bundleID) }
        return try await call("page_source", .object(p), timeout: 20)
    }

    /// page_source, parsed. Falls back to nothing: a web view (`recommendedChannel == "ocr"`) needs screenText().
    func readScreen(maxChildren: Int = 60) async throws -> ICTRLScreen {
        ICTRLScreen(result: try await pageSource(visibleOnly: true, maxChildren: maxChildren))
    }

    /// → {ref, visibility, is_text_input, alternatives, …}. Check `ref` is non-empty before tapping it.
    func findElement(_ label: String, match: String? = nil, elementType: String? = nil,
                     bundleID: String? = nil) async throws -> JSONValue {
        var p: [String: JSONValue] = ["element_id": .string(label)]
        if let match { p["match"] = .string(match) }
        if let elementType { p["element_type"] = .string(elementType) }
        if let bundleID { p["bundle_id"] = .string(bundleID) }
        return try await call("find_element", .object(p), timeout: 12)
    }

    func tap(ref: String) async throws -> JSONValue {
        try await call("tap", ["ref": .string(ref)], timeout: 12)
    }

    func tap(x: Double, y: Double) async throws -> JSONValue {
        try await call("tap", ["x": .number(x), "y": .number(y)], timeout: 12)
    }

    /// find_element, then tap its ref. Throws .rpc when nothing on screen has that label.
    func tap(label: String, match: String = "contains", elementType: String? = nil) async throws -> JSONValue {
        let found = try await findElement(label, match: match, elementType: elementType)
        guard let ref = found["ref"]?.string, !ref.isEmpty else {
            throw HandsError.rpc(ICTRLHands.short(found["hint"]?.string ?? found["message"]?.string
                                                  ?? "I couldn't find \"\(label)\" on the screen."))
        }
        return try await tap(ref: ref)
    }

    /// Types into the focused field. Typing APPENDS: pass clear: true to replace.
    func type(_ text: String, submit: Bool = false, clear: Bool = false) async throws -> JSONValue {
        try await call("type", ["text": .string(text), "submit": .bool(submit), "clear": .bool(clear)], timeout: 12)
    }

    func scroll(direction: String = "down") async throws -> JSONValue {
        try await call("scroll", ["direction": .string(direction)], timeout: 12)
    }

    /// ⅔ of a screen, no momentum; `moved: false` means the end.
    func page(direction: String = "down", distance: Double? = nil) async throws -> JSONValue {
        var p: [String: JSONValue] = ["direction": .string(direction)]
        if let distance { p["distance"] = .number(distance) }
        return try await call("page", .object(p), timeout: 12)
    }

    func launchApp(bundleID: String) async throws -> JSONValue {
        try await call("launch_app", ["bundle_id": .string(bundleID)], timeout: 20)
    }

    /// Brings an app back to the front keeping its state.
    func activateApp(bundleID: String) async throws -> JSONValue {
        try await call("activate_app", ["bundle_id": .string(bundleID)], timeout: 20)
    }

    /// Every name the app may go by in one go, separated by "|" ("WhatsApp|WhatsApp Messenger").
    func resolveApp(_ names: String, country: String? = nil) async throws -> JSONValue {
        var p: [String: JSONValue] = ["text": .string(names)]
        if let country { p["country"] = .string(country) }
        return try await call("resolve_app", .object(p), timeout: 20)
    }

    func openURL(_ url: String) async throws -> JSONValue {
        try await call("open_url", ["url": .string(url)], timeout: 15)
    }

    func home() async throws -> JSONValue {
        try await call("home", .object([:]), timeout: 12)
    }

    /// On-device OCR of the screen: items {label, confidence, x, y, width, height, center_x, center_y} in points.
    func screenText(containing text: String? = nil) async throws -> JSONValue {
        var p: [String: JSONValue] = [:]
        if let text { p["element_id"] = .string(text) }
        return try await call("screen_text", .object(p), timeout: 20)
    }

    /// JPEG by default (much smaller, so much faster through the envelope). scale 1 is plenty for a model.
    func screenshot(scale: Double = 1, quality: Double = 0.6) async throws -> ICTRLScreenshot {
        let r = try await call("screenshot", ["scale": .number(scale), "format": "jpeg", "quality": .number(quality)],
                               timeout: 20)
        guard let b64 = r["data"]?.string, let image = Data(base64Encoded: b64) else { throw HandsError.badReply }
        return ICTRLScreenshot(image: image, format: r["format"]?.string ?? "jpeg", scale: r["scale"]?.double ?? scale,
                               pointWidth: r["point_width"]?.double ?? 0, pointHeight: r["point_height"]?.double ?? 0)
    }

    func isLocked() async throws -> Bool {
        try await call("is_locked", .object([:]), timeout: 5)["locked"]?.bool ?? false
    }

    /// Battery, foreground app, screen_locked, geometry. Shares iCTRL's UI queue: not a health probe.
    func deviceInfo() async throws -> JSONValue {
        try await call("device_info", .object([:]), timeout: 12)
    }

    /// After a timeout: look for "⏱ ✓ <method>" before doing anything else (the action may have landed).
    func logs(containing text: String? = nil, lines: Int = 40) async throws -> JSONValue {
        var p: [String: JSONValue] = ["max_elements": .number(Double(lines))]
        if let text { p["text"] = .string(text) }
        return try await call("logs", .object(p), timeout: 8)
    }
}
