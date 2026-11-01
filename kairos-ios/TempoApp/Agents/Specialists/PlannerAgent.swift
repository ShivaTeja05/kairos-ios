import Foundation
import EventKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AlarmKit)
import AlarmKit
import SwiftUI
#endif

// The Time helper: alarms, timers, reminders and the calendar, all on the phone itself.
//
// - Alarms and timers use AlarmKit on iOS 26 (they ring through silent mode and Focus). A fixed-time alert needs no
//   widget extension; only AlarmKit's countdown Live Activity does, so timers are scheduled as a fixed alarm at
//   now + minutes instead of a countdown. Before iOS 26, or if alarms aren't allowed, it makes a Reminder with an
//   alert at that time and says so plainly.
// - Reminders and calendar events use EventKit (full access, iOS 17+).
// - Every time the model proposes is checked against the person's own latest words (SpokenTime). If they said
//   "8 tonight" and the model wrote 21:00, the person's words win: the argument is fixed, not refused.
// - Replies are built here from what was actually saved, with absolute wording ("7 tomorrow morning (Monday)").

struct PlannerAgent: SpecialistAgent {
    let id = "planner"
    let title = "Time helper"
    let icon = "alarm.fill"

    var instructions: String {
        """
        Alarms, timers, reminders and the calendar on this phone. \
        set_alarm: to wake the person or ring loudly at a clock time ("wake me at 7", "alarm for my bus at 8:10"); it rings even on silent; \
        it can repeat every day, every weekday (Monday to Friday) or once a week. \
        set_timer: a countdown in minutes ("timer for the oven, 40 minutes"). \
        "Remind me" or "wake me" N minutes before or after a clock time is set_alarm (or create_reminder) at that clock time \
        minus or plus N ("an hour before my 10 o'clock" is 09:00), never set_timer. A clock time with no am or pm that has \
        already gone today means the next one. \
        create_reminder: to remind them to do something at a time ("remind me to take my pills at 8 tonight"; repeat "daily" for "every night"); \
        also for a deadline from a letter, but only after the person says yes. If they said "remind me" but not when, ask when; \
        never save a reminder without a time unless they said they don't want one. \
        Alarms and reminders only go off at a clock time: there is no reminder for when someone arrives or leaves, or for a \
        place. Say so in a few words and ask what time instead; don't look anyone up for it. \
        Alarms, timers and reminders go on THIS phone only. If they want one on someone else's phone, say you can't, and offer, \
        as a question, to text that person instead. \
        add_calendar_event: an appointment on a day and time ("put the dentist in for Tuesday at 3"). \
        get_calendar_events: when they ask what is on a day ("what's on tomorrow?"). \
        If they did not say when, ask one short question; never invent a time. "At 3" means 15:00 unless they say morning or am. \
        time_hhmm is 24-hour ("07:00"); dates and times are the person's local wall-clock time. \
        Keep titles short and in their own words ("Take pills", "Dentist").
        """
    }

    var tools: [any KairosTool] {
        [PlannerSetTimerTool(), PlannerSetAlarmTool(), PlannerCreateReminderTool(), PlannerGetEventsTool(), PlannerAddEventTool()]
    }

    /// Ask for Reminders, Calendar and Alarms in one go. Call once on first launch, in the foreground: Siri in the
    /// background can't show permission prompts.
    static func askPermissionsUpFront() async {
        let kit = PlannerStore.shared
        _ = await kit.access(.reminder, canAsk: true)
        _ = await kit.access(.event, canAsk: true)
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *), AlarmManager.shared.authorizationState == .notDetermined {
            _ = try? await AlarmManager.shared.requestAuthorization()
        }
        #endif
    }
}

// MARK: - set_alarm

struct PlannerSetAlarmTool: KairosTool {
    let name = "set_alarm"
    let summary = "Set a loud alarm at a clock time on this phone, once, every day, every weekday or once a week. It rings even when the phone is on silent."
    let risk: Risk = .localWrite
    var parameters: JSONValue {
        Schema.object([
            "time_hhmm": Schema.string("24-hour time, e.g. \"07:00\" or \"18:30\""),
            "label": Schema.string("What it is for, in a word or two, e.g. \"Wake up\", \"Bus\", \"Pills\""),
            "day_iso": Schema.string("Only if they named a day: the date, e.g. \"2026-10-26\". Leave out for the next time that clock comes round. When changing an alarm from earlier in this conversation (\"make it 8 instead\"), that alarm's day."),
            "repeat": Schema.string("How often: none, daily (every day), weekdays (Monday to Friday), or weekly (that day each week)",
                                    oneOf: ["none", "daily", "weekdays", "weekly"]),
        ], required: ["time_hhmm", "label"])
    }

    func quickMatch(_ words: String, ctx: TurnContext) -> JSONValue? {
        guard !PlannerWords.severalRequests(words), !PlannerWords.otherDevice(words) else { return nil }
        let w = PlannerWords.core(words)
        guard let first = w.first,
              w.contains("alarm") || PlannerWords.starts(w, ["wake", "me"]) || PlannerWords.starts(w, ["wake", "up"]),
              ["set", "alarm", "an", "a", "wake", "make", "put", "new", "create", "give"].contains(first),
              !w.contains(where: { PlannerWords.notAnAlarmCommand.contains($0) }),
              let heard = SpokenTime.parse(words, now: ctx.now, calendar: ctx.calendar, prefer: .alarm),
              heard.clockCount == 1 || heard.relative != nil, heard.clockSaid || heard.relative != nil,
              // Words about when that the rules don't understand ("every other day") go to the model, never into the label.
              !PlannerWords.unreadTime(heard.leftover)
        else { return nil }
        // A label is a word or two ("Bus", "Hospital"). More than that is something else the person asked for
        // ("… and tells me tomorrow's weather"), so the model decides.
        let label = PlannerWords.alarmLabel(from: heard.leftover)
        guard label.split(separator: " ").count <= PlannerWords.longestLabel else { return nil }
        var args: [String: JSONValue] = [
            "time_hhmm": .string(SpokenTime.hhmm(heard.date, calendar: ctx.calendar)),
            "label": .string(label),
        ]
        if heard.daySaid || heard.relative != nil { args["day_iso"] = .string(SpokenTime.dayString(heard.date, calendar: ctx.calendar)) }
        if heard.repeats != .none { args["repeat"] = .string(heard.repeats.rawValue) }
        return .object(args)
    }

    func validate(_ args: JSONValue, ctx: TurnContext) -> Validation {
        if case .problem(let v) = PlannerWhen.alarm(args, ctx: ctx) { return v }
        return .ok
    }

    func describe(_ args: JSONValue, ctx: TurnContext) -> String {
        guard case .ready(let plan) = PlannerWhen.alarm(args, ctx: ctx) else { return "Set an alarm" }
        return "Alarm " + PlannerSay.when(plan.date, plan.repeats, ctx: ctx, lead: "for")
    }

    func execute(_ args: JSONValue, ctx: TurnContext) async throws -> ToolResult {
        guard case .ready(let plan) = PlannerWhen.alarm(args, ctx: ctx) else {
            return .fail("What time shall I set it for?")
        }
        let outcome = await PlannerAlarms.schedule(label: plan.label, at: plan.date, repeats: plan.repeats,
                                                   calendar: ctx.calendar, canAsk: ctx.canShowUI)
        guard case .scheduled(let alarmID) = outcome else {
            return await PlannerAlarms.reminderInstead(title: plan.label, at: plan.date, repeats: plan.repeats,
                                                       why: outcome, isTimer: false, ctx: ctx)
        }
        let called = PlannerWords.isGenericLabel(plan.label) ? "an alarm" : "an alarm called “\(plan.label)”"
        let say = "I've set \(called) \(PlannerSay.when(plan.date, plan.repeats, ctx: ctx, lead: "for"))."
        var data: [String: JSONValue] = [
            "kind": "alarm", "label": .string(plan.label), "rings_at": .string(SpokenTime.isoString(plan.date, calendar: ctx.calendar)),
            "repeats": .string(plan.repeats.rawValue), "rings_on_silent": true, "alarm_id": .string(alarmID),
        ]
        if plan.corrected { data["note"] = "Used the time the person said, not the one proposed." }
        return ToolResult(ok: true, say: say, data: .object(data))
    }
}

// MARK: - set_timer

struct PlannerSetTimerTool: KairosTool {
    let name = "set_timer"
    let summary = "Start a timer that rings when the time is up, e.g. for the oven. It rings even when the phone is on silent."
    let risk: Risk = .localWrite
    var parameters: JSONValue {
        Schema.object([
            "minutes": Schema.number("How many minutes, e.g. 10, or 1.5 for a minute and a half"),
            "label": Schema.string("What it is for, in a word or two, e.g. \"Oven\". Use \"Timer\" if they didn't say."),
        ], required: ["minutes", "label"])
    }

