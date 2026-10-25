import Foundation
import os

/// Model diagnostics for Console.app (which model answered, fallbacks after a 429). Never a key, never the person's words.
fileprivate let modelLog = Logger(subsystem: "uk.oxhack.tempo", category: "agents.model")

// The model behind the agents, behind one small interface so it can be swapped (Gemini today; an
// OpenAI-compatible endpoint, Ollama on a Mac, or Apple's on-device model later). History is kept in
// Gemini's "contents" shape ({role, parts}) because that is what we send most; other providers translate.
//
// Staying under Google's free tier (its limits are per model and per Google project, measured 25 Oct 2026):
// - A 429 on one model doesn't fail the request: if Google asks for a wait of 3 s or less we wait and ask once more,
//   otherwise the SAME request goes at once to the next model in the chain (the person's model, then
//   gemini-2.5-flash, then gemini-3.5-flash). A model that said 429 is skipped by every later request until its
//   hold is over (Google's retryDelay, else 60 s); one that answers 404 (or "model not found") is skipped for 10 min.
// - When every model is busy on the first key, the same chain is tried with the backup key (another project).
// - The person comes first (GeminiRateLimiter): background work (worker agents, the research team) waits while
//   one of the person's requests is in flight or was in the last 5 s, and uses at most 60% of each minute's budget.
// - Models switch only between requests, never inside one, so a step always goes to one model whole. Thought
//   signatures: Google's docs say to send them back unchanged, also after switching models ("the backend manages
//   compatibility"); measured 25 Oct: gemini-3.5-flash and gemini-2.5-flash accept gemini-3.5-flash-lite's. But
//   gemini-2.5-flash signs nothing, and Gemini 3 answers 400 ("Function call is missing a thought_signature") when
//   the first functionCall of a model step in the current turn has none, so before a Gemini 3 model sees history
//   another model wrote, such a call gets the documented skip value ("skip_thought_signature_validator", measured:
//   accepted). If Gemini still answers 400 about signatures, the request is re-sent once with every signature
//   replaced that way. (Function calls in earlier turns for tools not declared in this request are fine: measured.)

struct ModelTurn: Sendable {
    /// The model's words (thought summaries left out).
    var text: String
    /// Tool calls the model proposes, in order.
    var calls: [ToolCall]
    /// The model's content exactly as it came back. It goes into history unchanged: Gemini 3 checks the
    /// thought signatures on function calls and rejects a turn whose signature was dropped.
    var content: JSONValue
}

enum ModelError: LocalizedError, Equatable {
    case noKey, badKey, rateLimited, offline, blocked(String), empty, http(Int, String)

    /// Plain words for the person (spoken). Details for us go to the log.
    var errorDescription: String? {
        switch self {
        case .noKey: return "I need a Gemini key before I can think about that. Ask your helper to add one in Kairos settings."
        case .badKey: return "The Gemini key isn't working. Ask your helper to check it in Kairos settings."
        case .rateLimited:
            // Only said once every model, on every key, has said 429.
            return AgentSettings.hasBackupKey
                ? "Google's free allowance is busy for a minute. Please ask me again shortly."
                : "Google's free allowance is busy for a minute — I'll be quicker if you add a backup key in settings."
        case .offline: return "I can't reach the internet right now. Simple things like alarms and reminders still work."
        case .blocked: return "I can't help with that one."
        case .empty: return "Sorry, I didn't get an answer that time. Please try again."
        case .http(let code, _): return "Something went wrong talking to Gemini (\(code)). Please try again."
        }
    }
}

protocol ModelProvider: Sendable {
    var label: String { get }
    /// One agent step: system prompt + history (Gemini contents) + tool declarations in, text and/or tool calls out.
    func step(system: String, history: [JSONValue], tools: [JSONValue], requireTool: Bool) async throws -> ModelTurn
    /// One-shot generation for a specialist: parts (text, images) in; text out, or JSON text when a schema is given.
    func generate(system: String, parts: [JSONValue], jsonSchema: JSONValue?) async throws -> String
}

