import Foundation
import ImageIO

// The on-phone letter reader (the team's first agent), ported from tempo-hub/agents/document_interpreter.
//
//   photo(s) of a letter, bill or form
//     -> shrink      max side 1600 px, JPEG 0.7, before anything is sent (LetterPhoto)
//     -> read        ONE Gemini call: English facts + the spoken explanation in the person's language (LetterPrompts)
//     -> normalise   every key present, never trust the model's shape (LetterFacts.normalise, from schema.py)
//     -> assess      scam signals in code, never the model's word alone (LetterSafety, from safety.py)
//     -> say         code leads with a calm warning for a likely scam, drops phone numbers and links from a
//                    scam's explanation, and ends with a reminder offer when there's a deadline
//     -> remember    the last letter stays in RAM for an hour, for follow-up questions (LetterMemory)
//
// The photo is never stored. The letter's text goes back to Kairos as untrusted text, so the SafetyGate refuses
// to dial or open a number or link that only the letter (not the person) mentioned.

struct LetterAgent: SpecialistAgent {
    let id = "letter"
    let title = "Letter reader"
    let icon = "doc.text.viewfinder"
    var instructions: String {
        """
        Reads photos of letters, bills and forms and explains them in plain words, with scam checks. When the person \
        shows a photo of a letter, bill or form, call read_letter at once; never describe the photo yourself. If they \
        want a letter read but there's no photo, call read_letter and it opens the camera. For a question about the \
        letter already read, call ask_letter with their words. The person hears these answers as they are, so don't \
        retell them, and never call read_letter twice for the same photo. If read_letter gave a reminder_offer and the \
        person says yes, set the reminder with reminder_offer.title and reminder_offer.due.
        """
    }
    var tools: [any KairosTool] { [LetterReadTool(), LetterAskTool()] }
}

// MARK: - Tools

struct LetterReadTool: KairosTool {
    let name = "read_letter"
    let summary = "Read a photo of a letter, bill or form and explain it in plain words: who it's from, what it means, any money owed, what to do by when, and any scam signs. With no photo, it opens the camera."
    let risk = Risk.read
    var parameters: JSONValue {
        Schema.object([
            "question": Schema.string("What the person wants to know about the letter, in their own words, if they said"),
            "language": Schema.string("Language code to explain it in (e.g. te, hi, cy), only if the person asked for a different language"),
            "dialect": Schema.string("The regional way of speaking, only if the person asked (e.g. Telangana, Yorkshire)"),
        ])
    }

    func quickMatch(_ words: String, ctx: TurnContext) -> JSONValue? {
        LetterMatch.wantsReading(words, ctx: ctx) ? .object([:]) : nil
    }

    func describe(_ args: JSONValue, ctx: TurnContext) -> String {
        ctx.images.isEmpty ? "Opening the camera" : "Reading your letter"
    }

    func execute(_ args: JSONValue, ctx: TurnContext) async throws -> ToolResult {
        await LetterInterpreter.read(args, ctx: ctx)
    }
}

struct LetterAskTool: KairosTool {
    let name = "ask_letter"
    let summary = "Answer a question about the letter, bill or form Kairos read most recently, from what it said. No new photo needed."
    let risk = Risk.read
    var parameters: JSONValue {
        Schema.object(["question": Schema.string("The person's question about the letter, in their own words")],
                      required: ["question"])
    }

    func quickMatch(_ words: String, ctx: TurnContext) -> JSONValue? {
        LetterMatch.questionAboutLetter(words, ctx: ctx) ? .object(["question": .string(words)]) : nil
    }

    func validate(_ args: JSONValue, ctx: TurnContext) -> Validation {
        args.text("question") == nil ? .clarify("What would you like to know about the letter?") : .ok
    }

    func describe(_ args: JSONValue, ctx: TurnContext) -> String { "Looking back at the letter" }

    func execute(_ args: JSONValue, ctx: TurnContext) async throws -> ToolResult {
        guard let question = args.text("question") else { return .fail("What would you like to know about the letter?") }
        guard let record = LetterMemory.shared.latest(now: ctx.now) else {
            return ToolResult(ok: true,
                              say: "I haven't read a letter with you yet. If you'd like me to, just say: read my letter.",
                              data: ["no_letter": true], isAnswer: true)
        }
        return await LetterInterpreter.answer(question, record: record, ctx: ctx)
    }
}

// MARK: - The pipeline

enum LetterInterpreter {
    static let maxPages = 4
    /// Reading a photo takes longer than a router step (the design doc allows 40 s). Not for Siri in the background.
    static let readTimeout: TimeInterval = 40
    /// Optional: a different Gemini model just for reading photos (e.g. "gemini-3.8-flash"). Unset: Kairos's model.
    static let modelOverrideKey = "kairos.agents.letterModel"
    /// Follow-up questions are caught by the rules (no model call) for this long after a letter is read.
    static let followUpWindow: TimeInterval = 600

    static let needsKeySay = "Reading letters needs the internet and a Gemini key. Ask your helper to add the key in Kairos settings."
    static let unreadableSay = "I couldn't read that photo clearly. Please take another one in good light, with the letter flat on a table and the whole page in view."

