import SwiftUI
import UIKit

// Kairos's routing self-test, on the real phone with the real model, without doing anything.
//
// Each case sends one sentence to KairosAgent with dryRun on: the rules (quickMatch) and Gemini run exactly as
// usual, but no tool's execute() runs and no card shows (KairosAgent.dryRunOutcome). What Kairos WOULD have called
// is recorded and checked: "Create an agent to …" must reach spawn_agent and never create_agent.
//
// Start it with the launch argument -KairosSelfTest
//   xcrun devicectl device process launch --device <id> --terminate-existing <bundle id> -- -KairosSelfTest
// or More › Developer › Run self-test on the agent screen. Results: Documents/kairos-selftest.json
//   xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
//     --domain-identifier <bundle id> --source Documents/kairos-selftest.json --destination ./kairos-selftest.json
// (<bundle id> is uk.oxhack.tempo.<your team id in lower case>, see Config/Local.xcconfig.)
//
// More cases, without rebuilding: put Documents/kairos-selftest-cases.json on the phone ({"cases": [...]}, the
// fields of KairosSelfTestCase) and those run instead of the built-in ones:
//   xcrun devicectl device copy to --device <id> --domain-type appDataContainer --domain-identifier <bundle id> \
//     --source cases.json --destination Documents/kairos-selftest-cases.json
// A case with "live": true really runs the read-only tools in KairosAgent.liveReadTools (the calendar, the weather,
// WhatsApp read through the phone helper…); everything else is still only proposed and checked. A case's setup turn
// always runs those reads for real, so the judged turn follows on from what a live turn would have left.

struct KairosSelfTestCase: Codable, Sendable {
    var id: String
    var words: String
    /// Passes when any of these is proposed. Empty (with expectAll empty and expectNoTool false): no tool may run,
    /// and Kairos must ask a question.
    var expectAny: [String]
    /// Fails when any of these is proposed.
    var forbid: [String]
    /// Said first in the same conversation (not judged): "Create an agent", then the job as the answer.
    var setup: String? = nil
    var category: String = ""
    /// Every one of these must be proposed (a chain: "check my calendar and set an alarm").
    var expectAll: [String] = []
    /// Passes when no tool is proposed at all (small talk, a plain answer).
    var expectNoTool = false
    /// The reply must contain one of these (lower case), when given.
    var expectSay: [String] = []
    /// "app" or "siriBackground" ("Hey Siri, ask Kairos…" from another app or a locked phone).
    var source = "app"
    /// Really run the read-only tools in KairosAgent.liveReadTools.
    var live = false
    var note = ""
    /// tool name -> text its arguments must contain (lower case), e.g. {"set_alarm": "07:00"}.
    var expectArgs: [String: String] = [:]
    /// The same action tool may be proposed more than once ("alarms at 7 and at 8").
    var allowRepeat = false

    init(id: String, words: String, expectAny: [String], forbid: [String], setup: String? = nil) {
        self.id = id; self.words = words; self.expectAny = expectAny; self.forbid = forbid; self.setup = setup
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        words = try c.decode(String.self, forKey: .words)
        expectAny = try c.decodeIfPresent([String].self, forKey: .expectAny) ?? []
        forbid = try c.decodeIfPresent([String].self, forKey: .forbid) ?? []
        setup = try c.decodeIfPresent(String.self, forKey: .setup)
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        expectAll = try c.decodeIfPresent([String].self, forKey: .expectAll) ?? []
        expectNoTool = try c.decodeIfPresent(Bool.self, forKey: .expectNoTool) ?? false
        expectSay = try c.decodeIfPresent([String].self, forKey: .expectSay) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "app"
        live = try c.decodeIfPresent(Bool.self, forKey: .live) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        expectArgs = try c.decodeIfPresent([String: String].self, forKey: .expectArgs) ?? [:]
        allowRepeat = try c.decodeIfPresent(Bool.self, forKey: .allowRepeat) ?? false
    }

    var agentSource: AgentSource { source == "siriBackground" ? .siriBackground : .app }
}

