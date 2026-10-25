import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Calls and messages: finds the person's people in their own contacts, rings them, or opens Messages or WhatsApp
/// with the note ready. Kairos never dials or sends by itself: after the card and Face ID, iOS asks before a call
/// and the person taps Send. Who it goes to is always worked out by code from the contacts, never by the model.
struct PeopleAgent: SpecialistAgent {
    let id = "people"
    let title = "Calls and messages"
    let icon = "person.2.fill"

    var instructions: String {
        """
        Finds, phones and texts the person's own contacts. Pass the name or relation exactly as the person said it \
        ("Priya", "my daughter", "Dr Shah", "the GP"); code looks it up in their contacts, so never invent names or \
        numbers, and you don't need find_contact before calling or texting. call_contact rings someone (iOS then asks \
        them to tap Call). message_contact opens Messages, or WhatsApp if they ask for it, with the note ready; they \
        tap Send themselves. Write the note as they would send it: first person, their own words, nothing added. If \
        they haven't said what it should say, ask. Only put digits in "number" when the person said that number to \
        you themselves. When they tell you who someone is ("Priya is my daughter"), call remember_relation. For an \
        emergency, tell them to ring 999 themselves.
        """
    }

    var tools: [any KairosTool] { [FindContactTool(), CallContactTool(), MessageContactTool(), RememberRelationTool()] }
}

// MARK: - Tools

extension PeopleAgent {

    /// "Who is my daughter?", "Have I got Dr Shah's number?"
    struct FindContactTool: KairosTool {
        let name = "find_contact"
        let summary = "Look someone up in the person's contacts by name or relation (\"Priya\", \"my daughter\", \"Dr Shah\", \"the GP\"). Returns their name and which kinds of number they have (mobile, home, work) with the last 3 digits, never the whole number."
        var parameters: JSONValue {
            Schema.object([
                "name_or_relation": Schema.string("The name or relation exactly as the person said it, e.g. 'Priya', 'my son', 'the GP'."),
            ], required: ["name_or_relation"])
        }
        let risk = Risk.read

        func validate(_ args: JSONValue, ctx: TurnContext) -> Validation {
            args.text("name_or_relation") == nil ? .clarify("Who should I look for? Say their name, like 'my daughter Priya'.") : .ok
        }

        func describe(_ args: JSONValue, ctx: TurnContext) -> String {
            "Look up \(args.text("name_or_relation") ?? "a contact")"
        }

        func execute(_ args: JSONValue, ctx: TurnContext) async throws -> ToolResult {
            guard let said = args.text("name_or_relation") else {
                return .fail("Who should I look for? Say their name, like 'my daughter Priya'.")
            }
            var access = PeopleAccess.current
            if access == .notAsked, ctx.canShowUI {
                await PeopleAccess.request()
                access = PeopleAccess.current
            }
            guard access.canRead else { return await PeopleAgent.accessResult(access, ctx) }

            switch PeopleDirectory.shared.find(said) {
            case .none:
                return .fail(PeopleAgent.notFound(said, access))
            case .one(let card, let close):
                let intro = close ? "The closest I found is \(card.displayName)" : "I found \(card.displayName)"
                var say = card.phones.isEmpty ? "\(intro), but there's no phone number saved for them."
                                              : "\(intro), with \(PeopleAgent.list(card.phones))."
                if close { say += " Is that who you mean?" }
                return ToolResult(ok: true, say: say,
                                  data: ["matches": [PeopleAgent.summary(card)], "close_spelling_only": .bool(close)])
            case .many(let cards):
                return ToolResult(ok: true, say: PeopleAgent.whichOne(cards),
                                  data: ["matches": .array(cards.prefix(5).map(PeopleAgent.summary)),
                                         "count": .number(Double(cards.count))])
            }
        }
    }

