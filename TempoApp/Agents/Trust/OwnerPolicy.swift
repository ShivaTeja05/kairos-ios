import Foundation
import Combine
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

// The owner's trust policy: what the person who owns this phone lets their agents do WITHOUT asking each time.
//
// The rule, in the owner's words: banks have caps, social media doesn't need caps as long as the owner agrees.
// Everything is owner based. So:
//   - Hard caps live in code, never in storage, and no grant can change them: banks and payment apps always ask,
//     paying and buying always ask, passwords/PINs/codes and phone security are never done by an agent at all.
//   - Everything else asks by default, until the owner says otherwise, and saying otherwise needs Face ID.
//   - Making things SAFER (taking a permission back, "Stop everything") never needs Face ID.
// Every action an agent took on its own because of a setting is written to the activity log the owner can read.

// MARK: - What an agent is about to do

/// The kind of thing an agent is about to do in another app.
enum ActionClass: String, Codable, CaseIterable, Sendable {
    case send, post, share, upload, call, delete, purchase, pay, credentials, settings

    /// For the settings screen: "Send messages", "Post".
    var plainName: String {
        switch self {
        case .send: return "Send messages"
        case .post: return "Post"
        case .share: return "Share"
        case .upload: return "Upload photos and files"
        case .call: return "Make calls"
        case .delete: return "Delete things"
        case .purchase: return "Buy things"
        case .pay: return "Pay or send money"
        case .credentials: return "Type passwords and codes"
        case .settings: return "Change security settings"
        }
    }

    /// Inside a sentence: "let your agents post to Instagram".
    var phrase: String {
        switch self {
        case .send: return "send messages"
        case .post: return "post"
        case .share: return "share things"
        case .upload: return "upload photos and files"
        case .call: return "make calls"
        case .delete: return "delete things"
        case .purchase: return "buy things"
        case .pay: return "pay or send money"
        case .credentials: return "type passwords, PINs or codes"
        case .settings: return "change security or privacy settings"
        }
    }

    /// For progress lines: "Posting — you allowed Instagram".
    var doing: String {
        switch self {
        case .send: return "Sending"
        case .post: return "Posting"
        case .share: return "Sharing"
        case .upload: return "Uploading"
        case .call: return "Calling"
        case .delete: return "Deleting"
        case .purchase: return "Buying"
        case .pay: return "Paying"
        case .credentials: return "Typing a code"
        case .settings: return "Changing a setting"
        }
    }

    /// For the activity list: "Posted", "Sent a message".
    var done: String {
        switch self {
        case .send: return "Sent a message"
        case .post: return "Posted"
        case .share: return "Shared"
        case .upload: return "Uploaded"
        case .call: return "Made a call"
        case .delete: return "Deleted"
        case .purchase: return "Bought"
        case .pay: return "Paid"
        case .credentials: return "Typed a code"
        case .settings: return "Changed a setting"
        }
    }

    /// The little word before the app's name: "post to Instagram", "send messages in WhatsApp", "calls on WhatsApp".
    var preposition: String {
        switch self {
        case .post, .upload: return "to"
        case .call: return "on"
        default: return "in"
        }
    }

    /// What the owner may ever let agents do without asking. Money, passwords and phone security are never here.
    var canBeAllowed: Bool {
        switch self {
        case .send, .post, .share, .upload, .call, .delete: return true
        case .purchase, .pay, .credentials, .settings: return false
        }
    }

    static var allowable: [ActionClass] { allCases.filter(\.canBeAllowed) }

    // MARK: Reading an action from words

    /// Most dangerous first: "send money" is paying, not sending; "type my passcode" is a code, not a setting.
    private static let spokenRules: [(ActionClass, [String])] = [
        (.credentials, ["credentials", "password", "passwords", "pin", "pins", "passcode", "otp", "one time code",
                        "one time password", "verification code", "security code", "code", "codes", "cvv", "cvc",
                        "card number", "card details", "sort code", "account number", "memorable", "log in", "login",
                        "sign in", "sign up", "security question"]),
        (.settings, ["settings", "setting", "privacy", "security", "face id", "touch id", "apple id", "icloud account",
                     "two factor", "2fa", "two step", "sign out", "log out", "logout", "screen time", "location services",
                     "permissions", "delete account", "delete my account", "deactivate", "close my account",
                     "change my number", "change my email", "link a device", "linked devices"]),
        (.pay, ["pay", "pays", "paying", "payment", "payments", "send money", "transfer", "transfers", "top up",
                "withdraw", "donate", "money", "apple pay", "standing order", "direct debit", "gift", "gifts", "coins",
                "tip", "tips"]),
        (.purchase, ["purchase", "purchases", "buy", "buying", "checkout", "check out", "place order", "order",
                     "orders", "subscribe", "subscription", "shopping", "shop", "book", "booking", "boost", "boosts",
                     "promote", "advert", "adverts", "ads", "premium", "upgrade"]),
        (.delete, ["delete", "deletes", "deleting", "remove", "removing", "erase", "unsend", "bin", "trash", "clear",
                   "discard"]),
        (.call, ["call", "calls", "calling", "ring", "phone", "facetime", "video call", "voice call", "dial"]),
        (.upload, ["upload", "uploads", "uploading", "back up", "backup", "backing up", "save to drive", "add to drive",
                   "add to album"]),
        (.post, ["post", "posts", "posting", "publish", "tweet", "story", "stories", "reel", "reels", "go live",
                 "comment", "comments", "put on"]),
        (.share, ["share", "shares", "sharing", "share things", "invite"]),
        (.send, ["send", "sending", "send messages", "message", "messages", "messaging", "text", "texts", "texting",
                 "reply", "replies", "dm", "dms", "forward", "email", "emails", "mail"]),
    ]

    /// From the model's argument or the owner's words: "post", "send messages", "share things", "posting".
    init?(spoken: String) {
        let f = spoken.folded
        guard !f.isEmpty else { return nil }
        if let exact = ActionClass(rawValue: f) { self = exact; return }
        if let named = ActionClass.allCases.first(where: { $0.plainName.folded == f || $0.phrase.folded == f }) {
            self = named; return
        }
        guard let hit = Self.firstRule(Self.spokenRules, in: f) else { return nil }
        self = hit
    }

    /// Tap labels as apps write them. A button's own word, not a sentence.
    private static let tapRules: [(ActionClass, [String])] = [
        // Approving a sign-in ("Yes, it's me") hands the account to whoever is signing in: that is a credential.
        (.credentials, ["password", "passcode", "pin", "otp", "one time code", "one time password", "verification code",
                        "security code", "code", "cvv", "cvc", "card number", "card details", "sort code",
                        "account number", "memorable", "log in", "login", "sign in", "sign up", "security question",
                        "passkey", "passkeys", "authenticator", "backup codes", "recovery code", "yes it s me", "it s me",
                        "it was me", "this was me", "yes that was me", "confirm it s you", "verify it s you",
                        "approve sign in", "approve login"]),
        // Account takeover and losing the phone: linking a device, changing the number or email, deleting or
        // deactivating the account, erasing or unlinking the iPhone. Never by an agent, whatever is allowed.
        (.settings, ["face id", "touch id", "apple id", "two factor", "2fa", "two step", "sign out", "log out", "logout",
                     "erase all", "reset", "screen time", "location services", "allow access", "allow full access",
                     "allow while using", "allow once", "allow", "trust", "trust this computer", "privacy", "security",
                     "turn off", "permissions", "delete account", "delete my account", "delete your account",
                     "deactivate", "deactivate account", "close account", "close my account", "change number",
                     "change phone number", "change email", "change email address", "link a device", "link device",
                     "linked devices", "link with phone number", "erase this device", "erase iphone", "erase device",
                     "remove this device", "remove device", "remove from account", "lost mode", "mark as lost",
                     "recovery email", "recovery phone", "recovery contact", "trusted number", "make public",
                     "switch to public", "public account", "approve"]),
        // Paid features in social apps are money too: gifts, coins, stars, tips.
        (.pay, ["pay", "pay now", "payment", "confirm payment", "send money", "transfer", "top up", "withdraw",
                "donate", "tip", "request money", "apple pay", "send gift", "gift", "gifts", "coins", "get coins",
                "buy coins", "recharge", "stars", "send stars", "super chat", "super thanks", "super sticker"]),
        // "Boost post" spends money on an advert: buying, not posting.
        (.purchase, ["buy", "buy now", "purchase", "checkout", "check out", "place order", "order", "order now",
                     "confirm order", "subscribe", "install", "book now", "rent", "boost", "boost post", "boost reel",
                     "promote", "promote post", "upgrade", "premium", "go premium", "get premium", "try premium",
                     "free trial", "start free trial", "start trial", "get verified", "add to basket", "add to bag",
                     "add to cart", "renew"]),
        (.delete, ["delete", "remove", "erase", "unsend", "bin", "trash", "clear all", "discard", "delete for everyone",
                   "delete for me"]),
        (.call, ["call", "audio call", "voice call", "video call", "facetime", "dial", "ring"]),
        (.upload, ["upload", "back up", "backup", "add to drive", "save to drive", "add to album", "save to photos"]),
        (.post, ["post", "publish", "tweet", "your story", "add to story", "share to story", "share to feed", "go live",
                 "comment", "reply all"]),
        (.share, ["share", "share link", "invite"]),
        (.send, ["send", "send to", "reply", "forward", "submit message"]),
    ]