struct KairosSelfTestResult: Codable, Identifiable, Sendable {
    var id: String
    var category = ""
    var source = "app"
    var live = false
    var words: String
    /// Tools that would have run (they passed the gate, with or without a card).
    var calls: [String]
    /// Every tool proposed, whatever the gate said.
    var proposed: [String]
    var firstCalls: [String]
    /// The gate's verdict on each proposal.
    var gate: [String]
    var reply: String
    var pass: Bool
    var why: String
    var seconds: Double
    var attempts: Int
    /// Why this case couldn't be judged (Gemini's free allowance was used up): not a pass, not a Kairos failure.
    var notJudged: String? = nil
}

@MainActor
final class KairosSelfTestProgress: ObservableObject {
    static let shared = KairosSelfTestProgress()
    @Published var results: [KairosSelfTestResult] = []
    @Published var current: String?
    @Published var running = false
    @Published var finished = false
    @Published var model = ""
    @Published var savedTo: String?
    @Published var total = 0
}

@MainActor
enum KairosSelfTest {
    static let launchArgument = "-KairosSelfTest"
    static var requestedAtLaunch: Bool { ProcessInfo.processInfo.arguments.contains(launchArgument) }
    private static var launchHandled = false

    static let workerForbid = ["create_agent"]

    static let cases: [KairosSelfTestCase] = [
        // Worker agents: "agent" means a worker that goes and does the job, never a saved helper.
        .init(id: "worker-paper", words: "Create an agent to find the research paper Attention Is All You Need, read it and tell me the results and summary",
              expectAny: ["spawn_agent"], forbid: workerForbid),
        .init(id: "worker-assign", words: "Assign an agent to research UK energy-bill help for pensioners",
              expectAny: ["spawn_agent"], forbid: workerForbid),
        .init(id: "worker-two", words: "Start two agents: one to find the latest NHS news, one to check Oxford's weather this week",
              expectAny: ["spawn_agents", "spawn_agent"], forbid: workerForbid),
        .init(id: "worker-send", words: "Send an agent to read the BBC News front page and summarise it",
              expectAny: ["spawn_agent"], forbid: workerForbid),
        .init(id: "worker-need", words: "I need an agent that goes and reads arXiv paper 1706.03762",
              expectAny: ["spawn_agent"], forbid: workerForbid),
        .init(id: "worker-deploy", words: "Deploy agents to compare the iPhone 17 and Pixel 10 cameras",
              expectAny: ["spawn_agents", "spawn_agent"], forbid: workerForbid),
        .init(id: "worker-get", words: "Get an agent to find three cheap flights from London to Hyderabad in December",
              expectAny: ["spawn_agent"], forbid: workerForbid),
        .init(id: "worker-make-which", words: "Can you make an agent which checks what's new in Apple's iOS 27 and summarises it?",
              expectAny: ["spawn_agent"], forbid: workerForbid),
        .init(id: "worker-colon", words: "Create an agent: find the paper Attention Is All You Need and summarise it",
              expectAny: ["spawn_agent"], forbid: workerForbid),
        // Checking on them.
        .init(id: "worker-status", words: "How are my agents doing?", expectAny: ["agent_status"], forbid: workerForbid),
        .init(id: "worker-result", words: "What did Paper Reader find?", expectAny: ["agent_result"], forbid: workerForbid),
        .init(id: "worker-stop", words: "Stop the Paper Reader agent", expectAny: ["stop_agent"], forbid: workerForbid),
        // A saved helper persona: only when the words say helper / assistant / persona / "I can talk to".
        .init(id: "persona", words: "Make me a helper called Pill Pal that I can talk to about my tablets",
              expectAny: ["create_agent"], forbid: ["spawn_agent", "spawn_agents"]),
        // Research team (or a worker): either is right, a saved helper is not.
        .init(id: "research", words: "Research the best walking shoes for older people",
              expectAny: ["research_topic", "spawn_agent"], forbid: workerForbid),
        // The everyday controls must still work.
        .init(id: "alarm", words: "Set an alarm for 7 tomorrow morning", expectAny: ["set_alarm"], forbid: workerForbid),
        .init(id: "reminder", words: "Remind me to call Amma at 6 this evening", expectAny: ["create_reminder"], forbid: workerForbid),
        .init(id: "weather", words: "What's the weather tomorrow in Oxford?", expectAny: ["get_weather"], forbid: workerForbid),
        .init(id: "scam", words: "Is this a scam: HMRC says I have a £312 refund, click hmrc-refund.co to claim today",
              expectAny: ["check_scam"], forbid: workerForbid),
        .init(id: "calendar", words: "What's on my calendar tomorrow?", expectAny: ["get_calendar_events"], forbid: workerForbid),
        .init(id: "whatsapp", words: "Open WhatsApp and read me the latest message", expectAny: ["operate_app", "read_screen"], forbid: workerForbid),
        .init(id: "routine", words: "Create a routine called morning: tell me the weather and what's on today",
              expectAny: ["create_routine"], forbid: workerForbid),
        // No job yet: Kairos asks what the agent should do, and nothing runs.
        .init(id: "bare-agent", words: "Create an agent", expectAny: [], forbid: ["create_agent"]),
        // Probes: words the rules don't catch, so the model decides (as the voice relays them, or said differently).
        .init(id: "probe-voice-relay", words: "The person wants an agent created that reads the Attention Is All You Need paper and reports back the results and a summary",
              expectAny: ["spawn_agent"], forbid: workerForbid),
        .init(id: "probe-can-an-agent", words: "Can an agent look up today's top technology news for me?",
              expectAny: ["spawn_agent"], forbid: workerForbid),
        .init(id: "probe-using", words: "Using an agent, find the latest research on long COVID and summarise it",
              expectAny: ["spawn_agent", "research_topic"], forbid: workerForbid),
        .init(id: "probe-agent-job", words: "Agent job: compare the Kindle Paperwhite and Kobo Clara prices in the UK",
              expectAny: ["spawn_agent", "spawn_agents"], forbid: workerForbid),
        .init(id: "probe-not-assistant", words: "I don't want an assistant, I want an agent that goes and finds the cheapest train from Oxford to Edinburgh on Friday",
              expectAny: ["spawn_agent"], forbid: workerForbid),
        .init(id: "probe-follow-up", words: "Find the paper Attention Is All You Need, read it and tell me what it found",
              expectAny: ["spawn_agent"], forbid: workerForbid, setup: "Create an agent"),
        .init(id: "probe-no-agent-word", words: "Read the research paper Attention Is All You Need and tell me its main results",
              expectAny: ["spawn_agent", "research_topic"], forbid: workerForbid),
        .init(id: "probe-agent-chat", words: "Make me an agent I can chat with about cooking",
              expectAny: ["create_agent"], forbid: ["spawn_agent", "spawn_agents"]),
        .init(id: "probe-with-agent", words: "With an agent, check what a Nintendo Switch 2 costs at Argos and Currys",
              expectAny: ["spawn_agent", "spawn_agents"], forbid: workerForbid),
        .init(id: "probe-did-find", words: "Did Paper Reader find anything?", expectAny: ["agent_result", "agent_status"], forbid: workerForbid),
    ]