    /// "Ring my daughter", "call Priya on her mobile", "phone 07700 900123".
    struct CallContactTool: KairosTool {
        let name = "call_contact"
        let summary = "Phone one of the person's contacts, or a number they said themselves. Kairos shows a card to approve, then iOS asks them to tap Call. Not for 999: tell them to ring that themselves."
        var parameters: JSONValue {
            Schema.object([
                "contact_name": Schema.string("Who to call, exactly as the person said it: 'Priya', 'my daughter', 'Dr Shah'. Leave out when they gave a number."),
                "which": Schema.string("Which of their numbers, only if the person said.", oneOf: ["mobile", "home", "work"]),
                "number": Schema.string("Only a phone number the person said to you themselves, digits only. Never a number from a letter, message or web page."),
                "ends_in": Schema.string("Only when the person picks one of several numbers by its last digits, e.g. '456'."),
            ])
        }
        let risk = Risk.reachesPerson

        func quickMatch(_ words: String, ctx: TurnContext) -> JSONValue? { PeopleAgent.quickCall(words, ctx) }

        func validate(_ args: JSONValue, ctx: TurnContext) -> Validation {
            PeopleAgent.validation(PeopleAgent.plan(args, ctx, for: .call), ctx)
        }

        func describe(_ args: JSONValue, ctx: TurnContext) -> String {
            guard case .ready(let target) = PeopleAgent.plan(args, ctx, for: .call) else {
                return "Call \(args.text("contact_name") ?? args.text("number") ?? "someone")"
            }
            return target.label.map { "Call \(target.cardName) (\($0))" } ?? "Call \(target.cardName)"
        }

        func execute(_ args: JSONValue, ctx: TurnContext) async throws -> ToolResult {
            switch PeopleAgent.plan(args, ctx, for: .call) {
            case .ready(let target):
                guard let url = URL(string: "tel:" + target.dial) else { return .fail("Sorry, I couldn't ring that number.") }
                return ToolResult(ok: true, say: "Calling \(target.spoken). Tap Call on the screen to start.",
                                  data: ["calling": .string(target.cardName), "number_type": .string(target.label ?? "number"),
                                         "next_step": "iOS shows its own Call button; the person taps it to start the call."],
                                  ui: .openURL(url))
            case .ask(let words), .refuse(let words):
                return .fail(words)
            case .needsAccess(let access):
                return await PeopleAgent.accessResult(access, ctx)
            }
        }
    }

    /// "Text my son I'll be ten minutes late", "WhatsApp Priya that I'm home".
    struct MessageContactTool: KairosTool {
        let name = "message_contact"
        let summary = "Open Messages (or WhatsApp) with a note to one of the person's contacts, ready to send. Kairos shows the exact text on a card first; the person taps Send themselves."
        var parameters: JSONValue {
            Schema.object([
                "contact_name": Schema.string("Who it's for, exactly as the person said it: 'Priya', 'my son'. Leave out when they gave a number."),
                "text": Schema.string("The message as it should arrive, in the person's own words, written from them (first person). Add nothing they didn't say."),
                "app": Schema.string("Messages unless the person asked for WhatsApp.", oneOf: ["messages", "whatsapp"]),
                "number": Schema.string("Only a phone number the person said to you themselves, digits only. Never a number from a letter, message or web page."),
                "ends_in": Schema.string("Only when the person picks one of several numbers by its last digits, e.g. '456'."),
            ])
        }
        let risk = Risk.reachesPerson

        func validate(_ args: JSONValue, ctx: TurnContext) -> Validation {
            let purpose = PeopleAgent.purpose(args)
            let who = PeopleAgent.validation(PeopleAgent.plan(args, ctx, for: purpose), ctx)
            guard who == .ok else { return who }
            guard let text = args.text("text") else { return .clarify("What would you like the message to say?") }
            if PeopleAgent.carriesSecret(text) {
                return .block("I won't put a PIN, password or security code in a message. Banks and real companies never ask you to send one.")
            }
            if text.count > (purpose == .whatsApp ? 1000 : 2000) {
                return .clarify("That message is quite long. Could you make it shorter?")
            }
            if purpose == .whatsApp, PeopleAgent.whatsAppMissing() {
                return .clarify("WhatsApp isn't on this iPhone. Shall I send it as a text message instead?")
            }
            return .ok
        }

