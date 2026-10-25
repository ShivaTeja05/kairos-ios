import Foundation

// The model behind the agents, behind one small interface so it can be swapped (Gemini today; an
// OpenAI-compatible endpoint, Ollama on a Mac, or Apple's on-device model later). History is kept in
// Gemini's "contents" shape ({role, parts}) because that is what we send most; other providers translate.

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
        case .rateLimited: return "I've been asked a lot just now. Please try again in a minute."
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

struct GeminiProvider: ModelProvider {
    var model: String
    var apiKey: String
    var timeout: TimeInterval = 25
    var label: String { "Gemini (\(model))" }

    private var endpoint: URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
    }

    /// Gemini 3 Flash-Lite takes "minimal" thinking (fast, cheap); other Gemini 3 models start at "low";
    /// 2.5 Flash uses a token budget. Sampling parameters are left at the model's defaults (Gemini 3 guidance).
    private var thinking: JSONValue? {
        if model.hasPrefix("gemini-3") { return ["thinkingLevel": model.contains("lite") ? "minimal" : "low"] }
        if model.hasPrefix("gemini-2.5-flash") { return ["thinkingBudget": 0] }
        return nil
    }

    func step(system: String, history: [JSONValue], tools: [JSONValue], requireTool: Bool) async throws -> ModelTurn {
        var body: [String: JSONValue] = [
            "systemInstruction": ["parts": [GeminiContent.text(system)]],
            "contents": .array(history),
        ]
        if !tools.isEmpty {
            body["tools"] = [["functionDeclarations": .array(tools)]]
            body["toolConfig"] = ["functionCallingConfig": ["mode": requireTool ? "ANY" : "AUTO"]]
        }
        let reply = try await post(body, maxTokens: 1024)
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
            reply = try await post(body, maxTokens: 6000, extraConfig: extra)
        } catch ModelError.http(400, let text) where jsonSchema != nil && text.localizedCaseInsensitiveContains("schema") {
            // Older models only know the OpenAPI-style field.
            extra["responseJsonSchema"] = nil
            extra["responseSchema"] = jsonSchema
            reply = try await post(body, maxTokens: 6000, extraConfig: extra)
        }
        let turn = try Self.parseTurn(reply)
        guard !turn.text.isEmpty else { throw ModelError.empty }
        return turn.text
    }

    // MARK: - HTTP

    private func post(_ body: [String: JSONValue], maxTokens: Int, extraConfig: [String: JSONValue] = [:],
                      withThinking: Bool = true, attempt: Int = 0) async throws -> JSONValue {
        var config = extraConfig
        config["maxOutputTokens"] = .number(Double(maxTokens))
        if withThinking, let thinking { config["thinkingConfig"] = thinking }
        var full = body
        full["generationConfig"] = .object(config)

        var req = URLRequest(url: endpoint, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = JSONValue.object(full).encoded()

        let data: Data, response: URLResponse
        await GeminiRateLimiter.shared.waitForSlot()
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                                          .cannotConnectToHost, .dataNotAllowed].contains(e.code) {
            throw ModelError.offline
        } catch let e as URLError where e.code == .timedOut {
            if attempt == 0 { return try await post(body, maxTokens: maxTokens, extraConfig: extraConfig, withThinking: withThinking, attempt: 1) }
            throw ModelError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""
        switch status {
        case 200: return JSONValue.decode(data) ?? .null
        case 400 where withThinking && text.localizedCaseInsensitiveContains("thinking"):
            // This model doesn't take the thinking setting we chose: ask again without it.
            return try await post(body, maxTokens: maxTokens, extraConfig: extraConfig, withThinking: false, attempt: attempt)
        case 400 where text.contains("API_KEY_INVALID") || text.localizedCaseInsensitiveContains("api key not valid"),
             401, 403:
            throw ModelError.badKey
        case 429:
            // The free tier says how long to wait (google.rpc.RetryInfo "retryDelay": "6s"): retry once if it's short.
            if attempt == 0, let wait = Self.retryDelay(text), wait <= 8 {
                try? await Task.sleep(nanoseconds: UInt64(max(0.3, wait) * 1_000_000_000))
                return try await post(body, maxTokens: maxTokens, extraConfig: extraConfig, withThinking: withThinking, attempt: 1)
            }
            throw ModelError.rateLimited
        case 500, 502, 503, 504:
            if attempt == 0 {
                try? await Task.sleep(nanoseconds: 800_000_000)
                return try await post(body, maxTokens: maxTokens, extraConfig: extraConfig, withThinking: withThinking, attempt: 1)
            }
            throw ModelError.http(status, String(text.prefix(300)))
        default: throw ModelError.http(status, String(text.prefix(300)))
        }
    }

    /// Seconds from a 429 body's RetryInfo ("retryDelay": "6s" or "6.5s"), if there is one.
    static func retryDelay(_ body: String) -> Double? {
        guard let r = body.range(of: #""retryDelay"\s*:\s*"([0-9.]+)s""#, options: .regularExpression) else { return nil }
        let digits = body[r].split(separator: ":").last.map { $0.filter { "0123456789.".contains($0) } } ?? ""
        return Double(digits)
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

/// Where the agents' model settings live. The key stays in this phone's Keychain, never in the app's code.
enum AgentSettings {
    static let keyName = "gemini_api_key"
    static let modelDefaultsKey = "kairos.agents.model"
    static let defaultModel = "gemini-3.5-flash-lite"

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

    /// "gemini-3.5-flash-lite", "gemma-3-27b-it": lowercase family-version names, never key-shaped strings.
    static func isModelName(_ s: String) -> Bool {
        let families = ["gemini-", "gemma-", "learnlm-"]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        return s.count <= 60 && families.contains(where: { s.hasPrefix($0) })
            && s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static var hasKey: Bool { (KeyStore.get(keyName) ?? "").count >= 20 }

    /// Saves a pasted key after trimming spaces and quotes. Returns false if it can't be a key.
    @discardableResult
    static func saveKey(_ raw: String) -> Bool {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        guard key.count >= 20, key.count <= 200, !key.contains(" "), !key.contains("\n") else { return false }
        KeyStore.set(keyName, key)
        return true
    }

    static func provider(timeout: TimeInterval = 25) -> (any ModelProvider)? {
        guard let key = KeyStore.get(keyName), key.count >= 20 else { return nil }
        return GeminiProvider(model: model, apiKey: key, timeout: timeout)
    }
}


/// Keeps one process under the key's per-minute limit: at most `perMinute` Gemini requests in any rolling 60 s
/// (default 14, one under flash-lite's usual free tier; UserDefaults "kairos.gemini.rpm" overrides it, e.g. for a
/// paid key). A request waits up to 3 s for a slot, then goes anyway (the 429 retry above handles the rest).
actor GeminiRateLimiter {
    static let shared = GeminiRateLimiter()
    private var sent: [Date] = []
    var perMinute: Int { let v = UserDefaults.standard.integer(forKey: "kairos.gemini.rpm"); return v > 0 ? v : 14 }
    let maxWait: TimeInterval = 3

    func waitForSlot() async {
        let start = Date()
        while true {
            let now = Date()
            sent.removeAll { now.timeIntervalSince($0) >= 60 }
            if sent.count < perMinute { break }
            let waited = now.timeIntervalSince(start)
            guard waited < maxWait, let oldest = sent.first else { break }
            let free = 60 - now.timeIntervalSince(oldest)
            let nap = min(max(0.2, free), maxWait - waited)
            try? await Task.sleep(nanoseconds: UInt64(nap * 1_000_000_000))
        }
        sent.append(Date())
    }
}