    func quickMatch(_ words: String, ctx: TurnContext) -> JSONValue? {
        guard !PlannerWords.severalRequests(words), !PlannerWords.otherDevice(words) else { return nil }
        let toks = SpokenTime.tokens(words)
        let w = toks.map { $0.w }
        let range = PlannerWords.coreRange(w)
        let core = Array(toks[range])
        let coreWords = core.map { $0.w }
        guard coreWords.contains("timer"),
              !coreWords.contains(where: { PlannerWords.notATimerCommand.contains($0) }) else { return nil }
        let found = SpokenTime.durationMatches(core)
        guard found.count == 1, let d = found.first, (5...(24 * 3600)).contains(d.seconds) else { return nil }
        // Whatever is left after the length and the command words is the label ("for the oven" → Oven).
        let rest = core.indices.filter { !(d.start..<(d.start + d.length)).contains($0) && !PlannerWords.timerFiller.contains(core[$0].w) }
        if rest.contains(where: { SpokenTime.number(core, $0) != nil }) { return nil }  // a second number we don't understand
        // "10 minutes before my bus", "every 20 minutes": not a plain countdown, so the model decides. Nor is a long
        // label: "research the fuel rules, and while that's going set a timer" holds another request.
        if rest.contains(where: { PlannerWords.notACountdown.contains(core[$0].w) || core[$0].w.contains(":") }) { return nil }
        if rest.count > PlannerWords.longestLabel { return nil }
        let label = rest.isEmpty ? "Timer" : PlannerWords.capitalisedFirst(rest.map { core[$0].raw }.joined(separator: " "))
        return ["minutes": .number(d.seconds / 60), "label": .string(label)]
    }

    func validate(_ args: JSONValue, ctx: TurnContext) -> Validation {
        if case .problem(let v) = PlannerWhen.timer(args, ctx: ctx) { return v }
        return .ok
    }

    func describe(_ args: JSONValue, ctx: TurnContext) -> String {
        guard case .ready(let plan) = PlannerWhen.timer(args, ctx: ctx) else { return "Set a timer" }
        return "Timer for " + SpokenTime.durationWords(plan.seconds)
    }

    func execute(_ args: JSONValue, ctx: TurnContext) async throws -> ToolResult {
        guard case .ready(let plan) = PlannerWhen.timer(args, ctx: ctx) else {
            return .fail("How long shall I set the timer for?")
        }
        let rings = Date().addingTimeInterval(plan.seconds)
        let outcome = await PlannerAlarms.schedule(label: plan.label, at: rings, repeats: .none, calendar: ctx.calendar,
                                                   canAsk: ctx.canShowUI)
        guard case .scheduled(let alarmID) = outcome else {
            return await PlannerAlarms.reminderInstead(title: plan.label, at: rings, repeats: .none, why: outcome,
                                                       isTimer: true, ctx: ctx)
        }
        let called = PlannerWords.isGenericLabel(plan.label) ? "a timer" : "a timer called “\(plan.label)”"
        let say = "I've set \(called) for \(SpokenTime.durationWords(plan.seconds)). It will ring at \(SpokenTime.spoken(rings, now: Date(), calendar: ctx.calendar))."
        return ToolResult(ok: true, say: say, data: [
            "kind": "timer", "label": .string(plan.label), "seconds": .number(plan.seconds.rounded()),
            "rings_at": .string(SpokenTime.isoString(rings, calendar: ctx.calendar)), "rings_on_silent": true,
            "alarm_id": .string(alarmID),
        ])
    }
}

// MARK: - create_reminder

struct PlannerCreateReminderTool: KairosTool {
    let name = "create_reminder"
    let summary = "Add a reminder to the phone's Reminders, with an alert at the time. Can repeat every day or every week."
    let risk: Risk = .localWrite
    var parameters: JSONValue {
        Schema.object([
            "title": Schema.string("What to remember, short, in their words, e.g. \"Take pills\", \"Ring the GP\""),
            "due_iso": Schema.string("When to remind them: local date and time, e.g. \"2026-10-25T20:00:00+00:00\". Leave out only for a to-do with no alert (\"put milk on my list\"). If they said \"remind me\" but not when, ask when instead of calling this."),
            "repeat": Schema.string("How often: weekdays is Monday to Friday", oneOf: ["none", "daily", "weekdays", "weekly"]),
        ], required: ["title"])
    }

    func quickMatch(_ words: String, ctx: TurnContext) -> JSONValue? {
        guard !PlannerWords.severalRequests(words), !PlannerWords.otherDevice(words) else { return nil }
        let w = PlannerWords.core(words)
        guard let trigger = PlannerWords.reminderTriggers.first(where: { PlannerWords.starts(w, $0) }),
              !trigger.isEmpty, !w.contains("alarm"), !w.contains("timer"),
              let heard = SpokenTime.parse(words, now: ctx.now, calendar: ctx.calendar, prefer: .general),
              heard.clockCount <= 1, !PlannerWords.unreadTime(heard.leftover)
        else { return nil }
        var left = PlannerWords.strip(heard.leftover, leading: PlannerWords.politePrefixes, once: false)
        left = PlannerWords.strip(left, leading: PlannerWords.reminderTriggers, once: true)
        left = PlannerWords.strip(left, leading: PlannerWords.titleLeads, once: false)
        left = PlannerWords.strip(left, trailing: PlannerWords.politeSuffixes)
        guard let firstWord = left.first.map(PlannerWords.norm), !PlannerWords.questionWords.contains(firstWord) else { return nil }
        let title = PlannerWords.capitalisedFirst(left.joined(separator: " "))
        return [
            "title": .string(title),
            "due_iso": .string(SpokenTime.isoString(heard.date, calendar: ctx.calendar)),
            "repeat": .string(heard.repeats.rawValue),
        ]
    }

    func validate(_ args: JSONValue, ctx: TurnContext) -> Validation {
        if case .problem(let v) = PlannerWhen.reminder(args, ctx: ctx) { return v }
        return .ok
    }

    func describe(_ args: JSONValue, ctx: TurnContext) -> String {
        guard case .ready(let plan) = PlannerWhen.reminder(args, ctx: ctx) else { return "Add a reminder" }
        guard let due = plan.due else { return "Reminder: \(plan.title)" }
        return "Reminder: \(plan.title), " + PlannerSay.when(due, plan.repeats, ctx: ctx, lead: "")
    }

    func execute(_ args: JSONValue, ctx: TurnContext) async throws -> ToolResult {
        guard case .ready(let plan) = PlannerWhen.reminder(args, ctx: ctx) else {
            return .fail("When would you like me to remind you?")
        }
        switch await PlannerStore.shared.addReminder(title: plan.title, due: plan.due, repeats: plan.repeats, ctx: ctx) {
        case .problem(let result):
            return result
        case .failed:
            return .fail("Sorry, I couldn't save that reminder. Please try again.")
        case .saved(let list):
            let say: String
            if let due = plan.due {
                say = "I'll remind you \(PlannerWords.aboutPhrase(plan.title)) \(PlannerSay.when(due, plan.repeats, ctx: ctx, lead: "at"))."
            } else {
                say = "I've added “\(plan.title)” to your Reminders."
            }
            var data: [String: JSONValue] = [
                "kind": "reminder", "title": .string(plan.title), "repeats": .string(plan.repeats.rawValue), "list": .string(list),
            ]
            if let due = plan.due { data["due"] = .string(SpokenTime.isoString(due, calendar: ctx.calendar)) }
            if plan.corrected { data["note"] = "Used the time the person said, not the one proposed." }
            return ToolResult(ok: true, say: say, data: .object(data))
        }
    }
}

// MARK: - add_calendar_event

struct PlannerAddEventTool: KairosTool {
    let name = "add_calendar_event"
    let summary = "Put an appointment in the phone's calendar, with an alert an hour before."
    let risk: Risk = .localWrite
    var parameters: JSONValue {
        Schema.object([
            "title": Schema.string("What it is, short, e.g. \"Dentist\", \"Lunch with Priya\""),
            "start_iso": Schema.string("Local start date and time, e.g. \"2026-10-27T15:00:00+00:00\". A date alone (\"2026-10-31\") makes an all-day event."),
            "duration_min": Schema.integer("How long in minutes; 60 if they didn't say"),
            "location": Schema.string("Where, if they said"),
        ], required: ["title", "start_iso"])
    }

    func validate(_ args: JSONValue, ctx: TurnContext) -> Validation {
        if case .problem(let v) = PlannerWhen.event(args, ctx: ctx) { return v }
        return .ok
    }

    func describe(_ args: JSONValue, ctx: TurnContext) -> String {
        guard case .ready(let plan) = PlannerWhen.event(args, ctx: ctx) else { return "Add to your calendar" }
        let when = plan.allDay ? SpokenTime.dayPhrase(plan.start, now: ctx.now, calendar: ctx.calendar)
                               : SpokenTime.spoken(plan.start, now: ctx.now, calendar: ctx.calendar)
        return "Calendar: \(plan.title), \(when)"
    }