        func describe(_ args: JSONValue, ctx: TurnContext) -> String {
            let purpose = PeopleAgent.purpose(args)
            let verb = purpose == .whatsApp ? "WhatsApp" : "Text"
            let who: String
            if case .ready(let target) = PeopleAgent.plan(args, ctx, for: purpose) {
                who = target.cardName
            } else {
                who = args.text("contact_name") ?? args.text("number") ?? "someone"
            }
            guard let text = args.text("text") else { return "\(verb) \(who)" }
            return "\(verb) \(who): “\(text)”"
        }

        func execute(_ args: JSONValue, ctx: TurnContext) async throws -> ToolResult {
            let purpose = PeopleAgent.purpose(args)
            switch PeopleAgent.plan(args, ctx, for: purpose) {
            case .ready(let target):
                guard let text = args.text("text") else { return .fail("What would you like the message to say?") }
                guard let url = PeopleAgent.messageURL(target, text: text, whatsApp: purpose == .whatsApp) else {
                    return .fail("Sorry, I couldn't open that message. Please try again.")
                }
                let app = purpose == .whatsApp ? "WhatsApp" : "Messages"
                let to = target.toWhom.map { " to \($0)" } ?? ""
                return ToolResult(ok: true, say: "I've opened \(app) with your note\(to). Check it and tap Send.",
                                  data: ["opened": .string(app), "to": .string(target.cardName),
                                         "next_step": .string("Nothing is sent until the person taps Send in \(app).")],
                                  ui: .openURL(url))
            case .ask(let words), .refuse(let words):
                return .fail(words)
            case .needsAccess(let access):
                return await PeopleAgent.accessResult(access, ctx)
            }
        }
    }

    /// "Priya is my daughter", so "call my daughter" works from then on.
    struct RememberRelationTool: KairosTool {
        let name = "remember_relation"
        let summary = "Remember who one of the person's contacts is to them, when the person tells you (\"Priya is my daughter\", \"Dr Shah is my GP\"), so 'call my daughter' works next time. Kept only on this phone."
        var parameters: JSONValue {
            Schema.object([
                "relation": Schema.string("Who they are to the person, in the person's words: 'daughter', 'son', 'GP', 'neighbour'."),
                "contact_name": Schema.string("Their name as the person said it: 'Priya'."),
            ], required: ["relation", "contact_name"])
        }
        let risk = Risk.localWrite

        func quickMatch(_ words: String, ctx: TurnContext) -> JSONValue? { PeopleAgent.quickTeach(words, ctx) }

        func validate(_ args: JSONValue, ctx: TurnContext) -> Validation {
            guard let relation = args.text("relation"), let name = args.text("contact_name") else {
                return .clarify("Who is it? Say it like 'Priya is my daughter'.")
            }
            if relation.digitsOnly.count >= 3 || relation.contains("@") || PeopleDirectory.queryTokens(relation).isEmpty {
                return .block("I can only remember who someone is to you, like 'my daughter' or 'my GP'.")
            }
            // Names come from the person, never from a letter or a message.
            guard PeopleAgent.nameWasSaid(name, ctx) else { return .block("I'll only remember that if you tell me yourself.") }
            let access = PeopleAccess.current
            guard access.canRead else { return PeopleAgent.accessValidation(access, ctx) }
            switch PeopleDirectory.shared.findByName(name) {
            case .one(let card, let close): return close ? .clarify("Did you mean \(card.displayName)?") : .ok
            case .many(let cards): return .clarify(PeopleAgent.whichOne(cards))
            case .none: return .clarify(PeopleAgent.notFound(name, access))
            }
        }

        func describe(_ args: JSONValue, ctx: TurnContext) -> String {
            let relation = PeopleAgent.relationText(args.text("relation") ?? "")
            return "Remember \(args.text("contact_name") ?? "them") is your \(relation)"
        }

        func execute(_ args: JSONValue, ctx: TurnContext) async throws -> ToolResult {
            guard let relation = args.text("relation"), let name = args.text("contact_name"),
                  case .one(let card, close: false) = PeopleDirectory.shared.findByName(name) else {
                return .fail("Sorry, I couldn't work out who you mean. Please say their full name.")
            }
            PeopleDirectory.shared.teach(relation, card)
            let words = PeopleAgent.relationText(relation)
            return ToolResult(ok: true, say: "Got it. I'll remember that \(card.displayName) is your \(words).",
                              data: ["remembered": .string("\(card.displayName) is the person's \(words)")])
        }
    }
}