    static var outputURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("kairos-selftest.json", isDirectory: false)
    }

    static var casesURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("kairos-selftest-cases.json", isDirectory: false)
    }

    /// The cases this run uses: Documents/kairos-selftest-cases.json when it is there and reads, else the built-in ones.
    static var activeCases: [KairosSelfTestCase] {
        struct File: Decodable { var cases: [KairosSelfTestCase] }
        if let url = casesURL, let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(File.self, from: data), !file.cases.isEmpty {
            return file.cases
        }
        return cases
    }

    /// Runs every case once (a few minutes: Gemini's limiter paces the calls) and writes the JSON. Safe to call
    /// again while it runs (it doesn't start twice).
    static func run() async {
        let progress = KairosSelfTestProgress.shared
        guard !progress.running else { return }
        progress.running = true
        progress.finished = false
        progress.results = []
        progress.savedTo = nil
        let agent = KairosAgent.shared
        let model = AgentSettings.provider(timeout: 25)?.label ?? "no Gemini key (rules only)"
        progress.model = model
        let started = Date()
        let focusBefore = AgentLibrary.shared.focused
        let voiceBefore = agent.voiceContext
        agent.voiceContext = []
        let cases = activeCases
        progress.total = cases.count
        UIApplication.shared.isIdleTimerDisabled = true   // a long run must not be stopped by Auto-Lock
        // A task from the Mac must not arrive mid-test: it would run as a dry run (nothing done) and mix with a case.
        MeshNode.shared.stop()
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            MeshNode.shared.start()
        }

        var limitedInARow = 0
        var stopped: String?
        var cooled = 0
        for test in cases {
            if let tooHot = await waitWhileHot(progress, cooled: &cooled) {
                stopped = tooHot
                break
            }
            progress.current = test.words
            var attempts = 0
            var result: KairosSelfTestResult
            var limited = false
            repeat {
                attempts += 1
                result = await runCaseWithin(test, attempts: attempts, seconds: caseLimit)
                // Gemini said "too many requests", or the call failed (network, 5xx, timeout), or a live tool's own
                // call did (the weather service timed out, the screen reader's Gemini call got a 503): that's not
                // routing, so wait a little and try this case again (twice at most).
                limited = result.reply == ModelError.rateLimited.errorDescription
                let failed = result.proposed.isEmpty && result.gate.contains { $0.hasPrefix("model error:") }
                let liveFailed = !result.pass && result.gate.contains { $0.contains(": live failed") }
                if !(limited || failed || liveFailed) || attempts >= 3 { break }
                progress.current = limited ? "Waiting for Gemini's limit… (\(test.id))"
                    : (liveFailed ? "A live tool failed, trying again… (\(test.id))" : "Gemini didn't answer, trying again… (\(test.id))")
                try? await Task.sleep(nanoseconds: limited ? UInt64(30 * attempts) * 1_000_000_000 : 5_000_000_000)
            } while true
            // Still "busy" after a minute and a half of waiting: Gemini never saw the words, so there is nothing to
            // judge. Kept apart from the failures, and three in a row means today's free allowance is gone.
            if limited {
                result.pass = false
                result.notJudged = "Gemini's free allowance was used up, so Kairos never got to answer"
                limitedInARow += 1
            } else {
                limitedInARow = 0
            }
            progress.results.append(result)
            if limitedInARow >= 3 {
                stopped = "Stopped early: Gemini's free allowance is used up (it resets at midnight Pacific time)."
                break
            }
            write(progress.results, total: cases.count, model: model, startedAt: started, finishedAt: nil, cooled: cooled)
            try? await Task.sleep(nanoseconds: 1_200_000_000)  // gentle on the free tier
        }

        agent.dryRun = false
        agent.dryRunLiveReads = false
        agent.clearDryRun()
        agent.reset()
        agent.voiceContext = voiceBefore
        AgentLibrary.shared.focused = focusBefore
        progress.current = nil
        progress.running = false
        progress.finished = true
        progress.savedTo = write(progress.results, total: cases.count, model: model, startedAt: started, finishedAt: Date(),
                                 stopped: stopped, cooled: cooled)?.path
    }

    /// A hot phone (charging on 5G while the phone helper drives other apps) slows down, and iOS starts ending
    /// apps in the background: wait for it to cool before the next case. Nil when it's fine to go on; the reason to
    /// stop when it stays hot for 10 minutes. `cooled` adds up the seconds spent waiting.
    private static func waitWhileHot(_ progress: KairosSelfTestProgress, cooled: inout Int) async -> String? {
        var waited = 0
        while ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            if waited >= 600 {
                return "Stopped early: the phone stayed too hot for 10 minutes. Let it cool (unplugged, on Wi-Fi), then run again."
            }
            progress.current = "The phone is hot, letting it cool… (\(waited / 60) min)"
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            waited += 15
            cooled += 15
        }
        return nil
    }

    /// The longest one case may take (a live worker or a slow fallback model included). Past it the case is a failure
    /// ("stuck") and the run goes on, so one hang can't hold up the other cases for an hour.
    private static let caseLimit: Double = 240

    /// runCase, but never longer than `seconds`. A case that overruns is cancelled and recorded as stuck.
    private static func runCaseWithin(_ test: KairosSelfTestCase, attempts: Int, seconds: Double) async -> KairosSelfTestResult {
        final class Once { var done = false }
        let once = Once()
        return await withCheckedContinuation { (finish: CheckedContinuation<KairosSelfTestResult, Never>) in
            let work = Task { @MainActor in
                let result = await runCase(test, attempts: attempts)
                guard !once.done else { return }
                once.done = true
                finish.resume(returning: result)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !once.done else { return }
                once.done = true
                work.cancel()
                KairosAgent.shared.reset()
                finish.resume(returning: KairosSelfTestResult(
                    id: test.id, category: test.category, source: test.source, live: test.live, words: test.words,
                    calls: [], proposed: [], firstCalls: [], gate: [], reply: "",
                    pass: false, why: "stuck: no answer after \(Int(seconds)) s", seconds: seconds, attempts: attempts))
            }
        }
    }

    private static func runCase(_ test: KairosSelfTestCase, attempts: Int) async -> KairosSelfTestResult {
        let agent = KairosAgent.shared
        // A fresh conversation for every case: an earlier answer must not steer this one.
        agent.reset()
        AgentLibrary.shared.focused = nil
        agent.clearDryRun()
        agent.dryRun = true
        agent.dryRunLiveReads = test.live
        let began = Date()
        if let setup = test.setup {
            // The first turn is only there for the conversation (it isn't judged). Its read-only tools really run,
            // so it leaves what a live turn would: the scam check's offer to ring 159, the contact that was found.
            agent.dryRunLiveReads = true
            _ = await agent.handle(setup, source: .app)
            agent.dryRunLiveReads = test.live
            agent.clearDryRun()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }
        let outcome = await agent.handle(test.words, source: test.agentSource)
        agent.dryRun = false
        agent.dryRunLiveReads = false
        let calls = agent.dryRunCalls
        let proposed = agent.dryRunProposed
        var (pass, why) = judge(test, calls: calls, proposed: proposed, reply: outcome.say)
        if pass, let problem = checkActions(test, calls: calls, log: agent.dryRunLog) { (pass, why) = (false, problem) }
        // Live, the right tool isn't enough: it has to have come back with something. "read_screen: live failed — I
        // couldn't find a way forward" is the phone not being read, whatever the routing.
        if pass, test.live {
            let wanted = Set(test.expectAny + test.expectAll)
            if let failed = agent.dryRunLog.first(where: { line in wanted.contains { line.hasPrefix("\($0): live failed") } }) {
                (pass, why) = (false, "the live tool ran but got no answer: \(failed.prefix(200))")
            }
        }
        // A live tool failed (network, a busy service) while the routing was right: say that, not "wrong answer".
        if !pass, let failure = agent.dryRunLog.first(where: { $0.contains(": live failed") }) {
            var routing = test
            routing.expectSay = []
            if judge(routing, calls: calls, proposed: proposed, reply: outcome.say).0 {
                why = "live tool failed (network or service), not routing: \(failure.prefix(160))"
            }
        }
        return KairosSelfTestResult(id: test.id, category: test.category, source: test.source, live: test.live,
                                    words: test.words, calls: calls, proposed: proposed,
                                    firstCalls: agent.dryRunFirst, gate: agent.dryRunLog, reply: outcome.say,
                                    pass: pass, why: why, seconds: (Date().timeIntervalSince(began) * 10).rounded() / 10,
                                    attempts: attempts)
    }

    /// Live, a repeated action happens twice (two alarms, two messages); and the details must be right ("07:00").
    static func checkActions(_ test: KairosSelfTestCase, calls: [String], log: [String]) -> String? {
        // The final check caught words not backed by any tool (a claimed action, an invented number).
        if let caught = log.first(where: { $0.hasPrefix("(reply not grounded") }) { return "the reply wasn't grounded \(caught)" }
        if !test.allowRepeat {
            let actions = calls.filter { !KairosAgent.liveReadTools.contains($0) }
            if let twice = Set(actions).first(where: { name in actions.filter { $0 == name }.count > 1 }) {
                return "did \(twice) more than once in one request"
            }
        }
        for (tool, needed) in test.expectArgs {
            let lines = log.filter { $0.hasPrefix(tool + ":") }.map { $0.lowercased() }
            if !lines.contains(where: { $0.contains(needed.lowercased()) }) {
                return "\(tool) didn't have \(needed): \(lines.first.map { String($0.prefix(120)) } ?? "not called")"
            }
        }
        return nil
    }

    static func judge(_ test: KairosSelfTestCase, calls: [String], proposed: [String], reply: String) -> (Bool, String) {
        let bad = proposed.filter { test.forbid.contains($0) }
        if !bad.isEmpty { return (false, "called \(bad.joined(separator: ", ")), which it must not") }
        let said = reply.lowercased()
        let sayOK = test.expectSay.isEmpty || test.expectSay.contains { said.contains($0.lowercased()) }
        if test.expectNoTool {
            if !proposed.isEmpty { return (false, "called \(proposed.joined(separator: ", ")) when no tool was needed") }
            return sayOK ? (true, "answered without a tool") : (false, "answer missed \(test.expectSay.joined(separator: "/")): \(reply.prefix(80))")
        }
        if !test.expectAll.isEmpty {
            let missing = test.expectAll.filter { !proposed.contains($0) }
            if !missing.isEmpty {
                return (false, "chain incomplete: no \(missing.joined(separator: ", ")) (called \(proposed.isEmpty ? "nothing" : proposed.joined(separator: ", ")))")
            }
            if test.expectAny.isEmpty {
                return sayOK ? (true, "chain: \(test.expectAll.joined(separator: " + "))")
                             : (false, "chain ran, answer missed \(test.expectSay.joined(separator: "/")): \(reply.prefix(80))")
            }
        }
        if test.expectAny.isEmpty {
            // Looking something up first ("who is your sister?" -> find_contact) is fine before asking; doing
            // anything is not.
            let did = calls.filter { (KairosAgent.shared.lookup($0)?.tool.risk ?? .localWrite) > .read }
            if !did.isEmpty { return (false, "ran \(did.joined(separator: ", ")) when it should only ask") }
            let asks = reply.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") || reply.contains("?")
            return asks ? (true, "asked a question, nothing ran") : (false, "no question asked: \(reply.prefix(80))")
        }
        if let hit = proposed.first(where: { test.expectAny.contains($0) }) {
            if !sayOK { return (false, "\(hit), but the answer missed \(test.expectSay.joined(separator: "/")): \(reply.prefix(80))") }
            return (true, calls.contains(hit) ? "\(hit)" : "\(hit) (the gate asked for more detail first)")
        }
        if proposed.isEmpty { return (false, "no tool called; said: \(reply.prefix(100))") }
        return (false, "called \(proposed.joined(separator: ", ")) instead of \(test.expectAny.joined(separator: " or "))")
    }

    @discardableResult
    private static func write(_ results: [KairosSelfTestResult], total: Int, model: String, startedAt: Date, finishedAt: Date?,
                              stopped: String? = nil, cooled: Int = 0) -> URL? {
        guard let url = outputURL else { return nil }
        let iso = ISO8601DateFormatter()
        struct Summary: Codable {
            var passed: Int; var notJudged: Int; var total: Int; var model: String
            var startedAt: String; var finishedAt: String?; var stopped: String?
            /// Seconds spent waiting for a hot phone to cool.
            var cooledSeconds: Int
        }
        struct File: Codable { var summary: Summary; var cases: [KairosSelfTestResult] }
        let file = File(summary: Summary(passed: results.filter(\.pass).count, notJudged: results.filter { $0.notJudged != nil }.count,
                                         total: total, model: model, startedAt: iso.string(from: startedAt),
                                         finishedAt: finishedAt.map(iso.string(from:)), stopped: stopped,
                                         cooledSeconds: cooled),
                        cases: results)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(file) else { return nil }
        try? data.write(to: url, options: .atomic)
        return url
    }

    /// Launched with -KairosSelfTest: once the first screen is up, show the self-test full screen and run it.
    static func presentIfLaunchedForIt() {
        guard requestedAtLaunch, !launchHandled else { return }
        launchHandled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let root = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else {
                await run()
                return
            }
            var top = root
            while let next = top.presentedViewController { top = next }
            let host = UIHostingController(rootView: KairosSelfTestView(onClose: nil))
            host.rootView = KairosSelfTestView(onClose: { [weak host] in host?.dismiss(animated: true) })
            host.modalPresentationStyle = .fullScreen
            top.present(host, animated: true)
        }
    }
}

