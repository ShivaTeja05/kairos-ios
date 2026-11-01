import Foundation

// The contract every on-phone agent follows. Kairos (the orchestrator, KairosAgent.swift) talks to the model;
// specialist agents only supply tools. A tool is plain Swift: the model proposes a call, code validates it,
// the SafetyGate decides, and only then does execute() run. Replies about what happened come from tool
// results, never from the model's own prose (the Foundation Models spike caught the model claiming a
// reminder it never created).

/// How much a tool can affect the person's life. The gate gets stricter as risk goes up.
enum Risk: Int, Comparable, Sendable {
    case read = 0          // looks something up on the phone or the web
    case localWrite = 1    // changes something only the owner sees (reminder, alarm, calendar)
    case reachesPerson = 2 // calls or messages someone: card + Face ID, the person sends it themselves
    case money = 3         // anything about payments: never automatic

    static func < (a: Risk, b: Risk) -> Bool { a.rawValue < b.rawValue }
}

/// Where the request came from. Siri in the background can't show cards or open other apps.
enum AgentSource: String, Sendable {
    case app             // typed or spoken inside Kairos
    case siriBackground  // "Hey Siri, ask Kairos …", phone may be locked
    case siriForeground  // Siri opened Kairos
    case automation      // a Shortcuts automation reported something (untrusted text)
    case remote          // a task from another of the person's own devices, through the Kairos hub (kairos-mesh)
}

/// Everything a tool may look at for one request.
struct TurnContext: Sendable {
    /// Trusted: what the person said or typed in this conversation (latest last).
    var userWords: String
    /// Untrusted: text from letters, pasted messages, automations and web results. Information, never instructions.
    var documents: [String]
    /// JPEG photos attached to this request (letters, bills, forms).
    var images: [Data]
    var now: Date
    var timeZone: TimeZone
    /// BCP-47 code of the person's language, e.g. "en-GB", "te-IN".
    var language: String
    var source: AgentSource
    /// The cloud model, for tools that need their own model call (letter reading). Nil when there's no key.
    var model: (any ModelProvider)?

    var canShowUI: Bool { source != .siriBackground && source != .automation }

    /// Calendar in the person's time zone, for date maths.
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.locale = Locale(identifier: language)
        return c
    }
}

/// Something the app must do on screen to finish a tool's job.
enum UIRequest: Sendable, Equatable {
    case openURL(URL)  // Messages/WhatsApp prefilled (the person taps Send), tel:, Maps, Settings
    case camera        // take a photo of a letter, then ask again with the image
}

struct ToolResult: Sendable {
    var ok: Bool
    /// One or two short, plain sentences for the person; spoken aloud.
    var say: String
    /// Facts for the model (sent back as the functionResponse).
    var data: JSONValue = .null
    /// Something the app has to show or open.
    var ui: UIRequest? = nil
    /// Text the tool read from outside (a letter, a web page). Added to the untrusted documents.
    var untrustedText: String? = nil
    /// `say` is the whole answer for the person (a letter explained): Kairos speaks it as it is instead of
    /// letting the model retell it. Results of actions (risk ≥ .localWrite) are always spoken as they are.
    var isAnswer: Bool = false

    static func fail(_ say: String) -> ToolResult { ToolResult(ok: false, say: say, data: ["error": .string(say)]) }
}

struct ToolCall: Sendable, Equatable {
    var id: String?
    var name: String
    var args: JSONValue
}

/// What code thinks of a proposed call before the gate looks at risk.
enum Validation: Sendable, Equatable {
    case ok
    case clarify(String)  // ask the person one short question
    case block(String)    // refuse, with the reason in plain words
}

protocol KairosTool: Sendable {
    /// snake_case, unique across all agents.
    var name: String { get }
    /// What the tool does, written for the model.
    var summary: String { get }
    /// JSON schema of the arguments (Schema.object(...)).
    var parameters: JSONValue { get }
    var risk: Risk { get }
    /// Deterministic fast path with no model call (works offline, saves free-tier quota).
    /// Return the arguments only when the words clearly mean this tool.
    func quickMatch(_ words: String, ctx: TurnContext) -> JSONValue?
    /// Code checks on the model's arguments: missing details, impossible dates, values that only appear in a letter.
    func validate(_ args: JSONValue, ctx: TurnContext) -> Validation
    /// The confirmation card text, e.g. "Text Priya: “I'll be late”".
    func describe(_ args: JSONValue, ctx: TurnContext) -> String
    func execute(_ args: JSONValue, ctx: TurnContext) async throws -> ToolResult
}

