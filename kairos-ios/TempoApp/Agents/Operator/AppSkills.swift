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
        "uber": "com.ubercab.UberClient", "uber eats": "com.ubercab.UberEats", "ubereats": "com.ubercab.UberEats",
        "deliveroo": "com.deliveroo.orderapp", "amazon": "com.amazon.Amazon", "spotify": "com.spotify.client",
        "netflix": "com.netflix.Netflix", "tiktok": "com.zhiliaoapp.musically", "messenger": "com.facebook.Messenger",
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
        "com.ubercab.UberClient": "Uber", "com.ubercab.UberEats": "Uber Eats", "com.deliveroo.orderapp": "Deliveroo",
        "com.amazon.Amazon": "Amazon", "com.spotify.client": "Spotify", "com.netflix.Netflix": "Netflix",
        "com.zhiliaoapp.musically": "TikTok", "com.facebook.Messenger": "Messenger", "com.google.ios.youtube": "YouTube",
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

    /// Apps where tapping a row rings someone.
    static let callingBundles: Set<String> = ["com.apple.mobilephone", "com.apple.facetime"]
    /// The Phone app's tabs and filters, which only change what is shown.
    private static let callingAppSafeLabels: Set<String> = ["favourites", "favorites", "recents", "contacts", "keypad",
                                                            "voicemail", "all", "missed", "more info", "info", "back",
                                                            "search", "cancel", "done"]

    /// In the Phone and FaceTime apps, tapping a name in Recents or Favourites rings that person straight away.
    /// So a row or a name there counts as calling: reading who rang never rings anyone back. The tabs and the
    /// ⓘ button are still free to tap.
    static func ringsSomeone(_ e: ScreenElement, bundle: String) -> Bool {
        callingBundles.contains(bundle)
            && (e.kind == "Cell" || ((e.kind == "StaticText" || e.kind == "OCRText") && !e.shownText.isEmpty))
            && !callingAppSafeLabels.contains(e.shownText.folded)
    }

    /// Does tapping this element act for the person (send, pay, call, delete…)? In a messaging app a list row is
    /// judged by its name, not by the message preview inside it ("Amma · please send the photo" is just opening a
    /// chat), and a long text is a message bubble. Anywhere else a button-like text of any length counts
    /// ("Place order · £23.40 · Pay now" in a React Native app is kind Other), and so does a Settings switch.
    static func isSensitive(_ e: ScreenElement, bundle: String = "") -> Bool {
        let chat = OperatorAppCatalog.messagingBundles.contains(bundle)
        if e.kind == "Switch", bundle == "com.apple.Preferences" { return true }
        if ringsSomeone(e, bundle: bundle) { return true }
        if e.kind == "Cell" {
            if isSensitive(e.primaryText) || isSensitive(e.ident) { return true }
            return e.ownLabel && isSensitive(e.label) && (!chat || e.label.split(separator: " ").count <= 4)
        }
        if e.kind == "StaticText" || e.kind == "OCRText" || e.kind == "Other" {
            return (!chat || e.shownText.split(separator: " ").count <= 5) && (isSensitive(e.shownText) || isSensitive(e.ident))
        }
        return isSensitive(e.label) || isSensitive(e.ident) || (e.label.isEmpty && e.texts.contains { isSensitive($0) })
    }

    /// "£1.49", "£ 3", "2.50 GBP", "50p": amounts of money, taken out before judging the rest of a row.
    private static let amounts = try! NSRegularExpression(pattern:
        #"[£$€₹¥]\s?\d[\d.,]*|\d[\d.,]*\s?[£$€₹¥]|\b\d[\d.,]*\s?(gbp|usd|eur|inr|pounds?|quid|pence|p|dollars?|euros?|rupees?)\b"#,
        options: [.caseInsensitive])
    /// Words that make a row with a price into paying: pay, order, checkout, place, buy, a basket.
    private static let payWords = ["pay", "pay now", "order", "order now", "place order", "place", "checkout", "check out",
                                   "buy", "buy now", "purchase", "basket", "cart", "bag", "book", "subscribe", "tip",
                                   "donate", "top up", "confirm", "add", "get", "rent", "upgrade", "trial", "premium"]
    /// The same words inside one longer word, which the whole-word check misses: "Reorder", "Preorder", "Prepay",
    /// "Rebook", "Resubscribe" (on folded text).
    private static let compoundPayWords = try! NSRegularExpression(pattern:
        #"\b(re|pre)(order|pay|book|buy|subscribe|purchase|checkout)"#)

    /// A row in a list that only shows a price or a fee ("Tesco Express · £1.49 delivery fee · 20–30 min"): opening
    /// it to look is not paying. Only a Cell (a Button with a price stays gated), never with a pay, order, checkout,
    /// place or buy word on it (also inside a word: "Reorder"), and nothing else on it may need the owner's OK once
    /// the amounts are taken out.
    static func priceOnlyRow(_ e: ScreenElement, bundle: String, appName: String) -> Bool {
        guard e.kind == "Cell", !e.fromOCR else { return false }
        let all = ([e.label, e.value, e.ident] + e.texts).filter { !$0.isEmpty }.joined(separator: " · ")
        let folded = all.folded
        guard ActionClass.mentionsMoney(all), !AppSkills.has(folded, payWords),
              compoundPayWords.firstMatch(in: folded, range: NSRange(folded.startIndex..., in: folded)) == nil else { return false }
        let rest = amounts.stringByReplacingMatches(in: all, range: NSRange(all.startIndex..., in: all), withTemplate: " ")
        // A bare "£4.99" with nothing else on it may be the price button itself: still gated.
        guard rest.contains(where: { $0.isLetter }), !ActionClass.mentionsMoney(rest) else { return false }
        return ActionClass.forTap(label: rest, kind: e.kind, appBundleID: bundle, appName: appName) == nil && !isSensitive(rest)
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
                // A search bar's own button laid over its box, same frame (WhatsApp's "Ask Meta AI or Search"):
                // tapping the box is tapping it.
                && !(e.isSearchBox && o.kind == "Button" && o.x == e.x && o.y == e.y && o.w == e.w && o.h == e.h
                     && AppSearchSkill.saysSearch(o))
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

    /// The app's own login or two-step screen: a box for a password, PIN or code is on it (a secure field, or a text
    /// box named for one), and no message box. A message in a chat can ask for a code too, but brings no box for it.
    static func screenHasSecretBox(_ s: ScreenDigest) -> Bool {
        guard WhatsAppSkill.composer(s) == nil else { return false }
        return s.elements.contains { e in
            e.isSecure || (e.isTextInput && !e.fromOCR && !e.isSearchBox && isSecretField(e))
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
    /// "Open Uber": open the app, nothing else.
    case openApp(app: String)
    /// "Search water in Uber Eats": the app's own search, with the person's words.
    case appSearch(app: String, query: String)
}

enum AppSkills {
    /// A deterministic procedure for this goal, or nil (then the model plans).
    static func match(goal: String, app: String?, person: String?, text: String?) -> OperatorIntent? {
        // Any app, with no message and nobody to reach: "open Uber", "search water in Uber Eats".
        if nonEmpty(text) == nil, nonEmpty(person) == nil {
            if let name = plainOpen(goal: goal, app: app) { return .openApp(app: name) }
            if let found = appSearch(goal: goal, app: app) { return .appSearch(app: found.app, query: found.query) }
        }
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

    // MARK: Any app: open it, search in it

    private static let notAnApp: Set<String> = ["current", "screen", "this", "this screen", "the screen"]

    /// "Open Uber", "please open the Uber app for me": the whole goal is opening one app.
    private static let plainOpenPattern = try! NSRegularExpression(pattern:
        #"^\s*(?:(?:please|can you|could you|would you|kairos)[\s,]+)*(?:open(?:\s+up)?|launch|go\s+to|take\s+me\s+to|bring\s+up|switch\s+to)"#
        + #"\s+(?:the\s+|my\s+)?(.+?)(?:\s+app(?:lication)?)?(?:[\s,]+(?:for me|please|now|on my phone|on the phone))*[\s.!?]*$"#,
        options: [.caseInsensitive])

    /// "Open Uber": nothing to do there but open it. The app's name, or nil. Without the app argument, only a name
    /// this phone already knows (never a guess like "the home screen").
    static func plainOpen(goal: String, app: String?) -> String? {
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = plainOpenPattern.firstMatch(in: g, range: NSRange(g.startIndex..., in: g)),
              let r = Range(m.range(at: 1), in: g) else { return nil }
        let named = String(g[r]).trimmingCharacters(in: CharacterSet(charactersIn: " .,!?\"'“”‘’"))
        let words = named.folded.split(separator: " ").map(String.init)
        let notName: Set<String> = ["and", "then", "to", "with", "for", "in", "on", "at", "from", "of", "a", "an", "chat", "chats"]
        guard !named.isEmpty, words.count <= 3, !words.contains(where: { notName.contains($0) }) else { return nil }
        if let given = nonEmpty(app), !notAnApp.contains(given.folded) {
            return squash(given) == squash(named) ? given : nil
        }
        return OperatorAppCatalog.knownBundle(named) != nil || OperatorAppCatalog.cached(named) != nil ? named : nil
    }

    /// The search words, after "search (for)", "look up", "look for" or "find".
    private static let searchVerb = try! NSRegularExpression(pattern: #"\b(?:search(?:\s+for)?|look\s+up|look\s+for|find)\s+(.+)$"#,
                                                             options: [.caseInsensitive])
    /// What comes after the search words: "… and tell me the prices", "… then show me".
    private static let searchTail = try! NSRegularExpression(pattern:
        #"\s+(?:and\s+then|then|and\s+(?:tell|show|read|see|check|let|give|say|pick|choose|open|tap|list))\b.*$"#,
        options: [.caseInsensitive])
    /// "water in Uber Eats" → ("water", "Uber Eats"): the last in/on/using names the app.
    private static let appAfter = try! NSRegularExpression(pattern:
        #"^(.*)\s+(?:in|on|using|at|from|with)\s+(?:the\s+|my\s+)?(.+?)(?:\s+app)?$"#, options: [.caseInsensitive])
    /// "Uber Eats for water" → ("Uber Eats", "water").
    private static let appBefore = try! NSRegularExpression(pattern:
        #"^(?:the\s+|my\s+)?(.+?)(?:\s+app)?\s+for\s+(.+)$"#, options: [.caseInsensitive])
    /// Not something to type into a search box: the goal is too vague, or it's a question, not a search.
    private static let notQueries: Set<String> = ["something", "anything", "stuff", "it", "that", "this", "them", "things",
                                                  "everything", "the app", "app"]
    private static let notQueryStarts: Set<String> = ["my", "out", "how", "what", "where", "when", "why", "if", "whether",
                                                      "me", "someone", "somewhere", "a", "an", "some", "any"]
    /// Words for doing, not looking: buying, ordering, paying, booking, sending, posting, playing.
    static let doingWords = ["buy", "order", "pay", "checkout", "check out", "purchase", "book", "reserve", "subscribe",
                             "add", "basket", "cart", "send", "call", "ring", "message", "text", "post", "share", "delete",
                             "remove", "tip", "donate", "transfer", "top up", "follow", "like", "comment", "reply", "play",
                             "install", "download", "sign up", "join"]

    /// "Search water in Uber Eats", "look up pizza on Deliveroo", "search Amazon for batteries": the app and the
    /// words to search for, both from the person. Not in messaging apps (their search box can reach people or Meta
    /// AI), not for bank apps, and not when the goal also buys, orders, sends or plays something (the planner does
    /// those, with the gate on every tap).
    static func appSearch(goal: String, app: String?) -> (app: String, query: String)? {
        let g = goal.folded
        guard has(g, ["search", "look up", "look for", "find"]), !has(g, doingWords) else { return nil }
        let given = nonEmpty(app).flatMap { notAnApp.contains($0.folded) ? nil : $0 }
        guard let name = given ?? namedApp(in: goal), !isMessagingApp(name), !OperatorAppCatalog.isMoneyApp(name),
              let query = searchQuery(goal, app: name) else { return nil }
        return (name, query)
    }

    /// The words to search for: quoted words first, else what follows the search verb, without the app's name.
    static func searchQuery(_ goal: String, app: String) -> String? {
        var q: String
        if let inQuotes = quoted(goal) {
            q = inQuotes
        } else {
            guard let m = searchVerb.firstMatch(in: goal, range: NSRange(goal.startIndex..., in: goal)),
                  let r = Range(m.range(at: 1), in: goal) else { return nil }
            q = String(goal[r])
            q = searchTail.stringByReplacingMatches(in: q, range: NSRange(q.startIndex..., in: q), withTemplate: "")
            q = withoutApp(q.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?")), app: app)
        }
        q = q.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?"))
        for filler in ["for me", "please"] where q.lowercased().hasSuffix(" " + filler) { q = String(q.dropLast(filler.count + 1)) }
        for filler in ["for ", "me "] where q.lowercased().hasPrefix(filler) { q = String(q.dropFirst(filler.count)) }
        q = q.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?'\"“”‘’"))
        let f = q.folded
        let words = f.split(separator: " ").map(String.init)
        guard let first = words.first, words.count <= 6, q.count <= 60, !notQueries.contains(f), !notQueryStarts.contains(first),
              !has(f, [app.folded]), squash(q) != squash(app),
              !OperatorSafety.asksForSecret(q), !OperatorSafety.looksLikeSecretValue(q) else { return nil }
        return q
    }

    /// "water in Uber Eats" → "water"; "Uber Eats for water" → "water". Unchanged when the app isn't named.
    private static func withoutApp(_ q: String, app: String) -> String {
        let range = NSRange(q.startIndex..., in: q)
        if let m = appAfter.firstMatch(in: q, range: range), let head = Range(m.range(at: 1), in: q),
           let tail = Range(m.range(at: 2), in: q), squash(String(q[tail])) == squash(app) {
            return String(q[head])
        }
        if let m = appBefore.firstMatch(in: q, range: range), let head = Range(m.range(at: 1), in: q),
           let tail = Range(m.range(at: 2), in: q), squash(String(q[head])) == squash(app) {
            return String(q[tail])
        }
        return q
    }

    /// A known app named in the goal: the longest name wins ("uber eats" over "uber"). Very short names (x) don't count.
    static func namedApp(in goal: String) -> String? {
        let g = goal.folded
        return OperatorAppCatalog.known.keys.filter { $0.count > 2 && has(g, [$0]) }.max { $0.count < $1.count }
    }

    /// Messaging apps: a search box there can reach people (or Meta AI), so the planner handles them.
    static func isMessagingApp(_ name: String) -> Bool {
        if let b = OperatorAppCatalog.knownBundle(name) ?? OperatorAppCatalog.cached(name),
           OperatorAppCatalog.messagingBundles.contains(b) { return true }
        return has(name.folded, ["whatsapp", "whats app", "messages", "imessage", "messenger", "mail", "gmail", "outlook",
                                 "telegram", "signal", "sms", "texts"])
    }

    /// Looking, not doing: "search water in Uber Eats", "what's on the menu at Pizza Express on Deliveroo". Nothing
    /// about buying, ordering, paying, booking or sending.
    static func isBrowseGoal(_ goal: String) -> Bool {
        let g = goal.folded
        return has(g, ["search", "look up", "look for", "look at", "find", "browse", "show me", "see", "check", "what",
                       "which", "how much", "price", "prices", "menu", "compare", "read"])
            && !has(g, doingWords)
    }

    /// Names compared without spaces or case: "UberEats" is "Uber Eats".
    static func squash(_ s: String) -> String { s.folded.replacingOccurrences(of: " ", with: "") }

    /// Words in quotes: “…”, "…", ‘…’ or «…».
    static func quoted(_ goal: String) -> String? {
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
        return nil
    }

    /// The words to type: quoted text first, else what follows "saying", "that", ":".
    static func extractMessage(_ goal: String) -> String? {
        if let t = quoted(goal) { return t }
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

    /// "FaceTime Amma", "can you facetime my grandson for me", "video call Priya on FaceTime" -> "Amma", "my grandson",
    /// "Priya". Nil for anything else ("open FaceTime", "FaceTime settings", two requests), or for "her" with nobody
    /// to mean: the model asks.
    static func faceTimeTarget(_ words: String) -> String? {
        let f = words.folded.replacingOccurrences(of: "face time", with: "facetime")
        guard f.contains("facetime"), !severalRequests(words) else { return nil }
        let lead = #"^(?:(?:please|can|could|would|will|you|kairos|hey|hi|ok|okay|just|i|want|wanna|to|d|like|need|go|ahead|now)\s+)*"#
        let tail = #"(?:\s+(?:please|now|for|me|us|thanks|thank|you|kairos|right|away|quickly|then))*$"#
        let forms = [lead + #"facetime\s+(?:call\s+)?(?:with\s+)?(.+?)"# + tail,
                     lead + #"(?:video\s+call|call|ring)\s+(.+?)\s+(?:on|using|with|over|through)\s+facetime"# + tail]
        for form in forms {
            guard let re = try? NSRegularExpression(pattern: form),
                  let m = re.firstMatch(in: f, range: NSRange(f.startIndex..., in: f)),
                  let r = Range(m.range(at: 1), in: f) else { continue }
            var who = String(f[r])
            if PeopleAgent.pronouns.contains(who) {
                guard let person = PeopleAgent.RecentPerson.shared.name else { return nil }
                who = person
            }
            let tokens = who.split(separator: " ")
            guard (1...4).contains(tokens.count),
                  !has(who, ["app", "settings", "setting", "call", "calls", "video", "audio", "and", "on", "in", "at",
                             "facetime", "it", "me", "is", "isn", "isnt", "working", "back"]) else { return nil }
            return who
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
        // "the last message in my WhatsApp" -> "in my": a preposition or possessive starts no name.
        if let first = words.first?.lowercased(),
           ["in", "on", "at", "of", "for", "from", "to", "into", "up", "my", "your", "our", "his", "her", "their", "this", "that"].contains(first) {
            return ""
        }
        if has(folded, ["whatsapp", "message", "messages", "chat", "text"]) || folded.hasPrefix("a ") || folded.hasPrefix("an ") { return "" }
        // Bits of the sentence, not a name ("but don't send it").
        if has(folded, ["but", "send", "don", "dont", "it", "please", "saying", "that", "and", "if", "when", "what", "is", "are"]) { return "" }
        // Times, not names: "on WhatsApp every few minutes", "on WhatsApp yet".
        if has(folded, ["every", "minute", "minutes", "hour", "hours", "now", "yet", "today", "tonight", "tomorrow",
                        "later", "soon", "again", "already", "still", "constantly", "always"]) { return "" }
        return s
    }

    // MARK: Watching over time (Kairos can't)

    /// "keep checking", "keep an eye on", "monitor my WhatsApp", "watch for a reply".
    private static let keepWatching = try! NSRegularExpression(pattern:
        #"\bkeep(?:s|ing)?\s+(?:on\s+)?(?:checking|check|watching|looking|monitoring|refreshing|tabs|an?\s+eye|an?\s+ear|an?\s+look\s?out)\b"#
        + #"|\bmonitor(?:s|ing)?\s+(?:(?:my|the)\s+)?(?:whatsapp|whats\s+app|messages|texts|emails?|inbox|phone|calls|prices?|it|them|for)\b"#
        + #"|\bwatch(?:es|ing)?\s+(?:(?:my|the)\s+)?(?:whatsapp|whats\s+app|messages|texts|emails?|inbox|phone)\b"#
        + #"|\bwatch(?:es|ing)?\s+(?:out\s+)?for\s+(?:a\s+|any\s+|new\s+)?(?:reply|replies|message|messages|text|texts|email|emails|call|calls)\b"#,
        options: [.caseInsensitive])
    /// "every few minutes", "every hour", "constantly": only watching when it goes with looking ("check WhatsApp
    /// every few minutes"), not "my phone buzzes every few minutes" or "keep the screen on constantly".
    private static let everyFew = try! NSRegularExpression(pattern:
        #"\bevery\s+(?:few\s+|couple\s+of\s+|other\s+|\d+\s+|one\s+|two\s+|three\s+|five\s+|ten\s+|fifteen\s+|twenty\s+|thirty\s+|half\s+(?:an?\s+)?)?(?:seconds?|minutes?|mins?|hours?|hrs?)\b"#
        + #"|\bevery\s+so\s+often\b|\bevery\s+now\s+and\s+(?:then|again)\b|\b(?:constantly|continuously|all\s+day|round\s+the\s+clock)\b"#,
        options: [.caseInsensitive])
    private static let lookingWords = ["check", "checking", "look", "looking", "read", "reading", "see", "refresh", "scan", "open"]
    /// "tell me when Amma replies", "let me know as soon as she's replied", "alert me if Ravi texts me": something
    /// that hasn't happened yet, to be noticed when it does. ("Let me know if Amma has replied" is a look now.)
    private static let tellMeWhen = try! NSRegularExpression(pattern:
        #"\b(?:tell|let|alert|notify|ping|warn|buzz|shout|wake)\s+(?:me|us)\s+(?:know\s+)?(?:straight\s+away\s+|right\s+away\s+)?"#
        + #"(?:(?:when|whenever|as\s+soon\s+as|the\s+moment|the\s+minute|the\s+second|once)\s+(?:\w+\s+){0,3}?"#
        + #"(?:replies|answers|responds|writes|messages|texts|emails|rings|calls|phones|(?:has|have|s)\s+(?:replied|answered|responded|written|messaged|texted|emailed|rung|called|phoned)"#
        + #"|(?:get|gets|receive|receives|there\s+is|there\s+s)\s+(?:a\s+|an\s+|any\s+)?(?:new\s+)?(?:text|texts|message|messages|email|emails|whatsapp|whatsapps|call|calls|missed\s+call|reply|replies|voicemail))"#
        + #"|if\s+(?:\w+\s+){0,3}?(?:replies|answers|responds|writes\s+back|messages\s+me|texts\s+me|emails\s+me|rings|calls))\b"#,
        options: [.caseInsensitive])

    private static func tellsWhenInTouch(_ folded: String) -> Bool {
        tellMeWhen.firstMatch(in: folded, range: NSRange(folded.startIndex..., in: folded)) != nil
    }

    /// The person wants something watched over time: "keep checking WhatsApp", "check it every few minutes", "tell me
    /// when Amma replies". Nothing in Kairos watches an app in the background: it only looks when the person asks.
    static func asksToKeepWatching(_ words: String) -> Bool {
        let f = words.folded
        let range = NSRange(f.startIndex..., in: f)
        if keepWatching.firstMatch(in: f, range: range) != nil || tellsWhenInTouch(f) { return true }
        return everyFew.firstMatch(in: f, range: range) != nil && has(f, lookingWords)
    }

    /// Their own messages, emails or calls on this phone ("message" and "text" alone are left out: they are also
    /// verbs, as in "text me when the price drops").
    private static let phoneMessageWords = ["whatsapp", "whats app", "whatsapps", "messages", "texts", "sms", "imessage",
                                            "imessages", "emails", "my email", "inbox", "mail app", "missed call",
                                            "missed calls", "voicemail", "voicemails", "my phone", "my calls", "signal",
                                            "telegram", "messenger"]

    static func namesPhoneMessages(_ words: String) -> Bool {
        has(words.folded, phoneMessageWords)
    }

    /// "Keep an eye on my WhatsApp and tell me as soon as Amma replies": their messages, watched over time. Kairos
    /// can't do that, so it says so (cannotWatchSay) instead of starting something that would look as if it were.
    /// A repeating reminder ("remind me every hour to check my messages") is the planner's, and an app's own
    /// notifications ("set WhatsApp to alert me when Amma messages") are a setting: neither is this.
    /// "Text Ravi I'm running late and let me know when he replies" isn't either: the text comes first, so the model
    /// sends it and says it can't watch for the reply (asksToWatchPhone still sees the watching part).
    static func wantsPhoneWatched(_ words: String) -> Bool {
        asksToWatchPhone(words) && !asksToSendOrCall(words)
    }

    /// Their messages or calls, watched over time, whatever else the words ask for.
    static func asksToWatchPhone(_ words: String) -> Bool {
        let f = words.folded
        guard asksToKeepWatching(f),
              !has(f, ["remind", "reminder", "reminders", "alarm", "alarms", "timer", "timers", "notification",
                       "notifications", "setting", "settings", "ringtone", "sound", "turn on", "switch on",
                       "set whatsapp", "set my phone", "make my phone", "make whatsapp"]) else { return false }
        // "tell me when the surgery rings", "… when I get a new text": someone getting in touch comes in on the phone.
        if namesPhoneMessages(f) || tellsWhenInTouch(f) { return true }
        // "keep checking and see if Amma replies": so does a reply.
        return has(f, ["replies", "replied", "answers", "answered", "responds", "responded", "writes back", "texts me",
                       "messages me", "emails me"])
    }

    /// "Text my daughter …", "WhatsApp Priya that …", "ring my son", "tell Amma …": an order to send or ring someone,
    /// at the start of the request or of one of its parts. Never "text me" or "ring me" (that's telling the person),
    /// and never a noun ("WhatsApp keeps buzzing", "message from Amma", "text messages").
    private static let sendOrCall = try! NSRegularExpression(pattern:
        #"(?:^|[,.;:!?]\s*|\b(?:and|then|also|but)\s+)"#
        + #"(?:(?:please|kairos|hey|hi|ok|okay|so|now|just|first|can\s+you|could\s+you|would\s+you|will\s+you|"#
        + #"i\s+(?:want|need|would\s+like)\s+you\s+to|i'?d\s+like\s+you\s+to)[\s,]+)*"#
        + #"(?:text|message|msg|send|whats\s?app|e-?mail|dm|reply\s+to|reply|write\s+to|tell|call|ring|phone|face\s?time|video\s+call|voice\s+call)"#
        + #"\s+(?!(?:me|us|myself|ourselves|keeps?|is|was|has|from|messages?|chats?|groups?|notifications?|app|number|"#
        + #"numbers|history|log|list|and|for|on|in)\b)(?!(?:an?\s+|another\s+|some\s+|my\s+|the\s+)?(?:agents?|workers?)\b)\w"#,
        options: [.caseInsensitive])

    /// The words ask to send someone something or ring them, before any watching they ask for: "Text Ravi I'm late
    /// and let me know when he replies" does, "keep an eye on WhatsApp and text Amma when Ravi replies" doesn't
    /// (that text waits on the watching, which Kairos can't do).
    static func asksToSendOrCall(_ words: String) -> Bool {
        let text = words.replacingOccurrences(of: "\u{2019}", with: "'")
        guard let m = sendOrCall.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text) else { return false }
        return !asksToKeepWatching(String(text[..<r.lowerBound]))
    }

    /// "Send Priya a WhatsApp saying happy birthday and let me know if she replies" → "Send Priya a WhatsApp saying
    /// happy birthday": the send, without the watching part Kairos can't do. The goal as it was when that can't be
    /// split off cleanly.
    static func withoutWatching(_ goal: String) -> String {
        guard asksToKeepWatching(goal), asksToSendOrCall(goal) else { return goal }
        var rest = goal
        for _ in 0..<3 where asksToKeepWatching(rest) {
            // The last ", " / " and " / " then " / "; " after which the words still ask to watch.
            var cuts: [String.Index] = []
            for mark in [",", ";", " and ", " then ", " but "] {
                var from = rest.startIndex
                while let r = rest.range(of: mark, options: .caseInsensitive, range: from..<rest.endIndex) {
                    cuts.append(r.lowerBound)
                    from = r.upperBound
                }
            }
            guard let cut = cuts.sorted(by: >).first(where: { asksToKeepWatching(String(rest[$0...])) }) else { break }
            rest = String(rest[..<cut]).trimmingCharacters(in: CharacterSet(charactersIn: " ,;:"))
        }
        return !rest.isEmpty && !asksToKeepWatching(rest) && asksToSendOrCall(rest) ? rest : goal
    }

    /// The honest answer, naming what they asked about, with what Kairos can do instead.
    static func cannotWatchSay(_ words: String) -> String {
        let f = words.folded
        let what: String
        if has(f, ["whatsapp", "whats app", "whatsapps"]) { what = "WhatsApp" }
        else if has(f, ["emails", "email", "inbox", "mail", "mail app"]) { what = "your email" }
        else if has(f, ["texts", "text", "messages", "message", "sms", "imessage", "imessages", "replies", "reply", "replied"]) {
            what = "your messages"
        }
        else if has(f, ["missed call", "missed calls", "calls", "call", "rings", "ring", "rang", "phones", "voicemail",
                        "voicemails"]) { what = "your calls" }
        else { what = "it" }
        return "I can't keep watching \(what) in the background: I can only look when you ask me. "
            + "Would you like me to check now, or set a reminder for you to ask me later?"
    }

    /// "Open WhatsApp and read me Amma's message" (or "check WhatsApp and read me …") is one request: it is opened to
    /// be read. "Set an alarm for 7 and read me what Amma said" or "check WhatsApp and remind me at 7" are two, so the
    /// rules leave them to the model.
    private static let readOpener = try! NSRegularExpression(pattern:
        #"^\s*(?:(?:please|kairos|hey|ok|okay|can\s+you|could\s+you|will\s+you)[\s,]+)*(?:open|go\s+to|go\s+into|go\s+on|look\s+at|look\s+in|check\s+on|check)"#
        + #"\s+(?:up\s+)?(?:my\s+|the\s+)?whats\s?app(?:\s+app)?\s*,?\s+(?:and\s+then|and|then)\s+(?=(?:read|show|check|see|look|what|whats|what's)\b)"#,
        options: [.caseInsensitive])

    static func severalRequests(_ words: String) -> Bool {
        var rest = words.replacingOccurrences(of: "\u{2019}", with: "'")
        if let m = readOpener.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
           let r = Range(m.range, in: rest) {
            rest.removeSubrange(r)
        }
        return PlannerWords.severalRequests(rest)
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
        // A message box, never the search box (newer WhatsApp's Chats search is a TextView too).
        let hasComposer = composer(s) != nil
        let buttons = s.elements.filter { $0.kind == "Button" }
        if hasComposer || (buttons.contains { $0.label == "Voice message" }
                           && buttons.contains { $0.label == "Attach" || $0.label == "Share media" }) {
            return .chat
        }
        if OperatorSafety.screenAsksForSecret(s) { return .secret }
        if buttons.contains(where: { ["agree", "accept", "i agree", "agree and continue"].contains($0.label.folded) }) {
            return .terms
        }
        let box = s.elements.first(where: \.isSearchBox)
        if box != nil, searching(s) { return .search }
        // The Chats screen's own title above its search box (skills/whatsapp/SCREENS.md wa.chats_list), not the tab
        // bar's Chats button, which also shows on Updates, Calls and Settings, nor search results' "Chats" heading.
        if let box, s.elements.contains(where: { ($0.label.folded == "chats" || $0.ident.folded == "chats")
                                                 && ["NavigationBar", "StaticText"].contains($0.kind) && $0.y <= box.y }) {
            return .chatsList
        }
        let closers = ["not now", "later", "maybe later", "skip", "close", "got it", "ok", "continue"]
        for word in closers {
            if let b = buttons.first(where: { $0.label.folded == word }) { return .interstitial(b.index) }
        }
        return .unknown
    }

    /// Search is open: its Cancel (older WhatsApp) or the search page's own Back button, a way out ready() can tap.
    /// Not the keyboard or words left in the box: the Chats list can show those too.
    static func searching(_ s: ScreenDigest) -> Bool {
        s.elements.contains { $0.kind == "Button" && ($0.label.folded == "cancel" || $0.ident == "AISearch_PaperPlane_Back_Button") }
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
        case .openApp, .appSearch:
            return .needsModel("That isn't a WhatsApp procedure.")   // AppSearchSkill runs these
        }
    }

    // P0: get WhatsApp to the Chats list.
    enum Ready {
        case list(ScreenDigest)
        case stop(OperatorSkillOutcome)
    }

    /// WhatsApp opens where it was left: a chat, a group's description, settings, a status. Get back to Chats a
    /// step at a time (the Chats tab, else Back), and when that fails, start WhatsApp afresh (it opens on Chats).
    func ready() async throws -> Ready {
        try await d.open(bundle: Self.bundle, name: "WhatsApp")
        var s = try await d.read()
        var seen = Set<UInt64>()
        /// Lost: start WhatsApp afresh (once per run), unless something is being typed or a call is on.
        func restart() async -> Bool {
            guard !d.outOfTime, !OperatorDriver.typingOn(s) else { return false }
            do { try await d.restart(bundle: Self.bundle, name: "WhatsApp") } catch { return false }
            return true
        }
        for _ in 0..<7 {
            if d.outOfTime { return .stop(.needsModel("Out of time getting to the Chats list.")) }
            // Back on a screen already seen: going back isn't getting anywhere (a header that opens info, Edit/Done).
            if !seen.insert(s.fingerprint).inserted, Self.classify(s) != .chatsList {
                guard await restart() else { return .stop(.needsModel("Not on the Chats list.")) }
                s = try await d.read()
                continue
            }
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
                // Going back keeps a draft (WhatsApp saves it); only a restart could lose it, and restart() checks.
                if await goBack(s) { break }
                guard await restart() else { return .stop(.needsModel("Inside a chat; need the Chats list.")) }
            case .search:
                // Cancel, or on newer WhatsApp (no Cancel) the search page's Back; else start WhatsApp afresh.
                if let cancel = s.find(["Cancel"], kinds: ["Button"], exactOnly: true).first ?? Self.backButton(s),
                   case .done = await d.tap(cancel, in: s) { break }
                guard await restart() else { return .stop(.needsModel("Search is open; need the Chats list.")) }
            case .otherApp:
                return .stop(.needsModel("WhatsApp didn't come to the front."))
            case .unknown:
                // A tab bar shows Chats: tap it. Deeper in (a group's info, settings), there is no tab bar: go back.
                // Something typed here (an edit, a new group's name) is the person's: don't back out of it.
                if let tab = s.find(["Chats"], kinds: ["Button"], exactOnly: true).last, case .done = await d.tap(tab, in: s) { break }
                if OperatorDriver.typingOn(s) { return .stop(.needsModel("Something is being typed on this screen; need the Chats list.")) }
                if await goBack(s) { break }
                guard await restart() else { return .stop(.needsModel("Not on the Chats list.")) }
            }
            s = try await d.read()
        }
        if Self.classify(s) == .chatsList { return .list(s) }
        if await restart() {
            s = try await d.read()
            if Self.classify(s) == .chatsList { return .list(s) }
        }
        return .stop(.needsModel("Couldn't get to the Chats list."))
    }

    /// One screen back: the top-left Back button (never Cancel, Done, Edit or Save, which change things), or the
    /// iOS edge swipe. True if the screen changed.
    private func goBack(_ s: ScreenDigest) async -> Bool {
        let changes = ["cancel", "done", "close", "edit", "save", "delete", "more", "camera", "new chat", "compose", "add"]
        if let b = Self.backButton(s) ?? s.elements.first(where: {
            $0.kind == "Button" && $0.y < 150 && $0.x < 80 && !$0.label.isEmpty && !changes.contains($0.label.folded)
        }) {
            if case .done(let changed) = await d.tap(b, in: s) { return changed != false }
            return false
        }
        if case .done(let changed) = await d.swipeBack() { return changed != false }
        return false
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
            guard var field = list.elements.first(where: \.isSearchBox) else { return .stop(.needsModel("No search field on the Chats list.")) }
            var searchPage = list
            // Newer WhatsApp: the box (a TextView under its "Ask Meta AI or Search" button) opens a search page first.
            // Tap it, then type into the box on that page.
            if field.kind != "SearchField" {
                switch await d.tap(field, in: list) {
                case .done: break
                case .refused(let why), .failed(let why): return .stop(.needsModel(why))
                case .declined(let why): return .stop(.finished(OperatorFinish(ok: false, say: why)))
                }
                searchPage = try await d.read()
                guard let box = searchPage.elements.first(where: \.isSearchBox) else {
                    return .stop(.needsModel("Tapped the search box; no search box to type in."))
                }
                field = box
            }
            switch await d.type(person, into: field, in: searchPage) {
            case .done: break
            case .refused(let why), .failed(let why): return .stop(.needsModel(why))
            case .declined(let why): return .stop(.finished(OperatorFinish(ok: false, say: why)))
            }
            current = try await d.read()
            if Self.classify(current) != .search, Self.classify(current) != .chatsList {
                return .stop(.needsModel("Typed the name into search; the screen looks different."))
            }
            let found = ScreenNames.match(Self.searchResults(current), name: person)
            let pick = found.exact.count == 1 ? found.exact : (found.exact.isEmpty ? found.prefix : found.exact)
            if pick.count == 1 {
                target = pick[0]
            } else {
                if let cancel = current.find(["Cancel"], kinds: ["Button"], exactOnly: true).first ?? Self.backButton(current) {
                    _ = await d.tap(cancel, in: current)
                }
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

    /// The chats and people a search found (newer WhatsApp: ChatListSearchView_ChatResult, labelled with the chat's
    /// name): above the "Messages" heading, never a message found inside a chat, never Meta AI.
    static func searchResults(_ s: ScreenDigest) -> [ScreenElement] {
        let messagesHeader = s.elements.first { $0.kind != "Cell" && $0.label.folded == "messages" }?.y ?? .infinity
        return s.elements.filter { $0.kind == "Cell" && $0.y < messagesHeader && !$0.ident.hasSuffix("_MessageResult")
                                   && !$0.fullText.localizedCaseInsensitiveContains("Meta AI") }
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
                                            "stickers", "scroll to bottom", "jump to bottom", "online", "add", "plus",
                                            "share media", "gifs and stickers"]

    /// The message box: the LOWEST one on the chat screen (never the search box). A message whose text is written to
    /// look like a page_source row can add a fake "TextView" higher up (over the Audio call button); the real composer
    /// is at the bottom.
    static func composer(_ s: ScreenDigest) -> ScreenElement? {
        s.elements.filter(\.isMessageBox).max { $0.y < $1.y }
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

    /// The Chats list's rows, one line each, newest first: never the filter chips (All, Unread…) or the Archived row.
    static func chatRows(_ s: ScreenDigest) -> [String] {
        s.elements.compactMap { e -> String? in
            guard e.kind == "Cell", e.ident != "ChatListView_chipButtonsCell", e.ident != "ChatListView_archiveCell",
                  e.label.folded != "archived" else { return nil }
            let line = chatRow(e) ?? e.fullText
            return line.isEmpty ? nil : line
        }
    }

    /// Newer WhatsApp names a row by the chat and puts what VoiceOver reads in its value ("Your message, On my way,
    /// 7:17 PM, Sent to Amma, Delivered", "message, Did you eat?, 6:00 PM, Received from Amma"). As a line:
    /// "Amma, Did you eat?, 6:00 PM", and the person's own last message "You to Amma, On my way, 7:17 PM". An unread
    /// chat's "3 unread messages" (in its label, after the name) goes last: "Amma, Did you eat?, 6:00 PM, 3 unread
    /// messages". Nil for any other row, which is read as it is.
    private static func chatRow(_ e: ScreenElement) -> String? {
        // "7:17 PM" has a narrow no-break space in it.
        var parts = e.value.replacingOccurrences(of: "\u{202F}", with: " ").components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let end = parts.lastIndex(where: { $0.hasPrefix("Sent to ") || $0.hasPrefix("Received from ") || $0.hasPrefix("Received in ") }),
              end >= 2 else { return nil }
        let unread = (e.label.components(separatedBy: ", ").dropFirst() + parts[(end + 1)...])
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.folded.contains("unread") }
        parts.removeSubrange(end...)
        let kind = parts.removeFirst()
        let name = e.primaryText
        let head: [String]
        if kind == "Your message" { head = ["You to \(name)"] }
        else if kind.hasPrefix("Your ") { head = ["You to \(name)", kind] }
        else if kind == "message" { head = [name] }
        else if kind.hasPrefix("Message from ") { head = ["\(kind.dropFirst(13)) in \(name)"] }
        else { head = [name, kind] }
        return (head + parts + unread).joined(separator: ", ")
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }
}

// MARK: - Any app: open it, or use its own search

/// "Open Uber" and "search water in Uber Eats" with no model calls: open the app; for a search, find its search box
/// (through its Search or Browse tab or button when there's no box yet), type the person's words, press Search, and
/// hand what came up to the reader. On any screen it doesn't expect, the planner carries on from there. Every tap
/// and every typed word goes through the driver's safety rules, as always.
struct AppSearchSkill {
    let d: OperatorDriver

    /// Open the app, then one quick look that it really came to the front (a hidden or locked app asks for Face ID
    /// first). Nothing else: opening it was the goal.
    func open(_ app: String) async throws -> OperatorSkillOutcome {
        guard let bundle = try await d.resolveApp(app) else {
            return .finished(OperatorFinish(ok: false, say: "I couldn't find an app called \(app) on this phone."))
        }
        do {
            try await d.open(bundle: bundle, name: app)
        } catch let problem as OperatorProblem {
            throw problem
        } catch {
            return .finished(OperatorFinish(ok: false, say: "I couldn't open \(app). " + OperatorDriver.describe(error)))
        }
        let shown = OperatorAppCatalog.displayName(bundle, fallback: app)
        if let front = await d.frontBundle(), front != bundle {
            return .finished(OperatorFinish(ok: true, say: "I opened \(shown), but it isn't showing yet. If your iPhone asks for Face ID or your passcode, please do that yourself.",
                                            leaveInApp: true, asked: true))
        }
        return .finished(OperatorFinish(ok: true, say: "\(shown) is open.", leaveInApp: true))
    }

    func search(_ query: String, in app: String) async throws -> OperatorSkillOutcome {
        guard let bundle = try await d.resolveApp(app) else {
            return .finished(OperatorFinish(ok: false, say: "I couldn't find an app called \(app) on this phone."))
        }
        try await d.open(bundle: bundle, name: app)
        let shown = OperatorAppCatalog.displayName(bundle, fallback: app)
        var s = try await settledRead()
        if let stop = blocker(s, bundle: bundle, shown: shown) { return stop }
        // 1. The search box, or what opens it: a Search or Browse tab or button (at most two taps, each one once).
        var box = Self.searchBox(s, afterOpening: false)
        var tapped = Set<String>()
        for _ in 0..<2 where box == nil {
            guard let opener = Self.searchOpener(s, skipping: tapped) else { break }
            if let stop = await d.stopIfOutOfTime() { return .finished(stop) }
            tapped.insert(Self.key(opener))
            switch await d.tap(opener, in: s) {
            case .done: break
            case .declined(let why): return .finished(OperatorFinish(ok: false, say: why))
            case .refused(let why), .failed(let why): return .needsModel(why)
            }
            s = try await settledRead()
            if let stop = blocker(s, bundle: bundle, shown: shown) { return stop }
            box = Self.searchBox(s, afterOpening: true)
        }
        guard let box else { return .needsModel("Couldn't find the search box in \(shown).") }
        // 2. The person's words, then Search (the box was found through the app's search, so Return searches).
        if let stop = await d.stopIfOutOfTime() { return .finished(stop) }
        switch await d.type(query, into: box, in: s, submit: true, searchBox: true) {
        case .done: break
        case .declined(let why): return .finished(OperatorFinish(ok: false, say: why))
        case .refused(let why), .failed(let why): return .needsModel(why)
        }
        // 3. What came up, for the reader to answer from.
        s = try await settledRead()
        if let stop = blocker(s, bundle: bundle, shown: shown) { return stop }
        let lines = s.readableLines.filter { $0.folded != query.folded }
        guard !lines.isEmpty else { return .needsModel("Searched \(shown), but nothing readable came up yet.") }
        return .read(title: "\(shown) search results for “\(query)”", lines: lines)
    }

    /// A read that waits out a page still drawing: read() already gives a blank page a moment and a second look;
    /// still nearly empty and loading, one more read. Never with words read by OCR before (fresh).
    private func settledRead() async throws -> ScreenDigest {
        let s = try await d.read(fresh: true)
        guard s.loading, s.elements.count < 4 else { return s }
        return try await d.read(fresh: true)
    }

    /// A screen this procedure doesn't go on from by itself: a bank's app, an alert over the app, another app in front.
    private func blocker(_ s: ScreenDigest, bundle: String, shown: String) -> OperatorSkillOutcome? {
        if OperatorAppCatalog.isMoneyApp(s.bundleID + " " + s.appName) {
            return .finished(OperatorFinish(ok: false, say: OperatorRun.moneySay))
        }
        if s.systemAlert { return .needsModel("A message box is covering \(shown).") }
        if !s.bundleID.isEmpty, s.bundleID != bundle { return .needsModel("\(shown) isn't the app in front.") }
        return nil
    }

    /// The search box: a search field, else a search box of another kind or a text field that says search. Just after
    /// tapping Search, the only text field on the screen is it too. Never a secret field, and never a text view that
    /// isn't a search box (that's where messages are written).
    static func searchBox(_ s: ScreenDigest, afterOpening: Bool) -> ScreenElement? {
        let boxes = s.elements.filter { ($0.isSearchBox || $0.kind == "TextField") && !OperatorSafety.isSecretField($0) }
        if let field = boxes.first(where: { $0.kind == "SearchField" }) ?? boxes.first(where: { $0.isSearchBox || saysSearch($0) }) { return field }
        return afterOpening && boxes.count == 1 ? boxes[0] : nil
    }

    static func saysSearch(_ e: ScreenElement) -> Bool {
        (e.label + " " + e.ident + " " + e.value).folded.contains("search")
    }

    /// What opens the search: a Search or Browse tab or button (its exact name first, then one whose name starts
    /// with "Search" or whose identifier says search), else one read off the screen. Never a text box (those are
    /// typed into), and never anything that clears or deletes (Clear search history).
    static func searchOpener(_ s: ScreenDigest, skipping: Set<String>) -> ScreenElement? {
        let pool = s.elements.filter { e in
            let words = (e.label + " " + e.ident).folded
            return !e.isTextInput && !skipping.contains(key(e))
                && !AppSkills.has(words, ["clear", "delete", "remove", "history", "cancel", "recent", "recents"])
        }
        let names = ["search", "browse"]
        let controls: Set<String> = ["Button", "Tab"]
        return pool.first { controls.contains($0.kind) && names.contains($0.label.folded) }
            ?? pool.first { controls.contains($0.kind) && ($0.label.folded.hasPrefix("search ") || $0.ident.folded.contains("search")) }
            ?? pool.first { $0.kind == "Other" && names.contains($0.label.folded) }
            ?? pool.first { $0.kind == "OCRText" && names.contains($0.label.folded) }
    }

    /// One control, for "already tapped": its kind, name and identifier.
    static func key(_ e: ScreenElement) -> String { e.kind + "|" + e.label.folded + "|" + e.ident }
}
