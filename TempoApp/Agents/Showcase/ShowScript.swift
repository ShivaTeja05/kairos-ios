import Foundation

// Present mode's script: what Kairos says and which helper does what, step by step. The Presenter plays it.
//
// Every step is: narration before → an action (a tool through the SafetyGate, or a plain request to Kairos) →
// narration after (`{result}` is what the helper actually said) → on failure, a short line and on we go.
// Lines are short on purpose: the phone's voice speaks ~2.6 words a second, and a judge should never wait in
// silence for more than about four seconds (long actions get "while waiting" lines).
//
// Real tool behaviour this script relies on (checked against the tools' code):
//   - set_alarm only takes a time the person said, so the alarm is a spoken request (.ask), not a bare tool call.
//   - operate_app's WhatsApp procedure reads a chat with no model call when the goal says "read … chat with <name>"
//     and avoids the words "open", "group", "photo" (those switch to the model or leave you in WhatsApp).
//   - take_photo opens Kairos's camera and returns at once; the photo comes back as "Here's the photo for: …" and
//     Kairos then shares it (share_photo → the operator → the owner's Yes card unless WhatsApp is pre-allowed).
//     The caption is fixed text from this script (DemoProps.photoCaption), never words from a screen or a letter.
//   - create_agent can never be a routine step (RoutineCatalog.neverInRoutine), so "save that as a routine" after
//     Agent Studio would always fail: the routine step saves its own two steps with create_routine instead.

/// One whole show.
struct ShowScript: Sendable, Equatable {
    var title: String
    var steps: [ShowStep]

    /// The full show, about three minutes. Built fresh each time so the alarm time fits the hour.
    static var standard: ShowScript { standard(now: Date()) }
    /// The one-minute pitch: intro, alarm, Scam Shield, over to the judges.
    static var short: ShowScript { short(now: Date()) }

    /// Rough running time: every line at 2.6 words a second, plus each action's usual time.
    var estimatedSeconds: Double { steps.reduce(0) { $0 + $1.estimatedSeconds } }
}

/// One beat of the show: one helper doing one thing.
struct ShowStep: Sendable, Equatable, Identifiable {
    var id: String
    /// Shown on the overlay: the helper's name and SF Symbol, and what it is doing (lower case; the overlay
    /// capitalises it).
    var agent: String
    var icon: String
    var doing: String
    /// The prop the overlay can show while this step runs (the letter, the scam text).
    var prop: ShowProp? = nil
    var before: [String] = []
    var action: ShowAction = .none
    /// Spoken one at a time while a slow action runs (every ~3.5 s of silence), so the room is never quiet.
    var whileWaiting: [String] = []
    /// After success. A line with `{result}` is filled with what the helper said (or skipped if it said nothing).
    var after: [String] = []
    /// How much of the helper's answer to read out (a trailing question is always kept).
    var maxResultSentences: Int = 3
    /// Spoken when the action fails, times out or is stopped (and there is no fallback, or the fallback failed too).
    var fallbackLine: String
    /// On a failure or refusal, read out what the helper said instead ("OK, I haven't posted it…"), when it said
    /// something. A timeout still gets `fallbackLine`.
    var readsFailure = false
    /// Something else to show if the action fails (e.g. Maps directions when WhatsApp can't be driven).
    var fallback: ShowFallback? = nil
    /// The action's deadline. A Yes card on screen adds time; a camera step adds its tap time.
    var maxSeconds: Double = 20
    /// Spoken when a Yes/No card appears during this step. Nil: the standard line.
    var confirmLine: String? = nil
    /// The owner has to tap something (the camera shutter) before the step can finish.
    var tap: ShowTap? = nil
    /// Skip this step when the step before it didn't work (the reminder after an unread letter).
    var skipIfPreviousFailed = false
    /// The step may leave Kairos (WhatsApp, Maps): afterwards the presenter makes sure Kairos is back in front.
    var leavesApp = false
    /// For the running-time estimate: the action's usual seconds and how many words its answer usually has.
    var expectedSeconds: Double = 1
    var expectedResultWords: Int = 0