    static func read(_ args: JSONValue, ctx: TurnContext) async -> ToolResult {
        let question = args.text("question").map { String($0.prefix(300)) }

        if ctx.images.isEmpty {
            // "What does the letter say?" just after a letter was read: answer from memory, don't open the camera.
            if let question, let record = LetterMemory.shared.latest(now: ctx.now, within: followUpWindow) {
                return await answer(question, record: record, ctx: ctx)
            }
            guard ctx.model != nil else { return .fail(needsKeySay) }
            let say = ctx.canShowUI
                ? "Hold the letter flat and take a photo. I'll read it for you."
                : "Please open Kairos, then hold the letter flat and take a photo. I'll read it for you."
            return ToolResult(ok: true, say: say,
                              data: ["status": "The camera is opening. The photo will come with the person's next message."],
                              ui: .camera, isAnswer: true)
        }
        guard let base = ctx.model else { return .fail(needsKeySay) }

        let language = LetterLanguage.info(args.text("language") ?? ctx.language)
        let dialect = dialectFor(args, language: language)
        let pages = ctx.images.prefix(maxPages).map(LetterPhoto.prepared)
        let parts = pages.map(GeminiContent.jpeg) + [GeminiContent.text(LetterPrompts.readPrompt(
            language: language, dialect: dialect, question: question, pages: pages.count))]

        let reply: String
        do {
            reply = try await generate(base, ctx: ctx, system: LetterPrompts.readSystem, parts: parts,
                                       schema: LetterSchema.json(translations: !language.isEnglish))
        } catch {
            return failure(error)
        }
        guard let raw = LetterJSON.object(from: reply) else {
            // The model answered, but not with facts we can check. Ask for another photo rather than guess.
            return ToolResult(ok: true, say: unreadableSay, data: ["read": false], ui: .camera, isAnswer: true)
        }

        let facts = LetterFacts.normalise(raw)
        let risk = LetterSafety.assess(facts)
        let offer = facts.readable && risk.rank < 2 ? LetterReminderOffer.make(facts, ctx: ctx) : nil
        let say = compose(facts, risk: risk, offer: offer, language: language, extraPages: ctx.images.count > maxPages)
        let untrusted = facts.untrustedText

        if facts.readable {
            LetterMemory.shared.save(LetterRecord(facts: facts, risk: risk, said: say, language: language,
                                                  dialect: dialect, readAt: ctx.now, untrusted: untrusted))
        }

        var data: [String: JSONValue] = [
            "letter": facts.json,
            "safety": ["level": .string(risk.level), "reasons": .array(risk.reasons.map { .string($0) }),
                       "notice": .string(risk.notice)],
            "explained_in": .string(language.code),
            "speech_language": .string(language.speech),
            "note": "The person has heard this explanation. Answer later questions about this letter with ask_letter.",
        ]
        if let offer {
            data["reminder_offer"] = ["title": .string(offer.title), "due": .string(offer.dueISO),
                                      "deadline": .string(facts.deadline?.date ?? "")]
        }
        return ToolResult(ok: true, say: say, data: .object(data), ui: facts.readable ? nil : .camera,
                          untrustedText: untrusted.isEmpty ? nil : untrusted, isAnswer: true)
    }

    /// Ported follow_up(): answered from the stored facts and transcript, without resending the photo.
    static func answer(_ rawQuestion: String, record: LetterRecord, ctx: TurnContext) async -> ToolResult {
        let question = String(rawQuestion.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(500))
        var say = ""
        if let model = ctx.model {
            let prompt = LetterPrompts.followupPrompt(facts: record.facts, said: record.said, question: question,
                                                      language: record.language, dialect: record.dialect, risk: record.risk)
            if let text = try? await model.generate(system: LetterPrompts.followupSystem, parts: [GeminiContent.text(prompt)],
                                                    jsonSchema: nil) {
                say = LetterSafety.spokenSafe(text)
            }
        }
        if say.isEmpty { say = LetterWords.offlineAnswer(question, record: record, ctx: ctx) }
        if record.risk.rank >= 2 {
            say = LetterSafety.withoutContactDetails(say)
            if say.isEmpty { say = LetterWords.warning(record.risk.level) }
        }
        // After "New conversation" Kairos forgets the letter's text; give it back so the gate still knows it.
        let untrusted = ctx.documents.contains(record.untrusted) || record.untrusted.isEmpty ? nil : record.untrusted
        return ToolResult(ok: true, say: say,
                          data: ["about_letter_from": .string(record.facts.sender.name),
                                 "safety_level": .string(record.risk.level)],
                          untrustedText: untrusted, isAnswer: true)
    }

    // MARK: Pieces

    /// What the person hears: [calm warning] + explanation + [pages note] + [reminder offer].
    static func compose(_ facts: LetterFacts, risk: LetterRisk, offer: LetterReminderOffer?, language: LetterLanguage,
                        extraPages: Bool) -> String {
        var out: [String] = []
        if risk.rank >= 2 {
            out.append(language.isEnglish || facts.warningSpoken.isEmpty ? LetterWords.warning(risk.level)
                                                                         : LetterSafety.spokenSafe(facts.warningSpoken))
        }
        var explanation = LetterSafety.spokenSafe(facts.explanation)
        if explanation.isEmpty {
            explanation = facts.readable ? LetterSafety.spokenSafe(facts.summaryPlain) : unreadableSay
        }
        if risk.rank >= 2 {
            let cleaned = LetterSafety.withoutContactDetails(explanation)
            explanation = cleaned.isEmpty ? LetterSafety.withoutContactDetails(facts.summaryPlain) : cleaned
        }
        if !explanation.isEmpty { out.append(LetterWords.sentence(explanation)) }
        if extraPages, language.isEnglish { out.append("I only looked at the first four pages.") }
        if let offer {
            out.append(language.isEnglish || facts.offerSpoken.isEmpty ? offer.spoken
                                                                       : LetterSafety.spokenSafe(facts.offerSpoken))
        }
        return out.joined(separator: " ")
    }

    /// The dialect the person asked for, else the one saved on the letter screen if it's for this language.
    static func dialectFor(_ args: JSONValue, language: LetterLanguage) -> String {
        var raw = args.text("dialect") ?? ""
        if raw.isEmpty {
            let defaults = UserDefaults.standard
            if let saved = defaults.string(forKey: "letterDialect"), !saved.isEmpty,
               LetterLanguage.info(defaults.string(forKey: "letterLanguage") ?? "en-GB").base == language.base {
                raw = saved
            }
        }
        return String(raw.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(80))
    }