// MARK: - Working out who and which number

extension PeopleAgent {

    enum Purpose: Equatable, Sendable {
        case call, text, whatsApp
        var isCall: Bool { self == .call }
    }

    /// Who a call or message goes to, as code worked it out.
    struct Target: Sendable {
        /// On the card: "Priya Shah", "07700 900123", "NHS 111".
        var cardName: String
        /// Spoken: "Priya's mobile", "that number", "NHS 111".
        var spoken: String
        /// "Priya", for "your note to Priya"; nil for a bare number.
        var toWhom: String?
        /// What iOS dials: "+447700900123", "159".
        var dial: String
        var e164: String?
        /// "mobile", "home", "work" for the card; nil when the card doesn't say.
        var label: String?
    }

    enum Plan: Sendable {
        case ready(Target)
        case ask(String)       // one short question
        case refuse(String)    // can't be done this way; plain words why
        case needsAccess(PeopleAccess)
    }

    static func purpose(_ args: JSONValue) -> Purpose {
        let app = (args["app"]?.string ?? "").folded.replacingOccurrences(of: " ", with: "")
        return app.contains("whatsapp") ? .whatsApp : .text
    }

    /// The single place that decides who and which number. validate, describe and execute all use it, so the card
    /// always shows what will really be dialled or opened.
    static func plan(_ args: JSONValue, _ ctx: TurnContext, for purpose: Purpose) -> Plan {
        var number = args.text("number")
        var name = args.text("contact_name")
        if number == nil, let given = name, looksLikeNumber(given) { number = given; name = nil }
        if let number { return planNumber(number, ctx, purpose) }
        guard let name else {
            return .ask(purpose.isCall ? "Who should I call? Say their name, like 'my daughter Priya'."
                                       : "Who should I send it to? Say their name, like 'my daughter Priya'.")
        }
        let phrase = PeopleDirectory.queryTokens(name).joined(separator: " ")
        if emergencyPhrases.contains(phrase) { return .refuse(emergencyAdvice) }
        if let service = Service.named(phrase) {
            return purpose.isCall ? .ready(service.target) : .refuse("I can only ring \(service.title) for you, not send it a message.")
        }
        let access = PeopleAccess.current
        guard access.canRead else { return .needsAccess(access) }

        let ending = args.text("ends_in").map(\.digitsOnly).flatMap { $0.isEmpty ? nil : $0 }
        var lookup = PeopleDirectory.shared.find(name)
        if let ending, case .many(let cards) = lookup {
            // "The one ending 456": two cards with the same name, told apart by the person.
            let hits = cards.filter { $0.phones.contains { $0.dial.hasSuffix(ending) } }
            if hits.count == 1 { lookup = .one(hits[0], close: false) } else if !hits.isEmpty { lookup = .many(hits) }
        }
        switch lookup {
        case .none:
            if phrase.split(separator: " ").contains("police") { return .ask(policeAdvice) }
            return .ask(notFound(name, access))
        case .many(let cards):
            return .ask(whichOne(cards))
        case .one(let card, let close):
            if close { return .ask("Did you mean \(card.displayName)?") }
            let wanted = kind(args["which"]?.string) ?? PeopleDirectory.kindNamed(in: name)
            return choosePhone(card, wanted, ending, purpose)
        }
    }

    private static func planNumber(_ raw: String, _ ctx: TurnContext, _ purpose: Purpose) -> Plan {
        let digits = PeopleDirectory.asciiDigits(raw)
        if emergencyNumbers.contains(digits) { return .refuse(emergencyAdvice) }
        if let service = Service.numbered(digits) {
            return purpose.isCall ? .ready(service.target) : .refuse("I can only ring \(service.title) for you, not send it a message.")
        }
        // The SafetyGate also refuses numbers that only a letter or message contained; this checks the person said it.
        guard numberWasSaid(raw, ctx) else {
            return .refuse("I'll only use a phone number you tell me yourself. Please say the number to me.")
        }
        let e164 = PeopleDirectory.normalise(raw)
        let dial = e164 ?? PeopleDirectory.dialable(raw)
        guard dial.digitsOnly.count >= (purpose.isCall ? 3 : 5) else {
            return .ask("That number seems too short. Could you say it again, slowly?")
        }
        if purpose == .whatsApp, e164 == nil {
            return .ask("For WhatsApp I need the number with its country code, like +44. Could you say it that way?")
        }
        return .ready(Target(cardName: PeopleDirectory.shown(dial), spoken: "that number", toWhom: nil,
                             dial: dial, e164: e164, label: nil))
    }