    func execute(_ args: JSONValue, ctx: TurnContext) async throws -> ToolResult {
        guard case .ready(let plan) = PlannerWhen.event(args, ctx: ctx) else {
            return .fail("What day and time is it?")
        }
        let kit = PlannerStore.shared
        let access = await kit.access(.event, canAsk: ctx.canShowUI, writeOnlyIsEnough: true)
        guard access == .granted else { return await PlannerSay.noAccess(access, .calendar, ctx: ctx) }
        let store = kit.store
        guard let calendar = store.defaultCalendarForNewEvents
                ?? store.calendars(for: .event).first(where: { $0.allowsContentModifications }) else {
            return .fail("I couldn't find a calendar on this phone to put it in.")
        }
        let event = EKEvent(eventStore: store)
        event.title = plan.title
        event.calendar = calendar
        event.location = plan.location
        var remindsBefore = false
        if plan.allDay {
            event.isAllDay = true
            event.startDate = plan.start
            event.endDate = ctx.calendar.date(byAdding: .day, value: 1, to: plan.start) ?? plan.start.addingTimeInterval(86_400)
        } else {
            event.startDate = plan.start
            event.endDate = plan.start.addingTimeInterval(Double(plan.minutes) * 60)
            if plan.start.timeIntervalSince(ctx.now) > 3600 {
                event.addAlarm(EKAlarm(relativeOffset: -3600))
                remindsBefore = true
            }
        }
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            return .fail("Sorry, I couldn't put that in your calendar. Please try again.")
        }
        var say: String
        if plan.allDay {
            say = "I've put “\(plan.title)” in your calendar \(SpokenTime.dayPhrase(plan.start, now: ctx.now, calendar: ctx.calendar))."
        } else {
            say = "I've put “\(plan.title)” in your calendar for \(SpokenTime.spoken(plan.start, now: ctx.now, calendar: ctx.calendar))."
            if remindsBefore { say += " Your phone will remind you an hour before." }
        }
        var data: [String: JSONValue] = [
            "kind": "calendar_event", "title": .string(plan.title), "start": .string(SpokenTime.isoString(plan.start, calendar: ctx.calendar)),
            "all_day": .bool(plan.allDay), "minutes": .number(Double(plan.minutes)), "calendar": .string(calendar.title),
        ]
        if let location = plan.location { data["location"] = .string(location) }
        if plan.corrected { data["note"] = "Used the time the person said, not the one proposed." }
        return ToolResult(ok: true, say: say, data: .object(data))
    }
}

// MARK: - get_calendar_events

struct PlannerGetEventsTool: KairosTool {
    let name = "get_calendar_events"
    let summary = "Say what is in the person's calendar and Reminders on one day."
    let risk: Risk = .read
    var parameters: JSONValue {
        Schema.object(["date_iso": Schema.string("The day, e.g. \"2026-10-26\"")], required: ["date_iso"])
    }

    func quickMatch(_ words: String, ctx: TurnContext) -> JSONValue? {
        guard !PlannerWords.severalRequests(words) else { return nil }
        let w = PlannerWords.core(words)
        guard let lead = PlannerWords.dayQuestions.first(where: { PlannerWords.starts(w, $0) }),
              w.dropFirst(lead.count).allSatisfy({ PlannerWords.dayQuestionWords.contains($0) || SpokenTime.weekdays[$0] != nil }),
              let heard = SpokenTime.parse(words, now: ctx.now, calendar: ctx.calendar), heard.daySaid, !heard.clockSaid
        else { return nil }
        return ["date_iso": .string(SpokenTime.dayString(heard.date, calendar: ctx.calendar))]
    }

    func describe(_ args: JSONValue, ctx: TurnContext) -> String {
        "Looking at " + PlannerSay.dayName(PlannerWhen.day(args, ctx: ctx), ctx: ctx)
    }

    func execute(_ args: JSONValue, ctx: TurnContext) async throws -> ToolResult {
        let cal = ctx.calendar
        let day = PlannerWhen.day(args, ctx: ctx)
        let kit = PlannerStore.shared
        let access = await kit.access(.event, canAsk: ctx.canShowUI)
        guard access == .granted else { return await PlannerSay.noAccess(access, .calendar, ctx: ctx) }
        let store = kit.store
        let end = cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)

        var items: [PlannerDayItem] = store.events(matching: store.predicateForEvents(withStart: day, end: end, calendars: nil))
            .filter { $0.status != .canceled }
            .map { e in
                PlannerDayItem(title: e.title ?? "Something", start: e.startDate, allDay: e.isAllDay || e.startDate < day,
                               location: e.location, isReminder: false)
            }
        // Reminders due that day, if Kairos may already read them (no extra prompt for a question).
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: day, ending: end, calendars: nil)
            let due: [PlannerDayItem] = await withCheckedContinuation { cont in
                _ = store.fetchReminders(matching: predicate) { reminders in
                    let mapped = (reminders ?? []).map { r -> PlannerDayItem in
                        let comps = r.dueDateComponents
                        let hasTime = comps?.hour != nil
                        let date = comps.flatMap { cal.date(from: $0) }
                        return PlannerDayItem(title: r.title ?? "Something", start: hasTime ? date : nil, allDay: !hasTime,
                                              location: nil, isReminder: true)
                    }
                    cont.resume(returning: mapped)
                }
            }
            items += due
        }
        items.sort { a, b in
            switch (a.allDay || a.start == nil, b.allDay || b.start == nil) {
            case (true, false): return true
            case (false, true): return false
            default: return (a.start ?? .distantPast) < (b.start ?? .distantPast)
            }
        }

        let say = PlannerSay.daySummary(day: day, items: items, ctx: ctx)
        let list: [JSONValue] = items.prefix(30).map { item in
            var o: [String: JSONValue] = ["title": .string(item.title), "all_day": .bool(item.allDay),
                                          "kind": item.isReminder ? "reminder" : "event"]
            if let s = item.start, !item.allDay { o["time"] = .string(SpokenTime.hhmm(s, calendar: cal)) }
            if let l = item.location, !l.isEmpty { o["location"] = .string(l) }
            return .object(o)
        }
        // Calendar invites can come from strangers: treat their words as information, never instructions.
        let outside = items.map { [$0.title, $0.location ?? ""].filter { !$0.isEmpty }.joined(separator: " — ") }.joined(separator: "\n")
        return ToolResult(ok: true, say: say,
                          data: ["date": .string(SpokenTime.dayString(day, calendar: cal)), "items": .array(list)],
                          untrustedText: outside.isEmpty ? nil : outside, isAnswer: true)
    }
}

struct PlannerDayItem: Sendable {
    var title: String
    var start: Date?
    var allDay: Bool
    var location: String?
    var isReminder: Bool
}

// MARK: - Checking times against the person's words

enum PlannerCheck<Value> {
    case ready(Value)
    case problem(Validation)
}

struct PlannerAlarmPlan {
    var date: Date
    var repeats: SpokenTime.Repeat
    var label: String
    var corrected: Bool
}

struct PlannerTimerPlan {
    var seconds: TimeInterval
    var label: String
    var corrected: Bool
}

struct PlannerReminderPlan {
    var title: String
    var due: Date?
    var repeats: SpokenTime.Repeat
    var corrected: Bool
}

struct PlannerEventPlan {
    var title: String
    var start: Date
    var allDay: Bool
    var minutes: Int
    var location: String?
    var corrected: Bool
}

enum PlannerWhen {
    /// The person's latest words, for checking the model's times. Shortcuts automations are not the person
    /// speaking, and a sentence with several requests ("wake me at 7 and remind me to …") is left to the model.
    static func heard(_ ctx: TurnContext, prefer: SpokenTime.Prefer) -> SpokenTime? {
        guard ctx.source != .automation,
              let words = ctx.userWords.split(separator: "\n").last.map(String.init),
              !PlannerWords.severalRequests(words) else { return nil }
        return SpokenTime.parse(words, now: ctx.now, calendar: ctx.calendar, prefer: prefer)
    }