    /// The photo-reading call: the letter model if one is set (falling back to Kairos's own), with a longer timeout.
    private static func generate(_ base: any ModelProvider, ctx: TurnContext, system: String, parts: [JSONValue],
                                 schema: JSONValue) async throws -> String {
        var primary: any ModelProvider = base
        var fallback: (any ModelProvider)?
        if var gemini = base as? GeminiProvider {
            if ctx.source != .siriBackground { gemini.timeout = max(gemini.timeout, readTimeout) }
            primary = gemini
            let wanted = (UserDefaults.standard.string(forKey: modelOverrideKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if wanted.hasPrefix("gemini-"), wanted != gemini.model,
               wanted.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }) {
                var special = gemini
                special.model = wanted
                primary = special
                fallback = gemini
            }
        }
        do {
            return try await primary.generate(system: system, parts: parts, jsonSchema: schema)
        } catch let error as ModelError {
            guard let fallback, worthFallingBack(error) else { throw error }
            return try await fallback.generate(system: system, parts: parts, jsonSchema: schema)
        }
    }

    private static func worthFallingBack(_ error: ModelError) -> Bool {
        switch error {
        case .rateLimited, .empty: return true
        case .http(let code, _): return code == 400 || code == 404 || code >= 500
        default: return false
        }
    }

    private static func failure(_ error: Error) -> ToolResult {
        guard let modelError = error as? ModelError else {
            return .fail("Sorry, I couldn't read the letter that time. Please try again.")
        }
        switch modelError {
        case .offline: return .fail("I can't reach the internet just now, so I can't read the letter. Please try again in a moment.")
        case .blocked: return .fail("I couldn't read that one. Please try a different photo.")
        case .noKey: return .fail(needsKeySay)
        case .badKey, .rateLimited: return .fail(modelError.errorDescription ?? "Please try again in a minute.")
        case .empty, .http: return .fail("Sorry, I couldn't read the letter that time. Please try again.")
        }
    }
}

// MARK: - The facts (schema.py normalise)

/// What the model pulled out of the document, with every key present and every value checked.
struct LetterFacts: Sendable, Equatable {
    struct Party: Sendable, Equatable { var name = ""; var type = "unknown" }
    struct Money: Sendable, Equatable {
        var youOwe: Double?
        var theyOweYou: Double?
        var currency = "GBP"
        var alreadyPaid: Bool?
        var notes = ""
    }
    struct Dated: Sendable, Equatable { var date: String; var what: String }
    struct Action: Sendable, Equatable { var action: String; var byWhen: String; var how: String }
    struct Labelled: Sendable, Equatable { var label: String; var value: String }
    struct Contact: Sendable, Equatable { var phone = ""; var email = ""; var website = "" }

    var readable = true
    var readabilityIssues: [String] = []
    var languageOfDocument = ""
    var documentType = "other"
    var sender = Party()
    var recipientName = ""
    var dateOfDocument = ""
    var summaryPlain = ""
    var keyPoints: [String] = []
    /// nil when the document mentions no money.
    var money: Money?
    var dates: [Dated] = []
    var deadline: Dated?
    var actionsRequired: [Action] = []
    var urgency = "none"
    var tone = "neutral"
    var scamLevel = "none"
    var scamReasons: [String] = []
    var referenceNumbers: [Labelled] = []
    /// label = what it's for, value = the number as printed.
    var phoneNumbers: [Labelled] = []
    var contact = Contact()
    var transcript = ""
    var confidence = 0.5
    // Written for the person, in their language (the phone's single call).
    var explanation = ""
    var warningSpoken = ""
    var offerSpoken = ""