    /// What a sensitive tap does, from the element's label and kind ("Share" in Instagram, "Send" in WhatsApp).
    /// Nil when it isn't one of these kinds (the caller then asks the owner, as before).
    static func forTap(label: String, kind: String = "", appBundleID: String? = nil, appName: String? = nil) -> ActionClass? {
        if kind == "SecureTextField" { return .credentials }
        let f = label.folded
        guard !f.isEmpty else { return nil }
        let hit = firstRule(tapRules, in: f)
        if hit == .credentials || hit == .settings { return hit }
        // An amount of money on the button ("Send £20", "Tip $5", "Gift 100 coins for £1.99") is paying, whatever
        // the verb next to it says.
        if mentionsMoney(label) { return hit == .purchase ? .purchase : .pay }
        guard let hit else { return nil }
        // On social media the last button of a new post or story is often "Share": that's posting it publicly.
        if hit == .share, TrustApps.identify(bundleID: appBundleID, name: appName).category == .social { return .post }
        return hit
    }

    /// "£20", "$5", "€3.50", "20 GBP", "5 pounds": a sum of money in a label.
    static func mentionsMoney(_ text: String) -> Bool {
        let symbols = CharacterSet(charactersIn: "£$€₹¥")
        let chars = Array(text.unicodeScalars)
        for (i, c) in chars.enumerated() where symbols.contains(c) {
            let near = chars[max(0, i - 2)...min(chars.count - 1, i + 2)]
            if near.contains(where: { CharacterSet.decimalDigits.contains($0) }) { return true }
        }
        guard text.contains(where: { $0.isNumber }) else { return false }
        let units = ["gbp", "usd", "eur", "inr", "pound", "pounds", "quid", "pence", "dollar", "dollars", "euro", "euros",
                     "rupee", "rupees"]
        let padded = " " + text.folded + " "
        return units.contains { padded.contains(" " + $0 + " ") }
    }

    /// Typing something an agent must never type: into a password or code box, or a card number anywhere.
    static func forTyping(text: String, fieldLabel: String = "", fieldKind: String = "") -> ActionClass? {
        if fieldKind == "SecureTextField" { return .credentials }
        if let hit = firstRule(tapRules, in: fieldLabel.folded), hit == .credentials { return .credentials }
        let digits = text.filter { $0.isASCII && $0.isNumber }
        let other = text.filter { !($0.isASCII && $0.isNumber) && $0 != " " && $0 != "-" }
        if other.isEmpty, (13...19).contains(digits.count), Self.luhn(digits) { return .credentials }
        return nil
    }

    /// The card-number checksum, so a long phone number isn't mistaken for a card.
    static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard var d = ch.wholeNumberValue else { return false }
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }

    /// The owner's own words name this kind of action ("post", "send messages", "story" for post…). Used so the
    /// model can't turn "let it post" into "let it delete things".
    static func mentioned(_ action: ActionClass, in words: String) -> Bool {
        let padded = " " + words.folded + " "
        let phrases = (spokenRules.first { $0.0 == action }?.1 ?? []) + [action.rawValue, action.plainName.folded,
                                                                        action.phrase.folded]
        return phrases.contains { !$0.isEmpty && padded.contains(" " + $0 + " ") }
    }

    private static func firstRule(_ rules: [(ActionClass, [String])], in folded: String) -> ActionClass? {
        guard !folded.isEmpty else { return nil }
        let padded = " " + folded + " "
        for (action, phrases) in rules where phrases.contains(where: { padded.contains(" " + $0 + " ") }) {
            return action
        }
        return nil
    }
}

// MARK: - Which app

/// What kind of app it is. Banking is the one kind with hard caps.
enum AppCategory: String, Codable, CaseIterable, Sendable {
    case social, messaging, email, cloud, photos, shopping, banking, other

    var plainName: String {
        switch self {
        case .social: return "Social media"
        case .messaging: return "Messages and calls"
        case .email: return "Email"
        case .cloud: return "Cloud storage"
        case .photos: return "Photos"
        case .shopping: return "Shopping"
        case .banking: return "Banks and payments"
        case .other: return "Other apps"
        }
    }

    /// SF Symbol for the settings screen and the activity list.
    var symbol: String {
        switch self {
        case .social: return "person.3.fill"
        case .messaging: return "message.fill"
        case .email: return "envelope.fill"
        case .cloud: return "icloud.fill"
        case .photos: return "photo.on.rectangle"
        case .shopping: return "bag.fill"
        case .banking: return "building.columns.fill"
        case .other: return "square.grid.2x2.fill"
        }
    }

    /// The things that make sense to allow for apps of this kind, in the order the settings screen shows them.
    var everydayActions: [ActionClass] {
        switch self {
        case .social: return [.post, .send, .delete]
        case .messaging: return [.send, .share, .call, .delete]
        case .email: return [.send, .delete]
        case .cloud: return [.upload, .share, .delete]
        case .photos: return [.share, .upload, .delete]
        case .shopping, .banking: return []
        case .other: return [.send, .post, .share, .upload, .delete]
        }
    }
}

/// One app as the trust policy knows it.
struct TrustApp: Equatable, Identifiable, Sendable {
    var name: String
    var bundleID: String?
    var category: AppCategory
    /// Folded words that mean this app when someone says or writes it ("insta", "whats app").
    var keywords: [String] = []
    /// Bundle ID checked against the UK App Store on 25 Oct 2026. False: a system app or matched by name only.
    var verified: Bool = true
    /// From the catalogue below (false: an app we only know by what the phone or the person called it).
    var catalogued: Bool = true
    /// Passwords, Find My, authenticators and password managers: everything in them counts as phone security.
    var isSecurity: Bool = false

    /// The key grants are stored under: the bundle ID when known, else the app's name.
    var key: String { bundleID.map { $0.lowercased() } ?? "name:" + name.folded }
    var id: String { key }
    var isSystemSettings: Bool { bundleID?.lowercased() == "com.apple.preferences" }
    /// Nothing an agent does here can ever be allowed without asking (Settings, Passwords, Find My, authenticators).
    var neverTrusted: Bool { isSystemSettings || isSecurity }

    init(_ name: String, _ bundleID: String?, _ category: AppCategory, _ keywords: [String] = [], verified: Bool = true) {
        self.name = name
        self.bundleID = bundleID
        self.category = category
        self.keywords = keywords
        self.verified = verified
    }
}