    private static func choosePhone(_ card: PeopleDirectory.Card, _ wanted: PeopleDirectory.Phone.Kind?, _ ending: String?,
                                    _ purpose: Purpose) -> Plan {
        let name = card.displayName
        var phones = card.phones
        guard !phones.isEmpty else { return .refuse("I found \(name), but there's no phone number saved for them.") }
        if let ending {
            let hits = phones.filter { $0.dial.hasSuffix(ending) }
            if !hits.isEmpty { phones = hits }
        }
        let pick: PeopleDirectory.Phone
        if let wanted {
            guard let found = phones.first(where: { $0.kind == wanted })
                    ?? (wanted == .mobile ? phones.first(where: { $0.looksMobile }) : nil) else {
                return .ask("I don't have a \(word(wanted)) for \(name), only \(list(phones)). Which should I use?")
            }
            pick = found
        } else if purpose.isCall {
            // One number: that one. Several: the mobile, which is shown on the card so they can say no.
            guard let found = phones.count == 1 ? phones[0] : phones.first(where: { $0.kind == .mobile }) else {
                return .ask("\(name) has \(list(phones)). Which one should I ring?")
            }
            pick = found
        } else {
            guard let found = phones.first(where: { $0.kind == .mobile }) ?? phones.first(where: { $0.looksMobile })
                    ?? (phones.count == 1 && phones[0].kind == .other ? phones[0] : nil) else {
                return .refuse("I only have \(list(phones)) for \(name), and messages need a mobile number.")
            }
            pick = found
        }
        if purpose == .whatsApp, pick.e164 == nil {
            return .refuse("To use WhatsApp I need \(name)'s number with its country code, like +44. You can add it in Contacts.")
        }
        return .ready(Target(cardName: name, spoken: possessive(card.spokenName) + " " + pick.spoken,
                             toWhom: card.spokenName, dial: pick.dial, e164: pick.e164,
                             label: pick.kind == .other ? nil : pick.kind.rawValue))
    }

    static func validation(_ plan: Plan, _ ctx: TurnContext) -> Validation {
        switch plan {
        case .ready: return .ok
        case .ask(let question): return .clarify(question)
        case .refuse(let reason): return .block(reason)
        case .needsAccess(let access): return accessValidation(access, ctx)
        }
    }

    // MARK: Numbers the person said

    static func looksLikeNumber(_ s: String) -> Bool {
        !s.unicodeScalars.contains(where: CharacterSet.letters.contains) && PeopleDirectory.asciiDigits(s).count >= 3
    }

    /// True when these digits appear in what the person said or typed (not in a letter or a message).
    static func numberWasSaid(_ raw: String, _ ctx: TurnContext) -> Bool {
        let target = PeopleDirectory.asciiDigits(raw)
        guard target.count >= 3 else { return false }
        let wanted = PeopleDirectory.normalise(raw)
        for run in SafetyGate.digitRuns(ctx.userWords) {
            if run == target { return true }
            if let wanted, PeopleDirectory.normalise(run) == wanted { return true }
        }
        // Speech recognition can space spoken digits oddly: "0 7 7 0 0, 9 0 0 …".
        return target.count >= 7 && PeopleDirectory.asciiDigits(ctx.userWords).contains(target)
    }

    static func nameWasSaid(_ name: String, _ ctx: TurnContext) -> Bool {
        let said = Set(PeopleDirectory.tokens(ctx.userWords))
        return PeopleDirectory.tokens(name).contains { $0.count >= 2 && said.contains($0) }
    }

    // MARK: Emergencies and public helplines

