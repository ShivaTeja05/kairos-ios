import EventKit
import Foundation

/// What is happening on this phone right now, in a few plain lines. Gemini gets it with every request (so it can
/// follow "make it 8 instead", "is Paper Reader done yet?", "what did you just do?"), and the ElevenLabs voice gets
/// the short version when a call starts. Built from the app's own state only; nothing here is a secret.
@MainActor
enum PhoneContext {
    /// Extra lines from parts merged later (worker agents, research reports). Each returns nil when it has nothing.
    static var providers: [String: () -> String?] = [:]

    /// For Gemini's system prompt.
    static func snapshot(now: Date = Date(), maxChars: Int = 1800) -> String {
        var out: [String] = common(now: now)
        if let calendar = calendarLine(now: now, detail: true) { out.append(calendar) }
        let permissions = OwnerPolicy.shared.permissionsSummary(now: now)
        if !permissions.isEmpty { out.append("Owner's permissions: " + permissions) }
        out += providers.keys.sorted().compactMap { providers[$0]?() }
        return clipped(out, maxChars)
    }

    /// For the voice when a call starts: the same picture, with calendar counts instead of titles.
    static func voiceSummary(now: Date = Date()) -> String {
        var out: [String] = common(now: now)
        if let calendar = calendarLine(now: now, detail: false) { out.append(calendar) }
        out += providers.keys.sorted().compactMap { providers[$0]?() }
        return clipped(out, 900)
    }

    private static func common(now: Date) -> [String] {
        var out: [String] = []
        let agent = KairosAgent.shared
        if let focused = AgentLibrary.shared.focused {
            out.append("The person is talking to their agent “\(focused.name)” right now.")
        }
        let mine = AgentLibrary.shared.agents.filter { $0.origin != .builtin }.map(\.name)
        if !mine.isEmpty { out.append("Agents the person made: \(mine.prefix(8).joined(separator: ", ")).") }
        let routines = RoutineStore.shared.all.map(\.name)
        if !routines.isEmpty { out.append("Their routines: \(routines.prefix(8).joined(separator: ", ")).") }
        let recent = agent.lines.filter { [.done, .failed, .refused].contains($0.kind) }.suffix(6)
        if !recent.isEmpty {
            out.append("Recent actions on the phone: " + recent.map { line in
                let who = line.helper.map { "\($0): " } ?? ""
                return "\(mark(line.kind)) \(who)\(line.text)"
            }.joined(separator: "; ") + ".")
        }
        if let card = agent.confirmation { out.append("Waiting on screen for the owner's yes: \(card.detail).") }
        if let doing = agent.workingOn { out.append("Working on now: \(doing).") }
        return out
    }

    private static func mark(_ kind: AgentLine.Kind) -> String {
        switch kind {
        case .done: return "done"
        case .failed: return "failed"
        case .refused: return "refused"
        default: return ""
        }
    }

    private static func clipped(_ lines: [String], _ maxChars: Int) -> String {
        let text = lines.filter { !$0.isEmpty }.joined(separator: "\n")
        if text.isEmpty { return "Nothing special is happening on the phone." }
        return text.count > maxChars ? String(text.prefix(maxChars)) + "…" : text
    }

    // MARK: - Calendar (only if the person already allowed Kairos to see it; cached for a minute)

    private static let store = EKEventStore()
    private static var cache: (at: Date, detail: Bool, line: String?)?

    private static func calendarLine(now: Date, detail: Bool) -> String? {
        if let c = cache, c.detail == detail, now.timeIntervalSince(c.at) < 60 { return c.line }
        var line: String?
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            let cal = Calendar.current
            let start = cal.startOfDay(for: now)
            let end = cal.date(byAdding: .day, value: 2, to: start) ?? now.addingTimeInterval(172_800)
            let events = store.events(matching: store.predicateForEvents(withStart: now, end: end, calendars: nil))
                .filter { !$0.isAllDay || cal.isDate($0.startDate, inSameDayAs: now) }
                .sorted { $0.startDate < $1.startDate }
            if events.isEmpty {
                line = "Calendar: nothing for the rest of today or tomorrow."
            } else if detail {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_GB")
                f.dateFormat = "EEE HH:mm"
                line = "Calendar (next 2 days): " + events.prefix(6).map { "\(f.string(from: $0.startDate)) \($0.title ?? "event")" }
                    .joined(separator: "; ") + "."
            } else {
                let today = events.filter { cal.isDate($0.startDate, inSameDayAs: now) }.count
                line = "Calendar: \(today) thing(s) left today, \(events.count - today) tomorrow."
            }
        }
        cache = (now, detail, line)
        return line
    }
}
