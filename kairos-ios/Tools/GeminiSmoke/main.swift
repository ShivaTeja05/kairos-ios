import AppKit
import Foundation

// Calls Gemini from this Mac with the SAME Swift code the iPhone agents use (GeminiProvider, GeminiContent, Schema,
// and the research team's GroundedSearch), so a wrong model id or request shape shows up here instead of on stage.
// Never prints the key.

@main
struct GeminiSmoke {
    static func main() async {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["GEMINI_API_KEY"], key.count >= 20 else { print("No GEMINI_API_KEY."); exit(2) }
        let model = env["GEMINI_MODEL"] ?? AgentSettings.defaultModel
        let provider = GeminiProvider(model: model, apiKey: key, timeout: 40)
        print("Model: \(model)  (key ends …\(key.suffix(3)))\n")
        var failures = 0

        let system = """
        You are Kairos, a kind helper on an iPhone for people who are not confident with technology. \
        It is Sunday 25 October 2026, 09:00 (Europe/London, UTC+00:00). When asked to do something, call a tool. \
        Use ISO 8601 with the UTC offset in tool arguments. Never say you did something unless a tool result says so.
        """
        let tools: [JSONValue] = [
            ["name": "create_reminder", "description": "Create a reminder on the phone.",
             "parameters": Schema.object(["title": Schema.string("What to remember."),
                                          "due_iso": Schema.string("When, ISO 8601 with offset."),
                                          "repeat": Schema.string("How often.", oneOf: ["none", "daily", "weekly"])],
                                         required: ["title"])],
            ["name": "set_alarm", "description": "Set an alarm.",
             "parameters": Schema.object(["time_hhmm": Schema.string("24-hour time, e.g. 07:00."),
                                          "label": Schema.string("What it's for.")], required: ["time_hhmm"])],
            ["name": "call_contact", "description": "Call someone from the person's contacts.",
             "parameters": Schema.object(["contact_name": Schema.string("Who to call.")], required: ["contact_name"])],
        ]

        // 1 + 2. Tool call, then send the result back (proves thought signatures and ids round-trip).
        var history: [JSONValue] = [GeminiContent.user("Remind me to take my pills at 8 tonight, every night")]
        do {
            let t0 = Date()
            let turn = try await provider.step(system: system, history: history, tools: tools, requireTool: false)
            print("1. Tool call: \(ms(t0)) ms")
            print("   calls: \(turn.calls.map { "\($0.name) \($0.args.compactString)" })")
            print("   thought signature in reply: \(turn.content.compactString.contains("thoughtSignature") ? "yes" : "no")")
            if let call = turn.calls.first {
                history.append(turn.content)
                history.append(GeminiContent.functionResponses([(call, ["ok": true, "result": ["saved": true, "repeats": "daily"]])]))
                let t1 = Date()
                let turn2 = try await provider.step(system: system, history: history, tools: tools, requireTool: false)
                print("2. After the tool result: \(ms(t1)) ms — \"\(turn2.text)\"")
                print(turn2.calls.isEmpty ? "   PASS" : "   (it asked for another tool: \(turn2.calls.map(\.name)))")
            } else {
                print("   FAIL: no tool call. Text: \(turn.text)")
                failures += 1
            }
        } catch {
            print("   FAIL: \(describe(error))")
            failures += 1
        }

        // 3. Structured output (the letter reader's JSON).
        let letterSchema = Schema.object([
            "what_it_is": Schema.string("One line: what kind of letter."),
            "from": Schema.string("Who sent it."),
            "amount": Schema.string("Money asked for, if any."),
            "deadline_iso": Schema.string("Deadline as YYYY-MM-DD, if any."),
            "action": Schema.string("What the person must do, in plain words."),
            "scam_signs": Schema.array(of: Schema.string("A warning sign."), "Scam warning signs, if any."),
        ], required: ["what_it_is", "action"])
        let letter = """
        Oxford City Council — Council Tax reminder. Account 40012345. You have not paid the instalment of £142.50 \
        due on 1 October 2026. Please pay by 8 November 2026 to avoid a summons. Pay online at oxford.gov.uk/counciltax.
        """
        do {
            let t0 = Date()
            let json = try await provider.generate(system: "Read the letter and fill in the facts. Plain British English.",
                                                   parts: [GeminiContent.text(letter)], jsonSchema: letterSchema)
            let parsed = JSONValue.decode(Data(json.utf8))
            print("3. Structured output: \(ms(t0)) ms — \(parsed == nil ? "FAIL (not JSON)" : "PASS")")
            print("   \(json.prefix(400))")
            if parsed == nil { failures += 1 }
        } catch {
            print("3. Structured output FAIL: \(describe(error))")
            failures += 1
        }

        // 4. A photo (inlineData), like a picture of a letter.
        if let jpeg = renderLetterJPEG("COUNCIL TAX\nPay £142.50 by 8 November 2026\nOxford City Council") {
            do {
                let t0 = Date()
                let text = try await provider.generate(system: "Say in one short sentence what this letter asks for.",
                                                       parts: [GeminiContent.jpeg(jpeg), GeminiContent.text("What does this say?")], jsonSchema: nil)
                print("4. Photo: \(ms(t0)) ms — PASS — \"\(text)\"")
            } catch {
                print("4. Photo FAIL: \(describe(error))")
                failures += 1
            }
        }

        // 5. Grounded search, as the research team's researchers do it: Google Search must send sources back.
        do {
            let t0 = Date()
            // Same model the phone's agents search with (3.5 models can't search on the free tier).
            let searchModel = env["GEMINI_SEARCH_MODEL"] ?? GroundedSearch.defaultSearchModel
            print("   (searching with \(searchModel))")
            let search = GroundedSearch(model: searchModel, apiKey: key, timeout: 40)
            let today = DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .none)
            let found = try await search.search("What are two of the main UK news stories today, \(today)? Two sentences.",
                                                system: GroundedSearch.researcherSystem(number: 1))
            let n = found.sources.count
            print("5. Grounded search: \(ms(t0)) ms — \(n > 0 ? "PASS" : "FAIL (no sources came back)")")
            print("   sources came back: \(n > 0 ? "yes" : "no") (\(n)); Google searches run: \(found.queries.count); "
                  + "search suggestions: \(found.suggestionsHTML == nil ? "no" : "yes"); citations: \(found.cited.components(separatedBy: "[").count - 1)")
            if let chosen = found.fallbackFrom {
                print("   NOTE: \(chosen) can't search the web here, so \(found.model) answered instead (the app does the same).")
            }
            print("   requests sent: \(found.requests)")
            if n > 0 { print("   sites: \(found.sources.prefix(5).map(\.title).joined(separator: ", "))") }
            print("   \"\(found.text.prefix(240))\"")
            if n == 0 { failures += 1 }
        } catch {
            print("5. Grounded search FAIL: \(describe(error))")
            failures += 1
        }

        print(failures == 0 ? "\nAll good: the iPhone agents' Gemini calls work with this key and model."
                            : "\n\(failures) check(s) failed — send the output above to Claude (it never contains the key).")
        exit(failures == 0 ? 0 : 1)
    }

    static func ms(_ t: Date) -> Int { Int(Date().timeIntervalSince(t) * 1000) }

    static func describe(_ error: Error) -> String {
        if let e = error as? ResearchError {
            if case .http(let code, let body) = e { return "HTTP \(code): \(body)" }
            return "\(e) — \(e.errorDescription ?? "")"
        }
        if let e = error as? ModelError {
            if case .http(let code, let body) = e { return "HTTP \(code): \(body)" }
            return "\(e) — \(e.errorDescription ?? "")"
        }
        return error.localizedDescription
    }

    static func renderLetterJPEG(_ text: String) -> Data? {
        let size = NSSize(width: 900, height: 500)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(in: NSRect(x: 50, y: 50, width: 800, height: 400),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 44, weight: .semibold), .foregroundColor: NSColor.black])
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}