    /// Never fails on odd model output: wrong types fall back to the defaults, enums are checked, lists capped.
    static func normalise(_ raw: JSONValue) -> LetterFacts {
        let r = raw.object ?? [:]
        var f = LetterFacts()
        f.readable = r["readable"]?.bool ?? true
        f.readabilityIssues = strings(r["readability_issues"], max: 120, count: 5)
        f.languageOfDocument = text(r["language_of_document"], 20)
        f.documentType = oneOf(r["document_type"], LetterSchema.documentTypes, fallback: "other")
        if let s = r["sender"]?.object {
            let type = text(s["type"], 60)
            f.sender = Party(name: text(s["name"], 120), type: type.isEmpty ? "unknown" : type)
        } else if case .string(let name)? = r["sender"] {
            f.sender = Party(name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)), type: "unknown")
        }
        f.recipientName = text(r["recipient_name"], 120)
        f.dateOfDocument = text(r["date_of_document"], 25)
        f.summaryPlain = text(r["summary_plain"], 600)
        f.keyPoints = strings(r["key_points"], max: 300, count: 8)
        if let m = r["money"]?.object, !m.isEmpty {
            let currency = text(m["currency"], 8)
            f.money = Money(youOwe: number(m["you_owe"]), theyOweYou: number(m["they_owe_you"]),
                            currency: currency.isEmpty ? "GBP" : currency.uppercased(),
                            alreadyPaid: m["already_paid"]?.bool, notes: text(m["notes"], 300))
        }
        f.dates = Array((r["dates"]?.array ?? []).compactMap { d -> Dated? in
            guard let o = d.object else { return nil }
            let date = text(o["date"], 25)
            return date.isEmpty ? nil : Dated(date: date, what: text(o["what"], 120))
        }.prefix(10))
        if let d = r["deadline"]?.object {
            let date = text(d["date"], 25)
            if !date.isEmpty { f.deadline = Dated(date: date, what: text(d["what"], 160)) }
        }
        f.actionsRequired = Array((r["actions_required"]?.array ?? []).compactMap { a -> Action? in
            guard let o = a.object else { return nil }
            let action = text(o["action"], 200)
            return action.isEmpty ? nil : Action(action: action, byWhen: text(o["by_when"], 25), how: text(o["how"], 120))
        }.prefix(6))
        f.urgency = oneOf(r["urgency"], LetterSchema.urgency, fallback: "none")
        f.tone = oneOf(r["tone"], LetterSchema.tone, fallback: "neutral")
        if let s = r["scam_risk"]?.object {
            f.scamLevel = oneOf(s["level"], LetterSchema.risk, fallback: "none")
            f.scamReasons = strings(s["reasons"], max: 300, count: 6)
        }
        f.referenceNumbers = Array((r["reference_numbers"]?.array ?? []).compactMap { x -> Labelled? in
            guard let o = x.object else { return nil }
            let value = text(o["value"], 60)
            return value.isEmpty ? nil : Labelled(label: text(o["label"], 60), value: value)
        }.prefix(8))
        f.phoneNumbers = Array((r["phone_numbers"]?.array ?? []).compactMap { x -> Labelled? in
            if let o = x.object {
                let number = text(o["number"], 40)
                return number.isEmpty ? nil : Labelled(label: text(o["what"], 80), value: number)
            }
            let number = text(x, 40)
            return number.isEmpty ? nil : Labelled(label: "", value: number)
        }.prefix(8))
        if let c = r["contact"]?.object {
            f.contact = Contact(phone: text(c["phone"], 120), email: text(c["email"], 120), website: text(c["website"], 120))
        }
        f.transcript = String((r["transcript"]?.string ?? "").prefix(6000))
        if let c = r["confidence"]?.double, c.isFinite { f.confidence = min(1, max(0, c)) }
        f.explanation = text(r["explanation"], 2000)
        f.warningSpoken = text(r["warning_spoken"], 400)
        f.offerSpoken = text(r["offer_spoken"], 300)
        return f
    }

    /// The facts for Kairos and for follow-ups (schema.public): everything but the transcript and the spoken words.
    var json: JSONValue {
        var o: [String: JSONValue] = [
            "readable": .bool(readable),
            "document_type": .string(documentType),
            "sender": ["name": .string(sender.name), "type": .string(sender.type)],
            "summary_plain": .string(summaryPlain),
            "key_points": .array(keyPoints.map { .string($0) }),
            "urgency": .string(urgency),
            "tone": .string(tone),
            "scam_risk": ["level": .string(scamLevel), "reasons": .array(scamReasons.map { .string($0) })],
            "actions_required": .array(actionsRequired.map { a -> JSONValue in
                ["action": .string(a.action), "by_when": .string(a.byWhen), "how": .string(a.how)]
            }),
            "confidence": .number((confidence * 100).rounded() / 100),
        ]
        if !readabilityIssues.isEmpty { o["readability_issues"] = .array(readabilityIssues.map { .string($0) }) }
        if !languageOfDocument.isEmpty { o["language_of_document"] = .string(languageOfDocument) }
        if !recipientName.isEmpty { o["recipient_name"] = .string(recipientName) }
        if !dateOfDocument.isEmpty { o["date_of_document"] = .string(dateOfDocument) }
        if let money {
            var m: [String: JSONValue] = ["currency": .string(money.currency)]
            m["you_owe"] = money.youOwe.map { .number($0) } ?? .null
            m["they_owe_you"] = money.theyOweYou.map { .number($0) } ?? .null
            if let paid = money.alreadyPaid { m["already_paid"] = .bool(paid) }
            if !money.notes.isEmpty { m["notes"] = .string(money.notes) }
            o["money"] = .object(m)
        }
        if !dates.isEmpty {
            o["dates"] = .array(dates.map { d -> JSONValue in ["date": .string(d.date), "what": .string(d.what)] })
        }
        if let deadline { o["deadline"] = ["date": .string(deadline.date), "what": .string(deadline.what)] }
        if !referenceNumbers.isEmpty {
            o["reference_numbers"] = .array(referenceNumbers.map { x -> JSONValue in
                ["label": .string(x.label), "value": .string(x.value)]
            })
        }
        if !phoneNumbers.isEmpty {
            o["phone_numbers"] = .array(phoneNumbers.map { x -> JSONValue in
                ["number": .string(x.value), "what": .string(x.label)]
            })
        }
        let c = contact
        if !(c.phone.isEmpty && c.email.isEmpty && c.website.isEmpty) {
            o["contact"] = ["phone": .string(c.phone), "email": .string(c.email), "website": .string(c.website)]
        }
        return .object(o)
    }

    /// Everything the letter itself says, for the SafetyGate's "only the letter said this number" check.
    var untrustedText: String {
        var bits = [transcript, summaryPlain, sender.name, recipientName, contact.phone, contact.email, contact.website]
        bits += keyPoints
        bits += actionsRequired.map { "\($0.action) \($0.how)" }
        bits += referenceNumbers.map { "\($0.label) \($0.value)" }
        bits += phoneNumbers.map { "\($0.label) \($0.value)" }
        return bits.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    // MARK: Helpers

    private static func text(_ v: JSONValue?, _ max: Int) -> String {
        String((v?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(max))
    }

    private static func strings(_ v: JSONValue?, max: Int, count: Int) -> [String] {
        Array((v?.array ?? []).map { text($0, max) }.filter { !$0.isEmpty }.prefix(count))
    }

    private static func oneOf(_ v: JSONValue?, _ allowed: [String], fallback: String) -> String {
        let s = text(v, 40).lowercased()
        return allowed.contains(s) ? s : fallback
    }

    /// schema._num: "£1,234.50" -> 1234.5; nil for anything that isn't a number.
    static func number(_ v: JSONValue?) -> Double? {
        guard let v else { return nil }
        var value: Double?
        switch v {
        case .number(let n): value = n
        case .string(let s):
            var t = s
            for junk in [",", "£", "$", "€"] { t = t.replacingOccurrences(of: junk, with: "") }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            value = t.isEmpty ? nil : Double(t)
        default: value = nil
        }
        guard let value, value.isFinite else { return nil }
        return (value * 100).rounded() / 100
    }
}

// MARK: - Scam and safety checks (safety.py), pure functions over the facts

struct LetterRisk: Sendable, Equatable {
    var level: String
    var reasons: [String]
    var notice: String
    var modelLevel: String
    var signals: Int
    var rank: Int { LetterSafety.order[level] ?? 0 }
}

enum LetterSafety {
    static let order = ["none": 0, "low": 1, "medium": 2, "high": 3]

    static let paymentTraps = ["gift card", "itunes", "google play", "steam card", "bitcoin", "crypto", "western union",
                               "moneygram", "wire transfer", "transfer to", "personal account", "voucher code"]
    static let pressure = ["within 24 hours", "within 48 hours", "immediately", "act now", "today only", "final warning",
                           "last chance", "legal action will", "arrest", "warrant", "police", "court order", "suspended",
                           "will be closed", "lose your"]
    static let verify = ["verify your", "confirm your bank", "confirm your card", "update your details", "click the link",
                         "scan the qr", "whatsapp", "text us on", "reply with your"]
    static let official = ["hmrc", "hm revenue", "dvla", "dwp", "department for work", "royal mail", "nhs", "council",
                           "hm courts", "home office", "gov.uk", "bank", "barclays", "lloyds", "hsbc", "natwest",
                           "santander", "nationwide", "monzo"]
    static let govDomains = [".gov.uk", ".nhs.uk", ".police.uk", ".ac.uk"]
    static let siteWords = ["refund", "claim", "verify", "secure", "hmrc", "gov", "tax", "bank"]

    static let notices = [
        "none": "",
        "low": "Nothing here looks like a scam, but never share bank details because a letter asks.",
        "medium": "Some things about this look odd. Don't pay or share details until you've checked with the real organisation.",
        "high": "This looks like a scam. Don't pay, don't call the number on it, don't open the link. Check with the real organisation or someone you trust.",
    ]

    private static let siteRegex = try? NSRegularExpression(pattern: #"(?:https?://)?(?:www\.)?([a-z0-9-]+(?:\.[a-z0-9-]+)+)"#)
    private static let phoneRegex = try? NSRegularExpression(pattern: #"(?<!\d)(0[79]\d{2}\s?\d{3}\s?\d{3,4}|\+44\s?7\d{3}\s?\d{6})"#)
    private static let linkRegex = try? NSRegularExpression(
        pattern: #"(https?://|www\.|@|\b[a-z0-9-]+(\.[a-z0-9-]+)*\.(com|org|net|uk|info|online|xyz|io|co|site|top)\b)"#,
        options: [.caseInsensitive])

    /// The document as one lowercased text, for the word checks (safety._text, plus the printed phone numbers).
    static func text(_ f: LetterFacts) -> String {
        var bits = [f.transcript, f.summaryPlain, f.keyPoints.joined(separator: " ")]
        bits += [f.contact.website, f.contact.email, f.sender.name, f.contact.phone]
        bits += f.phoneNumbers.map(\.value)
        return bits.filter { !$0.isEmpty }.joined(separator: " ").lowercased()
    }

    /// safety.assess(): the model's verdict combined with fixed signals; the stricter one wins.
    static func assess(_ f: LetterFacts) -> LetterRisk {
        let modelLevel = order[f.scamLevel] != nil ? f.scamLevel : "none"
        var reasons = f.scamReasons
        let text = Self.text(f)
        var score = 0

        let traps = paymentTraps.filter { text.contains($0) }
        if !traps.isEmpty {
            score += 3
            reasons.append("asks for payment in an unusual way (" + traps.prefix(2).joined(separator: ", ") + ")")
        }
        let pushes = pressure.filter { text.contains($0) }
        if !pushes.isEmpty {
            score += pushes.count == 1 ? 1 : 2
            reasons.append("uses pressure or threats (" + pushes.prefix(2).joined(separator: ", ") + ")")
        }
        let asks = verify.filter { text.contains($0) }
        if !asks.isEmpty {
            score += 2
            reasons.append("wants you to confirm details via a link, message or WhatsApp")
        }
        let claimsOfficial = official.contains { text.contains($0) }
        let oddSites = sites(in: text).filter { site in !isOfficialDomain(site) && siteWords.contains { site.contains($0) } }
        if claimsOfficial, let site = oddSites.first {
            score += 2
            reasons.append("claims to be official but points to a non-official website (\(site))")
        }
        if claimsOfficial, hasMobileOrPremiumNumber(text) {
            score += 1
            reasons.append("an official body wouldn't use a mobile or premium number")
        }
        if (f.money?.theyOweYou ?? 0) > 0, !asks.isEmpty {
            score += 1
            reasons.append("a refund that needs your bank details is a classic scam")
        }

        let heuristic = score >= 4 ? "high" : score >= 2 ? "medium" : score == 1 ? "low" : "none"
        let final = (order[heuristic] ?? 0) > (order[modelLevel] ?? 0) ? heuristic : modelLevel
        var seen = Set<String>()
        var unique: [String] = []
        for reason in reasons {
            let r = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            if !r.isEmpty, seen.insert(r.lowercased()).inserted { unique.append(String(r.prefix(160))) }
        }
        return LetterRisk(level: final, reasons: Array(unique.prefix(6)), notice: notices[final] ?? "",
                          modelLevel: modelLevel, signals: score)
    }

    /// Web addresses in the text (the domain part).
    static func sites(in text: String) -> [String] {
        guard let re = siteRegex else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let r = m.range(at: 1)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    /// gov.uk itself counts as official, as well as anything under it (the Mac version missed the bare domain).
    static func isOfficialDomain(_ site: String) -> Bool {
        govDomains.contains { site.hasSuffix($0) || site == String($0.dropFirst()) }
    }

    /// A UK mobile (07…, +44 7…) or premium (09…) number. The Mac regex, plus a digits-only check so the usual
    /// "07700 900123" spacing is caught too.
    static func hasMobileOrPremiumNumber(_ text: String) -> Bool {
        if let re = phoneRegex, re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil {
            return true
        }
        for run in SafetyGate.digitRuns(text) {
            if run.count == 11, run.hasPrefix("07") || run.hasPrefix("09") { return true }
            if run.count == 12, run.hasPrefix("447") || run.hasPrefix("449") { return true }
            if run.count == 13, run.hasPrefix("4407") || run.hasPrefix("4409") { return true }
        }
        return false
    }

    /// safety.spoken_safe(): strip markdown, bullets and line breaks so the voice reads it smoothly.
    static func spokenSafe(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"[*_#`>]+"#, with: "", options: .regularExpression)
        if let bullets = try? NSRegularExpression(pattern: #"^\s*[-•]\s*"#, options: [.anchorsMatchLines]) {
            t = bullets.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length),
                                                 withTemplate: "")
        }
        t = t.replacingOccurrences(of: #"\s*\n\s*"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }

    /// Drops every sentence that carries a phone number or a link: for a likely scam, Kairos must not read them out.
    static func withoutContactDetails(_ text: String) -> String {
        var kept: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { sub, _, _, _ in
            guard let s = sub?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return }
            let hasNumber = SafetyGate.digitRuns(s).contains { $0.count >= 9 }
            let hasLink = linkRegex?.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
            if !hasNumber && !hasLink { kept.append(s) }
        }
        return kept.joined(separator: " ")
    }
}

// MARK: - Spoken words made by code (English)

enum LetterWords {
    /// The calm warning that leads a likely scam's explanation.
    static func warning(_ level: String) -> String {
        let first = level == "high" ? "Please be careful with this one. It looks like a scam."
                                    : "Please be careful with this one. Some things about it look odd."
        return first + " Don't pay anything, and don't call any number on this letter. If you're worried, call 159 to reach your bank safely."
    }

    /// Without the full stop (or ! ?) at the end, to go inside another sentence.
    static func bare(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = t.last, ".!?;:,".contains(last) { t.removeLast() }
        return t
    }

    /// Ends with a full stop if it ends with a letter or digit.
    static func sentence(_ s: String) -> String {
        guard let last = s.unicodeScalars.last else { return s }
        return CharacterSet.alphanumerics.contains(last) && last.isASCII ? s + "." : s
    }

    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch n % 100 {
        case 11, 12, 13: suffix = "th"
        default:
            switch n % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(n)\(suffix)"
    }

    /// "Friday the 30th", or "Friday the 30th of October".
    static func day(_ date: Date, ctx: TurnContext, withMonth: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = ctx.timeZone
        f.dateFormat = "EEEE"
        let weekday = f.string(from: date)
        f.dateFormat = "MMMM"
        let month = f.string(from: date)
        let n = ctx.calendar.component(.day, from: date)
        return "\(weekday) the \(ordinal(n))" + (withMonth ? " of \(month)" : "")
    }

    /// "today", "tomorrow", or "Tuesday the 3rd of November".
    static func when(_ date: Date, ctx: TurnContext) -> String {
        let cal = ctx.calendar
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: ctx.now), to: cal.startOfDay(for: date)).day ?? 99
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        default: return day(date, ctx: ctx, withMonth: true)
        }
    }

    /// "YYYY-MM-DD…" -> the start of that day in the person's time zone.
    static func parseDay(_ iso: String, ctx: TurnContext) -> Date? {
        let head = iso.trimmingCharacters(in: .whitespacesAndNewlines).prefix(10)
        let bits = head.split(separator: "-").compactMap { Int($0) }
        guard bits.count == 3, (2000...2100).contains(bits[0]), (1...12).contains(bits[1]), (1...31).contains(bits[2])
        else { return nil }
        var c = DateComponents()
        c.year = bits[0]; c.month = bits[1]; c.day = bits[2]; c.hour = 12
        let cal = ctx.calendar
        guard let d = cal.date(from: c), cal.component(.day, from: d) == bits[2] else { return nil }
        return cal.startOfDay(for: d)
    }

    /// "£31.20", "£142", "€15.50".
    static func amount(_ value: Double, currency: String) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.numberStyle = .decimal
        let whole = value.rounded() == value
        f.minimumFractionDigits = whole ? 0 : 2
        f.maximumFractionDigits = whole ? 0 : 2
        let n = f.string(from: NSNumber(value: value)) ?? String(value)
        switch currency.uppercased() {
        case "GBP": return "£" + n
        case "EUR": return "€" + n
        case "USD": return "$" + n
        default: return n + " " + currency
        }
    }

    /// "0800 316 9800" -> "0 8 0 0, 3 1 6, 9 8 0 0", so the voice says each digit.
    static func digits(_ value: String) -> String {
        value.split(whereSeparator: { $0 == " " || $0 == "-" }).map { group in
            group.map(String.init).joined(separator: " ")
        }.joined(separator: ", ")
    }

    /// Follow-up answers with no model (offline, or the call failed): the common questions, from the facts.
    static func offlineAnswer(_ question: String, record: LetterRecord, ctx: TurnContext) -> String {
        guard record.language.isEnglish else { return record.said }
        let f = record.facts
        let w = " " + question.folded + " "
        func asks(_ terms: [String]) -> Bool { terms.contains { w.contains($0) } }

        let deadlineWords: String? = f.deadline.flatMap { d in
            parseDay(d.date, ctx: ctx).map { when($0, ctx: ctx) }
        }
        if asks([" scam", " fake", " genuine", " real ", " trust", " safe "]) {
            return record.risk.rank >= 2 ? warning(record.risk.level)
                : "I didn't see any scam signs on it. Even so, never share your bank details just because a letter asks."
        }
        if asks([" phone", " ring ", " call ", " contact", " number for", " their number"]) {
            if record.risk.rank >= 2 {
                return "I'd rather not give you a number from this letter, because it might be a scam. If you're worried, call 159 to reach your bank safely."
            }
            let number = f.contact.phone.isEmpty ? (f.phoneNumbers.first?.value ?? "") : f.contact.phone
            return number.isEmpty ? "I didn't see a phone number on the letter."
                                  : "The number on the letter is \(digits(number))."
        }
        if asks([" how much", " owe", " pay", " amount", " cost", " money", " refund", " credit"]) {
            guard let money = f.money else { return "The letter doesn't mention any money." }
            var say: String
            if let owe = money.youOwe, owe > 0 {
                say = "It says you owe \(amount(owe, currency: money.currency))"
                say += deadlineWords.map { ", by \($0)." } ?? "."
            } else if let back = money.theyOweYou, back > 0 {
                say = "You don't owe anything. It says \(amount(back, currency: money.currency)) is coming back to you."
            } else if money.youOwe == 0 {
                say = "It says you don't owe anything."
            } else {
                say = f.summaryPlain.isEmpty ? "The letter doesn't say how much." : f.summaryPlain
            }
            return say
        }
        if asks([" when", " date", " deadline", " due", " how long", " by when"]) {
            guard let d = f.deadline, let words = deadlineWords else { return "The letter doesn't give a date to act by." }
            return d.what.isEmpty ? "The date to act by is \(words)." : "It says: \(bare(d.what)), by \(words)."
        }
        if asks([" who", " from", " sender", " sent"]) {
            return f.sender.name.isEmpty ? "The letter doesn't say clearly who it's from." : "It's from \(f.sender.name)."
        }
        if asks([" reference", " account number", " customer number"]) {
            guard let ref = f.referenceNumbers.first else { return "I didn't see a reference number on it." }
            return "The \(ref.label.isEmpty ? "reference" : ref.label.lowercased()) is \(digits(ref.value))."
        }
        if asks([" do i", " should i", " what do", " need to", " have to", " must i"]) {
            guard let first = f.actionsRequired.first else { return "It doesn't ask you to do anything." }
            return "It asks you to: \(sentence(first.action))"
        }
        return f.summaryPlain.isEmpty ? record.said : "Here's what it says. \(sentence(f.summaryPlain))"
    }
}