    /// Running time at the phone voice's pace. An agent action starts with the step's own lines and runs while
    /// they are spoken, so the step takes the longer of the two, then the answer.
    var estimatedSeconds: Double {
        func seconds(_ lines: [String]) -> Double {
            Double(lines.filter { !$0.contains("{result}") }.map(ShowTiming.words).reduce(0, +)) / ShowTiming.wordsPerSecond
        }
        // About 14 words a sentence, plus a closing question, which ShowText.clip always keeps.
        let resultWords = after.contains { $0.contains("{result}") } ? min(expectedResultWords, (maxResultSentences + 1) * 14) : 0
        let opening = action.usesAgent ? max(seconds(before), expectedSeconds) : seconds(before) + expectedSeconds
        let tapTime = tap.map { seconds([$0.prompt]) + $0.expectedSeconds } ?? 0
        return opening + tapTime + seconds(after) + Double(resultWords) / ShowTiming.wordsPerSecond
    }
}

/// What a step does.
enum ShowAction: Sendable, Equatable {
    /// Narration only.
    case none
    /// One tool through AgentHooks.runner (SafetyGate, cards and Face ID exactly as usual).
    case tool(ToolCall)
    /// A plain request to Kairos, as if the owner typed it, with optional prop photos (KairosAgent.handle).
    case ask(String, images: [ShowProp])
    /// The phone operator does `goal` in `app` (operate_app through the runner).
    case operate(goal: String, app: String, person: String?)
    /// A pause for effect.
    case pause(Double)
    /// Over to the judges: the live voice conversation, or the agent screen's microphone.
    case handToJudges

    /// Runs through Kairos (so it must wait for a card or an earlier request to finish).
    var usesAgent: Bool {
        switch self {
        case .tool, .ask, .operate: return true
        case .none, .pause, .handToJudges: return false
        }
    }

    static func tool(_ name: String, _ args: JSONValue = [:]) -> ShowAction {
        .tool(ToolCall(id: nil, name: name, args: args))
    }
}

/// Plan B for a step.
struct ShowFallback: Sendable, Equatable {
    var agent: String
    var icon: String
    var doing: String
    var before: [String]
    var action: ShowAction
    var after: [String] = ["{result}"]
    var maxSeconds: Double = 15
    /// How much of plan B's answer to read out. Nil: the step's own `maxResultSentences`.
    var maxResultSentences: Int? = nil
}

/// A step that needs the owner's tap (the camera shutter), then lets Kairos finish what the photo was for.
struct ShowTap: Sendable, Equatable {
    /// Spoken (and shown) when the camera is up.
    var prompt: String
    /// Spoken once, halfway through the wait, if nothing has happened.
    var nudge: String?
    /// How long to wait for the shutter.
    var seconds: Double = 25
    /// Then how long Kairos may take to do what the photo was for (save, open WhatsApp, the Yes card, send).
    var followUpSeconds: Double = 60
    var followUpLines: [String] = []
    /// For the running-time estimate: the tap plus the follow-up, usually.
    var expectedSeconds: Double = 20
}

// MARK: - Settings

enum ShowSettings {
    /// The WhatsApp chat the operator reads and the photo goes to. Avoid names ending in "group" or "chat".
    static let teamChatKey = "kairos.show.team_chat"
    /// "live" (default): hand over to the ElevenLabs call. "agent": open the agent screen's microphone instead.
    static let handOffKey = "kairos.show.handoff"
    /// "auto" (default): the live call's voice when a call is on, else the phone's voice. "device" or "live".
    static let voiceModeKey = "kairos.show.voice_mode"

    static var teamChat: String { text(teamChatKey) ?? "OxHack team" }
    static var handOff: String { text(handOffKey)?.lowercased() ?? "live" }
    static var voiceMode: String { text(voiceModeKey)?.lowercased() ?? "auto" }

