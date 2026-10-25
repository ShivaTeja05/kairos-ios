import Foundation

// Know-how the Phone operator uses without asking the model: which app is which, what it must never tap or type,
// what the goal means, and step-by-step procedures for apps it knows (WhatsApp, ported from
// phone-control/ios-app-agent/skills/whatsapp). A known task runs with zero model calls; the model only steps in
// when a screen isn't what the procedure expects.

// MARK: - Apps

enum OperatorAppCatalog {
    /// Folded app name → bundle id. Quicker and surer than an App Store lookup for the usual ones.
    static let known: [String: String] = [
        "whatsapp": "net.whatsapp.WhatsApp", "whats app": "net.whatsapp.WhatsApp",
        "whatsapp business": "net.whatsapp.WhatsAppSMB",
        "messages": "com.apple.MobileSMS", "message": "com.apple.MobileSMS", "imessage": "com.apple.MobileSMS",
        "texts": "com.apple.MobileSMS", "sms": "com.apple.MobileSMS",
        "phone": "com.apple.mobilephone", "facetime": "com.apple.facetime",
        "settings": "com.apple.Preferences", "safari": "com.apple.mobilesafari", "browser": "com.apple.mobilesafari",
        "photos": "com.apple.mobileslideshow", "camera": "com.apple.camera", "contacts": "com.apple.MobileAddressBook",
        "mail": "com.apple.mobilemail", "email": "com.apple.mobilemail", "calendar": "com.apple.mobilecal",
        "reminders": "com.apple.reminders", "notes": "com.apple.mobilenotes", "clock": "com.apple.mobiletimer",
        "alarm": "com.apple.mobiletimer", "alarms": "com.apple.mobiletimer", "maps": "com.apple.Maps",
        "apple maps": "com.apple.Maps", "music": "com.apple.Music", "files": "com.apple.DocumentsApp",
        "shortcuts": "com.apple.shortcuts", "app store": "com.apple.AppStore", "weather": "com.apple.weather",
        "health": "com.apple.Health", "calculator": "com.apple.calculator", "podcasts": "com.apple.podcasts",
        "youtube": "com.google.ios.youtube", "gmail": "com.google.Gmail", "google maps": "com.google.Maps",
        "google": "com.google.GoogleMobile", "chrome": "com.google.chrome.ios",
        "telegram": "ph.telegra.Telegraph", "signal": "org.whispersystems.signal",
        "trainline": "com.thetrainline.trainline", "national rail": "uk.co.nationalrail.nre",
        "uber": "com.ubercab.UberClient",
        "instagram": "com.burbn.instagram", "insta": "com.burbn.instagram", "facebook": "com.facebook.Facebook",
        "x": "com.atebits.Tweetie2", "twitter": "com.atebits.Tweetie2", "google drive": "com.google.Drive",
        "drive": "com.google.Drive", "google photos": "com.google.photos",
    ]
    static let displayNames: [String: String] = [
        "net.whatsapp.WhatsApp": "WhatsApp", "net.whatsapp.WhatsAppSMB": "WhatsApp Business",
        "com.apple.MobileSMS": "Messages", "com.apple.mobilephone": "Phone", "com.apple.Preferences": "Settings",
        "com.apple.mobilesafari": "Safari", "com.apple.mobileslideshow": "Photos", "com.apple.mobilemail": "Mail",
        "com.apple.mobilecal": "Calendar", "com.apple.reminders": "Reminders", "com.apple.mobilenotes": "Notes",
        "com.apple.mobiletimer": "Clock", "com.apple.Maps": "Maps", "com.apple.weather": "Weather",
        "com.apple.springboard": "the Home Screen",
        "com.burbn.instagram": "Instagram", "com.facebook.Facebook": "Facebook", "com.atebits.Tweetie2": "X",
        "com.google.Drive": "Google Drive", "com.google.photos": "Google Photos",
    ]
    /// Apps where Return or a tap can reach another person.
    static let messagingBundles: Set<String> = ["net.whatsapp.WhatsApp", "net.whatsapp.WhatsAppSMB", "com.apple.MobileSMS",
                                                "com.apple.mobilemail", "ph.telegra.Telegraph", "org.whispersystems.signal",
                                                "com.google.Gmail", "com.facebook.Messenger"]
    static let cacheKey = "kairos.operator.bundleCache"

    static func knownBundle(_ name: String) -> String? {
        let key = name.folded
        if let b = known[key] { return b }
        // "the WhatsApp app", "open whatsapp please"
        let stripped = key.replacingOccurrences(of: "the ", with: "").replacingOccurrences(of: " app", with: "")
        if let b = known[stripped] { return b }
        // Already a bundle id.
        if name.contains("."), !name.contains(" "), name.split(separator: ".").count >= 3 { return name }
        return nil
    }