// MARK: - The reminder offer (Letter -> Planner hand-off, built in code)

struct LetterReminderOffer: Sendable, Equatable {
    var title: String
    var due: Date
    /// ISO 8601 with the UTC offset, as the planner's tools take it.
    var dueISO: String
    /// "Shall I remind you on Thursday the 29th, the day before it's due?"
    var spoken: String

    /// Remind the day before the deadline at 10 in the morning; if it's due tomorrow, tomorrow at 9.
    /// Nothing when the deadline is today or has passed.
    static func make(_ facts: LetterFacts, ctx: TurnContext) -> LetterReminderOffer? {
        guard let deadline = facts.deadline, let day = LetterWords.parseDay(deadline.date, ctx: ctx) else { return nil }
        let cal = ctx.calendar
        guard let days = cal.dateComponents([.day], from: cal.startOfDay(for: ctx.now), to: day).day, days >= 1 else {
            return nil
        }
        let remindDay = days == 1 ? day : (cal.date(byAdding: .day, value: -1, to: day) ?? day)
        guard let due = cal.date(bySettingHour: days == 1 ? 9 : 10, minute: 0, second: 0, of: remindDay) else { return nil }

        let spoken: String
        switch days {
        case 1: spoken = "Shall I remind you tomorrow morning?"
        case 2: spoken = "Shall I remind you tomorrow morning, the day before it's due?"
        default:
            let sameMonth = cal.component(.month, from: remindDay) == cal.component(.month, from: ctx.now) && days < 25
            spoken = "Shall I remind you on \(LetterWords.day(remindDay, ctx: ctx, withMonth: !sameMonth)), the day before it's due?"
        }

        let what = !deadline.what.isEmpty ? deadline.what : (facts.actionsRequired.first?.action ?? "Deal with the letter")
        let from = facts.sender.name
        let title = from.isEmpty || what.localizedCaseInsensitiveContains(from) ? what : "\(what) (\(from))"

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = ctx.timeZone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return LetterReminderOffer(title: String(title.prefix(100)), due: due, dueISO: f.string(from: due), spoken: spoken)
    }
}