    static let emergencyNumbers: Set<String> = ["999", "112", "911"]
    static let emergencyPhrases: Set<String> = ["999", "112", "911", "emergency", "emergency services", "ambulance",
                                                "fire brigade", "fire service", "coastguard"]
    static let emergencyAdvice = "For an emergency, please ring 999 yourself straight away. Open the Phone app, tap Keypad, press 9 9 9, then the green button."
    static let policeAdvice = "If it's an emergency, please ring 999 yourself straight away. If it isn't urgent, shall I ring 101, the police non-emergency number?"

    /// Fixed UK public numbers, safe to ring whoever suggested them (the scam helper offers 159).
    struct Service: Sendable {
        var number: String
        var title: String
        var names: Set<String>

        var target: Target { Target(cardName: title, spoken: title, toWhom: title, dial: number, e164: nil, label: nil) }

        static let all: [Service] = [
            Service(number: "159", title: "159, the bank scam line",
                    names: ["159", "stop scams", "stop scams uk", "scam line", "scams line", "bank scam line", "fraud line", "bank fraud line"]),
            Service(number: "111", title: "NHS 111", names: ["111", "nhs 111", "nhs", "nhs helpline", "nhs one one one"]),
            Service(number: "101", title: "101, the police non-emergency number",
                    names: ["101", "police non emergency", "non emergency police", "police non emergency line"]),
            Service(number: "105", title: "105, the power cut line", names: ["105", "power cut", "power cut line"]),
        ]

        static func named(_ phrase: String) -> Service? { PeopleDirectory.isUK ? all.first { $0.names.contains(phrase) } : nil }
        static func numbered(_ digits: String) -> Service? { PeopleDirectory.isUK ? all.first { $0.number == digits } : nil }
    }

    // MARK: Messages

    /// "my PIN is 4821", "the code is 482913": what scammers ask people to text. Never sent through Kairos.
    static func carriesSecret(_ text: String) -> Bool {
        let t = " " + text.folded + " "
        let secrets = ["pin", "passcode", "password", "otp", "code", "cvv", "cvc", "card number"]
        guard secrets.contains(where: { t.contains(" \($0) ") }) else { return false }
        return SafetyGate.digitRuns(text).contains { (4...8).contains($0.count) }
    }

    private static let urlSafe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    /// Messages: "sms:+447700900123&body=…" (the iOS form). WhatsApp: "https://wa.me/447700900123?text=…".
    static func messageURL(_ target: Target, text: String, whatsApp: Bool) -> URL? {
        guard let body = text.addingPercentEncoding(withAllowedCharacters: urlSafe) else { return nil }
        if whatsApp {
            guard let e164 = target.e164 else { return nil }
            return URL(string: "https://wa.me/\(e164.digitsOnly)?text=\(body)")
        }
        return URL(string: "sms:\(target.dial)&body=\(body)")
    }