    /// The model's date with the person's own clock time and day put back where they differ.
    static func merge(_ model: Date, heard: SpokenTime?, ctx: TurnContext) -> (date: Date, corrected: Bool) {
        guard let heard, heard.clockCount <= 1 else { return (model, false) }
        let cal = ctx.calendar
        if heard.relative != nil {
            return abs(model.timeIntervalSince(heard.date)) > 120 ? (heard.date, true) : (model, false)
        }
        var c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: model)
        var changed = false
        if heard.clockSaid, let mh = c.hour, let mm = c.minute {
            let differs = heard.minute != mm || heard.hour % 12 != mh % 12 || (heard.halfDaySaid && heard.hour != mh)
            // "At 3" with no am or pm is the afternoon: a model that wrote 03:00 guessed the small hours.
            let smallHoursGuess = !heard.halfDaySaid && heard.hour != mh && mh < 6 && heard.hour >= 6
            if differs || smallHoursGuess {
                c.hour = heard.hour
                c.minute = heard.minute
                changed = true
            }
        }
        if heard.daySaid {
            let hd = cal.dateComponents([.year, .month, .day], from: heard.date)
            if hd.year != c.year || hd.month != c.month || hd.day != c.day {
                c.year = hd.year; c.month = hd.month; c.day = hd.day
                changed = true
            }
        }
        var date = changed ? (cal.date(from: c) ?? model) : model
        // The model put it in the past, the person named no day, and their words point to the next one.
        if date <= ctx.now, !heard.daySaid, heard.clockSaid, heard.date > ctx.now {
            date = heard.date
            changed = true
        }
        return (date, changed)
    }

    /// "07:00", "7:00", "0700", "7", "7pm", "19.30" → hour and minute.
    static func hourMinute(_ s: String) -> (Int, Int)? {
        let t = s.lowercased().replacingOccurrences(of: " ", with: "")
        guard let re = try? NSRegularExpression(pattern: #"^(\d{1,2})(?:[:.]?(\d{2}))?(am|pm)?$"#),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let hr = Range(m.range(at: 1), in: t), var h = Int(t[hr]) else { return nil }
        let minute = Range(m.range(at: 2), in: t).flatMap { Int(t[$0]) } ?? 0
        if let ap = Range(m.range(at: 3), in: t).map({ String(t[$0]) }) {
            guard (1...12).contains(h) else { return nil }
            h = h % 12 + (ap == "pm" ? 12 : 0)
        }
        guard (0...23).contains(h), (0...59).contains(minute) else { return nil }
        return (h, minute)
    }

    /// Any clock time said in this conversation, or in a letter it read: an alarm time must come from somewhere real.
    static func timeHasASource(_ date: Date, ctx: TurnContext) -> Bool {
        let lines = ctx.userWords.split(separator: "\n").map(String.init)
        if lines.contains(where: { SpokenTime.parse($0, now: ctx.now, calendar: ctx.calendar, prefer: .alarm).map { $0.clockSaid || $0.relative != nil } ?? false }) {
            return true
        }
        let h = ctx.calendar.component(.hour, from: date), m = ctx.calendar.component(.minute, from: date)
        let h12 = h % 12 == 0 ? 12 : h % 12
        let mm = String(format: "%02d", m)
        var forms = ["\(h):\(mm)", String(format: "%02d:%@", h, mm), "\(h).\(mm)", "\(h12):\(mm)", "\(h12).\(mm)"]
        if m == 0 { forms += ["\(h12)am", "\(h12) am", "\(h12)pm", "\(h12) pm", "\(h12) o'clock", "\(h12)a.m", "\(h12)p.m", "\(h12) a.m", "\(h12) p.m"] }
        let docs = ctx.documents.joined(separator: "\n").lowercased()
        return forms.contains { docs.contains($0) }
    }

    /// The person's latest line, when it is the person speaking (not a Shortcut's text).
    static func latestWords(_ ctx: TurnContext) -> String? {
        guard ctx.source != .automation else { return nil }
        return ctx.userWords.split(separator: "\n").last.map(String.init)
    }

    static func alarm(_ args: JSONValue, ctx: TurnContext) -> PlannerCheck<PlannerAlarmPlan> {
        let cal = ctx.calendar, now = ctx.now
        // Kairos can only ring this phone: "on my husband's phone" must not quietly set an alarm here. (Not checked
        // when the words hold several requests: "… and text my son on his phone" is about the text.)
        if let latest = latestWords(ctx), PlannerWords.otherDevice(latest), !PlannerWords.severalRequests(latest) {
            return .problem(.clarify(PlannerWords.otherDeviceAnswer))
        }
        let label = PlannerWords.cleanLabel(args.text("label"), fallback: "Alarm")
        // An alarm named from an earlier sentence: the time in the latest words belongs to something else.
        let heard = PlannerWords.fromEarlierLine(label, ctx: ctx) ? nil : heard(ctx, prefer: .alarm)
        var repeats = SpokenTime.Repeat(rawValue: args.text("repeat")?.lowercased() ?? "")
            ?? ((args["repeat_daily"]?.bool ?? false) ? .daily : .none)  // repeat_daily: routines saved before
        if let r = heard?.repeats, r != .none { repeats = r }
        // "Oh actually, make it 8 instead" after "an alarm for 7 tomorrow": still tomorrow, not this morning.
        let earlierDay = heard?.daySaid == true ? nil : PlannerWords.correctedDay(ctx)

        var modelDate: Date?
        if let tm = args.text("time_hhmm") {
            if let iso = SpokenTime.isoWallClock(tm, calendar: cal), iso.hasTime {
                modelDate = iso.date
            } else if let (h, m) = hourMinute(tm) {
                var day = cal.startOfDay(for: now)
                if let d = args.text("day_iso").flatMap({ SpokenTime.isoWallClock($0, calendar: cal) }) { day = cal.startOfDay(for: d.date) }
                else if let earlierDay { day = earlierDay }
                modelDate = cal.date(bySettingHour: h, minute: m, second: 0, of: day)
            }
        }

        var date: Date
        var corrected = false
        if let md = modelDate {
            if heard?.clockSaid != true, heard?.relative == nil, !timeHasASource(md, ctx: ctx) {
                return .problem(.clarify("What time shall I set it for?"))
            }
            (date, corrected) = merge(md, heard: heard, ctx: ctx)
        } else if let heard, heard.clockCount <= 1, heard.clockSaid || heard.relative != nil {
            date = heard.date
            if heard.relative == nil, let earlierDay {
                date = cal.date(bySettingHour: heard.hour, minute: heard.minute, second: 0, of: earlierDay) ?? date
            }
            corrected = true
        } else {
            return .problem(.clarify("What time shall I set it for?"))
        }

        if date <= now {
            if heard?.daySaid == true && repeats == .none {
                return .problem(.clarify("That time has already gone today. Shall I set it for tomorrow instead?"))
            }
            // An alarm means the next time that clock comes round.
            let h = cal.component(.hour, from: date), m = cal.component(.minute, from: date)
            date = cal.date(bySettingHour: h, minute: m, second: 0, of: now) ?? date
            if date <= now { date = cal.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400) }
        }
        // Every weekday starts on a weekday ("starting Monday" when it's said at the weekend).
        if repeats == .weekdays { date = SpokenTime.nextWeekday(date, calendar: cal) }
        return .ready(PlannerAlarmPlan(date: date, repeats: repeats, label: label, corrected: corrected))
    }

    static func timer(_ args: JSONValue, ctx: TurnContext) -> PlannerCheck<PlannerTimerPlan> {
        let label = PlannerWords.cleanLabel(args.text("label"), fallback: "Timer")
        let latest = latestWords(ctx)
        if let latest, PlannerWords.otherDevice(latest), !PlannerWords.severalRequests(latest) {
            return .problem(.clarify(PlannerWords.otherDeviceAnswer))
        }
        var heardLength: TimeInterval?
        if let words = latest, !PlannerWords.severalRequests(words) {
            let found = SpokenTime.durations(in: words)
            if found.count == 1 { heardLength = found[0] }
        }
        var seconds: TimeInterval
        var corrected = false
        if let minutes = args["minutes"]?.double, minutes > 0 {
            seconds = minutes * 60
            // Checked even when the words hold several requests: a timer can't stand in for a time of day.
            if let words = latest, let problem = clockNotCountdown(words, seconds: seconds, ctx: ctx) { return .problem(problem) }
            if let h = heardLength, abs(h - seconds) > 1 { seconds = h; corrected = true }
        } else if let h = heardLength {
            seconds = h
            corrected = true
        } else {
            return .problem(.clarify("How long shall I set the timer for?"))
        }
        guard seconds >= 5, seconds <= 24 * 3600 else {
            return .problem(.clarify("A timer can be up to 24 hours. How long would you like?"))
        }
        return .ready(PlannerTimerPlan(seconds: seconds, label: label, corrected: corrected))
    }

    /// "Tell me when it's ten minutes before my 4:15 bus" is a time of day, not a countdown: a timer for a number
    /// of minutes the person never said would ring at the wrong time.
    static func clockNotCountdown(_ words: String, seconds: TimeInterval, ctx: TurnContext) -> Validation? {
        guard let said = SpokenTime.parse(words, now: ctx.now, calendar: ctx.calendar), said.relative == nil else { return nil }
        if said.shift != nil, said.clockCount == 1 {
            let when = SpokenTime.spoken(said.date, now: ctx.now, calendar: ctx.calendar)
            return .clarify("A timer only counts minutes from now. Shall I set an alarm for \(when) instead?")
        }
        guard said.clockSaid else { return nil }
        // The minutes must be ones the person said: "20 minutes", or a plain "make it 15".
        let toks = SpokenTime.tokens(words)
        let lengths = SpokenTime.durationMatches(toks).map(\.seconds)
        let numbers = toks.indices.compactMap { SpokenTime.number(toks, $0).map { Double($0.0) * 60 } }
        if (lengths + numbers).contains(where: { abs($0 - seconds) <= 1 }) { return nil }
        return .clarify("How many minutes shall I set the timer for? If you meant a time of day, I can set an alarm instead.")
    }

    static func reminder(_ args: JSONValue, ctx: TurnContext) -> PlannerCheck<PlannerReminderPlan> {
        let cal = ctx.calendar, now = ctx.now
        guard let rawTitle = args.text("title") else {
            return .problem(.clarify("What would you like me to remind you about?"))
        }
        let title = PlannerWords.capitalisedFirst(String(rawTitle.prefix(200)))
        var repeats = SpokenTime.Repeat(rawValue: args.text("repeat")?.lowercased() ?? "none") ?? .none
        // A reminder named from an earlier sentence ("ring the surgery", when they now say "and another one at 2 to
        // pick up my prescription"): the time in the latest words belongs to the new one, not to this.
        let heard = PlannerWords.fromEarlierLine(title, ctx: ctx) ? nil : heard(ctx, prefer: .general)
        if let r = heard?.repeats, r != .none { repeats = r }

        var due: Date?
        var corrected = false
        if let iso = args.text("due_iso").flatMap({ SpokenTime.isoWallClock($0, calendar: cal) }) {
            let proposed = iso.hasTime ? iso.date : (cal.date(bySettingHour: 9, minute: 0, second: 0, of: iso.date) ?? iso.date)
            (due, corrected) = merge(proposed, heard: heard, ctx: ctx)
        } else if let heard, heard.clockCount <= 1 {
            due = heard.date  // the model left the time out, but the person said one
            corrected = true
        }
        // "Remind me to ring the council" with no time: a reminder without one never goes off, so ask when.
        if due == nil, let question = PlannerWords.askWhen(ctx) { return .problem(.clarify(question)) }

        if var d = due, d < now.addingTimeInterval(-60) {
            guard repeats != .none else {
                return .problem(.clarify("That time has already gone. When would you like me to remind you?"))
            }
            var steps = 0
            while d <= now, steps < 400 {
                d = cal.date(byAdding: .day, value: repeats == .weekly ? 7 : 1, to: d) ?? d.addingTimeInterval(86_400)
                steps += 1
            }
            due = d
        }
        if repeats == .weekdays, let d = due { due = SpokenTime.nextWeekday(d, calendar: cal) }
        return .ready(PlannerReminderPlan(title: title, due: due, repeats: repeats, corrected: corrected))
    }

    static func event(_ args: JSONValue, ctx: TurnContext) -> PlannerCheck<PlannerEventPlan> {
        let cal = ctx.calendar, now = ctx.now
        guard let rawTitle = args.text("title") else {
            return .problem(.clarify("What shall I call it in your calendar?"))
        }
        let title = PlannerWords.capitalisedFirst(String(rawTitle.prefix(200)))
        let heard = heard(ctx, prefer: .general)
        var start: Date
        var allDay = false
        var corrected = false
        if let iso = args.text("start_iso").flatMap({ SpokenTime.isoWallClock($0, calendar: cal) }) {
            if iso.hasTime || heard?.clockSaid == true {
                (start, corrected) = merge(iso.date, heard: heard, ctx: ctx)
            } else {
                start = cal.startOfDay(for: iso.date)
                allDay = true
                if let heard, heard.daySaid, !cal.isDate(heard.date, inSameDayAs: start) {
                    start = cal.startOfDay(for: heard.date)
                    corrected = true
                }
            }
        } else if let heard, heard.clockSaid, heard.clockCount == 1 {
            start = heard.date
            corrected = true
        } else {
            return .problem(.clarify("What day and time is it?"))
        }
        if allDay ? start < cal.startOfDay(for: now) : start < now.addingTimeInterval(-600) {
            return .problem(.clarify("That time has already gone. What day and time is it?"))
        }
        let minutes = min(max(args["duration_min"]?.int ?? 60, 5), 24 * 60)
        let location = args.text("location").map { String($0.prefix(200)) }
        return .ready(PlannerEventPlan(title: title, start: start, allDay: allDay, minutes: minutes, location: location,
                                       corrected: corrected))
    }

    /// The day to look at: the person's own words win ("tomorrow"), then the model's date, then today.
    static func day(_ args: JSONValue, ctx: TurnContext) -> Date {
        let cal = ctx.calendar
        if let heard = heard(ctx, prefer: .general), heard.daySaid { return cal.startOfDay(for: heard.date) }
        if let iso = args.text("date_iso").flatMap({ SpokenTime.isoWallClock($0, calendar: cal) }) { return cal.startOfDay(for: iso.date) }
        return cal.startOfDay(for: ctx.now)
    }
}

