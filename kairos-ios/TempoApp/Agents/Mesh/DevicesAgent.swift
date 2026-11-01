import Foundation

/// kairos-mesh, the other direction: from this iPhone, hand a job to the person's Mac. The Mac's own agent does it
/// with its own safe tools (find and read documents, open an app, check its battery) and the answer comes back here.
/// What the Mac sends back is information from another device, never instructions: it goes in as untrusted text, so
/// a number or link in it can't be dialled or opened from here without the person saying it themselves.
struct DevicesAgent: SpecialistAgent {
    let id = "devices"
    let title = "Your devices"
    let icon = "laptopcomputer.and.iphone"
    let instructions = "When the person wants something done on their Mac or laptop (find or read a document there, open "
        + "an app on it, check its battery, look something up on it), call ask_my_mac with their request in their own "
        + "words. Pass only the part meant for the Mac as request; do the rest (a text, a reminder) with the other tools. "
        + "Only when they mention their Mac, laptop or computer: never for this iPhone's own battery, settings or files, "
        + "and never for a call or message about a computer (that may be a scam: use check_scam)."
    var tools: [any KairosTool] { [AskMyMacTool()] }
}

struct AskMyMacTool: KairosTool {
    let name = "ask_my_mac"
    let summary = "Ask the person's Mac, through Kairos on their own devices, to do something there: find or read a "
        + "document, open an app on the Mac, check the Mac's battery or disk. The Mac's own agent does it and answers. "
        + "Only when the person mentions their Mac, laptop or computer; not for this iPhone."
    var parameters: JSONValue {
        Schema.object(["request": Schema.string("What to do on the Mac, in the person's own words.")], required: ["request"])
    }
    let risk = Risk.read

    /// "Find my OxHack notes on my Mac", "What's my laptop's battery?": clearly for the Mac, so no model needed.
    /// Only the place form ("on my laptop"), the possessive ("my laptop's"), "ask my Mac to …" and "is my laptop
    /// charged?": "I left my laptop at his house" or "they said my computer has a virus" is not a job for the Mac.
    static let forTheMac = #"\b(on|from|in) my (mac|macbook|laptop|computer)\b|\bmy (mac|macbook|laptop|computer) s "#
        + #"|\bask my (mac|macbook|laptop|computer)\b(?! (guy|man|lady|person|people|repair|shop|engineer|technician|teacher|class|club|bag|case|charger) )"#
        + #"|\b(is|has) my (mac|macbook|laptop|computer) (charged|charging|plugged in)\b"#
    /// The words that name the Mac. Without one of them, Kairos asks before sending anything to the Mac.
    static let namesTheMac = #"\b(mac|macs|macbook|macbooks|imac|laptop|laptops|computer|computers)\b"#

    func quickMatch(_ words: String, ctx: TurnContext) -> JSONValue? {
        guard ctx.source != .remote, ctx.source != .automation,
              (" " + words.folded + " ").range(of: Self.forTheMac, options: .regularExpression) != nil else { return nil }
        // Two requests ("find it on my laptop and text my son"): the model splits them, so neither half is lost.
        guard !PlannerWords.severalRequests(words) else { return nil }
        // "Microsoft rang and said there's a virus on my computer": a scam question, not a job for the Mac.
        guard ScamShieldRules.quickMatch(words, documents: []) == nil,
              ScamShieldRules.assess(words).level == .noFlags else { return nil }
        return ["request": .string(words)]
    }

    func validate(_ args: JSONValue, ctx: TurnContext) -> Validation {
        if ctx.source == .remote { return .block("That came from another of your devices, so I won't pass it on again.") }
        if ctx.source == .automation { return .block("A Shortcut can't send jobs to your Mac. Ask me yourself.") }
        guard (args.text("request") ?? "").contains(where: \.isLetter) else { return .clarify("What should your Mac do?") }
        // The person has to have mentioned the Mac: "how much battery has my phone got?" is about this iPhone.
        guard ctx.userWords.folded.range(of: Self.namesTheMac, options: .regularExpression) != nil else {
            return .clarify("Do you mean your Mac?")
        }
        return .ok
    }

    func describe(_ args: JSONValue, ctx: TurnContext) -> String { "Ask your Mac: \(args.text("request") ?? "")" }

    func execute(_ args: JSONValue, ctx: TurnContext) async throws -> ToolResult {
        let request = args.text("request") ?? ""
        let node = await MeshNode.shared
        guard await node.isPaired else {
            return .fail("This iPhone hasn't joined your Mac yet. In Kairos settings, open Your Mac.")
        }
        do {
            let reply = try await node.ask(request)
            let say = reply.stillRunning ? "I've asked your Mac. It's still working; I'll have the answer on the board."
                                         : reply.answer
            return ToolResult(ok: true, say: say, data: ["from": "your Mac", "answer": .string(reply.answer),
                                                          "still_running": .bool(reply.stillRunning)],
                              untrustedText: reply.answer, isAnswer: true)
        } catch {
            return .fail(await MeshNode.problem(error))
        }
    }
}