    /// Only answers when the integrator listed "whatsapp" in LSApplicationQueriesSchemes; otherwise assumes it's there.
    static func whatsAppMissing() -> Bool {
        #if canImport(UIKit)
        let declared = (Bundle.main.object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String])?.contains("whatsapp") == true
        guard declared, Thread.isMainThread, let probe = URL(string: "whatsapp://") else { return false }
        return MainActor.assumeIsolated { !UIApplication.shared.canOpenURL(probe) }
        #else
        return false
        #endif
    }

    // MARK: Contacts permission

    static let openKairosFirst = "Please open Kairos once, so I can ask to see your contacts."
    static let askingNow = "First I need to see your contacts. When your phone asks, let Kairos see them, then ask me again."
    static let deniedOpened = "I'm not allowed to see your contacts yet. I've opened Settings for you: tap Contacts, then choose Full Access."
    static let deniedSteps = "I'm not allowed to see your contacts yet. Open Settings, tap Apps, then Kairos, then Contacts, and choose Full Access."

    /// validate() can't return a screen to open, so it starts the prompt or opens Settings itself (only when Kairos
    /// is on screen) and says what to do.
    static func accessValidation(_ access: PeopleAccess, _ ctx: TurnContext) -> Validation {
        if access == .notAsked {
            guard ctx.canShowUI else { return .clarify(openKairosFirst) }
            Task { await PeopleAccess.request() }
            return .clarify(askingNow)
        }
        guard ctx.canShowUI else { return .block(deniedSteps) }
        openSettings()
        return .block(deniedOpened)
    }

    static func accessResult(_ access: PeopleAccess, _ ctx: TurnContext) async -> ToolResult {
        if access == .notAsked { return .fail(ctx.canShowUI ? askingNow : openKairosFirst) }
        guard ctx.canShowUI, let settings = await settingsRequest() else { return .fail(deniedSteps) }
        var result = ToolResult.fail(deniedOpened)
        result.ui = settings
        return result
    }

    static func settingsRequest() async -> UIRequest? {
        #if canImport(UIKit)
        let link = await MainActor.run { UIApplication.openSettingsURLString }
        return URL(string: link).map { .openURL($0) }
        #else
        return nil
        #endif
    }

    static func openSettings() {
        #if canImport(UIKit)
        Task { @MainActor in
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
        #endif
    }

    // MARK: Plain words

    static func kind(_ s: String?) -> PeopleDirectory.Phone.Kind? {
        switch s?.folded {
        case "mobile", "cell", "iphone": return .mobile
        case "home", "landline": return .home
        case "work", "office": return .work
        default: return nil
        }
    }

    static func word(_ kind: PeopleDirectory.Phone.Kind) -> String {
        switch kind {
        case .mobile: return "mobile number"
        case .home: return "home number"
        case .work: return "work number"
        case .other: return "other number"
        }
    }

    /// "a mobile and a home number", "2 mobile numbers".
    static func list(_ phones: [PeopleDirectory.Phone]) -> String {
        var counts: [(PeopleDirectory.Phone.Kind, Int)] = []
        for phone in phones {
            if let i = counts.firstIndex(where: { $0.0 == phone.kind }) { counts[i].1 += 1 } else { counts.append((phone.kind, 1)) }
        }
        let parts = counts.map { kind, n -> String in
            if n > 1 { return "\(n) \(word(kind))s" }
            switch kind {
            case .mobile: return "a mobile"
            case .home: return "a home number"
            case .work: return "a work number"
            case .other: return counts.count == 1 ? "one number" : "another number"
            }
        }
        return joined(parts)
    }

    static func joined(_ items: [String], _ last: String = "and") -> String {
        guard let final = items.last, items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " \(last) " + final
    }

    static func possessive(_ name: String) -> String { name + "'s" }

    /// "I found Priya Shah and Priya Rao. Which one?"
    static func whichOne(_ cards: [PeopleDirectory.Card]) -> String {
        let names = cards.map(\.displayName)
        if Set(names).count == 1, names.count > 1 {
            let endings = cards.compactMap { $0.phones.first?.endsIn }
            if endings.count == cards.count, Set(endings).count == endings.count {
                let spaced = endings.map { $0.map(String.init).joined(separator: " ") }
                return "You have \(cards.count) contacts called \(names[0]). Which one: the number ending in \(joined(spaced, "or"))?"
            }
        }
        if names.count > 3 {
            return "I found \(names.prefix(3).joined(separator: ", ")) and \(names.count - 3) more. Which one? You can say their full name."
        }
        return "I found \(joined(names)). Which one?"
    }

    static func notFound(_ said: String, _ access: PeopleAccess) -> String {
        let tokens = PeopleDirectory.queryTokens(said)
        if !tokens.isEmpty, tokens.allSatisfy({ PeopleDirectory.relationWords[$0] != nil }) {
            let relation = relationText(tokens.joined(separator: " "))
            return "I don't know who your \(relation) is yet. Tell me, like 'Priya is my \(relation)'."
        }
        var who = said.trimmingCharacters(in: .whitespacesAndNewlines)
        if who.lowercased().hasPrefix("my ") { who = "your " + who.dropFirst(3) }
        if access == .limited {
            return "I can't find \(who) in the contacts I'm allowed to see. To let me see them all, open Settings, tap Apps, then Kairos, then Contacts, and choose Full Access."
        }
        return "I can't find \(who) in your contacts. Could you say the name as it's saved in your phone?"
    }

    /// "my GP" -> "GP", "daughter" -> "daughter".
    static func relationText(_ relation: String) -> String {
        var words = relation.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
        while words.count > 1, let first = words.first, ["my", "the", "our", "your"].contains(first.lowercased()) { words.removeFirst() }
        return words.map { $0.lowercased() == "gp" ? "GP" : $0 }.joined(separator: " ")
    }

    static func summary(_ card: PeopleDirectory.Card) -> JSONValue {
        ["name": .string(card.displayName),
         "numbers": .array(card.phones.map { ["type": .string($0.kind.rawValue), "ends_in": .string($0.endsIn)] })]
    }

    // MARK: Fast paths (no model)

    /// "call Priya", "ring my daughter", "phone the GP", "call 07700 900123". Only when contacts access is already
    /// granted (never prompts) and code is sure who and which number; anything else goes to the model.
    static func quickCall(_ words: String, _ ctx: TurnContext) -> JSONValue? {
        guard let args = callParts(words) else { return nil }
        switch plan(args, ctx, for: .call) {
        case .ready, .refuse: return args   // .refuse: "call 999" gets the advice at once, offline
        case .ask, .needsAccess: return nil
        }
    }

    /// The words after "call" / "ring" / "phone", as call_contact arguments. Parsing only.
    static func callParts(_ words: String) -> JSONValue? {
        let t = PeopleDirectory.tokens(words)
        guard t.count <= 12, Set(t).isDisjoint(with: ["whatsapp", "facetime", "video"]) else { return nil }
        let lead: Set<String> = ["please", "can", "could", "would", "will", "you", "kairos", "hey", "hi", "ok", "okay", "just",
                                 "i", "want", "wanna", "to", "d", "like", "need", "go", "ahead", "and", "now", "yes", "right"]
        let verbs: Set<String> = ["call", "ring", "phone", "dial"]
        guard let v = t.firstIndex(where: verbs.contains), v <= 6, t[..<v].allSatisfy(lead.contains) else { return nil }
        var rest = Array(t[(v + 1)...])
        let edge: Set<String> = ["please", "now", "for", "me", "thanks", "thank", "you", "up", "straight", "away", "right",
                                 "kairos", "quickly"]
        while rest.first == "up" { rest.removeFirst() }
        while let last = rest.last, edge.contains(last) { rest.removeLast() }
        guard !rest.isEmpty, rest.count <= 5 else { return nil }

        if rest.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return ["number": .string(rest.joined())] }
        guard t[v] != "dial" else { return nil }
        return ["contact_name": .string(rest.joined(separator: " "))]
    }

    /// "Priya is my daughter", "my GP is Dr Shah". Only when the name is exactly one contact.
    static func quickTeach(_ words: String, _ ctx: TurnContext) -> JSONValue? {
        guard let parts = teachParts(words), PeopleAccess.current.canRead,
              case .one(_, close: false) = PeopleDirectory.shared.findByName(parts.name) else { return nil }
        return ["relation": .string(parts.relation), "contact_name": .string(parts.name)]
    }

    /// "Priya is my daughter" -> (name: "priya", relation: "daughter"). Parsing only.
    static func teachParts(_ words: String) -> (name: String, relation: String)? {
        var t = PeopleDirectory.tokens(words)
        while let first = t.first, ["kairos", "remember", "that", "please", "note", "ok", "okay", "so"].contains(first) { t.removeFirst() }
        guard (3...8).contains(t.count), let i = t.firstIndex(of: "is") else { return nil }
        var name: [String]
        var relation: [String]
        if i > 0, i + 2 < t.count, t[i + 1] == "my" {   // "Priya is my daughter"
            name = Array(t[..<i])
            relation = Array(t[(i + 2)...])
        } else if t.first == "my", i > 1, i + 1 < t.count {  // "my daughter is Priya", "my daughter's name is Priya"
            relation = Array(t[1..<i])
            name = Array(t[(i + 1)...])
            while let first = name.first, ["called", "named"].contains(first) { name.removeFirst() }
        } else {
            return nil
        }
        relation.removeAll { ["s", "name"].contains($0) }
        guard (1...3).contains(name.count), (1...3).contains(relation.count), !name.contains("my"),
              relation.contains(where: { PeopleDirectory.relationWords[$0] != nil }) else { return nil }
        return (name.joined(separator: " "), relation.joined(separator: " "))
    }
}