enum TrustApps {
    /// Common apps. Every third-party bundle ID here was looked up in the UK App Store (itunes.apple.com lookup and
    /// search, country=gb) on 25 Oct 2026; `verified: false` marks Apple system apps the store doesn't list.
    /// Note: Monzo is io.b2a.BankProd (com.getmondo.Monzo isn't in the UK store).
    static let catalogue: [TrustApp] = [
        // Social media: the owner decides.
        TrustApp("Instagram", "com.burbn.instagram", .social, ["instagram", "insta", "ig"]),
        TrustApp("Threads", "com.burbn.barcelona", .social, ["threads"]),
        TrustApp("Facebook", "com.facebook.Facebook", .social, ["facebook", "fb"]),
        TrustApp("X", "com.atebits.Tweetie2", .social, ["x", "twitter", "tweet"]),
        TrustApp("TikTok", "com.zhiliaoapp.musically", .social, ["tiktok", "tik tok"]),
        TrustApp("Snapchat", "com.toyopagroup.picaboo", .social, ["snapchat", "snap chat"]),
        TrustApp("LinkedIn", "com.linkedin.LinkedIn", .social, ["linkedin", "linked in"]),
        TrustApp("YouTube", "com.google.ios.youtube", .social, ["youtube", "you tube"]),
        TrustApp("Pinterest", "pinterest", .social, ["pinterest"]),
        TrustApp("Reddit", "com.reddit.Reddit", .social, ["reddit"]),
        TrustApp("Bluesky", "xyz.blueskyweb.app", .social, ["bluesky", "blue sky"]),
        // Messages and calls.
        TrustApp("WhatsApp", "net.whatsapp.WhatsApp", .messaging, ["whatsapp", "whats app", "whatsapp messenger"]),
        TrustApp("Messages", "com.apple.MobileSMS", .messaging, ["messages", "imessage", "text messages", "sms", "texts"],
                 verified: true),
        TrustApp("Messenger", "com.facebook.Messenger", .messaging, ["messenger", "facebook messenger"]),
        TrustApp("Telegram", "ph.telegra.Telegraph", .messaging, ["telegram"]),
        TrustApp("Signal", "org.whispersystems.signal", .messaging, ["signal"]),
        TrustApp("Viber", "com.viber", .messaging, ["viber"]),
        TrustApp("Discord", "com.hammerandchisel.discord", .messaging, ["discord"]),
        TrustApp("Phone", "com.apple.mobilephone", .messaging, ["phone", "phone app"]),
        TrustApp("FaceTime", "com.apple.facetime", .messaging, ["facetime", "face time"]),
        // Email.
        TrustApp("Gmail", "com.google.Gmail", .email, ["gmail", "google mail"]),
        TrustApp("Outlook", "com.microsoft.Office.Outlook", .email, ["outlook", "hotmail"]),
        TrustApp("Mail", "com.apple.mobilemail", .email, ["mail", "apple mail", "email"]),
        // Cloud storage.
        TrustApp("Google Drive", "com.google.Drive", .cloud, ["google drive", "drive"]),
        TrustApp("Dropbox", "com.getdropbox.Dropbox", .cloud, ["dropbox", "drop box"]),
        TrustApp("OneDrive", "com.microsoft.skydrive", .cloud, ["onedrive", "one drive"]),
        TrustApp("Files", "com.apple.DocumentsApp", .cloud, ["files", "icloud drive", "icloud"]),
        // Photos.
        TrustApp("Google Photos", "com.google.photos", .photos, ["google photos"]),
        TrustApp("Photos", "com.apple.mobileslideshow", .photos, ["photos", "apple photos", "camera roll", "gallery"]),
        // Shopping: buying always asks, whatever the owner allows.
        TrustApp("Amazon", "com.amazon.AmazonUK", .shopping, ["amazon"]),
        TrustApp("eBay", "com.ebay.iphone", .shopping, ["ebay"]),
        TrustApp("Vinted", "lt.manodrabuziai.fr", .shopping, ["vinted"]),
        TrustApp("Depop", "com.garageitaly.garage", .shopping, ["depop"]),
        TrustApp("Temu", "com.einnovation.temu", .shopping, ["temu"]),
        TrustApp("App Store", "com.apple.AppStore", .shopping, ["app store"], verified: false),
        // Banks and payments: hard caps.
        TrustApp("Barclays", "uk.co.barclays.bmbappstore", .banking, ["barclays"]),
        TrustApp("Barclaycard", "uk.co.barclays.mybarclaycard", .banking, ["barclaycard"]),
        TrustApp("HSBC", "uk.co.hsbc.hsbcukmobilebanking", .banking, ["hsbc"]),
        TrustApp("Lloyds", "com.lloydstsb.LloydsTSB", .banking, ["lloyds", "lloyds bank"]),
        TrustApp("Halifax", "com.halifax.mobilebank", .banking, ["halifax"]),
        TrustApp("Bank of Scotland", "com.bos.mobilebank", .banking, ["bank of scotland"]),
        TrustApp("NatWest", "com.monitise.matm.Monitise-iPhone-NatWest-EN-GB", .banking, ["natwest", "nat west"]),
        TrustApp("Royal Bank of Scotland", "com.monitise.matm.Monitise-iPhone-RBS-EN-GB", .banking,
                 ["rbs", "royal bank", "royal bank of scotland"]),
        TrustApp("Santander", "uk.co.santander.santanderUK", .banking, ["santander"]),
        TrustApp("Nationwide", "co.uk.Nationwide.MobileBanking", .banking, ["nationwide"]),
        TrustApp("Monzo", "io.b2a.BankProd", .banking, ["monzo"]),
        TrustApp("Starling", "uk.co.starlingbank.Starling", .banking, ["starling"]),
        TrustApp("Revolut", "com.revolut.revolut", .banking, ["revolut"]),
        TrustApp("PayPal", "com.yourcompany.PPClient", .banking, ["paypal", "pay pal"]),
        TrustApp("Chase UK", "com.chase.intl", .banking, ["chase", "chase uk"]),
        TrustApp("Metro Bank", "uk.plc.metrobankmobile.ios", .banking, ["metro bank"]),
        TrustApp("TSB", "uk.co.tsb.mobilebankt0", .banking, ["tsb"]),
        TrustApp("Co-operative Bank", "com.cooperativebank.bank", .banking,
                 ["co op bank", "coop bank", "cooperative bank", "co operative bank"]),
        TrustApp("first direct", "com.firstdirect.bankingonthego", .banking, ["first direct"]),
        TrustApp("Virgin Money", "com.virginmoney.uk.mobile.ios", .banking, ["virgin money"]),
        TrustApp("Tesco Bank", "com.tescobank.mobile.ios.iphone.TescoBank", .banking, ["tesco bank"]),
        TrustApp("Amex", "uk.co.americanexpress.amexservice", .banking, ["amex", "american express"]),
        TrustApp("Klarna", "com.klarna.app", .banking, ["klarna"]),
        TrustApp("Wise", "com.transferwise.Transferwise", .banking, ["wise", "transferwise"]),
        TrustApp("Curve", "com.imaginecurve.curve", .banking, ["curve"]),
        TrustApp("Coinbase", "com.vilcsak.bitcoin2", .banking, ["coinbase"]),
        TrustApp("Trading 212", "com.avuscapital.trading212", .banking, ["trading 212"]),
        TrustApp("Apple Wallet", "com.apple.Passbook", .banking, ["wallet", "apple wallet", "apple pay"]),
        // The phone's own Settings: anything sensitive there counts as a security setting.
        TrustApp("Settings", "com.apple.Preferences", .other, ["settings", "phone settings"], verified: false),
        // Passwords and Find My (Erase This Device, Remove This Device): phone security, never an agent's.
        TrustApp("Passwords", "com.apple.Passwords", .other, ["passwords", "passwords app", "keychain"], verified: false),
        TrustApp("Find My", "com.apple.findmy", .other, ["find my", "find my iphone"], verified: false),
    ]