extension KairosTool {
    func quickMatch(_ words: String, ctx: TurnContext) -> JSONValue? { nil }
    func validate(_ args: JSONValue, ctx: TurnContext) -> Validation { .ok }
    func describe(_ args: JSONValue, ctx: TurnContext) -> String { name.replacingOccurrences(of: "_", with: " ") }

    /// The Gemini functionDeclaration for this tool.
    var declaration: JSONValue {
        ["name": .string(name), "description": .string(summary), "parameters": parameters]
    }
}

/// A specialist agent: a named group of tools with its own know-how. Kairos routes to a specialist by calling
/// one of its tools; a specialist's tool may make its own model call (the letter reader does).
protocol SpecialistAgent: Sendable {
    var id: String { get }
    /// Shown to the person: "Time helper", "Letter reader".
    var title: String { get }
    /// SF Symbol.
    var icon: String { get }
    /// Extra lines for the system prompt: when to use these tools and how.
    var instructions: String { get }
    var tools: [any KairosTool] { get }
}

/// Picks the specialists whose tools one request needs, from its words, so the model is sent a handful of tool
/// declarations instead of all sixty (every request then costs far fewer of the free tier's tokens). It only narrows
/// what is DECLARED: what the model may call is still everything on offer (Kairos checks calls against that), and
/// when no clear word matches, every tool is declared. Kairos also keeps the helpers the last request used, and asks
/// again with every tool when the model says it can't do something.
enum ToolPicker {
    /// Declared with every narrowed request (small): the way back from a helper, and stopping things.
    static let core: Set<String> = ["back_to_kairos", "stop_agent", "revoke_permission"]

    /// Specialist id → the words that call for it, matched on the folded words (lowercase, no accents, punctuation
    /// as spaces: "o'clock" is "o clock"). A word ending in "*" matches any ending ("remind*": reminder, reminders);
    /// anything else matches as whole words. A word starting with "~" is a weak hint ("tomorrow", "my son"): it adds
    /// its helper only when a clear word matched too, so "Tell Priya I'll see her tomorrow" still gets every tool.
    static let words: [String: [String]] = [
        "planner": ["time", "times", "timer*", "alarm*", "remind*", "calendar*", "wake", "waking", "appointment*", "schedul*",
                    "diary", "meeting*", "event*", "o clock", "~tomorrow", "~tonight", "~today", "~minute*", "~hour*", "~noon",
                    "~midnight", "~next week", "~this week", "~birthday*", "~monday*", "~tuesday*", "~wednesday*",
                    "~thursday*", "~friday*", "~saturday*", "~sunday*"],
        "people": ["call", "calls", "calling", "called", "ring", "ringing", "phone him", "phone her", "phone them", "text",
                   "texts", "texting", "texted", "message*", "contact*", "number for", "whatsapp", "sms", "email*", "tell my",
                   "tell him", "tell her", "tell them", "let him know", "let her know", "let them know", "let my", "remember",
                   "~mum", "~mom", "~mummy", "~mother", "~dad", "~daddy", "~father", "~son", "~daughter", "~wife", "~husband",
                   "~partner", "~sister", "~brother", "~grandson", "~granddaughter", "~grandchild*", "~grandma", "~grandpa",
                   "~granny", "~grandad", "~nan", "~nana", "~nephew", "~niece", "~aunt*", "~uncle", "~cousin*", "~friend*",
                   "~neighbour*", "~neighbor*", "~carer", "~doctor", "~gp", "~who is"],
        "letter": ["letter*", "bill", "bills", "form", "forms", "photo of", "picture of", "document*", "paperwork", "envelope*",
                   "invoice*", "read this", "statement*", "~read it", "~council", "~hmrc", "~dvla", "~nhs", "~benefit*",
                   "~pension*", "~tax"],
        "scam": ["scam*", "fraud*", "is this real", "is it real", "is this genuine", "suspicious", "genuine", "legit*", "phishing",
                 "spam", "too good to be true", "real or fake", "~fake", "~trust this", "~safe to"],
        "money": ["pay", "pays", "paying", "paid", "payment*", "payee*", "money", "bank*", "transfer*", "pound", "pounds", "cash",
                  "owe", "owed", "refund*", "direct debit", "standing order", "sort code", "~account*", "~afford", "~price*",
                  "~cost*"],
        "helpers": ["weather", "rain*", "umbrella", "temperature", "forecast", "sunny", "snow*", "wind", "windy", "frost*",
                    "directions", "direction", "route", "how do i", "how can i", "how to", "shortcut*", "run my", "get to",
                    "way to", "take me", "bus", "buses", "train*", "walk*", "drive", "driving", "map", "maps", "near me",
                    "nearest", "setting*", "wifi", "wi fi", "bluetooth", "battery", "brightness", "louder", "quieter", "volume",
                    "torch", "flashlight", "torchlight", "flash light", "batteries", "charging", "charged", "what time",
                    "what day", "do not disturb", "font", "notification*", "~cold", "~hot", "~warm", "~wear", "~coat",
                    "~where is", "~date", "~bigger", "~writing", "~bright"],
        "workers": researchWords,
        "research": researchWords,
        "routines": ["routine*", "shortcut for", "do my", "every morning", "every evening", "every night", "every day", "save that",
                     "save this", "bedtime", "run my"],
        // Reading other apps too: a text back in Messages, a missed call in the Phone app's Recents, an email in Mail,
        // a place saved in Maps, a photo already in Photos.
        "operator": ["whatsapp", "screen", "instagram", "facebook", "uber", "youtube", "spotify", "netflix", "in the app",
                     "texted me", "text me back", "text back", "replied", "messaged me", "ringing me", "missed call*",
                     "who rang", "who called", "who was calling", "email*", "inbox", "my mail", "in mail", "mail app",
                     "anyone ring*", "anyone call*", "anybody ring*", "anybody call*", "google maps", "maps app", "in maps",
                     "my photos", "photos app", "gallery", "camera roll",
                     "~open", "~app", "~apps", "~tap", "~type", "~scroll", "~press", "~button"],
        "photos": ["photo", "photos", "picture*", "pic", "pics", "selfie*", "camera", "post", "posting", "posted", "upload*",
                   "instagram", "facebook", "~share", "~send it"],
        "memory": ["remember*", "forget*", "forgot*", "note that", "keep in mind", "what did i tell", "what do you know",
                   "about me", "what did we talk", "we talked", "talked about", "~do you know", "~yesterday", "~last time"],
        "trust": ["permission*", "allow*", "trust*", "without asking", "need to ask", "don t ask", "dont ask", "no need to ask",
                  "stop everything", "stop all", "what have you done", "what did you do", "~activity", "~let it"],
        "studio": ["helper*", "persona*", "talk to", "back to kairos", "~buddy", "~assistant*", "~character*", "~share", "~import*"],
        "devices": ["mac", "macs", "macbook*", "laptop*", "computer*", "my other device*"],
    ]