// MARK: - The last letter, for follow-ups (RAM only, one hour)

struct LetterRecord: Sendable {
    var facts: LetterFacts
    var risk: LetterRisk
    /// What Kairos told the person.
    var said: String
    var language: LetterLanguage
    var dialect: String
    var readAt: Date
    var untrusted: String
}

final class LetterMemory: @unchecked Sendable {
    static let shared = LetterMemory()
    static let keepFor: TimeInterval = 3600

    private let lock = NSLock()
    private var last: LetterRecord?

    func save(_ record: LetterRecord) {
        lock.lock(); defer { lock.unlock() }
        last = record
    }

    /// The last letter if it was read within `age` seconds (and never one older than an hour).
    func latest(now: Date = Date(), within age: TimeInterval = LetterMemory.keepFor) -> LetterRecord? {
        lock.lock(); defer { lock.unlock() }
        guard let record = last else { return nil }
        let elapsed = now.timeIntervalSince(record.readAt)
        if elapsed > Self.keepFor { last = nil; return nil }
        return elapsed <= age ? record : nil
    }

    func forget() {
        lock.lock(); defer { lock.unlock() }
        last = nil
    }
}

// MARK: - Rules first (no model): "read my letter", and questions just after one was read

enum LetterMatch {
    private static func padded(_ s: String) -> String { " " + s.folded + " " }
    private static func has(_ w: String, _ terms: [String]) -> Bool { terms.contains { w.contains($0) } }