/// Builders for Gemini-shaped contents and parts.
enum GeminiContent {
    static func text(_ s: String) -> JSONValue { ["text": .string(s)] }
    static func jpeg(_ data: Data) -> JSONValue {
        ["inlineData": ["mimeType": "image/jpeg", "data": .string(data.base64EncodedString())]]
    }
    static func user(_ text: String, images: [Data] = []) -> JSONValue {
        ["role": "user", "parts": .array(images.map(jpeg) + [Self.text(text)])]
    }
    /// The answer to the model's tool calls, one functionResponse part per call, ids echoed back.
    static func functionResponses(_ items: [(call: ToolCall, response: JSONValue)]) -> JSONValue {
        let parts: [JSONValue] = items.map { item in
            var fr: [String: JSONValue] = ["name": .string(item.call.name), "response": item.response]
            if let id = item.call.id { fr["id"] = .string(id) }
            return ["functionResponse": .object(fr)]
        }
        return ["role": "user", "parts": .array(parts)]
    }
}

/// Who is waiting for a Gemini answer: the person (Kairos, Siri, the voice call) or background work (worker agents,
/// the research team). Background calls give way to the person's.
enum GeminiPriority: String, Sendable {
    case foreground, background
}

/// Hooks that follow one request through every helper it calls (task-local).
enum GeminiCallScope {
    /// Called when one of the person's calls is about to wait more than a second (for the limiter, Google's short
    /// hold, or another model). Kairos shows "One moment…".
    @TaskLocal static var onWait: (@Sendable () -> Void)? = nil
}

/// The HTTP layer, swappable so tests can return canned Gemini replies.
struct GeminiTransport: Sendable {
    var send: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    static let live = GeminiTransport { request in try await URLSession.shared.data(for: request) }
}

/// Getting history ready for the model it is about to go to (see the notes at the top of this file).
enum GeminiHistory {
    /// Google's documented value for a function call that has no signature of its own.
    static let skipSignature = "skip_thought_signature_validator"

    /// Gemini 3 and later check thought signatures on function calls; 2.5 and older don't need them.
    static func checksSignatures(_ model: String) -> Bool {
        guard model.hasPrefix("gemini-") else { return false }
        return !model.hasPrefix("gemini-1") && !model.hasPrefix("gemini-2")
    }

    /// `history` as `model` should get it. Signatures stay exactly as they came; for a Gemini 3 model, the first
    /// functionCall of each model step that has none (gemini-2.5-flash signs nothing) gets the skip value.
    /// `resignAll` (after a 400 about signatures): every signature is taken out and each step's first call gets the
    /// skip value. The caller's history itself is never changed.
    static func prepared(_ history: [JSONValue], for model: String, resignAll: Bool = false) -> [JSONValue] {
        guard checksSignatures(model) || resignAll else { return history }
        return history.map { content in
            guard content["role"]?.string == "model", case .object(var o) = content, var parts = o["parts"]?.array else {
                return content
            }
            var changed = false
            if resignAll {
                for i in parts.indices {
                    guard case .object(var p) = parts[i], p["thoughtSignature"] != nil || p["thought_signature"] != nil else { continue }
                    p["thoughtSignature"] = nil
                    p["thought_signature"] = nil
                    parts[i] = .object(p)
                    changed = true
                }
            }
            if checksSignatures(model), let first = parts.firstIndex(where: { $0["functionCall"] != nil }),
               parts[first]["thoughtSignature"] == nil, parts[first]["thought_signature"] == nil,
               case .object(var p) = parts[first] {
                p["thoughtSignature"] = .string(skipSignature)
                parts[first] = .object(p)
                changed = true
            }
            guard changed else { return content }
            o["parts"] = .array(parts)
            return .object(o)
        }
    }
}

struct GeminiProvider: ModelProvider {
    var model: String
    var apiKey: String
    var timeout: TimeInterval = 25
    /// Asked in order when `model` is busy (429) or unknown (404) on a key. AgentSettings.provider fills it in;
    /// empty means this model only (the settings screen's "Check it works", tests).
    var fallbackModels: [String] = []
    /// A key from another Google project, tried with the same models when every one is busy on `apiKey`.
    var backupKey: String? = nil
    var priority: GeminiPriority = .foreground
    var transport: GeminiTransport = .live
    var limiter: GeminiRateLimiter = .shared
    var label: String { "Gemini (\(model))" }