    /// Bundle IDs and name words of security apps: Apple's Settings, Passwords and Find My, authenticators and
    /// password managers. Matching any of them makes every action there a security setting.
    static let securityBundles: Set<String> = ["com.apple.preferences", "com.apple.passwords", "com.apple.findmy"]
    static let securityWords = ["password", "passwords", "authenticator", "authy", "passkey", "passkeys", "keychain",
                                "find my", "1password", "bitwarden", "lastpass", "dashlane", "keeper", "vault"]
    static let securityFragments = ["password", "authenticator", "authy", "bitwarden", "lastpass", "dashlane", "findmy",
                                    "keychain", "passkey"]

    /// Words in bundle IDs that mean a catalogued bank even under an ID we don't know ("com.monzo.ios").
    static let bankFragments: [String] = {
        var out: Set<String> = ["hsbc", "amex"]
        for app in catalogue where app.category == .banking {
            for word in app.keywords + [app.name.folded] {
                let squashed = word.replacingOccurrences(of: " ", with: "")
                if squashed.count >= 5 { out.insert(squashed) }
            }
        }
        return out.sorted()
    }()

    /// Words that make any app a bank or payment app, even one we've never heard of.
    static let moneyWords = ["bank", "banking", "pay", "payment", "payments", "wallet", "crypto", "bitcoin", "invest",
                             "investing", "investment", "investments", "trading", "trade", "finance", "financial",
                             "money", "loan", "loans", "credit", "savings", "building society", "stocks", "mortgage",
                             "isa", "pension", "remit", "remittance", "exchange"]
    /// The same, inside run-together names and bundle IDs ("io.b2a.BankProd", "MoneyBox", "applepay").
    static let moneyFragments = ["bank", "pay", "wallet", "crypto", "bitcoin", "invest", "trading", "finance",
                                 "money", "loan", "credit", "mortgage", "remit"]

    /// Who this is: by bundle ID first (the phone says which app is in front), else by name.
    static func identify(bundleID: String?, name: String?) -> TrustApp {
        let trimmed = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bundle: String? = trimmed.isEmpty ? nil : trimmed
        let folded = name?.folded ?? ""
        var app: TrustApp
        if let bundle, let known = catalogue.first(where: { $0.bundleID?.lowercased() == bundle.lowercased() }) {
            app = known
        } else if bundle == nil, let known = byName(folded) {
            app = known
        } else {
            // A bundle ID we don't know is its own app, even if it calls itself "Instagram".
            let shown = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let displayName = shown.isEmpty ? (bundle?.split(separator: ".").last.map(String.init) ?? "this app") : shown
            app = TrustApp(displayName, bundle, .other)
            app.catalogued = false
            app.verified = false
        }
        // Money words always win: "Signal Bank" is a bank, not Signal, and a bank is a bank whatever it's called.
        // So does a bank's name under a bundle ID we don't know (an old or regional Monzo build is still Monzo),
        // and a bank's name inside the bundle ID: when in doubt, it is a bank.
        if app.category != .banking,
           looksLikeMoney(name: folded, bundleID: bundle)
            || byName(folded)?.category == .banking
            || bankFragments.contains(where: { (bundle?.lowercased() ?? "").contains($0) }) {
            app.category = .banking
        }
        if looksLikeSecurity(name: folded, bundleID: bundle) { app.isSecurity = true }
        return app
    }

    /// Settings, Passwords, Find My, an authenticator or a password manager, by bundle ID or name.
    static func looksLikeSecurity(name folded: String, bundleID: String?) -> Bool {
        let bundle = bundleID?.lowercased() ?? ""
        if securityBundles.contains(bundle) { return true }
        let padded = " " + folded + " "
        if securityWords.contains(where: { padded.contains(" " + $0 + " ") }) { return true }
        return securityFragments.contains { bundle.contains($0) }
    }

    /// The catalogue app whose longest keyword appears in these words ("Facebook Messenger" is Messenger).
    static func byName(_ folded: String) -> TrustApp? {
        guard !folded.isEmpty else { return nil }
        let padded = " " + folded + " "
        var best: (app: TrustApp, length: Int)?
        for app in catalogue {
            for kw in app.keywords + [app.name.folded] where padded.contains(" " + kw + " ") {
                if kw.count > (best?.length ?? 0) { best = (app, kw.count) }
            }
        }
        return best?.app
    }

    /// Any bank, payment, wallet, crypto or investing app, by its name or bundle ID.
    static func looksLikeMoney(name folded: String, bundleID: String?) -> Bool {
        let padded = " " + folded + " "
        if moneyWords.contains(where: { padded.contains(" " + $0 + " ") }) { return true }
        let squashed = folded.replacingOccurrences(of: " ", with: "")
        let bundle = bundleID?.lowercased() ?? ""
        return moneyFragments.contains { squashed.contains($0) || bundle.contains($0) }
    }

    /// Why this can never be allowed without asking, in plain words; nil when the owner may allow it.
    static func whyNeverAllowed(_ app: TrustApp, _ action: ActionClass) -> String? {
        switch action {
        case .credentials: return TrustWording.credentials
        case .settings: return TrustWording.settings
        default: break
        }
        if app.neverTrusted { return TrustWording.settings }
        if app.category == .banking {
            return "\(app.name) is a bank or payment app. Banks and payments always ask you first, and that can't be changed. It keeps your money safe."
        }
        switch action {
        case .pay: return "Paying or sending money always asks you first, in every app. That can't be changed."
        case .purchase: return "Buying things always asks you first, in every app. That can't be changed."
        default: return nil
        }
    }
}

// MARK: - Grants and decisions

/// How long the owner lets agents do something without asking.
enum TrustDuration: String, Codable, CaseIterable, Sendable {
    case oneHour = "one_hour", today, always

    var label: String {
        switch self {
        case .oneHour: return "1 hour"
        case .today: return "Today"
        case .always: return "Always"
        }
    }

    init?(spoken: String) {
        let f = spoken.folded
        if let exact = TrustDuration(rawValue: f.replacingOccurrences(of: " ", with: "_")) { self = exact; return }
        let padded = " " + f + " "
        if [" hour ", " 1 hour ", " an hour ", " one hour ", " 60 minutes "].contains(where: padded.contains) { self = .oneHour }
        else if [" today ", " rest of today ", " tonight ", " day "].contains(where: padded.contains) { self = .today }
        else if [" always ", " forever ", " from now on ", " any time ", " anytime ", " until i change it "].contains(where: padded.contains) {
            self = .always
        } else { return nil }
    }

    func mode(from now: Date, calendar: Calendar = .current) -> GrantMode {
        switch self {
        case .oneHour: return .allowUntil(now.addingTimeInterval(3600))
        case .today:
            let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(3600)
            return .allowUntil(midnight)
        case .always: return .always
        }
    }
}

/// What the owner has said for one app and one kind of action.
enum GrantMode: Codable, Equatable, Sendable {
    case ask
    case allowUntil(Date)
    case always
    /// The owner blocked it: agents refuse even if asked.
    case never

    /// Lets agents act without asking (now or until a time).
    var isPermissive: Bool {
        switch self {
        case .always, .allowUntil: return true
        case .ask, .never: return false
        }
    }
}

struct TrustGrant: Codable, Equatable, Identifiable, Sendable {
    var appKey: String
    var appName: String
    var bundleID: String?
    var category: AppCategory
    var action: ActionClass
    var mode: GrantMode
    /// What the owner picked on the screen (one hour / today / always), to show the right button.
    var duration: TrustDuration?
    var setAt: Date

    var id: String { appKey + "|" + action.rawValue }

    /// The longest a time limit can be: "today" set just after midnight, on a day the clocks go back.
    static let longestLimit: TimeInterval = 26 * 3600

    func isActive(at now: Date) -> Bool {
        guard case .allowUntil(let end) = mode else { return true }
        // A time limit only counts on a sane clock: never longer than a day, and never read before it was set
        // (the phone's clock was moved back, or the stored grant was edited). Otherwise it has run out.
        return end > now && setAt <= now.addingTimeInterval(300) && end.timeIntervalSince(setAt) <= Self.longestLimit
    }
}

