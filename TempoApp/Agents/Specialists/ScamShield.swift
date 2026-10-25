import Foundation

// Scam Shield on the iPhone: fixed rules, no model, so it answers at once and works in airplane mode.
//
// Ported from:
//  - tempo-hub/navigator/scamshield.py: the PRESSURE regexes, BIG_ASKS, ADVICE and the rule "likely scam if
//    there's a big ask or two signs, be careful if there's one".
//  - Tempo/packages/tempo_core/scam.py: the levels and the rule that matters most, never say "safe". The best
//    answer is "I didn't spot the usual scam signs", because a good scam is built to look normal.
//  - tempo-hub/guardian/threats.py: remote-access apps, "Hi Mum" new-number messages, parcel-fee texts, fake
//    refunds and prizes, threats of arrest, and links.
//  - tempo-hub/agents/document_interpreter/safety.py: "confirm your details" and official bodies using mobile numbers.
//
// Used by ScamShieldAgent (check_scam, call_159) and by MoneyAgent, which runs these rules on the person's words
// and on any letter or message in the conversation before it helps with a payment.

// MARK: - Verdicts

/// One warning sign the rules found, in plain words.
struct ScamShieldSign: Sendable, Equatable {
    /// Stable id: "safe_account", "code", "hi_mum_money" ...
    var id: String
    /// The short label (navigator's names): "a 'safe account'".
    var name: String
    /// For a sentence: "it talks about a 'safe account'".
    var because: String
    /// What to do about this sign, in one or two short sentences.
    var advice: String
    /// On its own this means "likely scam" (navigator's BIG_ASKS).
    var bigAsk = false
    /// Only counts next to another sign (a link is normal on its own).
    var soft = false
    /// Ringing 159 (Stop Scams UK, which puts you through to your own bank) is the right next step.
    var aboutBank = false
}

enum ScamShieldLevel: String, Sendable {
    case likelyScam = "likely_scam"
    case caution = "caution"
    case noFlags = "no_flags"  // never "safe"

    /// How the verdict is put to the person.
    var words: String {
        switch self {
        case .likelyScam: return "likely scam"
        case .caution: return "be careful"
        case .noFlags: return "looks normal"
        }
    }
}

struct ScamShieldVerdict: Sendable {
    var level: ScamShieldLevel
    /// Every sign found, the big asks first.
    var signs: [ScamShieldSign]
    /// What to do, in plain words.
    var advice: String
    /// Kairos should offer to ring 159.
    var offer159: Bool

    var refuse: Bool { level == .likelyScam }
}

// MARK: - The rules

enum ScamShieldRules {

    // MARK: Word lists (navigator's _DEADLINE, _CODES and _SECRECY, extended from the Guardian catalogue)

    static let deadlineWords = #"within (?:\d+|one|two|24) (?:hours?|minutes?)|act now|right now|immediately|urgent(?:ly)?|today only|before (?:midnight|the deadline)|or (?:it|your account) will be (?:closed|frozen|blocked)|last chance|expires? (?:today|tonight)|don'?t delay|time is running out"#
    static let codeWords = #"one[- ]time (?:pass)?code|one[- ]time password|otp|\bpin\b|password|security code|passcode|verification code|card (?:number|details)|cvv|memorable (?:word|answer|information)|what'?s the code|the (?:6|six)[- ]digit (?:code|number)|read (?:me|out|back|them|us|him|her) (?:the |your )?(?:code|number|digits|pin)"#
    static let secrecyWords = #"\b(?:don'?t|do not) tell\b|\bkeep (?:this|it) (?:secret|quiet|between us|confidential)\b|\bnot to tell\b|\btell no ?one\b|\bdon'?t mention\b|\bsay nothing\b|\bif (?:they|the bank|anyone) asks?,? (?:just )?say\b|\bthis call is confidential\b"#

    // MARK: Patterns