// MARK: - Reminders and Calendar (EventKit)

enum PlannerAccess: Equatable, Sendable { case granted, denied, restricted, needsApp }

enum PlannerSaveOutcome: Sendable {
    case saved(list: String)
    case problem(ToolResult)
    case failed
}

/// One EventKit store for the app. A store made before access was granted can miss the person's lists,
/// so a fresh one is made right after a yes.
final class PlannerStore: @unchecked Sendable {
    static let shared = PlannerStore()
    private let lock = NSLock()
    private var current = EKEventStore()

    var store: EKEventStore {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    private func renew() {
        lock.lock(); current = EKEventStore(); lock.unlock()
    }

    func access(_ type: EKEntityType, canAsk: Bool, writeOnlyIsEnough: Bool = false) async -> PlannerAccess {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: return .granted
        case .writeOnly: return writeOnlyIsEnough ? .granted : .denied
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined:
            guard canAsk else { return .needsApp }
            do {
                let granted: Bool
                if type == .reminder { granted = try await store.requestFullAccessToReminders() }
                else { granted = try await store.requestFullAccessToEvents() }
                guard granted else { return .denied }
                renew()
                return .granted
            } catch {
                return .denied
            }
        @unknown default:
            return .denied
        }
    }

    /// A reminder in the default list, with an alert at the due time and the repeat rule.
    func addReminder(title: String, due: Date?, repeats: SpokenTime.Repeat, ctx: TurnContext) async -> PlannerSaveOutcome {
        let access = await access(.reminder, canAsk: ctx.canShowUI)
        guard access == .granted else { return .problem(await PlannerSay.noAccess(access, .reminders, ctx: ctx)) }
        let store = store
        guard let list = store.defaultCalendarForNewReminders()
                ?? store.calendars(for: .reminder).first(where: { $0.allowsContentModifications }) else { return .failed }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list
        if let due {
            var comps = ctx.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            comps.timeZone = ctx.timeZone
            reminder.dueDateComponents = comps
            reminder.addAlarm(EKAlarm(absoluteDate: due))
            switch repeats {
            case .daily: reminder.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil))
            case .weekly: reminder.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil))
            case .weekdays:
                let days: [EKWeekday] = [.monday, .tuesday, .wednesday, .thursday, .friday]
                reminder.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1,
                                                            daysOfTheWeek: days.map { EKRecurrenceDayOfWeek($0) },
                                                            daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
                                                            daysOfTheYear: nil, setPositions: nil, end: nil))
            case .none: break
            }
        }
        do {
            try store.save(reminder, commit: true)
            return .saved(list: list.title)
        } catch {
            return .failed
        }
    }
}

// MARK: - Alarms (AlarmKit, iOS 26)

enum PlannerAlarmOutcome: Sendable, Equatable {
    case scheduled(String)  // the alarm's id
    case notAllowed         // the person said no to alarms
    case needsApp           // never asked yet, and Siri can't ask in the background
    case failed
    case unsupported        // before iOS 26
}