/// The policy's answer for one action an agent is about to take.
enum PolicyDecision: Equatable, Sendable {
    /// Go ahead without a card: the owner allowed it. The reason is for progress lines and the log.
    case autoApprove(reason: String)
    /// Show the big card and check it's the owner. The warning, if any, goes on the card.
    case ask(warning: String?)
    /// Never, whoever asks. The reason is said to the person.
    case refuse(reason: String)
}

/// What happened when the owner tried to allow something.
enum TrustGrantResult: Equatable, Sendable {
    case granted(TrustGrant)
    /// A hard cap, or the phone can't prove its owner.
    case notAllowed(String)
    /// Face ID / passcode didn't confirm the owner. Nothing changed.
    case ownerNotConfirmed(String)
}

/// One thing an agent did without asking, because the owner's setting allowed it.
struct TrustActivity: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var time: Date
    var appKey: String
    var appName: String
    var category: AppCategory
    var action: ActionClass
    /// "A photo of the garden, caption “First roses”".
    var detail: String
    /// Which helper did it: "Phone operator".
    var agent: String
    /// "you allowed Instagram to post without asking until 04:15".
    var reason: String
}

/// Words the policy says to the person.
enum TrustWording {
    static let credentials = "I never type passwords, PINs, codes or card numbers, and that can't be changed. Those are yours to type."
    static let settings = "Your agents never change security or privacy settings, Face ID, your passcode or your Apple ID. That can't be changed. Please do that yourself."
    static func bankMoney(_ app: String) -> String {
        "\(app) is a bank or payment app. Only say yes if you started this yourself and you know exactly who the money is going to. A real bank will never ask you to move money to keep it safe."
    }
    static func bankOther(_ app: String) -> String {
        "\(app) is a bank or payment app. Banks and payments always ask you first."
    }
    static let pay = "This pays or sends money. Check the amount and who it goes to before you say yes."
    static let purchase = "This buys something. Check what it is and the price before you say yes."
    static let noPasscode = "To let your agents do things without asking, this phone needs a passcode or Face ID first, so only you can change it."
    static let notConfirmed = "I didn't change anything, because Face ID didn't confirm it was you."
}

// MARK: - The policy

@MainActor
final class OwnerPolicy: ObservableObject {
    static let shared = OwnerPolicy()

    /// Everything the owner has set, including blocks. Expired one-hour and today grants are pruned.
    @Published private(set) var grants: [TrustGrant] = []
    /// What agents did on their own, oldest first, at most `keptActivity`.
    @Published private(set) var activity: [TrustActivity] = []

    nonisolated static let grantsKey = "kairos.trust.grants.v1"
    nonisolated static let activityKey = "kairos.trust.activity.v1"
    nonisolated static let keptActivity = 300
    /// Posted by revokeAll(): anything running on its own (the Phone operator) should stop at once.
    nonisolated static let stopEverythingNotification = Notification.Name("kairos.trust.stopEverything")

    private let defaults: UserDefaults
    private let verifyOwner: @MainActor (String) async -> Bool
    private let ownerCanBeChecked: @MainActor () -> Bool

    /// The app uses `shared`. Tests pass their own defaults suite and owner check.
    init(defaults: UserDefaults = .standard,
         verifyOwner: @escaping @MainActor (String) async -> Bool = { await OwnerCheck.verify(reason: $0) },
         ownerCanBeChecked: @escaping @MainActor () -> Bool = { OwnerPolicy.phoneCanCheckOwner() }) {
        self.defaults = defaults
        self.verifyOwner = verifyOwner
        self.ownerCanBeChecked = ownerCanBeChecked
        load()
        pruneExpired()
    }

    /// The newest first, for the screen.
    var recentActivity: [TrustActivity] { activity.reversed() }


    // MARK: Deciding

    /// What an agent may do right now. Hard caps first; then the owner's own setting; otherwise ask.
    func decide(appBundleID: String?, appName: String?, action: ActionClass, now: Date = Date()) -> PolicyDecision {
        let app = TrustApps.identify(bundleID: appBundleID, name: appName)
        var action = action
        if app.neverTrusted, action != .credentials { action = .settings }

        // 1. Never, whatever is stored.
        switch action {
        case .credentials: return .refuse(reason: TrustWording.credentials)
        case .settings: return .refuse(reason: TrustWording.settings)
        default: break
        }
        let grant = activeGrant(app: app, action: action, appName: appName, now: now)
        // 2. The owner's own block is always honoured (it only makes things safer).
        if grant?.mode == .never {
            return .refuse(reason: "You've told me your agents must never \(action.phrase) \(action.preposition) \(app.name). You can change that in Permissions.")
        }
        // 3. Banks and payment apps always ask, for every action.
        if app.category == .banking {
            switch action {
            case .pay, .purchase, .send, .share, .upload:
                return .ask(warning: TrustWording.bankMoney(app.name))
            default:
                return .ask(warning: TrustWording.bankOther(app.name))
            }
        }
        // 4. Money anywhere always asks.
        if action == .pay { return .ask(warning: TrustWording.pay) }
        if action == .purchase { return .ask(warning: TrustWording.purchase) }
        // 5. The owner's grant for exactly this app and this action (delete needs its own grant). Only when the
        //    phone itself says which app is in front (its bundle ID): a name alone can be any app calling itself
        //    "Instagram", or a name the model made up.
        guard let grant, action.canBeAllowed, grant.isActive(at: now), Self.knowsForegroundApp(appBundleID) else {
            return .ask(warning: nil)
        }
        switch grant.mode {
        case .always:
            return .autoApprove(reason: "you allowed \(app.name) to \(action.phrase) without asking")
        case .allowUntil(let end) where end > now:
            return .autoApprove(reason: "you allowed \(app.name) to \(action.phrase) without asking \(Self.untilPhrase(end, now: now))")
        default:
            return .ask(warning: nil)
        }
    }

    /// The owner's current, unexpired setting for this app and action (nil: ask, the default).
    func activeGrant(app: TrustApp, action: ActionClass, appName: String? = nil, now: Date = Date()) -> TrustGrant? {
        if let g = grants.first(where: { $0.appKey == app.key && $0.action == action }) {
            return g.isActive(at: now) ? g : nil
        }
        // An app we only know by name (granted by name, now seen with its bundle ID): match on the exact name, and
        // only when the bundle ID carries that name too ("Acme Chat" → com.acme.chat). A name passed in by the
        // caller (or the model) can't lend one app's permission to another app, such as a bank.
        guard !app.catalogued, let bundle = app.bundleID?.lowercased() else { return nil }
        let name = (appName ?? app.name).folded
        let nameKey = "name:" + name
        guard !name.isEmpty, nameKey != app.key, Self.bundle(bundle, carries: name),
              let g = grants.first(where: { $0.appKey == nameKey && $0.action == action }) else { return nil }
        return g.isActive(at: now) ? g : nil
    }

    /// The phone reported which app is in front. SpringBoard (the Home Screen and system alerts) never counts.
    nonisolated static func knowsForegroundApp(_ bundleID: String?) -> Bool {
        guard let b = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !b.isEmpty else { return false }
        return b != "com.apple.springboard"
    }

    /// The bundle ID contains the app's name, squashed ("acmechat") or its first word ("acme", three letters or more).
    nonisolated static func bundle(_ bundle: String, carries foldedName: String) -> Bool {
        let squashed = foldedName.replacingOccurrences(of: " ", with: "")
        if squashed.count >= 3, bundle.contains(squashed) { return true }
        guard let first = foldedName.split(separator: " ").first, first.count >= 3 else { return false }
        return bundle.contains(String(first))
    }

    // MARK: Changing trust