    private static func text(_ key: String) -> String? {
        let s = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }
}

// MARK: - Lines the presenter uses on any step

enum ShowLines {
    static let confirm = "There's my Yes card. I always ask before anything that reaches a person — tap Yes if you're happy."
    static let confirmNudge = "Tap Yes to go ahead, or No and nothing happens."
    static let cardWaiting = "There's a card on screen waiting for your answer. Tap Yes or No, and I'll carry on."
    static let cardSkip = "I'll leave that one and move on."
    static let swipeBack = "When you're ready, swipe back to Kairos and I'll carry on."
    /// The photo step's line when it doesn't finish (no shutter, an unanswered card, a slow share): true in every case.
    static let noPhoto = "Nothing was posted this time — never mind."
    /// After a slow step's own "while waiting" lines, at most these, about four seconds apart.
    static let stillWorking = ["Still on it.", "Nearly there.", "Just a moment more."]
}

// MARK: - The two shows

extension ShowScript {
    static func standard(now: Date, teamChat: String = ShowSettings.teamChat, calendar: Calendar = .current) -> ShowScript {
        let alarm = ShowAlarm.plan(now: now, calendar: calendar)
        let steps: [ShowStep] = [
            intro(short: false),
            alarmStep(alarm),
            ShowStep(
                id: "letter", agent: "Letter reader", icon: "doc.text.viewfinder", doing: "reading a council-tax letter",
                prop: .letter,
                before: ["Next, the Letter reader, with a council-tax letter — the kind that worries people."],
                action: .ask("Please read this letter", images: [.letter]),
                whileWaiting: ["Reading the small print, so you don't have to.",
                               "Finding who it's from, how much, and by when.",
                               "And checking it's genuine."],
                after: ["{result}"],
                maxResultSentences: 2,
                fallbackLine: "Reading letters needs the internet, and it's slow just now — let's move on.",
                maxSeconds: 35, expectedSeconds: 10, expectedResultWords: 40),
            ShowStep(
                id: "reminder", agent: "Time helper", icon: "bell.fill", doing: "reminder: pay the council tax",
                before: ["Now the Letter reader hands that date to the Time helper."],
                action: .tool("create_reminder", [
                    "title": .string("Pay Oxford council tax \(DemoProps.letterAmount)"),
                    "due_iso": .string(DemoProps.reminderDueISO(calendar: calendar)),
                    "repeat": "none",
                ]),
                after: ["{result}"],
                maxResultSentences: 1,
                fallbackLine: "The reminder didn't save, so I'll leave that one.",
                maxSeconds: 12, skipIfPreviousFailed: true, expectedSeconds: 1.5, expectedResultWords: 16),
            scamStep(short: false),
            ShowStep(
                id: "operator", agent: "Phone operator", icon: "hand.tap.fill", doing: "reading the team chat in WhatsApp",
                before: ["Now, what nobody else does on iPhone: I'll use WhatsApp like a person, and read our team chat."],
                action: .operate(goal: "Read me the latest message in my WhatsApp chat with \(teamChat)",
                                 app: "WhatsApp", person: teamChat),
                whileWaiting: ["I'm reading the screen and tapping, just as you would.",
                               "Finding the team chat.",
                               "Reading what it says.",
                               "No shortcuts here: it's real taps, in the real app."],
                after: ["{result}", "Any risky tap there stops for your OK first."],
                maxResultSentences: 2,
                fallbackLine: "The phone helper isn't running just now — let's move on.",
                fallback: ShowFallback(
                    agent: "Everyday helper", icon: "map.fill", doing: "walking directions to the Mathematical Institute",
                    before: ["WhatsApp needs the phone helper, so here's another: directions to the Mathematical Institute."],
                    action: .tool("get_directions", ["destination": "Mathematical Institute, Oxford", "mode": "walking"]),
                    after: ["{result}"], maxSeconds: 12, maxResultSentences: 1),
                maxSeconds: 35, leavesApp: true, expectedSeconds: 20, expectedResultWords: 20),
            ShowStep(
                id: "studio", agent: "Agent Studio", icon: "person.crop.rectangle.stack.fill",
                doing: "making a new agent: Judge Helper",
                before: ["Kairos grows, too. Here's a brand-new agent, from one sentence."],
                action: .ask("Make me a helper called Judge Helper that reminds me to score each team every 10 minutes and keeps my notes",
                             images: []),
                whileWaiting: ["Choosing its name, its tools and its rules.",
                               "It only gets the permissions it needs."],
                after: ["{result}"],
                maxResultSentences: 2,
                fallbackLine: "Making agents needs the internet just now — let's keep going.",
                maxSeconds: 35, expectedSeconds: 10, expectedResultWords: 18),
            ShowStep(
                id: "routine", agent: "Routines", icon: "repeat.circle.fill", doing: "saving the routine “judge mode”",
                before: ["And helpers team up. One routine, “judge mode”: today's calendar, then a good-luck line."],
                // No timer in it: replaying it below must not leave a real timer ringing in the next team's pitch.
                action: .tool("create_routine", Self.judgeModeRoutine),
                after: ["{result}"],
                maxResultSentences: 1,
                fallbackLine: "Routines are taking a breather — on we go.",
                maxSeconds: 12, expectedSeconds: 1, expectedResultWords: 8),
            ShowStep(
                id: "routine-run", agent: "Routines", icon: "repeat.circle.fill", doing: "running “judge mode”",
                before: ["Now I just say: judge mode."],
                // An exact routine name: run_routine replays the saved steps with no model call.
                action: .ask("judge mode", images: []),
                after: ["{result}"],
                maxResultSentences: 2,
                fallbackLine: "That one can wait — on we go.",
                maxSeconds: 12, skipIfPreviousFailed: true, expectedSeconds: 1.5, expectedResultWords: 14),
            ShowStep(
                id: "photo", agent: "Photo helper", icon: "camera.fill", doing: "taking a photo for the team chat",
                before: ["Last one: a photo of the judges' table, sent to our team chat."],
                action: .ask("Take a photo and send it to \(teamChat) on WhatsApp saying “\(DemoProps.photoCaption)”", images: []),
                after: ["{result}"],
                maxResultSentences: 2,
                fallbackLine: ShowLines.noPhoto,
                readsFailure: true,
                maxSeconds: 15,
                confirmLine: "There's my Yes card — I always ask before I post. Tap Yes if you're happy.",
                tap: ShowTap(prompt: "Big smiles! Tap the white button when you're ready.",
                             nudge: "Whenever you're ready — the big white button.",
                             seconds: 25, followUpSeconds: 90,
                             followUpLines: ["Saving it to Photos, then into WhatsApp.",
                                             "Finding the team chat.",
                                             "Adding the photo and the words."],
                             expectedSeconds: 26),
                leavesApp: true, expectedSeconds: 2, expectedResultWords: 10),
            handOver(short: false),
        ]
        return ShowScript(title: "Full show", steps: steps)
    }