    static let documents = [" letter", " my bill", " this bill", " the bill", " a bill", " bill from", " water bill",
                            " gas bill", " electric bill", " electricity bill", " phone bill", " council tax", " form ",
                            " forms ", " document", " statement", " notice ", " envelope", " my post ", " the post "]

    /// "Read my letter", "can you look at this bill", "help me with a form".
    static func wantsReading(_ words: String, ctx: TurnContext) -> Bool {
        let w = padded(words)
        let verbs = [" read ", " look at ", " check ", " scan ", " photo ", " picture ", " explain ", " understand ",
                     " what does ", " help me with "]
        let actions = [" remind", " alarm", " call ", " ring ", " phone ", " text ", " message", " whatsapp", " email",
                       " send ", " pay ", " write ", " reply ", " post it "]
        guard has(w, documents), has(w, verbs), !has(w, actions) else { return false }
        // Just read one? "What does the letter mean" is about that letter, unless they say it's another one.
        if LetterMemory.shared.latest(now: ctx.now, within: LetterInterpreter.followUpWindow) != nil,
           !has(w, [" new ", " another ", " next ", " different ", " second ", " other "]) {
            return false
        }
        return true
    }

    /// A question about the letter read in the last ten minutes: "When do I have to pay?", "Who's it from?"
    static func questionAboutLetter(_ words: String, ctx: TurnContext) -> Bool {
        guard LetterMemory.shared.latest(now: ctx.now, within: LetterInterpreter.followUpWindow) != nil else { return false }
        let w = padded(words)
        let starters: Set<String> = ["what", "when", "how", "who", "why", "where", "which", "do", "does", "did", "is",
                                     "are", "can", "could", "should", "will", "would", "have", "has", "must", "am", "tell"]
        let first = w.split(separator: " ").first.map(String.init) ?? ""
        guard words.contains("?") || starters.contains(first) else { return false }
        let actions = [" remind", " alarm", " timer", " calendar", " diary", " call ", " ring ", " text ", " message",
                       " whatsapp", " email", " send ", " directions", " pay it for me ", " pay for me ", " pay it now ",
                       " pay now ", " new letter", " another letter", " next letter", " time is it ", " weather"]
        guard !has(w, actions) else { return false }
        let about = [" letter", " bill", " form ", " document", " owe ", " pay ", " paid ", " payment", " due ",
                     " deadline", " by when ", " how much ", " reference", " who sent ", " who is it from ",
                     " who s it from ", " what does it mean ", " what does that mean ", " what should i do ",
                     " what do i do ", " what do i need to do ", " can t pay ", " cannot pay ", " refund",
                     " appointment", " a scam ", " it real ", " it genuine ", " this real ", " this genuine "]
        return has(w, about)
    }
}