    /// Lets agents do one kind of thing in one app without asking. Always checks Face ID / passcode first:
    /// there is no way to give agents more freedom without the owner. Hard caps are refused before Face ID.
    func grant(appBundleID: String?, appName: String, action: ActionClass, duration: TrustDuration,
               now: Date = Date()) async -> TrustGrantResult {
        let app = TrustApps.identify(bundleID: appBundleID, name: appName)
        if let reason = TrustApps.whyNeverAllowed(app, action) { return .notAllowed(reason) }
        guard action.canBeAllowed else { return .notAllowed(TrustWording.settings) }
        guard ownerCanBeChecked() else { return .notAllowed(TrustWording.noPasscode) }
        let mode = duration.mode(from: now)
        let reason = "Let your agents \(action.phrase) \(action.preposition) \(app.name) without asking you, \(Self.durationPhrase(mode, now: now))."
        guard await verifyOwner(reason) else { return .ownerNotConfirmed(TrustWording.notConfirmed) }
        let g = TrustGrant(appKey: app.key, appName: app.name, bundleID: app.bundleID, category: app.category,
                           action: action, mode: mode, duration: duration, setAt: now)
        upsert(g)
        pruneExpired(now: now)
        return .granted(g)
    }

    /// Lifts the owner's own block (back to asking). That gives agents more room, so it needs Face ID too.
    func unblock(appBundleID: String?, appName: String, action: ActionClass) async -> Bool {
        let app = TrustApps.identify(bundleID: appBundleID, name: appName)
        guard grants.contains(where: { $0.appKey == app.key && $0.action == action && $0.mode == .never }) else { return true }
        guard ownerCanBeChecked(),
              await verifyOwner("Let your agents ask you again before they \(action.phrase) \(action.preposition) \(app.name).")
        else { return false }
        grants.removeAll { $0.appKey == app.key && $0.action == action && $0.mode == .never }
        save()
        return true
    }

    /// Blocks agents from one kind of thing in one app, even when asked. Safer, so no Face ID.
    func forbid(appBundleID: String?, appName: String, action: ActionClass, now: Date = Date()) {
        let app = TrustApps.identify(bundleID: appBundleID, name: appName)
        upsert(TrustGrant(appKey: app.key, appName: app.name, bundleID: app.bundleID, category: app.category,
                          action: action, mode: .never, duration: nil, setAt: now))
    }