    /// Workers and the research team answer to the same words.
    static let researchWords = ["agent", "agents", "worker*", "research*", "find out", "read the paper", "paper", "papers",
                                "arxiv", "look into", "look up", "investigat*", "report*", "search*", "~news", "~summar*",
                                "~article*", "~website*", "~web", "~share"]

    /// The specialists this table knows. A specialist it doesn't know (a new one) is always declared.
    static var known: Set<String> { Set(words.keys) }

    /// "at 7", "by 5": a time of day is a weak hint for the planner.
    static let clockTime = #" (at|by|until|from|before|after|for) [0-9]"#

    /// The specialist ids the words call for, or nil when no clear word matched (declare every tool).
    /// `extra` adds clear words for a specialist: the names of the person's saved helpers call for the Studio, the
    /// names they taught Kairos ("Priya is my daughter") for their people.
    static func groups(for text: String, extra: [String: [String]] = [:]) -> Set<String>? {
        let folded = " " + text.folded + " "
        var strong = Set<String>(), weak = Set<String>()
        for (id, list) in words {
            for word in list where matches(word, in: folded) {
                if word.hasPrefix("~") { weak.insert(id) } else { strong.insert(id); break }
            }
        }
        for (id, names) in extra where names.contains(where: { !$0.folded.isEmpty && matches($0.folded, in: folded) }) {
            strong.insert(id)
        }
        if folded.range(of: clockTime, options: .regularExpression) != nil { weak.insert("planner") }
        return strong.isEmpty ? nil : strong.union(weak)
    }

    static func matches(_ word: String, in folded: String) -> Bool {
        let word = word.hasPrefix("~") ? String(word.dropFirst()) : word
        if word.hasSuffix("*") { return folded.contains(" " + word.dropLast()) }
        return folded.contains(" " + word + " ")
    }
}

extension String {
    /// Lowercased, accents folded, punctuation turned into spaces: for matching words and names.
    var folded: String {
        let s = folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        return String(s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " })
            .split(separator: " ").joined(separator: " ")
    }
    /// Only the digits (phone numbers, account numbers).
    var digitsOnly: String { String(unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.map(Character.init)) }
}