enum PlannerAlarms {
    static func schedule(label: String, at date: Date, repeats: SpokenTime.Repeat, calendar: Calendar,
                         canAsk: Bool) async -> PlannerAlarmOutcome {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            return await PlannerAlarmKit.schedule(label: label, at: date, repeats: repeats, calendar: calendar, canAsk: canAsk)
        }
        #endif
        return .unsupported
    }

    /// When a proper alarm can't be set: a reminder with an alert at the same time, said plainly.
    static func reminderInstead(title: String, at date: Date, repeats: SpokenTime.Repeat, why: PlannerAlarmOutcome,
                                isTimer: Bool, ctx: TurnContext) async -> ToolResult {
        let what = isTimer ? "timer" : "alarm"
        switch await PlannerStore.shared.addReminder(title: title, due: date, repeats: repeats, ctx: ctx) {
        case .problem(let result):
            if why == .needsApp {
                return .fail("I need your permission to set \(what)s first. Please open Kairos and ask me there.")
            }
            return result
        case .failed:
            return .fail("Sorry, I couldn't set that \(what). Please try again.")
        case .saved:
            let when = PlannerSay.when(date, repeats, ctx: ctx, lead: "for")
            let say: String
            switch why {
            case .notAllowed:
                say = "Kairos isn't allowed to set \(what)s, so I've made a reminder \(when) instead. It won't ring if the phone is on silent."
            case .needsApp:
                say = "I've made a reminder \(when). Open Kairos once, and I'll be able to set proper \(what)s too."
            default:
                say = "I couldn't set a loud \(what) on this phone, so I've made a reminder \(when) instead. It won't ring if the phone is on silent."
            }
            return ToolResult(ok: true, say: say, data: [
                "kind": .string("reminder_instead_of_\(what)"), "title": .string(title),
                "due": .string(SpokenTime.isoString(date, calendar: ctx.calendar)), "repeats": .string(repeats.rawValue),
                "rings_on_silent": false,
            ])
        }
    }
}

#if canImport(AlarmKit)
@available(iOS 26.0, *)
struct PlannerAlarmMetadata: AlarmMetadata {
    var label: String
}

@available(iOS 26.0, *)
enum PlannerAlarmKit {
    static let everyDay: [Locale.Weekday] = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]

    static func schedule(label: String, at date: Date, repeats: SpokenTime.Repeat, calendar: Calendar,
                         canAsk: Bool) async -> PlannerAlarmOutcome {
        let manager = AlarmManager.shared
        switch manager.authorizationState {
        case .authorized:
            break
        case .denied:
            return .notAllowed
        case .notDetermined:
            guard canAsk else { return .needsApp }
            do {
                guard try await manager.requestAuthorization() == .authorized else { return .notAllowed }
            } catch {
                return .failed  // e.g. NSAlarmKitUsageDescription missing from Info.plist
            }
        @unknown default:
            return .notAllowed
        }

        let comps = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        let time = Alarm.Schedule.Relative.Time(hour: comps.hour ?? 7, minute: comps.minute ?? 0)
        let schedule: Alarm.Schedule
        switch repeats {
        case .none:
            schedule = .fixed(date)
        case .daily:
            schedule = .relative(Alarm.Schedule.Relative(time: time, repeats: .weekly(everyDay)))
        case .weekly:
            let day = everyDay[((comps.weekday ?? 1) - 1 + 7) % 7]
            schedule = .relative(Alarm.Schedule.Relative(time: time, repeats: .weekly([day])))
        case .weekdays:
            schedule = .relative(Alarm.Schedule.Relative(time: time, repeats: .weekly([.monday, .tuesday, .wednesday,
                                                                                      .thursday, .friday])))
        }

        // A plain alert with one big Stop button. No countdown, so no widget extension is needed.
        let stop = AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle.fill")
        let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: label), stopButton: stop)
        let attributes = AlarmAttributes<PlannerAlarmMetadata>(presentation: AlarmPresentation(alert: alert),
                                                               metadata: PlannerAlarmMetadata(label: label),
                                                               tintColor: .orange)
        let id = UUID()
        do {
            let configuration = AlarmManager.AlarmConfiguration<PlannerAlarmMetadata>.alarm(schedule: schedule, attributes: attributes)
            _ = try await manager.schedule(id: id, configuration: configuration)
            return .scheduled(id.uuidString)
        } catch {
            return .failed
        }
    }
}
#endif

// MARK: - Words for the person

enum PlannerThing { case reminders, calendar }

enum PlannerSay {
    /// "for 7 tomorrow morning (Monday)", or "at 8 every night, starting tonight" when it repeats.
    static func when(_ date: Date, _ repeats: SpokenTime.Repeat, ctx: TurnContext, lead: String) -> String {
        if repeats != .none { return SpokenTime.repeating(date, repeats, now: ctx.now, calendar: ctx.calendar) }
        let spoken = SpokenTime.spoken(date, now: ctx.now, calendar: ctx.calendar)
        return lead.isEmpty ? spoken : "\(lead) \(spoken)"
    }

    static func settingsURL() async -> URL {
        #if canImport(UIKit)
        let s = await MainActor.run { UIApplication.openSettingsURLString }
        return URL(string: s) ?? URL(string: "app-settings:")!
        #else
        return URL(string: "app-settings:")!
        #endif
    }

    /// Plain instructions when Kairos may not use Reminders or the calendar, and Settings opened at Kairos's page.
    static func noAccess(_ access: PlannerAccess, _ thing: PlannerThing, ctx: TurnContext) async -> ToolResult {
        let name = thing == .reminders ? "Reminders" : "your calendar"
        let row = thing == .reminders ? "Reminders" : "Calendars"
        switch access {
        case .needsApp:
            return .fail("I need your permission to use \(name) first. Please open Kairos and ask me there.")
        case .restricted:
            return .fail("\(thing == .reminders ? "Reminders are" : "The calendar is") switched off on this phone, so I can't do that. Whoever looks after the phone's settings can turn it on.")
        case .denied, .granted:
            let say = ctx.canShowUI
                ? "Kairos isn't allowed to use \(name) yet. I've opened Settings for you: tap \(row), then choose Full Access."
                : "Kairos isn't allowed to use \(name) yet. Open Settings, tap Kairos, and turn on \(row)."
            return ToolResult(ok: false, say: say, data: ["error": .string(say)], ui: .openURL(await settingsURL()))
        }
    }

    /// "today", "tomorrow (Monday)", "Tuesday 27 October".
    static func dayName(_ day: Date, ctx: TurnContext) -> String {
        let phrase = SpokenTime.dayPhrase(day, now: ctx.now, calendar: ctx.calendar)
        return phrase.hasPrefix("on ") ? String(phrase.dropFirst(3)) : phrase
    }

    /// "Tomorrow you have 2 things: Dentist at 3, and Bins out."
    static func daySummary(day: Date, items: [PlannerDayItem], ctx: TurnContext) -> String {
        let cal = ctx.calendar
        let diff = cal.dateComponents([.day], from: cal.startOfDay(for: ctx.now), to: day).day ?? 0
        let named = dayName(day, ctx: ctx)  // "Tuesday 27 October"
        let lead = diff == 0 ? "Today" : diff == 1 ? "Tomorrow" : (diff == -1 ? "Yesterday" : "On " + named)
        guard !items.isEmpty else {
            let forDay = diff == 0 ? "today" : diff == 1 ? "tomorrow" : (diff == -1 ? "yesterday" : named)
            return "There's nothing in your calendar for \(forDay)."
        }
        let shown = items.prefix(items.count > 6 ? 5 : 6).map { item -> String in
            guard let s = item.start, !item.allDay else { return item.title }
            return "\(item.title) at \(SpokenTime.shortClock(s, calendar: cal))"
        }
        var list: String
        if items.count > 6 {
            list = shown.joined(separator: ", ") + ", and \(items.count - shown.count) more"
        } else if shown.count == 1 {
            list = shown[0]
        } else {
            list = shown.dropLast().joined(separator: ", ") + ", and " + (shown.last ?? "")
        }
        return items.count == 1 ? "\(lead) you have \(list)." : "\(lead) you have \(items.count) things: \(list)."
    }
}

// MARK: - Reading commands