    static func cached(_ name: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String])?[name.folded]
    }

    static func remember(_ name: String, bundle: String) {
        var map = (UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String]) ?? [:]
        map[name.folded] = bundle
        if map.count > 80 { map = Dictionary(uniqueKeysWithValues: map.prefix(80).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(map, forKey: cacheKey)
    }

    static func displayName(_ bundle: String, fallback: String = "") -> String {
        if let n = displayNames[bundle] { return n }
        if !fallback.isEmpty { return fallback }
        return bundle.split(separator: ".").last.map(String.init) ?? "the app"
    }

    private static let money = try! NSRegularExpression(pattern:
        #"bank|monzo|revolut|starling|barclays|hsbc|lloyds|natwest|santander|nationwide|halifax|paypal|\bwise\b|venmo|"#
        + #"cash ?app|coinbase|binance|kraken|crypto|wallet|phonepe|paytm|gpay|google pay|apple pay|\bamex\b|"#
        + #"american express|trading|invest|stocks|chase|capital one|klarna|bhim|\bupi\b|"#
        // UK banks and money apps, and the remittance apps families use to send money home.
        + #"\btsb\b|first ?direct|virgin ?money|transferwise|\bcurve\b|zopa|\bkroo\b|monese|\btide\b|\bn26\b|bunq|"#
        + #"western ?union|remitly|world ?remit|\bxoom\b|skrill|paysend|moneygram|icici|hdfc|\bsbi\b|\byono\b|kotak|"#
        + #"payzapp|\bcred\b|amazon ?pay|samsung ?pay|clearpay|laybuy|zilch|moneybox|freetrade|etoro|robinhood|"#
        + #"vanguard|hargreaves|nutmeg"#, options: [.caseInsensitive])

    /// Money apps NAMED in free words (a goal), whole words only: "Bankole", "I'm at the bank", "my wallet" or
    /// "chase the plumber" are not apps. The app argument and bundle ids still go through isMoneyApp.
    private static let moneyNamed = try! NSRegularExpression(pattern:
        #"\b(monzo|revolut|starling|barclays|hsbc|lloyds|natwest|santander|nationwide|halifax|paypal|venmo|cash ?app|"#
        + #"coinbase|binance|kraken|phonepe|paytm|gpay|google pay|apple pay|amex|american express|capital one|klarna|"#
        + #"bhim|upi|tsb|first ?direct|virgin money|transferwise|wise app|zopa|kroo|monese|n26|bunq|western union|"#
        + #"remitly|world ?remit|xoom|skrill|paysend|moneygram|icici|hdfc|sbi|yono|kotak|payzapp|amazon pay|"#
        + #"samsung pay|clearpay|laybuy|zilch|moneybox|freetrade|trading 212|etoro|robinhood|vanguard|hargreaves|"#
        + #"nutmeg|chase (bank|app|uk)|metro bank|co-?op bank|bank(ing)? app|bank's app|online banking|mobile banking|"#
        + #"my bank|crypto|send money|transfer money)\b"#, options: [.caseInsensitive])

    /// Banking, payment and investment apps are off-limits to the operator: the money helper checks a payment, then
    /// the person opens their bank's own app themselves.
    static func isMoneyApp(_ text: String) -> Bool {
        money.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func namesMoneyApp(_ words: String) -> Bool {
        moneyNamed.firstMatch(in: words, range: NSRange(words.startIndex..., in: words)) != nil
    }
}

// MARK: - Safety rules (code decides; the model only proposes)

enum OperatorSafety {
    private static let sensitiveWords = try! NSRegularExpression(pattern:
        #"\b(send|pay|payment|buy|purchase|order|place order|checkout|check out|confirm|delete|remove|erase|post|share|"#
        + #"forward|call|transfer|submit|subscribe|accept|agree|allow|trust|install|donate|book now|sign out|log out|"#
        + #"block|report|end call|upload|your story|add to story|share to|share to story|close friends|create link|"#
        + #"copy link|publish|tweet|post all|"#
        // Undoable only with effort: leaving a group, clearing a chat, unsending, resetting, forgetting a device;
        // and spending: booking, requesting a ride, topping up, renewing, upgrading, tipping, dialling.
        + #"exit group|leave group|leave community|leave channel|clear chat|clear all|clear history|clear (all )?messages|"#
        + #"unsend|discard|reset|unpair|forget this|unsubscribe|dial|facetime|request|book|reserve|top up|renew|upgrade|"#
        + #"start (free )?trial|tip|approve|turn off|gift|rent|ring|leave|unfollow|join)\b"#, options: [.caseInsensitive])

    /// The same words in the languages a phone in the UK is often set to (Spanish, French, German, Italian, Polish,
    /// Portuguese, Romanian), whole words: send, pay, buy, delete, call, confirm, share, post, transfer.
    private static let sensitiveLatin = try! NSRegularExpression(pattern:
        #"\b(enviar|envía|envia|pagar|comprar|eliminar|borrar|llamar|confirmar|compartir|publicar|transferir|"#
        + #"envoyer|payer|acheter|supprimer|appeler|confirmer|partager|publier|virement|"#
        + #"senden|bezahlen|kaufen|löschen|anrufen|bestätigen|teilen|überweisen|"#
        + #"inviare|invia|pagare|paga|acquista|elimina|chiama|conferma|condividi|"#
        + #"wyślij|zapłać|kup|usuń|zadzwoń|potwierdź|udostępnij|przelew|"#
        + #"excluir|apagar|ligar|partilhar|compartilhar|trimite|plătește|șterge|sună)\b"#, options: [.caseInsensitive])
    /// Hindi and Telugu words for the same (send, pay, buy, order, confirm, delete, share, call, transfer, submit, post),
    /// then Urdu, Punjabi, Bengali, Gujarati, Tamil, Arabic and Chinese (send, pay, delete, call).
    private static let sensitiveOther = ["भेजें", "भेजो", "भेजना", "भुगतान", "खरीदें", "खरीदो", "ऑर्डर", "पुष्टि", "हटाएं",
                                         "हटाओ", "मिटाएं", "डिलीट", "शेयर", "कॉल", "ट्रांसफर", "सबमिट", "पोस्ट",
                                         "పంపు", "పంపండి", "చెల్లించు", "చెల్లించండి", "కొను", "కొనండి", "ఆర్డర్",
                                         "నిర్ధారించు", "తొలగించు", "తొలగించండి", "షేర్", "కాల్", "బదిలీ", "సమర్పించు", "పోస్ట్",
                                         "بھیجیں", "بھیجو", "ادائیگی", "حذف", "کال", "ਭੇਜੋ", "ਭੁਗਤਾਨ", "ਮਿਟਾਓ", "ਕਾਲ",
                                         "পাঠান", "পাঠাও", "পেমেন্ট", "মুছুন", "কল করুন", "મોકલો", "ચૂકવો", "કાઢી નાખો", "કૉલ",
                                         "அனுப்பு", "செலுத்து", "நீக்கு", "அழை", "إرسال", "ارسال", "ادفع", "دفع", "اتصال", "شراء",
                                         "发送", "傳送", "支付", "付款", "删除", "刪除", "购买", "購買", "呼叫", "拨打", "撥打", "确认", "確認"]

    /// "sendButton", "btn_send", "voice-call" → "send Button", "btn send", "voice call": identifiers and camelCase
    /// labels hide the word from \b…\b otherwise.
    static func spaced(_ s: String) -> String {
        var out = ""
        var previous: Character?
        for ch in s {
            if let p = previous, p.isLowercase, ch.isUppercase { out.append(" ") }
            out.append("_-.".contains(ch) ? " " : ch)
            previous = ch
        }
        return out
    }

    static func isSensitive(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let t = spaced(text)
        let range = NSRange(t.startIndex..., in: t)
        if sensitiveWords.firstMatch(in: t, range: range) != nil || sensitiveLatin.firstMatch(in: t, range: range) != nil {
            return true
        }
        return sensitiveOther.contains { text.contains($0) }
    }

    /// Does tapping this element act for the person (send, pay, call, delete…)? In a messaging app a list row is
    /// judged by its name, not by the message preview inside it ("Amma · please send the photo" is just opening a
    /// chat), and a long text is a message bubble. Anywhere else a button-like text of any length counts
    /// ("Place order · £23.40 · Pay now" in a React Native app is kind Other), and so does a Settings switch.
    static func isSensitive(_ e: ScreenElement, bundle: String = "") -> Bool {
        let chat = OperatorAppCatalog.messagingBundles.contains(bundle)
        if e.kind == "Switch", bundle == "com.apple.Preferences" { return true }
        if e.kind == "Cell" {
            if isSensitive(e.primaryText) || isSensitive(e.ident) { return true }
            return e.ownLabel && isSensitive(e.label) && (!chat || e.label.split(separator: " ").count <= 4)
        }
        if e.kind == "StaticText" || e.kind == "OCRText" || e.kind == "Other" {
            return (!chat || e.shownText.split(separator: " ").count <= 5) && (isSensitive(e.shownText) || isSensitive(e.ident))
        }
        return isSensitive(e.label) || isSensitive(e.ident) || (e.label.isEmpty && e.texts.contains { isSensitive($0) })
    }

    private static let neverTapWords = try! NSRegularExpression(pattern:
        #"voice message|record voice|hold to record|microphone|\bmeta ai\b|ask meta ai|imagine"#, options: [.caseInsensitive])

    /// Elements the operator never taps (the WhatsApp microphone records audio; Meta AI isn't the person's chat).
    static func neverTap(_ e: ScreenElement) -> String? {
        if e.isTextInput { return nil }  // WhatsApp's search box is labelled "Ask Meta AI or Search"
        let t = spaced(e.label + " " + e.ident)
        if neverTapWords.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil {
            return "That button records audio or opens an AI chat, so I won't tap it."
        }
        return nil
    }

    private static let digitKey = try! NSRegularExpression(pattern: #"^\s*([0-9])(\s+[a-z+]{1,4})?\s*$|^\s*[*#]\s*$"#,
                                                           options: [.caseInsensitive])

    /// A key of a number pad: "1", "2 ABC", "0 +", "*", "#".
    static func isDigitKey(_ e: ScreenElement) -> Bool {
        let t = e.label.isEmpty ? e.shownText : e.label
        return !t.isEmpty && digitKey.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }

    /// A passcode, PIN or phone keypad is on the screen (six or more number keys). Tapping its keys one by one is
    /// typing a PIN or dialling a number, which the operator never does.
    static func isNumberPad(_ s: ScreenDigest) -> Bool {
        s.elements.filter(isDigitKey).count >= 6
    }

    /// Another real control under the middle of `e` that must not be hit by a tap at e's coordinates: a send, call,
    /// pay or delete button, the microphone, or a number key. A label that arrives in page_source can carry new lines
    /// (a WhatsApp message does), and a message written to look like a row can put a fake element with an innocent
    /// name on top of the Audio call or Send button. A coordinate tap would then land on the real button.
    static func riskyUnder(_ e: ScreenElement, in s: ScreenDigest) -> ScreenElement? {
        let x = e.midX, y = e.midY
        let pad = isNumberPad(s)
        // An icon-only button with no name at all (we can't tell Send from Attach): never hit it by position.
        if var hidden = s.unnamedControls.first(where: { $0.x <= x && x <= $0.x + $0.w && $0.y <= y && y <= $0.y + $0.h }) {
            hidden.label = "a button with no name"
            return hidden
        }
        return s.elements.first { o in
            // The same control seen twice (a Button "Send" inside an Other "Send", OCR over the tree) isn't another one.
            o.index != e.index && !(o.kind == e.kind && o.label == e.label && o.ident == e.ident)
                && !(!e.label.isEmpty && o.label == e.label)
                && o.w > 1 && o.h > 1 && o.x <= x && x <= o.x + o.w && o.y <= y && y <= o.y + o.h
                && (neverTap(o) != nil || isSensitive(o, bundle: s.bundleID) || (pad && isDigitKey(o)))
        }
    }

    private static let secretAsk = try! NSRegularExpression(pattern:
        #"\b(enter|type|put in|fill in|tell|give|use|share|read out|key in)\b.{0,24}\b(pin|passcode|password|otp|code)\b|"#
        + #"\b(my|the|bank|card|sim|phone|app) pin\b|\bpin (code|number)\b|\bpasscode\b|\bpassword\b|\botp\b|"#
        + #"one[- ]time (pass)?code|verification code|security code|\bcvv\b|\bcvc\b|card number|card details|"#
        + #"sort code|account number|memorable (word|information)"#, options: [.caseInsensitive])
    private static let secretField = try! NSRegularExpression(pattern:
        #"\b(pin|passcode|password|otp|cvv|cvc|code)\b|card number|security|verification|memorable|one[- ]time"#,
                                                             options: [.caseInsensitive])

    /// A goal (or a screen) that wants a PIN, passcode, password, one-time code or card number.
    static func asksForSecret(_ text: String) -> Bool {
        secretAsk.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// A text field that takes a secret.
    static func isSecretField(_ e: ScreenElement) -> Bool {
        if e.isSecure { return true }
        let t = e.label + " " + e.ident
        return secretField.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }

    private static let secretPrompt = try! NSRegularExpression(pattern:
        #"\b(enter|type|confirm|re-?enter|input)\b.{0,30}\b(pin|passcode|password|code)\b|two-step verification|"#
        + #"verification code|one[- ]time (pass)?code|\botp\b|security code"#, options: [.caseInsensitive])

    /// The screen is asking for a PIN, passcode or code (WhatsApp two-step verification, a bank login). Only the
    /// screen's own prompts count, not messages in a chat.
    static func screenAsksForSecret(_ s: ScreenDigest) -> Bool {
        if s.elements.contains(where: { $0.isSecure }) { return true }
        return s.elements.contains { e in
            guard ["StaticText", "NavigationBar", "Alert", "OCRText"].contains(e.kind) else { return false }
            // Up to a long paragraph ("To keep your account safe, please enter the 6-digit code we have just sent by
            // text message to …"): a false hit only stops a bare number from being typed.
            let t = e.shownText
            return t.count < 240 && secretPrompt.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
        }
    }

    /// Looks like a card number (13–19 digits) or a short code (4–8 digits and nothing else).
    static func looksLikeSecretValue(_ text: String) -> Bool {
        let stripped = text.filter { !" -".contains($0) }
        guard !stripped.isEmpty, stripped.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return text.digitsOnly.count >= 13 && text.digitsOnly.count <= 19 && text.filter(\.isLetter).isEmpty
        }
        return (4...8).contains(stripped.count) || (13...19).contains(stripped.count)
    }

    /// Text the operator types must come from the person's own words or the goal, never from the screen. Long numbers
    /// (phone, account) must have been said by the person.
    static func typedTextAllowed(_ text: String, sources: [String], userWords: String) -> Bool {
        let want = text.folded.split(separator: " ").map(String.init)
        guard !want.isEmpty else { return true }
        let have = Set(sources.joined(separator: " ").folded.split(separator: " ").map(String.init))
        if want.contains(where: { !have.contains($0) }) { return false }
        let said = SafetyGate.digitRuns(userWords)
        for run in SafetyGate.digitRuns(text) where run.count >= 6 {
            if !said.contains(where: { $0.contains(run) }) { return false }
        }
        // Links and email addresses too: the goal may carry one from a letter or a message ("go to secure-refund.com").
        let saidLinks = SafetyGate.plainLinks(userWords)
        for link in SafetyGate.links(text) where !saidLinks.contains(SafetyGate.plainLinks(link)) { return false }
        return true
    }

    private static let scamAsk = try! NSRegularExpression(pattern:
        #"\b(send|transfer|pay|give|move)\b.{0,20}(\bmoney\b|\bcash\b|£|\$|€)|\bgift ?cards?\b|\bbitcoin\b|\bcrypto\b|"#
        + #"\bbank details\b|account (is |has been )?(locked|suspended|blocked|frozen)|verify your (account|identity|details)"#,
                                                     options: [.caseInsensitive])

    /// Words a model wrote after seeing the screen that pass on a scam: asking for a PIN, a code, card details or money.
    static func repeatsScam(_ say: String) -> Bool {
        asksForSecret(say) || scamAsk.firstMatch(in: say, range: NSRange(say.startIndex..., in: say)) != nil
    }

    /// Words the model wrote after seeing the screen: long numbers and links the person never said are taken out,
    /// so a message on the screen can't put "ring 0900…" into Kairos's mouth.
    static func scrub(_ say: String, userWords: String) -> String {
        var out = say
        let said = SafetyGate.digitRuns(userWords)
        for run in SafetyGate.digitRuns(say) where run.count >= 6 && !said.contains(where: { $0.contains(run) }) {
            if let r = out.range(of: run) { out.replaceSubrange(r, with: "a number") }
        }
        let saidLower = userWords.lowercased()
        for link in SafetyGate.links(say) where !saidLower.contains(link) {
            if let r = out.range(of: link, options: .caseInsensitive) { out.replaceSubrange(r, with: "a link") }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - What the goal means

enum OperatorIntent: Equatable, Sendable {
    case whatsAppOpenChat(person: String)
    case whatsAppRead(person: String, count: Int)
    /// send: true taps Send after the owner approves; false leaves the message typed for the person to send.
    case whatsAppMessage(person: String, text: String, send: Bool)
}

enum AppSkills {
    /// A deterministic procedure for this goal, or nil (then the model plans).
    static func match(goal: String, app: String?, person: String?, text: String?) -> OperatorIntent? {
        let message = nonEmpty(text) ?? extractMessage(goal)
        // Judge the request without the message itself ("tell Amma I checked" is not a request to read).
        var rest = goal
        if let message, let r = rest.range(of: message, options: .caseInsensitive) { rest.removeSubrange(r) }
        let g = rest.folded
        let a = (app ?? "").folded
        guard a.contains("whatsapp") || a == "whats app" || g.contains("whatsapp") || g.contains("whats app") else { return nil }
        // Not covered by the procedures: the model handles these (and the gate still checks every tap).
        if has(g, ["call", "ring", "video", "photo", "picture", "group", "delete", "block", "report", "archive", "mute",
                   "pin", "status", "forward", "unread", "search", "settings"]) { return nil }
        let given = nonEmpty(person).map { name -> String in let c = cleanPerson(name); return c.isEmpty ? name : c }
        guard let who = given ?? extractPerson(rest), !who.isEmpty else { return nil }
        let read = has(g, ["read", "what did", "what has", "latest", "last message", "last messages", "new message",
                           "new messages", "any message", "any messages", "messages from", "check", "replied", "said", "say"])
        let sendVerbs = ["send", "tell", "reply", "write", "type", "draft"]
        let messaging = has(g, sendVerbs + ["message", "text", "let"]) || g.hasPrefix("whatsapp ")
        let open = has(g, ["open", "show", "go to", "take me to", "bring up"])
        if let message, messaging, !read || has(g, sendVerbs) {
            return .whatsAppMessage(person: who, text: message, send: !wantsDraftOnly(g))
        }
        if read { return .whatsAppRead(person: who, count: count(g)) }
        if open { return .whatsAppOpenChat(person: who) }
        return nil
    }

    static func wantsDraftOnly(_ g: String) -> Bool {
        has(g, ["type", "write", "draft", "prepare", "ready to send", "dont send", "don t send", "do not send",
                "without sending", "not send", "i ll send", "i will send", "let me send", "leave it"])
    }

    /// The words to type: quoted text first, else what follows "saying", "that", ":".
    static func extractMessage(_ goal: String) -> String? {
        for (open, close) in [("“", "”"), ("\"", "\""), ("‘", "’"), ("«", "»")] {
            // ’ is also an apostrophe (“I’m”): take the last one.
            let backwards: String.CompareOptions = close == "’" ? .backwards : []
            if let a = goal.range(of: open),
               let b = goal.range(of: close, options: backwards, range: a.upperBound..<goal.endIndex),
               a.upperBound < b.lowerBound {
                let t = String(goal[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { return t }
            }
        }
        for marker in [" saying ", " that says ", " to say ", " which says ", ": ", " that "] {
            if let r = goal.range(of: marker, options: .caseInsensitive) {
                var t = String(goal[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                for tail in [" on whatsapp", " in whatsapp", " via whatsapp", " on WhatsApp", " but don't send it",
                             " but do not send it", " but don't send", " and send it", " and send"] {
                    if t.lowercased().hasSuffix(tail.lowercased()) { t = String(t.dropLast(tail.count)) }
                }
                t = t.trimmingCharacters(in: CharacterSet(charactersIn: " .,;"))
                if !t.isEmpty, t.count <= 1000 { return t }
            }
        }
        return nil
    }

    private static let personPatterns: [String] = [
        #"(?:chat|conversation|messages?|whatsapps?)\s+(?:with|from)\s+(.+?)(?=\s+(?:on|in|saying|that|and|to)\b|[,.!?:;]|$)"#,
        #"\bwhat\s+(?:did|has|have)\s+(.+?)\s+(?:say|said|send|sent|write|written|reply|replied)\b"#,
        #"\b([\p{L}][\p{L}\-]*)['’]s\s+(?:chat|messages?|whatsapp)"#,
        #"\b(?:send|message|text|tell|whatsapp|reply to|write to|ask|open)\s+(.+?)(?=\s+(?:a|an)\s+(?:whatsapp|message|text)\b|\s+(?:saying|that|to|on|in|and|but)\b|[,.!?:;]|$)"#,
        #"\bto\s+(.+?)(?=\s+(?:on|in|saying|that|and|but)\b|[,.!?:;]|$)"#,
        #"\b(?:from|with)\s+(.+?)(?=\s+(?:on|in|saying|that|and)\b|[,.!?:;]|$)"#,
    ]

    static func extractPerson(_ goal: String) -> String? {
        for pattern in personPatterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: goal, range: NSRange(goal.startIndex..., in: goal)),
                  let r = Range(m.range(at: 1), in: goal) else { continue }
            let name = cleanPerson(String(goal[r]))
            if !name.isEmpty { return name }
        }
        return nil
    }

    private static let notNames: Set<String> = ["whatsapp", "messages", "message", "me", "her", "him", "them", "it", "my",
                                                "chat", "the", "a", "an", "text", "my chat", "the chat", "everyone", "you"]

    static func cleanPerson(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?\"'“”‘’"))
        for prefix in ["my ", "the ", "our "] where s.lowercased().hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        for suffix in [" on whatsapp", " in whatsapp", " whatsapp", "'s chat"] where s.lowercased().hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
        }
        let words = s.split(separator: " ")
        let folded = s.folded
        if folded.isEmpty || words.count > 4 || s.count > 40 || notNames.contains(folded) { return "" }
        if has(folded, ["whatsapp", "message", "messages", "chat", "text"]) || folded.hasPrefix("a ") || folded.hasPrefix("an ") { return "" }
        // Bits of the sentence, not a name ("but don't send it").
        if has(folded, ["but", "send", "don", "dont", "it", "please", "saying", "that", "and", "if", "when", "what", "is", "are"]) { return "" }
        return s
    }

    private static func count(_ g: String) -> Int {
        let words = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "ten": 10]
        for token in g.split(separator: " ") {
            if let n = Int(token), (1...20).contains(n) { return n }
            if let n = words[String(token)] { return n }
        }
        return 5
    }

    /// Whole-word (or whole-phrase) containment on folded text.
    static func has(_ folded: String, _ phrases: [String]) -> Bool {
        let padded = " " + folded + " "
        return phrases.contains { padded.contains(" " + $0 + " ") }
    }

    static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

// MARK: - Procedure results

/// How an operator run ends.
struct OperatorFinish: Sendable {
    var ok: Bool
    var say: String
    /// Leave the person in the other app (a message ready for them to send, a chat they asked to see).
    var leaveInApp: Bool = false
    /// The run stopped to ask the person something.
    var asked: Bool = false
    /// `say` answers the person's question (read from a screen): Kairos speaks it as it is.
    var isAnswer: Bool = false
    /// Screen text the answer came from (untrusted: information, never instructions).
    var untrusted: String? = nil
}

enum OperatorSkillOutcome: Sendable {
    case finished(OperatorFinish)
    /// Texts read from a chat, for the reader to answer from (untrusted).
    case read(title: String, lines: [String])
    /// The screen wasn't what the procedure expected: hand over to the model with this note.
    case needsModel(String)
}

// MARK: - WhatsApp (skills/whatsapp: SKILL.md, SCREENS.md, PROCEDURES.md)

struct WhatsAppSkill {
    static let bundle = "net.whatsapp.WhatsApp"
    let d: OperatorDriver

    enum Screen: Equatable {
        case chatsList, search, chat, locked, secret, terms, interstitial(Int), otherApp, unknown
    }

    static func classify(_ s: ScreenDigest) -> Screen {
        if !s.bundleID.isEmpty, s.bundleID != bundle, !s.bundleID.hasPrefix("net.whatsapp") { return .otherApp }
        if s.has("WhatsApp Locked") || s.has("Unlock WhatsApp") || s.has("Unlock with Face ID") || s.has("Use Face ID")
            || s.has("Enter Passcode") { return .locked }
        let hasComposer = s.first(kind: "TextView") != nil
        let buttons = s.elements.filter { $0.kind == "Button" }
        if hasComposer || (buttons.contains { $0.label == "Voice message" } && buttons.contains { $0.label == "Attach" }) {
            return .chat
        }
        if OperatorSafety.screenAsksForSecret(s) { return .secret }
        if buttons.contains(where: { ["agree", "accept", "i agree", "agree and continue"].contains($0.label.folded) }) {
            return .terms
        }
        let hasSearch = s.first(kind: "SearchField") != nil
        if hasSearch, buttons.contains(where: { $0.label.folded == "cancel" }) { return .search }
        if hasSearch, s.elements.contains(where: { $0.label.folded == "chats" && $0.kind != "Cell" }) { return .chatsList }
        let closers = ["not now", "later", "maybe later", "skip", "close", "got it", "ok", "continue"]
        for word in closers {
            if let b = buttons.first(where: { $0.label.folded == word }) { return .interstitial(b.index) }
        }
        return .unknown
    }

    enum Opened {
        case chat(ScreenDigest, title: String)
        case stop(OperatorSkillOutcome)
    }

    func run(_ intent: OperatorIntent) async throws -> OperatorSkillOutcome {
        switch intent {
        case .whatsAppOpenChat(let person):
            switch try await openChat(person) {
            case .stop(let outcome): return outcome
            case .chat(_, let title):
                return .finished(OperatorFinish(ok: true, say: "Your WhatsApp chat with \(ScreenNames.spoken(title)) is open.", leaveInApp: true))
            }
        case .whatsAppRead(let person, _):
            switch try await openChat(person) {
            case .stop(let outcome): return outcome
            case .chat(let s, let title): return .read(title: title, lines: Self.bubbles(s))
            }
        case .whatsAppMessage(let person, let text, let send):
            return try await message(person, text: text, send: send)
        }
    }

    // P0: get WhatsApp to the Chats list.
    enum Ready {
        case list(ScreenDigest)
        case stop(OperatorSkillOutcome)
    }

    func ready() async throws -> Ready {
        try await d.open(bundle: Self.bundle, name: "WhatsApp")
        var s = try await d.read()
        for _ in 0..<4 {
            switch Self.classify(s) {
            case .chatsList:
                return .list(s)
            case .locked:
                return .stop(.finished(OperatorFinish(ok: false, say: "WhatsApp is locked. Please unlock it yourself, then ask me again.",
                                                         leaveInApp: true, asked: true)))
            case .secret:
                return .stop(.finished(OperatorFinish(ok: false, say: "WhatsApp is asking for your PIN. Please type it in yourself; I never type PINs or codes.",
                                                         leaveInApp: true, asked: true)))
            case .terms:
                return .stop(.finished(OperatorFinish(ok: false, say: "WhatsApp wants you to agree to something new. Please read it and decide yourself, then ask me again.",
                                                         leaveInApp: true, asked: true)))
            case .interstitial(let index):
                guard let b = s.element(index) else { return .stop(.needsModel("A message box is covering WhatsApp.")) }
                guard case .done = await d.tap(b, in: s) else { return .stop(.needsModel("A message box is covering WhatsApp.")) }
            case .chat:
                guard let back = Self.backButton(s), case .done = await d.tap(back, in: s) else {
                    return .stop(.needsModel("Inside a chat; need the Chats list."))
                }
            case .search:
                guard let cancel = s.find(["Cancel"], kinds: ["Button"], exactOnly: true).first,
                      case .done = await d.tap(cancel, in: s) else { return .stop(.needsModel("Search is open; need the Chats list.")) }
            case .otherApp:
                return .stop(.needsModel("WhatsApp didn't come to the front."))
            case .unknown:
                guard let tab = s.find(["Chats"], kinds: ["Button"], exactOnly: true).last,
                      case .done = await d.tap(tab, in: s) else { return .stop(.needsModel("Not on the Chats list.")) }
            }
            s = try await d.read()
        }
        return Self.classify(s) == .chatsList ? .list(s) : .stop(.needsModel("Couldn't get to the Chats list."))
    }

    // P1: open the right chat (by name: the visible row if it's an exact match, else search).
    func openChat(_ person: String) async throws -> Opened {
        let list: ScreenDigest
        switch try await ready() {
        case .stop(let stop): return .stop(stop)
        case .list(let s): list = s
        }
        var target: ScreenElement?
        var current = list
        let rows = list.elements.filter { $0.kind == "Cell" }
        let visible = ScreenNames.match(rows, name: person)
        if visible.exact.count == 1 {
            target = visible.exact[0]
        } else {
            guard let field = list.first(kind: "SearchField") else { return .stop(.needsModel("No search field on the Chats list.")) }
            switch await d.type(person, into: field, in: list) {
            case .done: break
            case .refused(let why), .failed(let why): return .stop(.needsModel(why))
            case .declined(let why): return .stop(.finished(OperatorFinish(ok: false, say: why)))
            }
            current = try await d.read()
            if Self.classify(current) != .search, Self.classify(current) != .chatsList {
                return .stop(.needsModel("Typed the name into search; the screen looks different."))
            }
            let messagesHeader = current.elements.first { $0.kind != "Cell" && $0.label.folded == "messages" }?.y ?? .infinity
            let people = current.elements.filter { $0.kind == "Cell" && $0.y < messagesHeader && !$0.fullText.localizedCaseInsensitiveContains("Meta AI") }
            let found = ScreenNames.match(people, name: person)
            let pick = found.exact.count == 1 ? found.exact : (found.exact.isEmpty ? found.prefix : found.exact)
            if pick.count == 1 {
                target = pick[0]
            } else {
                if let cancel = current.find(["Cancel"], kinds: ["Button"], exactOnly: true).first { _ = await d.tap(cancel, in: current) }
                if pick.count > 1 {
                    let names = pick.prefix(3).map { ScreenNames.spoken($0.primaryText) }
                    return .stop(.finished(OperatorFinish(ok: true, say: "I found \(Self.list(names)) in WhatsApp. Which one do you mean?", asked: true)))
                }
                return .stop(.finished(OperatorFinish(ok: false, say: "I couldn't find \(person) in WhatsApp. Are they saved under a different name?", asked: true)))
            }
        }
        guard let row = target else { return .stop(.needsModel("No chat row to open.")) }
        switch await d.tap(row, in: current) {
        case .done: break
        case .refused(let why), .failed(let why): return .stop(.needsModel(why))
        case .declined(let why): return .stop(.finished(OperatorFinish(ok: false, say: why)))
        }
        let chat = try await d.read()
        guard Self.classify(chat) == .chat else { return .stop(.needsModel("Tapped \(person)'s row; the chat didn't open.")) }
        let title = Self.chatTitle(chat) ?? row.primaryText
        if !ScreenNames.sameName(title, person), !ScreenNames.sameName(title, row.primaryText) {
            if let back = Self.backButton(chat) { _ = await d.tap(back, in: chat) }
            return .stop(.finished(OperatorFinish(ok: false, say: "That opened a chat with \(ScreenNames.spoken(title)), not \(person), so I stopped. Who did you mean?", asked: true)))
        }
        return .chat(chat, title: title)
    }

    // wa.send_message (B, by name): type, check, then Send only with the owner's OK; or leave it ready.
    func message(_ person: String, text: String, send: Bool) async throws -> OperatorSkillOutcome {
        let chat: ScreenDigest, title: String
        switch try await openChat(person) {
        case .stop(let outcome): return outcome
        case .chat(let s, let t): chat = s; title = t
        }
        guard let composer = Self.composer(chat) else { return .needsModel("No message box in the chat.") }
        switch await d.type(text, into: composer, in: chat) {
        case .done: break
        case .refused(let why): return .finished(OperatorFinish(ok: false, say: why))
        case .failed(let why): return .needsModel(why)
        case .declined(let why): return .finished(OperatorFinish(ok: false, say: why))
        }
        var typed = try await d.read()
        // The Send next to the message box: the lowest one (a message can carry a fake "Send" row higher up).
        var sendButton = typed.find(["Send"], kinds: ["Button"], exactOnly: true).max { $0.y < $1.y }
        if sendButton == nil, let again = Self.composer(typed) {
            // Troubleshooting: the text went elsewhere. Tap the message box and type again (clear first, so never twice).
            _ = await d.type(text, into: again, in: typed)
            typed = try await d.read()
            sendButton = typed.find(["Send"], kinds: ["Button"], exactOnly: true).max { $0.y < $1.y }
        }
        guard let sendButton else {
            return .finished(OperatorFinish(ok: false, say: "I typed the message, but WhatsApp didn't show its Send button. Please check the chat with \(ScreenNames.spoken(title)).",
                                            leaveInApp: true))
        }
        guard send else {
            return .finished(OperatorFinish(ok: true, say: "Your message to \(ScreenNames.spoken(title)) is ready in WhatsApp. Check it, then tap Send yourself.",
                                            leaveInApp: true))
        }
        switch await d.tap(sendButton, in: typed, context: "to \(title): “\(ScreenDigest.short(text, 120))”") {
        case .done:
            let after = try await d.read()
            let start = String(text.folded.prefix(25))
            if Self.bubbles(after).contains(where: { $0.folded.contains(start) }) {
                return .finished(OperatorFinish(ok: true, say: "I sent “\(ScreenDigest.short(text, 80))” to \(ScreenNames.spoken(title)) on WhatsApp."))
            }
            return .finished(OperatorFinish(ok: true, say: "I tapped Send, but I can't see the message in the chat yet. Please check WhatsApp before trying again."))
        case .declined(let why):
            await d.clearDraft(bundle: Self.bundle)
            return .finished(OperatorFinish(ok: false, say: why))
        case .refused(let why), .failed(let why):
            await d.clearDraft(bundle: Self.bundle)
            return .finished(OperatorFinish(ok: false, say: why + " Nothing was sent."))
        }
    }

    // MARK: - Reading a chat

    static let chromeLabels: Set<String> = ["back", "video call", "audio call", "voice call", "call", "video", "chats",
                                            "search", "more", "camera", "attach", "send", "voice message", "sticker",
                                            "stickers", "scroll to bottom", "jump to bottom", "online", "add", "plus"]

    /// The message box: the LOWEST text view on the chat screen. A message whose text is written to look like a
    /// page_source row can add a fake "TextView" higher up (over the Audio call button); the real composer is at the bottom.
    static func composer(_ s: ScreenDigest) -> ScreenElement? {
        s.elements.filter { $0.kind == "TextView" }.max { $0.y < $1.y }
    }

    static func backButton(_ s: ScreenDigest) -> ScreenElement? {
        s.elements.first { $0.kind == "Button" && $0.y < 150 && ($0.label.folded == "back" || $0.label.folded.hasPrefix("back ")) }
            ?? s.elements.first { $0.kind == "Button" && $0.y < 150 && $0.x < 100 && $0.label.folded.hasPrefix("chats") }
    }

    static func chatTitle(_ s: ScreenDigest) -> String? {
        let top = s.elements.filter { $0.y < 150 && $0.y > 20 && ($0.kind == "Button" || $0.kind == "StaticText" || $0.kind == "NavigationBar") }
        let named = top.filter { e in
            let f = e.label.folded
            return !f.isEmpty && !chromeLabels.contains(f) && !f.hasPrefix("back") && !f.hasPrefix("last seen")
                && !f.hasPrefix("typing") && !f.hasPrefix("tap here")
        }
        return (named.first { $0.kind == "Button" } ?? named.first)?.label
    }

    private static let notMessages = try! NSRegularExpression(pattern:
        #"^(today|yesterday|monday|tuesday|wednesday|thursday|friday|saturday|sunday)$|^\d{1,2}[ /.-]\w+([ /.-]\d{2,4})?$|"#
        + #"end-to-end encrypted|unread messages?$|^\d+ unread|added you|created (this )?group|changed (the )?(group|subject)|"#
        + #"joined using|security code (with|changed)|disappearing messages|this message was deleted"#,
                                                          options: [.caseInsensitive])

    /// The message bubbles on a chat screen, oldest first: between the title bar and the message box.
    static func bubbles(_ s: ScreenDigest) -> [String] {
        let composerTop = composer(s)?.y ?? s.keyboardTop ?? .infinity
        return s.elements.compactMap { e -> String? in
            guard e.y >= 100, e.y < composerTop, ["Cell", "Other", "StaticText", "OCRText"].contains(e.kind) else { return nil }
            let t = e.fullText
            guard !t.isEmpty, !chromeLabels.contains(t.folded) else { return nil }
            if notMessages.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil { return nil }
            return t
        }
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }
}