    static func short(now: Date, calendar: Calendar = .current) -> ShowScript {
        ShowScript(title: "Quick pitch", steps: [
            intro(short: true),
            alarmStep(ShowAlarm.plan(now: now, calendar: calendar)),
            scamStep(short: true),
            handOver(short: true),
        ])
    }

    // MARK: Shared steps

    /// "Judge mode": a ten-minute timer for the next team, then today's calendar. Both steps work offline and
    /// neither reaches a person; {{today}} is filled in each time it runs.
    static let judgeModeRoutine: JSONValue = [
        "name": "Judge mode",
        "phrases": ["judge mode", "start judge mode", "do judge mode"],
        "summary": "Today's calendar, then a good-luck line",
        "steps": [
            ["kind": "tool", "tool": "get_calendar_events", "args": ["date_iso": "{{today}}"], "label": "today's calendar"],
            ["kind": "say", "text": "Good luck to the next team.", "label": "a good-luck line"],
        ],
    ]

    private static func intro(short: Bool) -> ShowStep {
        let lines = ["Hello, judges. I'm Kairos, a helper that lives on this iPhone.",
                     "iPhones don't let apps use other apps, so almost nobody builds agents for iOS. Let me show you instead."]
        return ShowStep(id: "intro", agent: "Kairos", icon: "sparkles", doing: "introducing itself",
                        before: lines, fallbackLine: "", expectedSeconds: 0.5)
    }