enum PlannerWords {
    static let politePrefixes: [[String]] = [
        ["hey"], ["hi"], ["hello"], ["kairos"], ["ok"], ["okay"], ["please"], ["just"], ["can", "you"], ["could", "you"],
        ["would", "you"], ["will", "you"], ["can", "u"], ["i", "want", "you", "to"], ["i", "need", "you", "to"],
        ["id", "like", "you", "to"], ["i", "would", "like", "you", "to"], ["go", "and"],
    ]
    static let politeSuffixes: [[String]] = [["please"], ["thanks"], ["thank", "you"], ["kairos"], ["for", "me"], ["ok"]]
    static let reminderTriggers: [[String]] = [
        ["remind", "me"], ["set", "a", "reminder"], ["set", "me", "a", "reminder"], ["add", "a", "reminder"],
        ["make", "a", "reminder"], ["put", "a", "reminder"], ["create", "a", "reminder"], ["new", "reminder"],
    ]
    /// Words between "remind me" and the thing itself: "to", "that I need to", "about".
    static let titleLeads: [[String]] = [
        ["to", "remember", "to"], ["that", "i", "need", "to"], ["that", "i", "have", "to"], ["i", "need", "to"],
        ["i", "have", "to"], ["i", "must"], ["ive", "got", "to"], ["i", "should"], ["to"], ["that"], ["about"],
        ["for"], ["of"], ["in"], ["me", "to"],
    ]
    static let questionWords: Set<String> = ["what", "whats", "when", "where", "who", "how", "if", "whether", "which", "why"]
    /// Verbs that start a second request after "and" or "then": "… and text my son".
    static let requestVerbs: Set<String> = [
        "text", "message", "call", "ring", "phone", "email", "send", "tell", "pay", "read", "set", "remind", "add", "put",
        "what", "whats", "wake", "check", "open", "show", "find", "play", "turn", "cancel", "delete", "make", "start",
        "book", "is", "are", "how", "translate", "explain", "give", "help",
        // "… and then reply saying I'll call her tonight"
        "reply", "respond", "forward", "share", "post", "save", "write",
    ]
    static let notAnAlarmCommand: Set<String> = ["remind", "reminder", "timer", "calendar", "diary", "cancel", "delete",
                                                 "stop", "off", "snooze", "what", "whats", "when", "change", "move", "is"]
    static let notATimerCommand: Set<String> = ["remind", "reminder", "alarm", "calendar", "diary", "cancel", "delete",
                                                "stop", "off", "pause", "what", "whats", "how", "long", "left", "is"]
    static let timerFiller: Set<String> = ["set", "start", "a", "an", "the", "my", "timer", "for", "please", "me", "put",
                                           "on", "new", "make", "up", "of", "it", "to", "in", "kairos", "minute",
                                           "minutes", "countdown", "go", "and", "can", "you"]
    static let alarmFiller: Set<String> = ["set", "an", "a", "alarm", "me", "up", "for", "please", "at", "to", "make",
                                           "put", "on", "can", "you", "could", "would", "kairos", "the", "my", "new",
                                           "i", "want", "need", "will", "shall", "give", "create", "wake", "ring", "it",
                                           "hey", "ok", "okay", "just", "thanks", "phone", "iphone", "another"]
    static let dayQuestions: [[String]] = [
        ["whats", "on"], ["what", "is", "on"], ["what", "have", "i", "got"], ["what", "have", "i", "on"],
        ["what", "do", "i", "have"], ["what", "am", "i", "doing"], ["whats", "happening"], ["what", "is", "happening"],
        ["have", "i", "got", "anything"], ["do", "i", "have", "anything"], ["anything", "on"], ["whats", "in", "my"],
        ["what", "is", "in", "my"], ["is", "there", "anything"], ["whats", "my", "day"], ["whats", "planned"],
    ]
    static let dayQuestionWords: Set<String> = [
        "on", "for", "my", "in", "the", "calendar", "diary", "today", "tonight", "tomorrow", "this", "morning",
        "afternoon", "evening", "next", "coming", "day", "after", "got", "planned", "happening", "is", "there",
        "anything", "me", "please", "i", "have", "do", "like", "look", "looking", "doing", "am",
    ]
    static let genericLabels: Set<String> = ["", "alarm", "an alarm", "wake up", "wake-up", "wakeup", "timer", "a timer",
                                             "kairos", "kairos alarm", "reminder", "my alarm"]
    static let verbs: Set<String> = [
        "take", "call", "ring", "phone", "pay", "buy", "get", "pick", "collect", "put", "book", "check", "send", "go",
        "see", "water", "feed", "text", "email", "post", "renew", "cancel", "bring", "make", "do", "visit", "meet",
        "order", "eat", "drink", "walk", "clean", "wash", "start", "stop", "turn", "switch", "charge", "lock", "leave",
        "empty", "ask", "tell", "write", "read", "watch", "fill", "change", "move", "give", "return", "sort", "prepare",
        "cook", "clear", "look", "have", "use", "open", "close", "defrost", "record", "join", "wish", "thank", "top",
        "apply", "register", "submit", "sign", "print", "fetch", "drop", "message", "remember", "put", "plug", "unplug",
    ]

    static func norm(_ raw: String) -> String {
        raw.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
    }

    static func starts(_ w: [String], _ prefix: [String]) -> Bool {
        w.count >= prefix.count && Array(w.prefix(prefix.count)) == prefix
    }

    /// The token range left after "Kairos, can you … please".
    static func coreRange(_ w: [String]) -> Range<Int> {
        var lo = 0, hi = w.count
        var moved = true
        while moved {
            moved = false
            for p in politePrefixes where hi - lo >= p.count && Array(w[lo..<(lo + p.count)]) == p { lo += p.count; moved = true }
            for s in politeSuffixes where hi - lo >= s.count && Array(w[(hi - s.count)..<hi]) == s { hi -= s.count; moved = true }
        }
        return lo..<hi
    }

    static func core(_ text: String) -> [String] {
        let w = SpokenTime.tokens(text).map { $0.w }
        return Array(w[coreRange(w)])
    }

    /// "… and text my son", "… then call Priya": a second request the model should handle.
    static func severalRequests(_ text: String) -> Bool {
        let w = SpokenTime.tokens(text).map { $0.w }
        var reminder: Bool?
        for (k, x) in w.enumerated() where x == "and" || x == "then" {
            var j = k + 1
            while j < w.count, ["also", "then", "please", "can", "could", "you", "will", "just"].contains(w[j]) { j += 1 }
            guard j < w.count, requestVerbs.contains(w[j]) else { continue }
            // "Remind me at 10 to buy a card and post it": the posting is part of what to remember.
            if reminderTaskVerbs.contains(w[j]) {
                if reminder == nil { let c = core(text); reminder = reminderTriggers.contains { starts(c, $0) } }
                if reminder == true { continue }
            }
            return true
        }
        return false
    }
    /// After "and" in a reminder ("… and post Mum's card", "… and write the cheque"), part of the same thing to do.
    static let reminderTaskVerbs: Set<String> = ["post", "save", "write", "share"]