// MARK: - Photo size (llm.prepare_image)

/// Gemini bills about 1,100 tokens a photo whatever its size, but a 12-megapixel JPEG is slow to send on a phone
/// connection. Anything large, not a JPEG, or rotated by EXIF is redrawn upright at max side 1600, JPEG 0.7.
/// If ImageIO can't read it, the original bytes go as they are.
enum LetterPhoto {
    static let maxSide = 1600
    static let quality = 0.7
    static let largeBytes = 600_000

    static func prepared(_ data: Data) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            return data
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let orientation = (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let isJPEG = (CGImageSourceGetType(source) as String?) == "public.jpeg"
        let longest = max(width, height)
        if isJPEG, orientation == 1, data.count <= largeBytes, longest > 0, longest <= maxSide { return data }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longest > 0 ? min(maxSide, longest) : maxSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return data }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return data }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination), out.length > 0 else { return data }
        return out as Data
    }
}

// MARK: - Lenient JSON (llm._json_from_text, plus repair of a reply cut off at the token limit)

enum LetterJSON {
    /// The first JSON object in the model's reply: as is, inside ``` fences or prose, or cut off part-way.
    static func object(from reply: String) -> JSONValue? {
        var t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
            t = t.replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        }
        if let v = decodeObject(Array(t.utf8)) { return v }
        guard let start = t.firstIndex(of: "{") else { return nil }
        if let end = t.lastIndex(of: "}"), end > start, let v = decodeObject(Array(t[start...end].utf8)) { return v }
        return repaired(Array(t[start...].utf8))
    }

    private static func decodeObject(_ bytes: [UInt8]) -> JSONValue? {
        guard let v = JSONValue.decode(Data(bytes)), v.object != nil else { return nil }
        return v
    }

    /// Closes an unfinished string and the open brackets; if that isn't valid, cuts back to an earlier comma.
    static func repaired(_ b: [UInt8]) -> JSONValue? {
        let quote: UInt8 = 0x22, backslash: UInt8 = 0x5C, comma: UInt8 = 0x2C
        let openObject: UInt8 = 0x7B, closeObject: UInt8 = 0x7D, openArray: UInt8 = 0x5B, closeArray: UInt8 = 0x5D
        var stack: [UInt8] = []
        var inString = false, escaped = false
        var cuts: [(at: Int, stack: [UInt8])] = []
        for (i, c) in b.enumerated() {
            if inString {
                if escaped { escaped = false } else if c == backslash { escaped = true } else if c == quote { inString = false }
                continue
            }
            switch c {
            case quote: inString = true
            case openObject, openArray: stack.append(c)
            case closeObject, closeArray:
                if !stack.isEmpty { stack.removeLast() }
                if stack.isEmpty { return decodeObject(Array(b[...i])) }
            case comma: cuts.append((i, stack))
            default: break
            }
        }
        func closers(_ open: [UInt8]) -> [UInt8] { open.reversed().map { $0 == openObject ? closeObject : closeArray } }
        var tail = b
        if inString {
            if escaped { tail.removeLast() }
            tail.append(quote)
        }
        if let v = decodeObject(tail + closers(stack)) { return v }
        for cut in cuts.reversed().prefix(60) {
            if let v = decodeObject(Array(b[..<cut.at]) + closers(cut.stack)) { return v }
        }
        return nil
    }
}