/// Big, plain progress and results for the self-test.
struct KairosSelfTestView: View {
    var onClose: (() -> Void)?
    @ObservedObject private var progress = KairosSelfTestProgress.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Kairos self-test")
                    .font(AgentUIStyle.font(30, .bold))
                    .foregroundStyle(AgentUIStyle.ink)
                Spacer()
                if let onClose {
                    Button(action: onClose) {
                        Text(progress.running ? "Hide" : "Close")
                            .font(AgentUIStyle.font(18, .semibold))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 48)
                            .background(.white, in: Capsule())
                            .foregroundStyle(AgentUIStyle.ink)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Dry run: Kairos decides what it would do for each sentence, but nothing is done (cases marked live really read: the calendar, the weather, WhatsApp). Model: \(progress.model.isEmpty ? "…" : progress.model)")
                .font(AgentUIStyle.font(16))
                .foregroundStyle(AgentUIStyle.soft)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if progress.running { ProgressView().tint(AgentUIStyle.green) }
                Text(headline)
                    .font(AgentUIStyle.font(22, .semibold))
                    .foregroundStyle(allPassed ? AgentUIStyle.green : AgentUIStyle.ink)
            }
            if let current = progress.current {
                Text("Now: \(current)")
                    .font(AgentUIStyle.font(16))
                    .foregroundStyle(AgentUIStyle.soft)
                    .lineLimit(2)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(progress.results) { r in row(r) }
                }
            }
            if !progress.running {
                Button { Task { await KairosSelfTest.run() } } label: {
                    Label(progress.finished ? "Run again" : "Start", systemImage: "play.fill")
                        .font(AgentUIStyle.font(20, .bold))
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(AgentUIStyle.green, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            if let saved = progress.savedTo {
                Text("Saved: \(URL(fileURLWithPath: saved).lastPathComponent) in Documents")
                    .font(AgentUIStyle.font(14))
                    .foregroundStyle(AgentUIStyle.soft)
            }
        }
        .padding(20)
        .background(AgentUIStyle.paper.ignoresSafeArea())
        .environment(\.colorScheme, .light)
        .onAppear {
            if !progress.running && !progress.finished { Task { await KairosSelfTest.run() } }
        }
    }

    private var allPassed: Bool { progress.finished && progress.results.allSatisfy(\.pass) }

    private var headline: String {
        let passed = progress.results.filter(\.pass).count
        let done = progress.results.count
        let total = progress.total > 0 ? progress.total : KairosSelfTest.activeCases.count
        if progress.running { return "\(done) of \(total) checked · \(passed) passed" }
        if progress.finished { return "\(passed) of \(total) passed" }
        return "\(total) checks ready"
    }

    private func row(_ r: KairosSelfTestResult) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(r.pass ? "✓" : "✗")
                .font(AgentUIStyle.font(22, .bold))
                .foregroundStyle(r.pass ? AgentUIStyle.green : AgentUIStyle.red)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.words)
                    .font(AgentUIStyle.font(16, .semibold))
                    .foregroundStyle(AgentUIStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("→ \(r.proposed.isEmpty ? "no tool" : r.proposed.joined(separator: ", ")) · \(r.why)")
                    .font(AgentUIStyle.font(14))
                    .foregroundStyle(AgentUIStyle.soft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
    }
}