    /// Words about when that the rules can't read yet ("every other day", "at weekends", "monthly", "next month"):
    /// a rule that sees one stands back for the model, instead of putting it in the label or title. Some only count
    /// next to another word, so "the monthly rent", "another tablet" and "each grandchild" stay in the title.
    static let unreadTimeWords: Set<String> = [
        "every", "weekday", "weekdays", "weekend", "weekends", "fortnight", "workday", "workdays", "annually",
    ]
    /// "pay the rent monthly", not "the monthly rent".
    static let unreadTimeAdverbs: Set<String> = ["monthly", "yearly", "hourly", "fortnightly"]
    static let timeUnits: Set<String> = ["day", "days", "morning", "mornings", "afternoon", "afternoons", "evening",
                                         "evenings", "night", "nights", "week", "weeks", "month", "months", "year",
                                         "years", "weekday", "weekdays", "weekend", "weekends", "fortnight", "hour", "hours"]
    static let lengthWords: Set<String> = ["minute", "minutes", "min", "mins", "hour", "hours", "hr", "hrs"]
    static func unreadTime(_ leftover: [String]) -> Bool {
        let w = leftover.map(norm)
        let small: Set<String> = ["a", "an", "the", "my", "our", "your", "his", "her", "their", "this", "that"]
        let numbers: Set<String> = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                                    "eleven", "twelve", "few", "couple", "several"]
        for (i, x) in w.enumerated() {
            let before = i > 0 ? w[i - 1] : "", after = i + 1 < w.count ? w[i + 1] : ""
            if unreadTimeWords.contains(x) { return true }
            switch x {
            case "each":  // "each morning", "each Tuesday"
                if timeUnits.contains(after) || SpokenTime.weekdays[after] != nil { return true }
            case "working":  // "on working days", not "check the heating is working"
                if ["day", "days", "week", "weeks"].contains(after) { return true }
            case _ where unreadTimeAdverbs.contains(x):
                let owner = i > 0 && leftover[i - 1].lowercased().hasSuffix("'s")
                if !small.contains(before), !owner { return true }
            case "month", "months", "year", "years":  // "next month", "in 3 months", "the end of the month"
                if ["every", "each", "next", "a", "per", "this", "last", "coming", "following"].contains(before)
                    || numbers.contains(before) || Int(before) != nil || (before == "the" && i > 1 && w[i - 2] == "of") {
                    return true
                }
            case "earlier", "later":  // "wake me at 6, half an hour earlier" (than usual): not a label
                if lengthWords.contains(before) { return true }
            case "another":  // a second alarm: "and another an hour later", "and another one"; not "another tablet"
                var j = i + 1
                if j < w.count, w[j] == "one" { j += 1 }
                let next = w[j..<min(w.count, j + 3)]
                if next.isEmpty || next.contains(where: { lengthWords.contains($0) || $0 == "later" || $0 == "earlier" }) {
                    return true
                }
            default: break
            }
        }
        return false
    }

    /// The most words an alarm or timer label from the rules may have.
    static let longestLabel = 4

    /// Left over in a timer command, these make it something other than a plain countdown ("10 minutes before my bus").
    static let notACountdown: Set<String> = ["before", "after", "earlier", "later", "until", "till", "every", "each",
                                             "oclock", "am", "pm"]

    /// "Set an alarm on my husband's phone", "put a reminder in Ravi's iPad": a phone that isn't this one. Kairos can
    /// only ring this one. Only someone else's device ("his", "her", "their", "Ravi's") right after on/in/onto/to, in
    /// words led by set or put. Not "an alarm for 3 to ring Ravi on his mobile" (the phone is about the call), "for my
    /// GP phone appointment", "on my iPhone", or "a timer for Ravi's iPad time".
    static let deviceWords: Set<String> = ["phone", "iphone", "mobile", "ipad"]
    static let deviceNouns: Set<String> = ["call", "calls", "appointment", "appointments", "interview", "number", "numbers",
                                           "bill", "bills", "time"]
    static let otherOwners: Set<String> = ["his", "her", "their"]
    static let notPossessive: Set<String> = ["its", "thats", "whats", "theres", "heres", "whos", "hes", "shes", "lets",
                                             "wheres", "hows"]
    static let placingVerbs: Set<String> = ["set", "put", "add", "make", "create"]
    static let reachingVerbs: Set<String> = ["ring", "call", "phone", "text", "message", "email", "send", "tell", "facetime",
                                             "whatsapp", "reply"]
    static func otherDevice(_ text: String) -> Bool {
        let toks = SpokenTime.tokens(text)
        let w = toks.map { $0.w }
        for d in w.indices where d >= 2 && deviceWords.contains(w[d]) {
            if d + 1 < w.count, deviceNouns.contains(w[d + 1]) { continue }
            let owner = toks[d - 1].raw.lowercased()
            guard otherOwners.contains(owner) || owner.hasSuffix("s'")
                    || (owner.hasSuffix("'s") && !notPossessive.contains(w[d - 1])) else { continue }
            // "on Ravi's phone", "on my husband's phone"
            var at = d - 2
            if ["my", "our", "the"].contains(w[at]), at > 0 { at -= 1 }
            guard ["on", "onto", "in", "to"].contains(w[at]) else { continue }
            for v in stride(from: at - 1, through: 0, by: -1) {
                if reachingVerbs.contains(w[v]) { break }
                if placingVerbs.contains(w[v]) { return true }
            }
        }
        return false
    }
    static let otherDeviceAnswer = "I can only set alarms and reminders on this iPhone, not on anyone else's phone. Shall I send them a text to remind them instead?"

    /// "Oh actually", "make it 8 instead", "change it to 9": the person is changing what they just asked for.
    static func isCorrection(_ text: String) -> Bool {
        let w = SpokenTime.tokens(text).map { $0.w }
        if w.contains("instead") || w.contains("actually") || w.contains("rather") { return true }
        return zip(w, w.dropFirst()).contains { ["make", "change", "move"].contains($0.0) && ["it", "that"].contains($0.1) }
    }

    /// The day of the time said just before a correction ("an alarm for 7 tomorrow", then "make it 8 instead").
    static func correctedDay(_ ctx: TurnContext) -> Date? {
        guard ctx.source != .automation else { return nil }
        let lines = ctx.userWords.split(separator: "\n").map(String.init)
        guard lines.count >= 2, let latest = lines.last, isCorrection(latest),
              let before = SpokenTime.parse(lines[lines.count - 2], now: ctx.now, calendar: ctx.calendar, prefer: .alarm),
              before.clockSaid || before.daySaid else { return nil }
        return ctx.calendar.startOfDay(for: before.date)
    }

    /// Small words that don't tell two titles apart.
    static let titleSmallWords: Set<String> = ["the", "and", "for", "about", "with", "from", "your", "my", "alarm",
                                               "reminder", "remind", "wake", "set", "that", "this", "time"]

    /// The title (or label) came from an earlier sentence, not the latest one: none of its words are in the latest
    /// line, and some are in an earlier one ("ring the surgery", when they now say "and another one at 2"). Not for
    /// a correction ("make it 8:20 instead"): then the latest time is for that same item.
    static func fromEarlierLine(_ title: String, ctx: TurnContext) -> Bool {
        guard ctx.source != .automation else { return false }
        let lines = ctx.userWords.split(separator: "\n").map(String.init)
        guard lines.count >= 2, let latest = lines.last, !isCorrection(latest) else { return false }
        func words(_ s: String) -> Set<String> { Set(SpokenTime.tokens(s).map { $0.w }) }
        let content = words(title).filter { $0.count >= 3 && !titleSmallWords.contains($0) }
        guard !content.isEmpty, content.isDisjoint(with: words(latest)) else { return false }
        return lines.dropLast().contains { !content.isDisjoint(with: words($0)) }
    }

    /// "Put milk on my list", "no particular time": the person doesn't want an alert.
    static let noTimePhrases = ["no time", "any time", "anytime", "no particular time", "dont need a time",
                                "don t need a time", "without a time", "no alarm", "no alert", "on my list", "to my list",
                                "on the list", "to do list", "todo", "just a note"]
    static func noTimeWanted(_ text: String) -> Bool {
        let folded = " " + text.folded + " "
        return noTimePhrases.contains { folded.contains(" " + $0 + " ") }
    }

    /// The question to ask when the model would save a reminder with no time: the person said "remind me" but not
    /// when (and didn't say they want no time). Nil when that isn't so.
    static func askWhen(_ ctx: TurnContext) -> String? {
        guard ctx.source != .automation, let latest = ctx.userWords.split(separator: "\n").last.map(String.init) else { return nil }
        let w = core(latest)
        guard reminderTriggers.contains(where: { starts(w, $0) }),
              SpokenTime.parse(latest, now: ctx.now, calendar: ctx.calendar) == nil,
              !noTimeWanted(latest) else { return nil }
        // "Remind me when my daughter gets home": reminders only go off at a clock time.
        if w.contains("when") || w.contains("whenever") || latest.folded.contains("as soon as") {
            return "I can only remind you at a time of day, not when something happens. What time shall I remind you?"
        }
        return "When would you like me to remind you?"
    }

    /// Takes known word sequences off the front of raw words (compared lowercased, without apostrophes).
    static func strip(_ raw: [String], leading seqs: [[String]], once: Bool) -> [String] {
        var out = raw
        var moved = true
        while moved && !out.isEmpty {
            moved = false
            let lower = out.map(norm)
            if let s = seqs.first(where: { starts(lower, $0) }) {
                out.removeFirst(s.count)
                moved = !once
            }
        }
        return out
    }

    static func strip(_ raw: [String], trailing seqs: [[String]]) -> [String] {
        var out = raw
        var moved = true
        while moved && !out.isEmpty {
            moved = false
            let lower = out.map(norm)
            if let s = seqs.first(where: { lower.count >= $0.count && Array(lower.suffix($0.count)) == $0 }) {
                out.removeLast(s.count)
                moved = true
            }
        }
        return out
    }

    static func capitalisedFirst(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let f = t.first else { return t }
        return f.uppercased() + t.dropFirst()
    }

    static func cleanLabel(_ label: String?, fallback: String) -> String {
        let t = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”")))
        return t.isEmpty ? fallback : capitalisedFirst(String(t.prefix(60)))
    }

    static func isGenericLabel(_ label: String) -> Bool { genericLabels.contains(label.lowercased()) }

    /// "wake me up" → "Wake up"; "set an alarm for my bus" → "Bus"; otherwise "Alarm".
    static func alarmLabel(from leftover: [String]) -> String {
        let rest = leftover.filter { !alarmFiller.contains(norm($0)) }
        if !rest.isEmpty { return capitalisedFirst(rest.joined(separator: " ")) }
        return leftover.contains(where: { norm($0) == "wake" }) ? "Wake up" : "Alarm"
    }

    /// The title as the person hears it: "to take your pills", or "about “Dentist”".
    static func aboutPhrase(_ title: String) -> String {
        let first = title.split(separator: " ").first.map { norm(String($0)) } ?? ""
        guard verbs.contains(first) else { return "about “\(title)”" }
        let lowered = (title.first.map { String($0).lowercased() } ?? "") + title.dropFirst()
        return "to " + yourWords(lowered)
    }

    /// "take my pills" → "take your pills", for saying back.
    static func yourWords(_ s: String) -> String {
        let swaps: [String: String] = ["my": "your", "me": "you", "myself": "yourself", "mine": "yours", "i": "you",
                                       "im": "you're", "ive": "you've", "ill": "you'll", "id": "you'd"]
        return s.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            let w = String(word)
            let key = norm(w.trimmingCharacters(in: .punctuationCharacters))
            guard let swap = swaps[key], key != "ill" || w.contains("'") || w.contains("\u{2019}"),
                  key != "id" || w.contains("'") || w.contains("\u{2019}") else { return w }
            return swap
        }.joined(separator: " ")
    }
}