    private static func alarmStep(_ alarm: ShowAlarm) -> ShowStep {
        ShowStep(id: "alarm", agent: "Time helper", icon: "alarm.fill", doing: "setting an alarm for \(alarm.hhmm)",
                 before: [alarm.intro],
                 action: .ask(alarm.request, images: []),
                 after: ["{result}"],
                 maxResultSentences: 2,
                 fallbackLine: "The alarm is being stubborn — let's move on.",
                 maxSeconds: 12, expectedSeconds: 1.5, expectedResultWords: 12)
    }

    private static func scamStep(short: Bool) -> ShowStep {
        ShowStep(id: "scam", agent: "Scam Shield", icon: "shield.lefthalf.filled", doing: "checking a text from “HMRC”",
                 prop: .scamText,
                 before: [short ? "Scam Shield. This text claims to be HMRC, offering a refund."
                                : "Now, Scam Shield. This text claims to be HMRC, offering a refund."],
                 action: .tool("check_scam", ["text": .string(DemoProps.scamText)]),
                 after: ["{result}", "That check runs on the phone."],
                 maxResultSentences: 2,
                 fallbackLine: "Scam Shield hit a snag — but remember, HMRC never texts you a refund link.",
                 maxSeconds: 10, expectedSeconds: 0.5, expectedResultWords: 34)
    }

    private static func handOver(short: Bool) -> ShowStep {
        ShowStep(id: "handover", agent: "Kairos", icon: "person.wave.2.fill", doing: "over to you: ask me anything",
                 before: short ? [] : ["That's Kairos: helpers that read, check, remind and use the phone — and always ask before anything risky."],
                 action: .handToJudges,
                 fallbackLine: "", expectedSeconds: 0.5)
            .withLastLine("Now it's your turn. Ask me anything you'd like done on this phone, and I'll do it for you.")
    }
}

private extension ShowStep {
    func withLastLine(_ line: String) -> ShowStep {
        var s = self
        s.before.append(line)
        return s
    }
}

/// The alarm for step 2: 12:45 "for the judging" in the morning; during judging, ten minutes from now for the next team.
struct ShowAlarm: Sendable, Equatable {
    var hhmm: String
    /// What the owner "says" (the Time helper only takes times the person said).
    var request: String
    var intro: String

    static func plan(now: Date, calendar: Calendar) -> ShowAlarm {
        let h = calendar.component(.hour, from: now), m = calendar.component(.minute, from: now)
        let minutes = h * 60 + m
        if minutes < 12 * 60 + 30 {
            return ShowAlarm(hhmm: "12:45", request: "Set an alarm for 12:45 for the judging",
                             intro: "First, my Time helper — an alarm, so nobody's late for judging.")
        }
        // During judging: the next five minutes, at least ten minutes away.
        let t = (((minutes + 10) + 4) / 5 * 5) % (24 * 60)
        let hhmm = String(format: "%02d:%02d", t / 60, t % 60)
        return ShowAlarm(hhmm: hhmm, request: "Set an alarm for \(hhmm) for the next team",
                         intro: "First, my Time helper — an alarm, so you never lose track of the next team.")
    }
}