    /// Takes permissions back: agents ask first again. Safer, so no Face ID. Nil app = every app, nil action =
    /// every action; both nil is "Stop everything". Blocks the owner set stay (removing one would loosen things).
    /// Returns how many permissions were taken back.
    @discardableResult
    func revoke(appBundleID: String? = nil, appName: String? = nil, action: ActionClass? = nil) -> Int {
        let hasApp = !(appBundleID ?? "").isEmpty || !(appName ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        var keys: Set<String> = []
        if hasApp {
            let app = TrustApps.identify(bundleID: appBundleID, name: appName)
            keys = [app.key]
            if let appName, !appName.folded.isEmpty { keys.insert("name:" + appName.folded) }
        }
        let before = grants.count
        grants.removeAll { g in
            g.mode.isPermissive && (!hasApp || keys.contains(g.appKey)) && (action == nil || g.action == action)
        }
        let removed = before - grants.count
        if removed > 0 { save() }
        return removed
    }

    /// "Stop everything": every permission taken back at once, and anything running on its own told to stop.
    @discardableResult
    func revokeAll() -> Int {
        let removed = revoke()
        // Only the app's real policy tells running agents to stop (a self-test's private copy must not).
        if self === OwnerPolicy.shared { NotificationCenter.default.post(name: Self.stopEverythingNotification, object: nil) }
        return removed
    }

    // MARK: Activity log

    /// Write down something an agent did on its own because the owner allowed it. Call it after the action worked.
    func record(appBundleID: String?, appName: String?, action: ActionClass, detail: String, agent: String,
                reason: String = "allowed by your setting", at time: Date = Date()) {
        let app = TrustApps.identify(bundleID: appBundleID, name: appName)
        record(TrustActivity(time: time, appKey: app.key, appName: app.name, category: app.category, action: action,
                             detail: String(detail.prefix(240)), agent: agent, reason: reason))
    }

    func record(_ entry: TrustActivity) {
        activity.append(entry)
        if activity.count > Self.keptActivity { activity.removeFirst(activity.count - Self.keptActivity) }
        saveActivity()
    }

    /// Prune expired grants (the screen calls this on a timer; decide() ignores them anyway).
    func refresh(now: Date = Date()) { pruneExpired(now: now) }

    // MARK: In words

    /// "Your agents can post to Instagram until 04:15, without asking you. Everything else asks you first…"
    func permissionsSummary(now: Date = Date()) -> String {
        let allowed = grants.filter { $0.mode.isPermissive && $0.isActive(at: now) }
            .sorted { ($0.appName, $0.action.rawValue) < ($1.appName, $1.action.rawValue) }
        let blocked = grants.filter { $0.mode == .never }
        var out: String
        if allowed.isEmpty {
            out = "Right now your agents ask you first before they post, send, share or upload anything for you."
        } else {
            let parts = allowed.map { "\($0.action.phrase) \($0.action.preposition) \($0.appName) \(Self.durationPhrase($0.mode, now: now))" }
            out = "Your agents can \(Self.list(parts)), without asking you. Everything else asks you first."
        }
        if !blocked.isEmpty {
            out += " You've told them never to " + Self.list(blocked.map { "\($0.action.phrase) \($0.action.preposition) \($0.appName)" }) + "."
        }
        return out + " Banks and payments always ask you, and passwords and codes are always yours to type."
    }

    /// "In the last hour your agents posted 1 photo to Instagram, allowed by your setting."
    func activitySummary(now: Date = Date(), calendar: Calendar = .current) -> String {
        let windows: [(start: Date, words: String)] = [
            (now.addingTimeInterval(-3600), "In the last hour"),
            (calendar.startOfDay(for: now), "Today"),
            (now.addingTimeInterval(-7 * 86400), "In the last week"),
        ]
        for window in windows {
            let entries = activity.filter { $0.time >= window.start && $0.time <= now.addingTimeInterval(60) }
            guard !entries.isEmpty else { continue }
            var groups: [(key: String, entries: [TrustActivity])] = []
            for e in entries {
                let key = e.appKey + "|" + e.action.rawValue
                if let i = groups.firstIndex(where: { $0.key == key }) { groups[i].entries.append(e) }
                else { groups.append((key, [e])) }
            }
            var parts = groups.prefix(3).map { Self.didPhrase($0.entries) }
            let rest = groups.dropFirst(3).reduce(0) { $0 + $1.entries.count }
            if rest > 0 { parts.append("did \(rest) other \(rest == 1 ? "thing" : "things")") }
            return "\(window.words) your agents \(Self.list(parts)), allowed by your \(groups.count == 1 ? "setting" : "settings")."
        }
        return "Your agents haven't done anything without asking you in the last week."
    }

    // MARK: Helpers

    /// A phone with no passcode can't prove its owner, so it can't give agents more freedom.
    nonisolated static func phoneCanCheckOwner() -> Bool {
        #if canImport(LocalAuthentication)
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        #else
        return false
        #endif
    }

    nonisolated static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// "until 04:15", "for the rest of today", "until tomorrow at 09:00".
    nonisolated static func untilPhrase(_ end: Date, now: Date, calendar: Calendar = .current) -> String {
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        if let midnight, abs(end.timeIntervalSince(midnight)) < 1 { return "for the rest of today" }
        if calendar.isDate(end, inSameDayAs: now) { return "until \(clock(end))" }
        return "until tomorrow at \(clock(end))"
    }

    nonisolated static func durationPhrase(_ mode: GrantMode, now: Date) -> String {
        switch mode {
        case .always: return "any time, until you change it"
        case .allowUntil(let end): return untilPhrase(end, now: now)
        case .ask: return "only when you say yes"
        case .never: return "never"
        }
    }

    /// "a, b and c".
    nonisolated static func list(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }

    /// "posted 1 photo to Instagram", "sent 2 messages in WhatsApp".
    nonisolated static func didPhrase(_ entries: [TrustActivity]) -> String {
        guard let first = entries.first else { return "" }
        let n = entries.count
        let photos = entries.allSatisfy { e in ["photo", "picture", "pic", "selfie", "image"].contains { e.detail.folded.contains($0) } }
        func count(_ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        let app = first.appName
        switch first.action {
        case .post: return "posted \(photos ? count("photo", "photos") : count("post", "posts")) to \(app)"
        case .send: return "sent \(count("message", "messages")) in \(app)"
        case .share: return "shared \(photos ? count("photo", "photos") : count("thing", "things")) in \(app)"
        case .upload: return "uploaded \(photos ? count("photo", "photos") : count("file", "files")) to \(app)"
        case .call: return "made \(count("call", "calls")) on \(app)"
        case .delete: return "deleted \(count("thing", "things")) in \(app)"
        default: return "did \(count("thing", "things")) in \(app)"
        }
    }

    private func upsert(_ g: TrustGrant) {
        grants.removeAll { $0.appKey == g.appKey && $0.action == g.action }
        grants.append(g)
        save()
    }

    private func pruneExpired(now: Date = Date()) {
        let before = grants.count
        grants.removeAll { !$0.isActive(at: now) }
        if grants.count != before { save() }
    }

    private func load() {
        // Anything unreadable counts as nothing allowed: the safe default is to ask.
        // One unreadable entry is dropped on its own, so it can't take the owner's blocks down with it.
        if let data = defaults.data(forKey: Self.grantsKey),
           let saved = try? JSONDecoder().decode([TrustLossy<TrustGrant>].self, from: data) {
            grants = saved.compactMap(\.value)
        }
        if let data = defaults.data(forKey: Self.activityKey),
           let saved = try? JSONDecoder().decode([TrustLossy<TrustActivity>].self, from: data) {
            activity = Array(saved.compactMap(\.value).suffix(Self.keptActivity))
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(grants) { defaults.set(data, forKey: Self.grantsKey) }
    }

    private func saveActivity() {
        if let data = try? JSONEncoder().encode(activity) { defaults.set(data, forKey: Self.activityKey) }
    }
}

/// Decodes one stored entry, or nil if it can't be read (an old version, or edited storage).
private struct TrustLossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// MARK: - Self-test (logic only; runs on a Mac)

extension OwnerPolicy {
    /// Checks the hard caps hold whatever is stored. Returns the failures (empty = all good).
    static func selfTest() async -> [String] {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }
        func isAuto(_ d: PolicyDecision) -> Bool { if case .autoApprove = d { return true }; return false }
        func isAsk(_ d: PolicyDecision) -> Bool { if case .ask = d { return true }; return false }
        func isRefuse(_ d: PolicyDecision) -> Bool { if case .refuse = d { return true }; return false }

        let suite = "kairos.trust.selftest.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return ["couldn't make a test defaults suite"] }
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_793_000_000)

        // Storage someone tampered with: "always" for every action in banks, Instagram and a made-up bank.
        var tampered: [TrustGrant] = []
        let apps: [(String?, String)] = [("uk.co.barclays.bmbappstore", "Barclays"), ("io.b2a.BankProd", "Monzo"),
                                         ("com.burbn.instagram", "Instagram"), (nil, "Acme Savings"),
                                         ("com.example.newbank", "Acme")]
        for (bundle, name) in apps {
            let app = TrustApps.identify(bundleID: bundle, name: name)
            for action in ActionClass.allCases {
                tampered.append(TrustGrant(appKey: app.key, appName: app.name, bundleID: app.bundleID, category: .social,
                                           action: action, mode: .always, duration: .always, setAt: now))
            }
        }
        defaults.set(try? JSONEncoder().encode(tampered), forKey: grantsKey)

        var faceIDCalls = 0
        var faceIDAnswer = true
        let policy = OwnerPolicy(defaults: defaults, verifyOwner: { _ in faceIDCalls += 1; return faceIDAnswer },
                                 ownerCanBeChecked: { true })

        // 1. Banking can never auto-approve, even with "always" stored, by bundle ID, by name, or by money words.
        for (bundle, name) in apps where bundle != "com.burbn.instagram" {
            for action in ActionClass.allCases {
                let d = policy.decide(appBundleID: bundle, appName: name, action: action, now: now)
                check(!isAuto(d), "bank \(name) auto-approved \(action)")
            }
        }
        check(isAsk(policy.decide(appBundleID: nil, appName: "Barclays", action: .send, now: now)), "Barclays by name should ask")
        check(TrustApps.identify(bundleID: "com.example.newbank", name: "Acme").category == .banking, "bank-like bundle not banking")
        check(TrustApps.identify(bundleID: nil, name: "Acme Savings").category == .banking, "savings app not banking")
        if case .ask(let w) = policy.decide(appBundleID: "uk.co.barclays.bmbappstore", appName: nil, action: .pay, now: now) {
            check(w?.contains("exactly who the money") == true, "bank payment should carry the strongest warning")
        } else { failures.append("bank payment should ask") }

        // 2. Credentials always refused, settings always refused, money always asks, even in Instagram with "always".
        for (bundle, name) in apps {
            check(isRefuse(policy.decide(appBundleID: bundle, appName: name, action: .credentials, now: now)), "credentials not refused in \(name)")
            check(isRefuse(policy.decide(appBundleID: bundle, appName: name, action: .settings, now: now)), "settings not refused in \(name)")
        }
        check(isAsk(policy.decide(appBundleID: "com.burbn.instagram", appName: nil, action: .pay, now: now)), "pay in Instagram should ask")
        check(isAsk(policy.decide(appBundleID: "com.amazon.AmazonUK", appName: nil, action: .purchase, now: now)), "purchase should ask")
        check(isRefuse(policy.decide(appBundleID: "com.apple.Preferences", appName: nil, action: .post, now: now)), "Settings app taps should be refused")
        // The owner's grant does work where there is no cap.
        check(isAuto(policy.decide(appBundleID: "com.burbn.instagram", appName: "Instagram", action: .post, now: now)), "Instagram post with always should auto-approve")

        // 3. revokeAll takes everything back, and it stays taken back after a restart.
        policy.revokeAll()
        check(policy.grants.filter(\.mode.isPermissive).isEmpty, "revokeAll left permissions")
        check(isAsk(policy.decide(appBundleID: "com.burbn.instagram", appName: nil, action: .post, now: now)), "after revokeAll Instagram should ask")
        let reloaded = OwnerPolicy(defaults: defaults, verifyOwner: { _ in true }, ownerCanBeChecked: { true })
        check(reloaded.grants.filter(\.mode.isPermissive).isEmpty, "revokeAll wasn't saved")

        // 4. grant(): hard caps refused before Face ID; Face ID "no" changes nothing; "yes" grants; expiry works.
        faceIDCalls = 0
        if case .granted = await policy.grant(appBundleID: "io.b2a.BankProd", appName: "Monzo", action: .send, duration: .always, now: now) {
            failures.append("granted a bank")
        }
        if case .granted = await policy.grant(appBundleID: nil, appName: "Instagram", action: .credentials, duration: .always, now: now) {
            failures.append("granted credentials")
        }
        check(faceIDCalls == 0, "Face ID asked for something that can never be allowed")
        faceIDAnswer = false
        if case .granted = await policy.grant(appBundleID: nil, appName: "Instagram", action: .post, duration: .oneHour, now: now) {
            failures.append("granted without the owner")
        }
        check(faceIDCalls == 1, "grant didn't check Face ID")
        faceIDAnswer = true
        let result = await policy.grant(appBundleID: nil, appName: "Instagram", action: .post, duration: .oneHour, now: now)
        if case .granted(let g) = result { check(g.appKey == "com.burbn.instagram", "Instagram by name should key by bundle ID") }
        else { failures.append("owner-approved grant failed") }
        check(isAuto(policy.decide(appBundleID: "com.burbn.instagram", appName: nil, action: .post, now: now.addingTimeInterval(3599))), "one-hour grant should work for the hour")
        check(isAsk(policy.decide(appBundleID: "com.burbn.instagram", appName: nil, action: .post, now: now.addingTimeInterval(3601))), "one-hour grant should expire")
        policy.refresh(now: now.addingTimeInterval(3601))
        check(policy.grants.isEmpty, "expired grant wasn't pruned")

        // 5. Delete needs its own grant; a post grant doesn't cover it.
        _ = await policy.grant(appBundleID: "com.burbn.instagram", appName: "Instagram", action: .post, duration: .always, now: now)
        check(isAsk(policy.decide(appBundleID: "com.burbn.instagram", appName: nil, action: .delete, now: now)), "post grant covered delete")
        _ = await policy.grant(appBundleID: "com.burbn.instagram", appName: "Instagram", action: .delete, duration: .today, now: now)
        check(isAuto(policy.decide(appBundleID: "com.burbn.instagram", appName: nil, action: .delete, now: now)), "explicit delete grant should work")

        // 6. Blocks are honoured and survive "Stop everything".
        policy.forbid(appBundleID: "net.whatsapp.WhatsApp", appName: "WhatsApp", action: .call, now: now)
        policy.revokeAll()
        check(isRefuse(policy.decide(appBundleID: "net.whatsapp.WhatsApp", appName: nil, action: .call, now: now)), "owner's block not honoured")

        // 7. Reading taps and words.
        check(ActionClass.forTap(label: "Share", appBundleID: "com.burbn.instagram") == .post, "Instagram Share should be posting")
        check(ActionClass.forTap(label: "Send", appBundleID: "net.whatsapp.WhatsApp") == .send, "Send")
        check(ActionClass.forTap(label: "Send money") == .pay, "Send money should be paying")
        check(ActionClass.forTap(label: "Delete for everyone") == .delete, "Delete")
        check(ActionClass.forTap(label: "Anything", kind: "SecureTextField") == .credentials, "secure field")
        check(ActionClass.forTyping(text: "4242 4242 4242 4242") == .credentials, "card number")
        check(ActionClass.forTyping(text: "07700 900123") == nil, "phone number isn't a card")
        check(ActionClass(spoken: "send messages") == .send && ActionClass(spoken: "posting") == .post
              && ActionClass(spoken: "send money") == .pay, "spoken actions")
        check(TrustApps.byName("facebook messenger")?.name == "Messenger" && TrustApps.byName("insta")?.name == "Instagram",
              "app names")
        check(TrustApps.identify(bundleID: nil, name: "Signal Bank").category == .banking, "a bank named like a chat app")
        for app in TrustApps.catalogue {
            let seen = TrustApps.identify(bundleID: app.bundleID, name: app.name)
            check(seen.category == app.category, "\(app.name) changed category to \(seen.category)")
            check(TrustApps.identify(bundleID: nil, name: app.name).name == app.name, "\(app.name) not found by its name")
        }

        // 7b. Money, account takeover and phone security hiding behind everyday verbs.
        for (label, want) in [("Send £20", ActionClass.pay), ("Tip $5", .pay), ("Send gift", .pay), ("Get coins", .pay),
                              ("Boost post", .purchase), ("Promote", .purchase), ("Delete account", .settings),
                              ("Erase This Device", .settings), ("Link a device", .settings), ("Change number", .settings),
                              ("Yes, it's me", .credentials), ("Approve sign-in", .credentials)] {
            let got = ActionClass.forTap(label: label, appBundleID: "com.burbn.instagram")
            check(got == want, "tap ‘\(label)’ read as \(String(describing: got)), not \(want)")
        }
        check(ActionClass.forTap(label: "Share", appBundleID: "net.whatsapp.WhatsApp") == .share, "plain Share")
        check(ActionClass.forTap(label: "Post", appBundleID: "com.burbn.instagram") == .post, "plain Post")
        check(TrustApps.identify(bundleID: "com.getmondo.Monzo", name: "Monzo").category == .banking, "Monzo under an unknown ID")
        check(TrustApps.identify(bundleID: "com.monzo.ios", name: nil).category == .banking, "bank name in a bundle ID")
        for (bundle, name) in [("com.apple.Passwords", "Passwords"), ("com.apple.findmy", "Find My"),
                               ("com.google.Authenticator", "Authenticator"), (nil, "Bitwarden")] as [(String?, String)] {
            check(isRefuse(policy.decide(appBundleID: bundle, appName: name, action: .delete, now: now)), "\(name) not refused")
            if case .granted = await policy.grant(appBundleID: bundle, appName: name, action: .delete, duration: .always, now: now) {
                failures.append("granted \(name)")
            }
        }

        // 7c. Who is in front: the phone's bundle ID, never a name on its own.
        faceIDAnswer = true
        _ = await policy.grant(appBundleID: nil, appName: "Instagram", action: .post, duration: .oneHour, now: now)
        check(!isAuto(policy.decide(appBundleID: nil, appName: "Instagram", action: .post, now: now)), "auto-approved by name only")
        check(!isAuto(policy.decide(appBundleID: "com.apple.springboard", appName: "Instagram", action: .post, now: now)),
              "auto-approved on the Home Screen")
        check(!isAuto(policy.decide(appBundleID: "com.evil.ig", appName: "Instagram", action: .post, now: now)),
              "another app calling itself Instagram auto-approved")
        _ = await policy.grant(appBundleID: nil, appName: "Acme Chat", action: .send, duration: .always, now: now)
        check(isAuto(policy.decide(appBundleID: "com.acme.chat", appName: "Acme Chat", action: .send, now: now)),
              "app allowed by name should work under its own bundle ID")
        check(!isAuto(policy.decide(appBundleID: "com.getmondo.Monzo", appName: "Acme Chat", action: .send, now: now)),
              "a name lent its permission to a bank")
        check(!isAuto(policy.decide(appBundleID: "com.example.notes", appName: "Acme Chat", action: .send, now: now)),
              "a name lent its permission to another app")
        // The clock moved back three hours: a one-hour grant must not last four.
        check(!isAuto(policy.decide(appBundleID: "com.burbn.instagram", appName: nil, action: .post,
                                    now: now.addingTimeInterval(-3 * 3600))), "clock moved back stretched a grant")
        // A stored one-hour grant edited to last a year doesn't count.
        let forged = TrustGrant(appKey: "com.burbn.instagram", appName: "Instagram", bundleID: "com.burbn.instagram",
                                category: .social, action: .share, mode: .allowUntil(now.addingTimeInterval(365 * 86400)),
                                duration: .oneHour, setAt: now)
        check(!forged.isActive(at: now), "a year-long time limit counted")
        // One unreadable stored entry doesn't wipe the owner's blocks.
        let block = TrustGrant(appKey: "net.whatsapp.whatsapp", appName: "WhatsApp", bundleID: "net.whatsapp.WhatsApp",
                               category: .messaging, action: .call, mode: .never, duration: nil, setAt: now)
        if let blockData = try? JSONEncoder().encode(block), let blockJSON = String(data: blockData, encoding: .utf8) {
            let stored = "[\(blockJSON), {\"appKey\": \"x\", \"action\": \"teleport\"}]"
            let lossySuite = suite + ".lossy"
            if let d2 = UserDefaults(suiteName: lossySuite) {
                d2.set(Data(stored.utf8), forKey: grantsKey)
                let p2 = OwnerPolicy(defaults: d2, verifyOwner: { _ in true }, ownerCanBeChecked: { true })
                check(isRefuse(p2.decide(appBundleID: "net.whatsapp.WhatsApp", appName: nil, action: .call, now: now)),
                      "a bad stored entry wiped the owner's block")
                d2.removePersistentDomain(forName: lossySuite)
            }
        }

        // 8. The activity log keeps the last 300, and says what happened in words.
        for i in 0..<305 {
            policy.record(appBundleID: "com.burbn.instagram", appName: nil, action: .post, detail: "photo \(i)",
                          agent: "Phone operator", at: now.addingTimeInterval(Double(i) - 400))
        }
        check(policy.activity.count == keptActivity, "activity not capped at 300")
        let words = policy.activitySummary(now: now)
        check(words.hasPrefix("In the last hour your agents posted 300 photos to Instagram"), "activity summary: \(words)")
        return failures
    }
}