    /// The models to try, in order, without repeats.
    var chain: [String] {
        var seen = Set<String>()
        return ([model] + fallbackModels.filter(AgentSettings.isModelName)).filter { seen.insert($0).inserted }
    }

    /// The keys to try, in order: the backup only when it is a different, usable key.
    var keys: [String] {
        guard let backupKey, backupKey.count >= 20, backupKey != apiKey else { return [apiKey] }
        return [apiKey, backupKey]
    }

    /// How long the person's request waits, at most, for a model whose hold is nearly over before trying it anyway.
    var holdPatience: TimeInterval { priority == .foreground ? 6 : 15 }

    static func endpoint(_ model: String) -> URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
    }

    /// Gemini 3 Flash-Lite takes "minimal" thinking (fast, cheap); other Gemini 3 models start at "low";
    /// 2.5 Flash uses a token budget. Sampling parameters are left at the model's defaults (Gemini 3 guidance).
    static func thinking(for model: String) -> JSONValue? {
        if model.hasPrefix("gemini-3") { return ["thinkingLevel": model.contains("lite") ? "minimal" : "low"] }
        if model.hasPrefix("gemini-2.5-flash") { return ["thinkingBudget": 0] }
        return nil
    }

    func step(system: String, history: [JSONValue], tools: [JSONValue], requireTool: Bool) async throws -> ModelTurn {
        let reply = try await send(maxTokens: 1024) { model, resign in
            var body: [String: JSONValue] = [
                "systemInstruction": ["parts": [GeminiContent.text(system)]],
                "contents": .array(GeminiHistory.prepared(history, for: model, resignAll: resign)),
            ]
            if !tools.isEmpty {
                body["tools"] = [["functionDeclarations": .array(tools)]]
                body["toolConfig"] = ["functionCallingConfig": ["mode": requireTool ? "ANY" : "AUTO"]]
            }
            return body
        }
        return try Self.parseTurn(reply)
    }

    func generate(system: String, parts: [JSONValue], jsonSchema: JSONValue?) async throws -> String {
        let body: [String: JSONValue] = [
            "systemInstruction": ["parts": [GeminiContent.text(system)]],
            "contents": [["role": "user", "parts": .array(parts)]],
        ]
        var extra: [String: JSONValue] = [:]
        if let jsonSchema {
            extra["responseMimeType"] = "application/json"
            extra["responseJsonSchema"] = jsonSchema
        }
        let reply: JSONValue
        do {
            reply = try await send(maxTokens: 6000, extraConfig: extra) { _, _ in body }
        } catch ModelError.http(400, let text) where jsonSchema != nil && text.localizedCaseInsensitiveContains("schema") {
            // Older models only know the OpenAPI-style field.
            extra["responseJsonSchema"] = nil
            extra["responseSchema"] = jsonSchema
            reply = try await send(maxTokens: 6000, extraConfig: extra) { _, _ in body }
        }
        let turn = try Self.parseTurn(reply)
        guard !turn.text.isEmpty else { throw ModelError.empty }
        return turn.text
    }

    // MARK: - Which model, which key

    /// One model on one key.
    struct Candidate: Sendable {
        var key: String
        var model: String
        var slot: GeminiRateLimiter.Slot
    }

    /// Why one model on one key couldn't answer (the next one may).
    private enum Skip: Error {
        /// 429: Google's hold in seconds (nil when it didn't say); `long` when waiting can't help soon (no free
        /// allowance for this model, or today's is used up).
        case busy(seconds: Double?, long: Bool)
        /// This key can't use this model (404, "model not found").
        case unavailable(ModelError)
        /// The key itself was refused: its other models won't work either.
        case badKey
    }

    /// One request, sent to the first model and key that can take it (see the notes at the top of this file).
    /// `make` builds the body for a model (`resign`: after a 400 about thought signatures).
    private func send(maxTokens: Int, extraConfig: [String: JSONValue] = [:],
                      body make: (_ model: String, _ resign: Bool) -> [String: JSONValue]) async throws -> JSONValue {
        let candidates = keys.flatMap { key in
            chain.map { Candidate(key: key, model: $0, slot: GeminiRateLimiter.Slot(key: GeminiRateLimiter.keyID(key), model: $0)) }
        }
        let onWait = priority == .foreground ? GeminiCallScope.onWait : nil
        var tried = Set<Int>()
        var sawLimit = false
        var lastError: Error?
        while true {
            try Task.checkCancellation()
            guard let index = await next(candidates, tried: tried, onWait: onWait) else { break }
            if !tried.isEmpty { onWait?() }  // a fallback: the person hears "One moment…"
            tried.insert(index)
            let c = candidates[index]
            do {
                let reply = try await attempt(c, maxTokens: maxTokens, extraConfig: extraConfig, make: make, onWait: onWait)
                if index > 0 { modelLog.notice("Answered by \(c.model, privacy: .public) (key \(c.key == apiKey ? 1 : 2, privacy: .public)) after a fallback") }
                return reply
            } catch let skip as Skip {
                switch skip {
                case .busy(let seconds, let long):
                    sawLimit = true
                    let hold = long ? 600 : (seconds ?? 60)
                    await limiter.coolDown(c.slot, seconds: hold)
                    modelLog.notice("429 from \(c.model, privacy: .public) (key \(c.key == apiKey ? 1 : 2, privacy: .public)); resting it \(Int(hold), privacy: .public) s")
                case .unavailable(let error):
                    lastError = error
                    await limiter.coolDown(c.slot, seconds: 600)
                    modelLog.notice("\(c.model, privacy: .public) isn't available on this key; skipping it for 10 minutes")
                case .badKey:
                    lastError = ModelError.badKey
                    for (i, other) in candidates.enumerated() where other.key == c.key { tried.insert(i) }
                }
            }
        }
        if sawLimit { throw ModelError.rateLimited }
        throw lastError ?? ModelError.rateLimited
    }

    /// The candidate to ask next: the first one not tried whose hold is over, preferring one with room in its own
    /// per-minute count. When every one left is resting: wait for the one whose hold ends first if that is soon,
    /// or (when nothing has been sent yet) ask it anyway, since Google's hold is often shorter than it says.
    private func next(_ candidates: [Candidate], tried: Set<Int>, onWait: (@Sendable () -> Void)?) async -> Int? {
        var ready: [Int] = []
        var soonest: (index: Int, hold: TimeInterval)?
        for i in candidates.indices where !tried.contains(i) {
            let hold = await limiter.holdRemaining(candidates[i].slot)
            if hold <= 0 { ready.append(i) } else if soonest.map({ hold < $0.hold }) ?? true { soonest = (i, hold) }
        }
        for i in ready {
            if await limiter.hasRoom(candidates[i].slot, priority: priority) { return i }
        }
        if let first = ready.first { return first }
        guard let soonest else { return nil }
        if soonest.hold <= holdPatience {
            onWait?()
            try? await Task.sleep(nanoseconds: UInt64(soonest.hold * 1_000_000_000))
            return soonest.index
        }
        return tried.isEmpty ? soonest.index : nil
    }

    // MARK: - HTTP

    /// One model on one key: the retries that stay on that model (no thinking setting, a re-signed history, a short
    /// hold, a timeout, a server hiccup). Throws Skip when the next model or key should be asked instead.
    private func attempt(_ c: Candidate, maxTokens: Int, extraConfig: [String: JSONValue],
                         make: (String, Bool) -> [String: JSONValue], onWait: (@Sendable () -> Void)?) async throws -> JSONValue {
        var withThinking = true, resign = false, waitedShort = false, timedOut = false, serverRetried = false
        while true {
            var config = extraConfig
            config["maxOutputTokens"] = .number(Double(maxTokens))
            if withThinking, let thinking = Self.thinking(for: c.model) { config["thinkingConfig"] = thinking }
            var full = make(c.model, resign)
            full["generationConfig"] = .object(config)

            var req = URLRequest(url: Self.endpoint(c.model), timeoutInterval: timeout)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(c.key, forHTTPHeaderField: "x-goog-api-key")
            req.httpBody = JSONValue.object(full).encoded()

            let lease = await limiter.waitForSlot(c.slot, priority: priority, onLongWait: onWait)
            let outcome: Result<(Data, URLResponse), Error>
            do { outcome = .success(try await transport.send(req)) } catch { outcome = .failure(error) }
            await limiter.finished(lease)

            let data: Data, response: URLResponse
            switch outcome {
            case .success(let reply):
                (data, response) = reply
            case .failure(let e as URLError) where [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                                                    .cannotConnectToHost, .dataNotAllowed].contains(e.code):
                throw ModelError.offline
            case .failure(let e as URLError) where e.code == .timedOut:
                if !timedOut { timedOut = true; continue }
                throw ModelError.offline
            case .failure(let e):
                throw e
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data, encoding: .utf8) ?? ""
            switch status {
            case 200:
                await limiter.answered(c.slot)
                return JSONValue.decode(data) ?? .null
            case 400 where withThinking && text.localizedCaseInsensitiveContains("thinking"):
                // This model doesn't take the thinking setting we chose: ask again without it.
                withThinking = false
            case 400 where !resign && Self.aboutSignatures(text):
                resign = true
            case 400 where text.contains("API_KEY_INVALID") || text.localizedCaseInsensitiveContains("api key not valid"),
                 401, 403:
                throw Skip.badKey
            case 404:
                throw Skip.unavailable(.http(404, String(text.prefix(300))))
            case 400 where Self.unknownModel(text):
                throw Skip.unavailable(.http(400, String(text.prefix(300))))
            case 429:
                // The free tier says how long to wait (google.rpc.RetryInfo "retryDelay": "6s"). A short hold is
                // waited out on this model; anything longer goes to the next model straight away.
                let delay = Self.retryDelay(text)
                let long = Self.noAllowance(text) || Self.perDay(text)
                if !waitedShort, !long, let delay, delay <= 3 {
                    waitedShort = true
                    if delay > 1 { onWait?() }
                    try? await Task.sleep(nanoseconds: UInt64(max(0.3, delay) * 1_000_000_000))
                    continue
                }
                throw Skip.busy(seconds: delay, long: long)
            case 500, 502, 503, 504:
                if !serverRetried {
                    serverRetried = true
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    continue
                }
                throw ModelError.http(status, String(text.prefix(300)))
            default:
                throw ModelError.http(status, String(text.prefix(300)))
            }
        }
    }

    /// Seconds from a 429 body's RetryInfo ("retryDelay": "6s" or "6.5s"), if there is one.
    static func retryDelay(_ body: String) -> Double? {
        guard let r = body.range(of: #""retryDelay"\s*:\s*"([0-9.]+)s""#, options: .regularExpression) else { return nil }
        let digits = body[r].split(separator: ":").last.map { $0.filter { "0123456789.".contains($0) } } ?? ""
        return Double(digits)
    }

    /// "Quota exceeded for metric: …, limit: 0": this model has no free allowance on this key at all.
    static func noAllowance(_ body: String) -> Bool {
        body.range(of: #"limit:\s*0(?![0-9])"#, options: .regularExpression) != nil
    }

    /// A per-day quota (quotaId "…PerDay…"): used up until it resets.
    static func perDay(_ body: String) -> Bool {
        let lower = body.lowercased()
        return lower.contains("perday") || lower.contains("per day")
    }

    /// A 400 that is about thought signatures ("Function call is missing a thought_signature …").
    static func aboutSignatures(_ body: String) -> Bool {
        let lower = body.lowercased()
        return lower.contains("thought_signature") || lower.contains("thought signature") || lower.contains("thoughtsignature")
    }

    /// A 400 that says the model itself isn't there for this key (not a problem with the request).
    static func unknownModel(_ body: String) -> Bool {
        let lower = body.lowercased()
        return (lower.contains("model") && (lower.contains("not found") || lower.contains("is not supported for generatecontent")
                                            || lower.contains("unknown model") || lower.contains("does not exist")))
            && !lower.contains("api key")
    }

    static let refusalReasons: Set<String> = ["SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "IMAGE_SAFETY"]

    /// candidates[0].content → text + function calls. Exposed for tests.
    static func parseTurn(_ reply: JSONValue) throws -> ModelTurn {
        guard let candidate = reply["candidates"]?.array?.first else {
            if let reason = reply["promptFeedback"]?["blockReason"]?.string { throw ModelError.blocked(reason) }
            throw ModelError.empty
        }
        guard var content = candidate["content"], let parts = content["parts"]?.array else {
            // Only a real refusal is "I can't help with that one." MALFORMED_FUNCTION_CALL, MAX_TOKENS and the
            // like are glitches: .empty asks the person to try again.
            if let reason = candidate["finishReason"]?.string, refusalReasons.contains(reason) { throw ModelError.blocked(reason) }
            throw ModelError.empty
        }
        if content["role"] == nil, case .object(var o) = content { o["role"] = "model"; content = .object(o) }
        var text = ""
        var calls: [ToolCall] = []
        for part in parts {
            if let fc = part["functionCall"], let name = fc["name"]?.string {
                calls.append(ToolCall(id: fc["id"]?.string, name: name, args: fc["args"] ?? [:]))
            } else if let t = part["text"]?.string, part["thought"]?.bool != true {
                text += t
            }
        }
        return ModelTurn(text: text.trimmingCharacters(in: .whitespacesAndNewlines), calls: calls, content: content)
    }
}

/// Where the agents' model settings live. The keys stay in this phone's Keychain, never in the app's code.
enum AgentSettings {
    static let keyName = "gemini_api_key"
    /// An optional second key, from another Google project: Kairos uses it when every model is busy on the first.
    static let backupKeyName = "gemini_api_key_2"
    static let modelDefaultsKey = "kairos.agents.model"
    static let defaultModel = "gemini-3.5-flash-lite"
    /// Asked in turn when the person's model is busy (429). Google's free allowance is per model.
    static let backupModels = ["gemini-2.5-flash", "gemini-3.5-flash"]

    /// Only real model names are kept. Anything else (an API key pasted into the model box once caused 404s)
    /// is wiped from UserDefaults, which, unlike the Keychain, is not a safe place for a key.
    static var model: String {
        get {
            guard let saved = UserDefaults.standard.string(forKey: modelDefaultsKey) else { return defaultModel }
            if isModelName(saved) { return saved }
            UserDefaults.standard.removeObject(forKey: modelDefaultsKey)
            return defaultModel
        }
        set {
            if isModelName(newValue) { UserDefaults.standard.set(newValue, forKey: modelDefaultsKey) }
        }
    }

    /// The person's model first, then the backup models, without repeats.
    static var modelChain: [String] {
        var seen = Set<String>()
        return ([model] + backupModels).filter { seen.insert($0).inserted }
    }

    /// "gemini-3.5-flash-lite", "gemma-3-27b-it": lowercase family-version names, never key-shaped strings.
    static func isModelName(_ s: String) -> Bool {
        let families = ["gemini-", "gemma-", "learnlm-"]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        return s.count <= 60 && families.contains(where: { s.hasPrefix($0) })
            && s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static var hasKey: Bool { (KeyStore.get(keyName) ?? "").count >= 20 }

    /// The main key, if one is saved.
    static var key: String? { usable(KeyStore.get(keyName)) }

    /// The backup key, if one is saved and it isn't the main key again.
    static var backupKey: String? {
        guard let backup = usable(KeyStore.get(backupKeyName)), backup != key else { return nil }
        return backup
    }

    static var hasBackupKey: Bool { backupKey != nil }

    private static func usable(_ raw: String?) -> String? {
        guard let raw, raw.count >= 20 else { return nil }
        return raw
    }

    /// A pasted key after trimming spaces and quotes, or nil if it can't be a key.
    static func cleanKey(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        guard key.count >= 20, key.count <= 200, !key.contains(" "), !key.contains("\n") else { return nil }
        return key
    }

    /// Saves a pasted key after trimming spaces and quotes. Returns false if it can't be a key.
    @discardableResult
    static func saveKey(_ raw: String) -> Bool {
        guard let key = cleanKey(raw) else { return false }
        KeyStore.set(keyName, key)
        return true
    }

    /// Saves a pasted backup key. Returns false if it can't be a key.
    @discardableResult
    static func saveBackupKey(_ raw: String) -> Bool {
        guard let key = cleanKey(raw) else { return false }
        KeyStore.set(backupKeyName, key)
        return true
    }

    static func removeBackupKey() {
        KeyStore.set(backupKeyName, "")  // KeyStore has no delete; an empty key counts as no key
    }

    /// Gemini with the saved keys, the person's model first and the backup models after it. Background work
    /// (worker agents, the research team) passes `.background`, so the person's own requests go first.
    static func provider(timeout: TimeInterval = 25, priority: GeminiPriority = .foreground) -> (any ModelProvider)? {
        guard let key else { return nil }
        return GeminiProvider(model: model, apiKey: key, timeout: timeout, fallbackModels: backupModels,
                              backupKey: backupKey, priority: priority)
    }
}


/// Keeps Kairos under each model's per-minute limit, with the person first. Google's free-tier limits are per model
/// and per project, so requests are counted per model and key (a Slot):
/// - at most `perMinute` requests to one slot in any rolling 60 s (UserDefaults "kairos.gemini.rpm", else 14 for
///   Flash-Lite and 9 for other models, one under their usual free tiers);
/// - the person's requests wait up to 3 s for room, then go anyway (a 429 moves them on to the next model);
/// - background requests wait while one of the person's requests is in flight or was in the last 5 s, use at most
///   60% of a slot's minute, and wait up to 15 s before going anyway (so a worker is never stuck for good);
/// - a slot that said 429 rests until Google's hold is over (holdRemaining), and an answer clears it.
actor GeminiRateLimiter {
    static let shared = GeminiRateLimiter()

    /// One model on one key. `key` is a hash of the key, never the key itself.
    struct Slot: Hashable, Sendable {
        var key: Int
        var model: String
    }

    /// A request's place in the count, handed back with finished().
    struct Lease: Sendable {
        var id: UUID
        var priority: GeminiPriority
    }

    static func keyID(_ key: String) -> Int {
        var h = Hasher()
        h.combine(key)
        return h.finalize()
    }

    /// The slot a raw Gemini request belongs to (model from the URL, key from its header).
    static func slot(for request: URLRequest) -> Slot {
        let path = request.url?.lastPathComponent ?? ""
        let model = path.split(separator: ":").first.map(String.init) ?? path
        return Slot(key: keyID(request.value(forHTTPHeaderField: "x-goog-api-key") ?? ""), model: model)
    }

    private var sent: [Slot: [(at: Date, background: Bool)]] = [:]
    private var holds: [Slot: Date] = [:]
    /// The person's requests on the wire now, with when they started (a lost one is forgotten after a minute).
    private var foregroundInFlight: [UUID: Date] = [:]
    private var lastForeground: Date?
    /// Requests let through since start (tests read these).
    private(set) var grantedForeground = 0
    private(set) var grantedBackground = 0

    let fixedPerMinute: Int?
    let window: TimeInterval
    let maxWait: TimeInterval
    let maxBackgroundWait: TimeInterval
    let quiet: TimeInterval
    let backgroundShare: Double

    init(perMinute: Int? = nil, window: TimeInterval = 60, maxWait: TimeInterval = 3, maxBackgroundWait: TimeInterval = 15,
         quiet: TimeInterval = 5, backgroundShare: Double = 0.6) {
        self.fixedPerMinute = perMinute
        self.window = window
        self.maxWait = maxWait
        self.maxBackgroundWait = maxBackgroundWait
        self.quiet = quiet
        self.backgroundShare = backgroundShare
    }

    /// Requests a minute for one model on one key.
    func perMinute(_ model: String) -> Int {
        if let fixedPerMinute { return max(1, fixedPerMinute) }
        let v = UserDefaults.standard.integer(forKey: "kairos.gemini.rpm")
        if v > 0 { return v }
        return model.contains("lite") ? 14 : 9
    }

    /// The most background requests a slot takes in a minute.
    func backgroundLimit(_ model: String) -> Int {
        max(1, Int((Double(perMinute(model)) * backgroundShare).rounded(.down)))
    }

    /// Waits for a turn to send one request to `slot` (see the rules above), then counts it. Hand the lease back
    /// with finished() when the answer is in. `onLongWait` hears once when the wait will be longer than a second.
    func waitForSlot(_ slot: Slot, priority: GeminiPriority, onLongWait: (@Sendable () -> Void)? = nil) async -> Lease {
        let start = Date()
        var told = false
        while !Task.isCancelled {
            let now = Date()
            tidy(now)
            let wait = self.wait(slot, priority: priority, now: now)
            if wait <= 0 { break }
            let waited = now.timeIntervalSince(start)
            let cap = priority == .foreground ? maxWait : maxBackgroundWait
            if waited >= cap { break }
            let left = min(wait, cap - waited)
            if !told, left > 1 { told = true; onLongWait?() }
            try? await Task.sleep(nanoseconds: UInt64(max(0.02, min(left, 0.25)) * 1_000_000_000))
        }
        let now = Date()
        sent[slot, default: []].append((now, priority == .background))
        let lease = Lease(id: UUID(), priority: priority)
        if priority == .foreground {
            foregroundInFlight[lease.id] = now
            lastForeground = now
            grantedForeground += 1
        } else {
            grantedBackground += 1
        }
        return lease
    }

    /// The request is over (answered, failed or cancelled).
    func finished(_ lease: Lease) {
        guard lease.priority == .foreground else { return }
        foregroundInFlight[lease.id] = nil
        lastForeground = Date()
    }

    /// Seconds `priority` would wait for `slot` now (0 = it can go).
    private func wait(_ slot: Slot, priority: GeminiPriority, now: Date) -> TimeInterval {
        let list = sent[slot] ?? []
        var wait: TimeInterval = 0
        if list.count >= perMinute(slot.model), let oldest = list.first { wait = window - now.timeIntervalSince(oldest.at) }
        guard priority == .background else { return wait }
        if !foregroundInFlight.isEmpty {
            wait = max(wait, 0.25)
        } else if let last = lastForeground {
            wait = max(wait, quiet - now.timeIntervalSince(last))
        }
        let mine = list.filter { $0.background }
        if mine.count >= backgroundLimit(slot.model), let oldest = mine.first {
            wait = max(wait, window - now.timeIntervalSince(oldest.at))
        }
        return wait
    }

    private func tidy(_ now: Date) {
        for (slot, list) in sent {
            let kept = list.filter { now.timeIntervalSince($0.at) < window }
            sent[slot] = kept.isEmpty ? nil : kept
        }
        foregroundInFlight = foregroundInFlight.filter { now.timeIntervalSince($0.value) < 60 }
    }

    /// Whether `slot` has room in its own count for one more request of this priority right now.
    func hasRoom(_ slot: Slot, priority: GeminiPriority) -> Bool {
        let now = Date()
        tidy(now)
        let list = sent[slot] ?? []
        if list.count >= perMinute(slot.model) { return false }
        if priority == .background, list.filter({ $0.background }).count >= backgroundLimit(slot.model) { return false }
        return true
    }

    /// Google said 429 for this slot: rest it for this many seconds (at least 1, at most 10 minutes).
    func coolDown(_ slot: Slot, seconds: Double) {
        let until = Date().addingTimeInterval(min(max(seconds, 1), 600))
        if let current = holds[slot], current > until { return }
        holds[slot] = until
    }

    /// Seconds until `slot` may be asked again (0 = now).
    func holdRemaining(_ slot: Slot) -> TimeInterval {
        guard let until = holds[slot] else { return 0 }
        let left = until.timeIntervalSinceNow
        if left <= 0 { holds[slot] = nil; return 0 }
        return left
    }

    /// The slot answered: whatever hold it had is over.
    func answered(_ slot: Slot) {
        holds[slot] = nil
    }

    /// Whether one of the person's requests is on the wire now (tests read this).
    var foregroundBusy: Bool { !foregroundInFlight.isEmpty }

    func reset() {
        sent = [:]
        holds = [:]
        foregroundInFlight = [:]
        lastForeground = nil
        grantedForeground = 0
        grantedBackground = 0
    }
}