    static let safeAccount = rx(#"\bsafe account\b|\bsecure account\b|\bholding account\b|\bsafe ?keeping account\b|\bnew account (?:we|i)'?ve (?:set up|opened)\b"#)
    static let moveSavings = rx(#"\b(?:move|transfer|empty)\b.{0,30}\b(?:all (?:my|the|your) money|your money|your funds|savings|everything|whole balance)\b"#)
    static let giftCrypto = rx(#"\b(?:gift ?cards?|itunes|steam (?:cards?|vouchers?)|google play (?:cards?|vouchers?)|voucher codes?|bitcoin|crypto(?:currency)?|usdt|binance)\b"#)
    /// Paying or buying, as opposed to being offered something.
    static let paying = rx(#"\b(?:buy|bought|pay|paid|paying|purchase|send|sent|top up|load|transfer)\b"#)
    static let deadline = rx(#"\b(?:"# + deadlineWords + #")\b"#)
    static let codes = rx(#"\b(?:"# + codeWords + #")\b"#)
    /// Someone asking for the code, not just a bank's own "never share this code" text.
    static let codeAsk = rx(#"\b(?:read|tell|give|send|share|say)\b(?: it| that| this)?(?: back)? (?:to )?(?:me|us|them|him|her|the caller)\b|\bwhat'?s the code\b|\bread (?:me|out|back|them|us)\b|\b(?:need|want|wants|asks?|asking|asked) (?:for )?(?:the |your |a )?(?:code|pin|password|passcode|otp)\b|\b(?:confirm|verify|enter|type) (?:the |your )?(?:code|pin|password|passcode|card)\b"#)
    static let codeWarning = rx(#"\b(?:never|do not|don'?t) (?:share|give|tell|disclose|pass on|read out)\b|\bwe(?: will|'?ll) never (?:ask|call)\b"#)
    static let secrecy = rx(secrecyWords)
    static let authority = rx(
        // navigator: the person describing who pushed them
        #"\b(?:the bank|my bank|fraud (?:team|department)|the police|hmrc|tax office|amazon|microsoft|bt|royal mail)\b.{0,40}\b(?:told|said|asked|called|rang|phoned|texted|instructed|needs? me|wants? me)\b|\b(?:told|asked|instructed) (?:me )?(?:by|from) (?:the bank|my bank|the police|hmrc)\b|"#
        // the message itself claiming to be them
        + #"\b(?:this is|we are|we'?re|i am|i'?m|calling from|call from|message from|on behalf of) (?:your bank|the bank|(?:the )?(?:metropolitan )?police|hmrc|hm revenue|(?:the )?tax office|(?:the |your bank'?s )?fraud (?:team|department)|(?:the )?dvla|(?:the )?dwp|(?:the )?national crime agency|microsoft|apple|amazon|bt)\b|"#
        + #"\b(?:bank security team|police officer|detective (?:constable|sergeant|inspector)|national crime agency)\b|\bhmrc\b.{0,80}\b(?:owe|arrears|arrest|fine|penalty|legal action|unpaid)\b"#)
    static let stranger = rx(#"\b(?:someone i (?:met|matched with) online|my new (?:boyfriend|girlfriend|friend|partner) online|an? (?:investment|trading|crypto) (?:adviser|advisor|manager|expert) (?:i met )?online|(?:i'?ve|i have) never met (?:him|her|them) in person|met (?:him|her|them) on (?:facebook|instagram|tiktok|whatsapp|tinder|a dating (?:app|site)))\b|\bmet\b.{0,30}\bonline\b"#)
    static let remoteAccess = rx(#"\b(?:anydesk|any desk|teamviewer|team viewer|quick ?support|remote (?:access|desktop|support|control)|logmein|rustdesk|supremo|ultraviewer)\b|\binstall (?:this|the|an|a) app so (?:i|we) can\b|\blet (?:me|us) (?:control|access|into) your (?:phone|screen|computer|device|laptop)\b"#)
    static let screenShare = rx(#"\bscreen ?shar(?:e|ing)\b|\bshare (?:my|your) screen\b|\blet (?:me|us) see your (?:phone|screen|computer)\b"#)
    static let familyGreeting = rx(#"\b(?:hi|hello|hey|hiya)\s+(?:mum|mom|mam|mummy|dad|daddy|nan|nana|nanna|gran|grandma|grandad|granny|grandpa|papa|amma|abba|ammi)\b"#)
    static let familyWord = rx(#"\b(?:mum|mom|mam|dad|nan|gran|grandma|grandad|granny|grandpa)\b|\bit'?s (?:me|your (?:son|daughter|child|grandson|granddaughter))\b"#)
    static let newNumber = rx(#"\b(?:(?:this is|it'?s) my new (?:number|phone)|new number|new phone|(?:lost|dropped|broke|smashed|damaged|cracked) (?:my|his|her|their) phone|(?:my )?phone (?:is |was |got )?(?:broken|smashed|lost|stolen|dead)|can'?t (?:talk|call|speak)(?: right now| at the moment)?|delete (?:my|the) old number|save (?:this|my new) number)\b"#)
    static let moneyAsk = rx(#"\b(?:send|transfer|lend|borrow|pay|need|help)\b.{0,40}(?:\bmoney\b|\bcash\b|£|\bpounds?\b|\bquid\b|\bbills?\b|\brent\b|\bpayment\b)"#)
    static let oddPayment = rx(#"\b(?:western union|moneygram)\b|\bcourier (?:will |to |is going to )?(?:collect|pick up|come)\b|\bhand (?:it|them|the (?:cash|money|card|cards)|your (?:card|cards|cash)) (?:over )?to (?:a|the|our) courier\b"#)
    static let parcelFee = rx(#"\b(?:parcel|package|delivery|shipment|evri|hermes|royal mail|dpd|yodel|dhl|ups|fedex|post office)\b.{0,60}\b(?:fee|redeliver\w*|re-delivery|unpaid|customs|held|pay\s?£?\d)|\b(?:missed (?:your )?delivery|couldn'?t deliver|could not deliver|unable to deliver|redelivery fee)\b"#)
    static let confirmDetails = rx(#"\b(?:verify|confirm|update|re-?enter|validate) (?:your|the) (?:bank |card |account |payment |billing |personal |security |login )?(?:details|information|info|identity|account)\b|\breply with your\b|\b(?:send|give) (?:us|me) your (?:bank|card|account) details\b"#)
    static let threat = rx(#"\b(?:arrest(?:ed)?|prison|jail|deport(?:ed|ation)?|warrant|bailiffs?|legal action|prosecut\w*|court action)\b"#)
    static let accountAlarm = rx(#"\b(?:account|card) (?:has been|will be|is|was|is being) (?:suspended|closed|frozen|compromised|hacked|locked|blocked|restricted|cancelled)\b|\bsomeone (?:has|is|was) (?:using|accessed|trying to access|tried to use) your (?:account|card)\b|\b(?:suspicious|unusual) (?:activity|transaction|login|payment|sign[- ]in)\b"#)
    static let reward = rx(#"\byou(?:'ve| have) (?:won|been selected|been chosen)\b|\brefund (?:is )?(?:due|waiting|owed|pending|of £?\d)|\btax (?:refund|rebate)\b|\bcompensation (?:is )?(?:due|owed|waiting)\b|\bclaim your\b|\bprize\b|\bfree gift\b|\bguaranteed (?:returns?|profits?|income)\b|\bdouble your (?:money|investment)\b|\b\d{1,3} ?% (?:a|per|every) (?:month|week|day)\b|\breturns? of \d{1,3} ?%"#)
    static let investment = rx(#"\bguaranteed\b|\breturns?\b|\binvest\w*|\d ?%"#)
    static let officialWords = rx(#"\b(?:hmrc|hm revenue|dvla|dwp|nhs|council|royal mail|police|gov\.uk|bank|barclays|lloyds|hsbc|natwest|santander|nationwide|halifax|monzo|starling|tsb)\b"#)
    static let ukMobile = rx(#"(?<!\d)(?:07\d{3}\s?\d{3}\s?\d{3}|\+44\s?7\d{3}\s?\d{6})(?!\d)"#)
    static let link = rx(#"(?:https?://|www\.|bit\.ly/|tinyurl\.com|\bt\.co/|\b[a-z0-9][a-z0-9-]*\.(?:com|co\.uk|org\.uk|uk|net|org|info|top|xyz|online|site|link|click|shop|live)\b|\bclick (?:here|the link|on the link|this link)\b|\btap (?:here|the link|on the link|this link)\b|\bscan (?:this|the) (?:qr|code)\b)"#)
    static let bankWords = rx(#"\b(?:bank|banking|card|account|barclays|lloyds|hsbc|natwest|santander|nationwide|halifax|monzo|starling|tsb|revolut|first direct)\b"#)

    // MARK: Advice (navigator's and Tempo's ADVICE, in Kairos's voice)

    static let bankAdvice = "Your bank will never ask you to move money or share a code. Hang up or don't reply."
    static let codeAdvice = "Never share a code or password with anyone who asks for it, even if they say they're your bank."
    static let codeNoticeAdvice = "Never read it out or share it with anyone, even someone who says they're from your bank. If you didn't ask for a code, call your bank on the number on your card."
    static let rushAdvice = "There's no need to rush. Check with the company on a number you already trust first."
    static let noFlagsAnswer = "I didn't spot the usual scam signs, but if in doubt, call the company on a number you already trust."
    static let linkTip = " If it asks you to do something, use the company's own app or website, not the link."
    static let offer159Line = " Shall I ring 159 for you? It puts you through to your bank safely."
    /// navigator's ADVICE["likely_scam"], for refusing a payment.
    static let paymentAdvice = "This has the signs of a scam, so I won't help with this payment. Your bank will never ask you to move money to a 'safe account', read out a code, or pay in gift cards or crypto. Hang up, wait a few minutes, and call your bank on the number on your card, or call 159."
    /// navigator's ADVICE["caution"].
    static let cautionAdvice = "Slow down. Nobody genuine needs you to do this in a hurry or in secret. Check with the firm on a number you already trust first."
    /// Tempo's ADVICE[LIKELY_SCAM], when no sign has its own advice.
    static let genericLikelyAdvice = "Don't reply, click or pay. Call the firm on the number from its own website or your bank card, never one from the message."

    /// Which sign's advice to give when several are found (most protective first).
    static let advicePriority = ["safe_account", "move_savings", "remote_access", "hi_mum_money", "code", "odd_payment",
                                 "gift_crypto", "authority", "hi_mum", "parcel_fee", "confirm_details", "reward", "stranger",
                                 "official_mobile", "threat", "account_alarm", "screen_share", "code_notice", "secrecy", "deadline", "gift_offer", "link"]

    // MARK: Assess

    /// Which pressure signs the text shows. Links count only when `countLinks` (letters on paper often carry a website).
    static func signs(in raw: String, countLinks: Bool = true) -> [ScamShieldSign] {
        let t = clean(raw)
        guard !t.isEmpty else { return [] }
        let mentionsBank = has(bankWords, t)
        var out: [ScamShieldSign] = []

        // navigator's PRESSURE, in its order
        if has(safeAccount, t) {
            out.append(ScamShieldSign(id: "safe_account", name: "a 'safe account'", because: "it talks about a 'safe account'",
                                      advice: bankAdvice, bigAsk: true, aboutBank: true))
        }
        if has(moveSavings, t) {
            out.append(ScamShieldSign(id: "move_savings", name: "moving your savings", because: "it asks you to move your savings",
                                      advice: bankAdvice, aboutBank: true))
        }
        if has(giftCrypto, t) {
            if has(paying, t) {
                out.append(ScamShieldSign(id: "gift_crypto", name: "gift cards or crypto", because: "it wants paying in gift cards or crypto",
                                          advice: "Don't buy gift cards or crypto for anyone. No real company or official asks to be paid that way.",
                                          bigAsk: true))
            } else {
                // "You've won a gift card": a lure, not a payment. Counts only next to another sign (a genuine gift exists).
                out.append(ScamShieldSign(id: "gift_offer", name: "a gift card or crypto offer", because: "it offers gift cards or crypto",
                                          advice: "Don't tap or reply. Nobody gives away gift cards or crypto like this.", soft: true))
            }
        }
        if has(deadline, t) {
            out.append(ScamShieldSign(id: "deadline", name: "a deadline to act now", because: "it rushes you to act now", advice: rushAdvice))
        }
        var codeNotice = false
        if has(codes, t) {
            if has(codeWarning, t) && !has(codeAsk, t) {
                // A bank's own "here is your code, never share it" text. Not a big ask, but worth a word.
                codeNotice = true
                out.append(ScamShieldSign(id: "code_notice", name: "a security code", because: "it's a security code",
                                          advice: codeNoticeAdvice, aboutBank: true))
            } else {
                out.append(ScamShieldSign(id: "code", name: "a code or password", because: "it asks for a code or password",
                                          advice: codeAdvice, bigAsk: true, aboutBank: mentionsBank))
            }
        }
        if !codeNotice, has(secrecy, t) {
            out.append(ScamShieldSign(id: "secrecy", name: "secrecy", because: "it asks you to keep it secret",
                                      advice: "Talk to someone you trust before doing anything. Nobody genuine asks you to keep it secret."))
        }
        if let hit = first(authority, in: t) {
            out.append(authoritySign(hit))
        }
        if has(stranger, t) {
            out.append(ScamShieldSign(id: "stranger", name: "a stranger or someone just met", because: "it's from someone you only know online",
                                      advice: "Please don't send money to someone you haven't met in person. Talk to someone you trust first."))
        }

        // From the Guardian's catalogue and the letter checks
        if has(remoteAccess, t) {
            out.append(ScamShieldSign(id: "remote_access", name: "an app to control your phone",
                                      because: "it asks you to install an app that lets them control your phone or computer",
                                      advice: "Don't install anything they ask for, and hang up. Nobody honest needs to control your phone or computer.",
                                      bigAsk: true))
        } else if has(screenShare, t) {
            out.append(ScamShieldSign(id: "screen_share", name: "asking to see your screen", because: "it asks to see your screen",
                                      advice: "Don't share your screen with someone you don't know. Nobody honest needs to see it."))
        }
        let greeting = has(familyGreeting, t)
        let family = greeting || has(familyWord, t)
        let fromNewNumber = has(newNumber, t)
        let asksForMoney = has(moneyAsk, t)
        let familyAdvice = "Don't send anything yet. Call them on the number you already have for them first."
        if family && fromNewNumber && asksForMoney {
            out.append(ScamShieldSign(id: "hi_mum_money", name: "a 'new number' message from family asking for money",
                                      because: "it's a 'new number' message from family asking for money",
                                      advice: familyAdvice, bigAsk: true))
        } else if family && fromNewNumber {
            out.append(ScamShieldSign(id: "hi_mum", name: "a 'new number' message from family",
                                      because: "it says it's family, writing from a new number", advice: familyAdvice))
        } else if greeting && asksForMoney {
            out.append(ScamShieldSign(id: "hi_mum", name: "a message from family asking for money",
                                      because: "it says it's family and asks for money", advice: familyAdvice))
        }
        if has(oddPayment, t) {
            out.append(ScamShieldSign(id: "odd_payment", name: "an odd way to pay",
                                      because: "it wants money sent through a money transfer shop or handed to a courier",
                                      advice: "Don't send money that way or hand anything to a courier. No real bank or official asks for that.",
                                      bigAsk: true))
        }
        if has(parcelFee, t) {
            out.append(ScamShieldSign(id: "parcel_fee", name: "a parcel text asking for a fee", because: "it's a parcel message asking for a fee",
                                      advice: "Don't tap the link or pay the fee. Check your parcel in the shop's own app, and forward the text to 7726 to report it."))
        }
        if has(confirmDetails, t) {
            out.append(ScamShieldSign(id: "confirm_details", name: "asking you to confirm your details",
                                      because: "it asks you to confirm your details",
                                      advice: "Don't reply or tap any link. If you're worried, use the company's own app or call a number you already trust.",
                                      aboutBank: mentionsBank))
        }
        if has(threat, t) {
            out.append(ScamShieldSign(id: "threat", name: "a threat of arrest or legal action",
                                      because: "it threatens arrest or legal action",
                                      advice: "Don't let it frighten you into paying. Check with them on a number you already trust, like one on an old letter."))
        }
        if has(accountAlarm, t) {
            out.append(ScamShieldSign(id: "account_alarm", name: "an alarm about your account or card",
                                      because: "it says something is wrong with your account or card",
                                      advice: "Don't tap links or ring numbers from the message. Call your bank on the number on the back of your card.",
                                      aboutBank: true))
        }
        if has(reward, t) {
            out.append(ScamShieldSign(id: "reward", name: "a prize, refund or 'guaranteed' return",
                                      because: "it promises a prize, a refund or big returns",
                                      advice: has(investment, t)
                                        ? "Nobody can guarantee a return. Please don't send any money until you've talked to someone you trust."
                                        : "Don't tap or reply. Real refunds and prizes don't arrive like this."))
        }
        if has(officialWords, t), has(ukMobile, t) {
            out.append(ScamShieldSign(id: "official_mobile", name: "an official body using a mobile number",
                                      because: "it says it's official but gives a mobile number",
                                      advice: "Don't call that number. Use the number on an old letter or the official website instead."))
        }
        if countLinks, has(link, t) {
            out.append(ScamShieldSign(id: "link", name: "a link to tap", because: "it has a link to tap",
                                      advice: "Don't tap the link. Use the company's own app or website instead.", soft: true))
        }
        // Big asks first, then the other signs, then the soft ones; otherwise in the order found.
        return out.enumerated().sorted { a, b in
            let ra = a.element.bigAsk ? 0 : (a.element.soft ? 2 : 1)
            let rb = b.element.bigAsk ? 0 : (b.element.soft ? 2 : 1)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    /// navigator's assess(): a big ask, or two signs, is a likely scam; one sign is "be careful"; none is
    /// "no warning signs", never "safe".
    static func assess(_ raw: String, countLinks: Bool = true) -> ScamShieldVerdict {
        let found = signs(in: raw, countLinks: countLinks)
        let hard = found.filter { !$0.soft }
        let level: ScamShieldLevel
        if hard.contains(where: { $0.bigAsk }) || hard.count >= 2 || (hard.count == 1 && found.count >= 2) {
            level = .likelyScam
        } else if hard.count == 1 {
            level = .caution
        } else {
            level = .noFlags
        }
        let shown = level == .noFlags ? [] : found
        var advice: String
        switch level {
        case .noFlags:
            advice = noFlagsAnswer
        case .caution, .likelyScam:
            let pick = advicePriority.lazy.compactMap { id in shown.first(where: { $0.id == id }) }.first
            advice = pick?.advice ?? (level == .likelyScam ? genericLikelyAdvice : cautionAdvice)
        }
        let offer = level != .noFlags && shown.contains(where: { $0.aboutBank })
        if level == .noFlags, found.contains(where: { $0.id == "link" }) { advice += linkTip }
        return ScamShieldVerdict(level: level, signs: shown, advice: advice, offer159: offer)
    }

    /// The whole spoken answer for check_scam: verdict, the signs, what to do, and the offer to ring 159.
    static func answer(_ v: ScamShieldVerdict) -> String {
        switch v.level {
        case .noFlags:
            return v.advice
        case .likelyScam, .caution:
            let opener = v.level == .likelyScam ? "This looks like a scam" : "Be careful with this one"
            let reasons = listed(v.signs.prefix(3).map(\.because))
            return "\(opener): \(reasons). \(v.advice)" + (v.offer159 ? offer159Line : "")
        }
    }

    // MARK: Quick match ("Is this a scam? …")

    static let question = rx(#"\b(?:is|was|does) (?:this|that|it) (?:a |an )?(?:scam|con|fraud|fake|hoax)\b|\b(?:is|was) (?:this|that) (?:message |text |email |letter |call )?(?:real|genuine|legit|legitimate|for real|trustworthy|dodgy|kosher)\b|\b(?:is|was) (?:this|that|it) (?:really )?from (?:my|the) (?:bank|council|hmrc|post office|royal mail|police)\b|\b(?:can|should) i trust (?:this|that|it|them)\b|\bdoes (?:this|that|it) look (?:like a scam|real|genuine|dodgy|right|legit)\b|\b(?:a )?scam or not\b|\breal or (?:a )?(?:scam|fake)\b|\bcheck (?:this|that|it) for (?:a )?scams?\b|\bscam\s*\?|\bam i being scammed\b|\bis someone (?:trying to )?scam(?:ming)? me\b"#)
    static let leadIn = rx(#"^(?:(?:i|we) (?:just )?(?:got|received|had|have got|have) (?:this|a|an|the following) (?:text|message|email|e-mail|letter|call|phone call|whatsapp|voicemail)(?: (?:from|saying|that says)[^:]{0,40})?|(?:this|the|a) (?:text|message|email|letter) (?:says|said|reads)|it says|they said|someone (?:sent|texted|emailed|rang|called) (?:me|us)(?: this| saying)?|(?:can|could) you check (?:this|that)|please check (?:this|that)|check this)\s*[:,.\-]*\s*"#)
    /// A request for a reminder, alarm or calendar entry: the planner's job, even when it mentions a bill or the bank.
    static let planning = rx(#"\b(?:remind|reminder|alarm|timer|calendar|diary|appointment|schedule)\b"#)
    /// The person is describing someone else's words, not giving their own command.
    static let describesSomeone = rx(#"\b(?:someone|somebody|they|he|she|caller|a man|a woman|a lady|rang|called|phoned|texted|emailed|message|text|email|letter|voicemail|said|says|told|asked|asking|wants me|want me|wanted me)\b"#)

    /// check_scam's fast path. A pasted message with "is this a scam?" (or "is this real?") checks the pasted part;
    /// the question alone checks the last letter or message in the conversation, or asks for one. With no question,
    /// a description of someone pushing them that shows two or more signs goes straight to the rules too
    /// ("My bank rang, they want me to move my savings to a safe account and read them the code").
    static func quickMatch(_ words: String, documents: [String]) -> JSONValue? {
        let t = clean(words)
        guard !t.isEmpty else { return nil }
        if has(question, t) {
            var rest = replacing(question, in: t, with: " ")
            rest = clean(rest).trimmingCharacters(in: CharacterSet(charactersIn: " \"'?!.,:;-"))
            rest = replacing(leadIn, in: rest, with: "").trimmingCharacters(in: CharacterSet(charactersIn: " \"'?!.,:;-"))
            if rest.split(separator: " ").count >= 5 { return ["text": .string(rest)] }
            if let doc = documents.last { return ["text": .string(doc)] }
            return [:]
        }
        let v = assess(t)
        if v.level == .likelyScam, v.signs.filter({ !$0.soft }).count >= 2, has(describesSomeone, t) {
            return ["text": .string(t)]
        }
        return nil
    }

    // MARK: Helpers

    static func rx(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    static func first(_ r: NSRegularExpression?, in s: String) -> String? {
        guard let r, let m = r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let range = Range(m.range, in: s) else { return nil }
        return String(s[range])
    }

    static func has(_ r: NSRegularExpression?, _ s: String) -> Bool { first(r, in: s) != nil }

    static func replacing(_ r: NSRegularExpression?, in s: String, with template: String) -> String {
        guard let r else { return s }
        return r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// Curly quotes from the iPhone keyboard made straight, and all whitespace (newlines too) made single spaces.
    static func clean(_ text: String) -> String {
        let straight = text
            .replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        return straight.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// "a", "a and b", "a, b and c".
    static func listed(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    /// Who the message says it's from, for "someone says they're from your bank".
    static func authoritySign(_ hit: String) -> ScamShieldSign {
        let h = hit.lowercased()
        let who: String, kind: String
        if h.contains("fraud") || h.contains("bank") { (who, kind) = ("your bank", "bank") }
        else if h.contains("police") || h.contains("detective") || h.contains("crime agency") { (who, kind) = ("the police", "police") }
        else if h.contains("hmrc") || h.contains("hm revenue") || h.contains("tax office") { (who, kind) = ("HMRC", "official") }
        else if h.contains("dvla") { (who, kind) = ("the DVLA", "official") }
        else if h.contains("dwp") { (who, kind) = ("the DWP", "official") }
        else if h.contains("amazon") { (who, kind) = ("Amazon", "company") }
        else if h.contains("microsoft") { (who, kind) = ("Microsoft", "company") }
        else if h.contains("apple") { (who, kind) = ("Apple", "company") }
        else if h.contains("royal mail") { (who, kind) = ("Royal Mail", "company") }
        else if h.range(of: #"\bbt\b"#, options: .regularExpression) != nil { (who, kind) = ("BT", "company") }
        else { (who, kind) = ("an official body", "official") }
        let advice: String
        switch kind {
        case "bank": advice = bankAdvice
        case "police": advice = "The police will never ask you to move money or hand over your card. Hang up or don't reply."
        case "company": advice = "Don't reply or do what they ask. If you're worried, use the company's own app or website."
        default: advice = "Don't pay or reply. Check on gov.uk, or call a number from an old letter you trust."
        }
        return ScamShieldSign(id: "authority", name: "someone claiming to be the bank or police",
                              because: "someone says they're from \(who)", advice: advice, aboutBank: kind == "bank")
    }

    /// Every pattern, for selfTest(): a pattern that fails to compile silently never matches.
    static var allPatterns: [(String, NSRegularExpression?)] {
        [("safeAccount", safeAccount), ("moveSavings", moveSavings), ("giftCrypto", giftCrypto), ("deadline", deadline),
         ("codes", codes), ("codeAsk", codeAsk), ("codeWarning", codeWarning), ("secrecy", secrecy), ("authority", authority),
         ("stranger", stranger), ("paying", paying), ("planning", planning), ("remoteAccess", remoteAccess), ("screenShare", screenShare), ("familyGreeting", familyGreeting),
         ("familyWord", familyWord), ("newNumber", newNumber), ("moneyAsk", moneyAsk), ("oddPayment", oddPayment),
         ("parcelFee", parcelFee), ("confirmDetails", confirmDetails), ("threat", threat), ("accountAlarm", accountAlarm), ("reward", reward),
         ("investment", investment), ("officialWords", officialWords), ("ukMobile", ukMobile), ("link", link), ("bankWords", bankWords),
         ("question", question), ("leadIn", leadIn), ("describesSomeone", describesSomeone),
         ("yes", ScamShieldCall159Tool.yes), ("no", ScamShieldCall159Tool.no), ("call159", ScamShieldCall159Tool.explicit)]
    }

    // MARK: - Self test (run on macOS by the integrator)

    /// Fixed messages, scam and normal, with the verdict each must get. Returns one line per check and a summary
    /// line last; any line starting "FAIL" is a regression.
    static func selfTest() -> [String] {
        var lines: [String] = []
        var failed = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failed += 1 }
            lines.append((ok ? "PASS " : "FAIL ") + what)
        }
        for (name, pattern) in allPatterns { check(pattern != nil, "pattern compiles: \(name)") }

        let cases: [(String, ScamShieldLevel, Bool?)] = [  // message, level, offers 159 (nil = don't care)
            ("Your account is locked. Move your money to a safe account within 2 hours.", .likelyScam, true),
            ("My bank rang, they want me to move my savings to a safe account and read them the code.", .likelyScam, true),
            ("Hi Mum, this is my new number, I dropped my phone. Can you send me £300 for a bill today? Don't tell Dad.", .likelyScam, false),
            ("Royal Mail: your parcel is held due to an unpaid £1.45 fee. Pay at http://royalmail-redelivery.top", .likelyScam, nil),
            ("This is HMRC. You owe £640 in unpaid tax. Pay today or a warrant will be issued for your arrest.", .likelyScam, nil),
            ("Hello, I'm calling from Microsoft. Your computer has a virus. Please install AnyDesk so I can fix it.", .likelyScam, nil),
            ("Congratulations, you've won a £500 Tesco gift card! Claim your prize at bit.ly/xyz", .likelyScam, nil),
            ("I met a lovely man online, he's an investment adviser and promises guaranteed returns of 20% a month if I send him bitcoin.", .likelyScam, nil),
            ("Barclays: we've noticed unusual activity on your card. Please call us on the number on the back of your card.", .caution, true),
            ("Your one-time passcode is 482913. Never share this code with anyone. We will never call you to ask for it.", .caution, true),
            ("Hi Dad, can you pick me up from the station at 6?", .noFlags, false),
            ("Your Thames Water bill of £31.00 is due on 1 November. You can pay by direct debit or online.", .noFlags, false),
            ("Reminder: your GP appointment is on Tuesday 28 October at 10:30. Reply CANCEL to cancel.", .noFlags, false),
            ("Hi, it's Sarah from the book club. Lovely to see you on Thursday! The next one is at www.bookclub.org", .noFlags, false),
            ("Happy birthday Nan! I've put a little Marks and Spencer gift card in your card. Love, Ella", .noFlags, false),
        ]
        for (i, c) in cases.enumerated() {
            let v = assess(c.0)
            let said = answer(v)
            var ok = v.level == c.1
            if let offer = c.2 { ok = ok && v.offer159 == offer }
            let neverSafe = !said.lowercased().contains("it's safe") && !said.lowercased().contains("is safe")
                && !said.lowercased().contains("looks safe") && !said.lowercased().contains("you're safe")
            check(ok && neverSafe && !said.isEmpty,
                  "\(i + 1). \(v.level.words) [\(v.signs.map(\.id).joined(separator: ","))] \(c.0.prefix(50)) -> \(said)")
        }
        // The fast path pulls the pasted message out of the question.
        let pasted = quickMatch("I got this text: \u{201C}Your parcel could not be delivered, pay the £1.45 redelivery fee at evri-fee.top\u{201D} is this a scam?", documents: [])
        check(pasted?.text("text") == "Your parcel could not be delivered, pay the £1.45 redelivery fee at evri-fee.top",
              "quickMatch pulls out the pasted text: \(pasted?.text("text") ?? "nil")")
        check(quickMatch("Is this a scam?", documents: []) == [:], "a bare question with nothing to check asks for the message")
        check(quickMatch("Is this real?", documents: ["Your tax refund of £245 is waiting"])?.text("text") == "Your tax refund of £245 is waiting",
              "a bare question checks the last letter or message")
        check(quickMatch("I need to change my PIN right now", documents: []) == nil, "the person's own request is not checked as a scam")
        check(quickMatch("Set an alarm for 7 tomorrow morning", documents: []) == nil, "ordinary requests are left alone")
        check(has(ScamShieldCall159Tool.explicit, "ring my bank") && !has(planning, "ring my bank")
              && has(planning, "remind me to call my bank tomorrow"), "a reminder to ring the bank is left to the planner")
        check(assess("Pay the electricity bill £86.40").level == .noFlags, "an ordinary payment has no signs")
        check(assess("Final notice: pay within 7 days or we will take legal action. www.thameswater.co.uk", countLinks: false).level == .caution,
              "a letter's website is not counted as a sign")
        lines.append(failed == 0 ? "ScamShield self test: all \(lines.count) checks passed" : "ScamShield self test: \(failed) FAILED")
        return lines
    }
}

// MARK: - Short follow-ups ("Shall I ring 159?" "Yes.")

/// Remembers a question Kairos just asked (an offer to ring 159, "how much?"), so the person's short answer can be
/// handled by rules, offline. The answer only counts when it is the very next thing the person says, within 5 minutes.
enum ScamShieldFollowUp {
    static let window: TimeInterval = 300

    static func remember(_ key: String, ctx: TurnContext, payload: String = "") {
        let entry: [String: Any] = ["said": ctx.userWords, "time": ctx.now.timeIntervalSince1970, "payload": payload]
        UserDefaults.standard.set(entry, forKey: "kairos.followup." + key)
    }

    static func forget(_ key: String) { UserDefaults.standard.removeObject(forKey: "kairos.followup." + key) }

    /// The payload, when `words` is the person's first reply after Kairos asked.
    static func answer(_ key: String, words: String, ctx: TurnContext) -> String? {
        guard let entry = UserDefaults.standard.dictionary(forKey: "kairos.followup." + key),
              let said = entry["said"] as? String, let time = entry["time"] as? Double,
              ctx.now.timeIntervalSince1970 - time < window, ctx.now.timeIntervalSince1970 >= time - 1 else { return nil }
        let w = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, ctx.userWords.hasSuffix(w) else { return nil }
        var prior = String(ctx.userWords.dropLast(w.count))
        if prior.hasSuffix("\n") { prior.removeLast() }
        guard !prior.isEmpty, said == prior || said.hasSuffix("\n" + prior) else { return nil }
        return entry["payload"] as? String ?? ""
    }
}

// MARK: - The agent

struct ScamShieldAgent: SpecialistAgent {
    let id = "scam"
    let title = "Scam Shield"
    let icon = "shield.lefthalf.filled"
    var instructions: String {
        "Use check_scam whenever the person asks if a call, text, email or letter is real, or tells you someone is pushing them "
        + "to move money, share a code or PIN, buy gift cards or crypto, install an app, or keep it secret. Pass the message, or "
        + "what they were told, word for word. Its answer is complete: don't add to it. If it offers to ring 159, use call_159 "
        + "only after the person says yes."
    }
    var tools: [any KairosTool] { [ScamShieldCheckTool(), ScamShieldCall159Tool()] }
}

/// check_scam: rules only, no model, works offline.
struct ScamShieldCheckTool: KairosTool {
    let name = "check_scam"
    let summary = "Check a text, email, letter or phone call for scam signs with fixed rules on the phone (works offline). "
        + "Pass the message, or what the caller said, word for word. It answers the person directly: likely scam, be careful, "
        + "or no usual scam signs, with the signs it found and what to do."
    var parameters: JSONValue {
        Schema.object(["text": Schema.string("The message, letter, or what the caller said, copied word for word.")], required: ["text"])
    }
    let risk = Risk.read

    func quickMatch(_ words: String, ctx: TurnContext) -> JSONValue? {
        ScamShieldRules.quickMatch(words, documents: ctx.documents)
    }

    private func message(_ args: JSONValue, ctx: TurnContext) -> String? {
        args.text("text") ?? args.text("message") ?? ctx.documents.last
    }

    func validate(_ args: JSONValue, ctx: TurnContext) -> Validation {
        message(args, ctx: ctx) == nil ? .clarify("Read me the message, or paste it in, and I'll check it for you.") : .ok
    }

    func describe(_ args: JSONValue, ctx: TurnContext) -> String { "Check a message for scam signs" }

    func execute(_ args: JSONValue, ctx: TurnContext) async throws -> ToolResult {
        guard let text = message(args, ctx: ctx) else {
            return .fail("Read me the message, or paste it in, and I'll check it for you.")
        }
        let verdict = ScamShieldRules.assess(text)
        let say = ScamShieldRules.answer(verdict)
        if verdict.offer159 { ScamShieldFollowUp.remember("call159", ctx: ctx) } else { ScamShieldFollowUp.forget("call159") }
        var result = ToolResult(ok: true, say: say, data: [
            "verdict": .string(verdict.level.rawValue),
            "verdict_words": .string(verdict.level.words),
            "signs": .array(verdict.signs.map { .string($0.name) }),
            "what_to_do": .string(verdict.advice),
            "offered_to_call_159": .bool(verdict.offer159),
            "note": "No warning signs never proves a message is genuine. Never call it safe.",
        ])
        result.isAnswer = true
        result.untrustedText = ctx.documents.contains(text) ? nil : text
        return result
    }
}

/// call_159: Stop Scams UK's 159 puts the person through to their own bank's fraud line. Card + Face ID, then the
/// iPhone's own "Call 159?" prompt.
struct ScamShieldCall159Tool: KairosTool {
    let name = "call_159"
    let summary = "Ring 159, the free Stop Scams UK number that puts the person through to their own bank safely. Use it after "
        + "a likely scam, or when they want their bank about fraud, a lost card or a payment they didn't make. The person approves it first."
    var parameters: JSONValue {
        Schema.object(["reason": Schema.string("Why, in a few words (optional).")])
    }
    let risk = Risk.reachesPerson

    static let explicit = ScamShieldRules.rx(#"\b(?:call|ring|phone|dial)\b.{0,20}\b159\b|^\s*159\s*$|\bstop scams\b|\b(?:call|ring|phone)\b (?:my|the) bank\b"#)
    static let yes = ScamShieldRules.rx(#"^(?:yes|yeah|yep|yup|ok|okay|go on|go ahead|do it|please|please do|sure|call them|ring them|call it|ring it|call 159|ring 159)\b"#)
    static let no = ScamShieldRules.rx(#"\b(?:no|not|don'?t|dont|cancel|stop|wait)\b"#)

    func quickMatch(_ words: String, ctx: TurnContext) -> JSONValue? {
        let t = ScamShieldRules.clean(words).lowercased()
        if ScamShieldRules.has(ScamShieldRules.planning, t) { return nil }
        if ScamShieldRules.has(Self.explicit, t), !ScamShieldRules.has(Self.no, t) {
            return ["reason": "the person asked to ring their bank safely"]
        }
        // "Shall I ring 159 for you?" "Yes please."
        if t.split(separator: " ").count <= 8, ScamShieldRules.has(Self.yes, t), !ScamShieldRules.has(Self.no, t),
           ScamShieldFollowUp.answer("call159", words: words, ctx: ctx) != nil {
            return ["reason": "the person said yes to ringing 159"]
        }
        return nil
    }

    func describe(_ args: JSONValue, ctx: TurnContext) -> String { "Call 159 (Stop Scams UK) to reach your bank safely" }

    func execute(_ args: JSONValue, ctx: TurnContext) async throws -> ToolResult {
        ScamShieldFollowUp.forget("call159")
        guard let url = URL(string: "tel:159") else { return .fail("Sorry, I couldn't start the call. Please dial 159 yourself.") }
        var result = ToolResult(ok: true,
                                say: "Tap the green Call button. 159 will ask which bank you're with, then put you through to them.",
                                data: ["calling": "159", "what_it_is": "Stop Scams UK: connects you safely to your own bank"])
        result.ui = .openURL(url)
        return result
    }
}
