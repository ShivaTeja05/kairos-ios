import Foundation

// British spoken times and dates, turned into a date in the person's time zone:
// "8 tonight", "half past eight in the morning", "quarter to 3", "noon", "midday", "in 20 minutes",
// "tomorrow morning" (9:00), "next Tuesday at 3" (15:00 unless "am"), "8pm", "20:00", "this evening".
// The Time helper uses it twice: for its quick commands (no model, works offline) and to check the model's
// ISO times against the person's own words. NSDataDetector is a second opinion when these rules find nothing.
// Pure Foundation, so the self-test runs on a Mac.

struct SpokenTime: Equatable, Sendable {
    enum Repeat: String, Sendable { case none, daily, weekly }
    /// How to read a bare hour like "at 7": alarms lean to the morning, everything else to the waking day
    /// (1–6 is afternoon, 7–11 is morning, or this evening when the morning has gone).
    enum Prefer: Sendable { case general, alarm }
    enum Period: Sendable { case morning, afternoon, evening, night }

    /// The moment the words mean (the next one, when no day was said).
    var date: Date
    var hour: Int
    var minute: Int
    /// A clock time was said ("7", "half past 8", "20:00", "noon"), not just "tomorrow morning".
    var clockSaid = false
    /// No doubt about morning or afternoon: am/pm, a part of the day, 24-hour, noon or midnight.
    var halfDaySaid = false
    /// A day was said: today, tonight, tomorrow, Tuesday, 1 November.
    var daySaid = false
    /// "in 20 minutes": seconds from now.
    var relative: TimeInterval?
    var repeats: Repeat = .none
    /// How many clock times the words hold. More than one: don't correct the model with any of them.
    var clockCount = 0
    /// The words that were not about time, in the person's spelling (for reminder titles).
    var leftover: [String] = []
}

// MARK: - Words

extension SpokenTime {
    struct Token: Equatable, Sendable {
        var raw: String  // as typed, punctuation trimmed
        var w: String    // lowercased, apostrophes removed, "a.m." → "am", "8.30" → "8:30"
    }

    static func tokens(_ text: String) -> [Token] {
        var s = text.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
        let rules: [(String, String)] = [
            (#"(\d)\s*([ap])\.?\s?m\.?(?![a-z])"#, "$1 $2m"),                       // 8pm, 6:30a.m. → 8 pm
            (#"(\d)(mins?|minutes?|hrs?|hours?|secs?|seconds?)\b"#, "$1 $2"),       // 20mins → 20 mins
            (#"([a-z])-([a-z])"#, "$1 $2"),                                          // twenty-five → twenty five
            (#"(\d)-([a-z])"#, "$1 $2"),                                             // 20-minute → 20 minute
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
        }
        let edge = CharacterSet(charactersIn: ".!?\"()[]{}:;,…")
        var out: [Token] = []
        for piece in s.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" }) {
            let raw = String(piece).trimmingCharacters(in: edge)
            guard !raw.isEmpty else { continue }
            var w = raw.lowercased().replacingOccurrences(of: "'", with: "")
            if w == "a.m" || w == "a.m." { w = "am" }
            if w == "p.m" || w == "p.m." { w = "pm" }
            if w.range(of: #"^\d{1,2}\.\d{2}$"#, options: .regularExpression) != nil {
                w = w.replacingOccurrences(of: ".", with: ":")
            }
            guard !w.isEmpty, w != "-" else { continue }
            out.append(Token(raw: raw, w: w))
        }
        return out
    }

    static let smallNumbers: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
        "eighteen": 18, "nineteen": 19,
    ]
    static let tensNumbers: [String: Int] = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50]
    static let ordinalWords: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9,
        "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15,
        "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19, "twentieth": 20, "thirtieth": 30,
    ]
    static let months: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3, "april": 4, "apr": 4, "may": 5,
        "june": 6, "jun": 6, "july": 7, "jul": 7, "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9,
        "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12,
    ]
    /// Calendar weekday numbers (1 = Sunday), singular and plural ("every Monday", "on Mondays").
    static let weekdays: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "tues": 3, "wednesday": 4, "weds": 4, "thursday": 5, "thurs": 5,
        "friday": 6, "saturday": 7, "sundays": 1, "mondays": 2, "tuesdays": 3, "wednesdays": 4, "thursdays": 5,
        "fridays": 6, "saturdays": 7,
    ]
    static let periodWords: [String: Period] = ["morning": .morning, "afternoon": .afternoon, "evening": .evening,
                                                "night": .night]
    static let units: Set<String> = [
        "minute", "minutes", "min", "mins", "hour", "hours", "hr", "hrs", "second", "seconds", "sec", "secs", "day",
        "days", "week", "weeks", "month", "months", "year", "years", "pound", "pounds", "quid", "p", "pence",
        "percent", "times", "pill", "pills", "tablet", "tablets", "people", "mile", "miles", "km", "kilos", "kg",
        "grams", "litres", "pints", "cups", "spoons", "slices",
    ]
    /// Words before a number that make it a time ("at 8", "by 5", "around 7", "from 3").
    static let timePrepositions: Set<String> = ["at", "by", "around", "about", "from"]
    /// Words before a number that make it a quantity ("take 2 tonight" is two tablets, not 2 a.m.).
    static let quantityWords: Set<String> = ["take", "takes", "taking", "buy", "get", "have", "eat", "drink", "need",
                                             "bring", "order", "pick", "with", "of", "give", "only", "just"]
    /// Words that can sit around a bare answer like "10" or "make it half 8".
    static let fillers: Set<String> = ["at", "about", "around", "for", "please", "ok", "okay", "make", "it", "say", "um",
                                       "er", "erm", "lets", "shall", "we", "just", "yes", "yeah", "actually",
                                       "sorry", "then", "maybe", "perhaps", "kairos", "thanks", "thank", "you"]
    /// Words that belong to the time phrase that follows them ("at 8", "on Tuesday", "every night").
    static let absorbed: Set<String> = ["at", "on", "for", "by", "in", "this", "next", "the", "every", "each", "around",
                                        "about", "of", "from", "coming", "starting"]

    /// A whole number at i: digits ("20") or words ("twenty five"). The value and how many tokens it used.
    static func number(_ t: [Token], _ i: Int) -> (Int, Int)? {
        guard i >= 0, i < t.count else { return nil }
        let w = t[i].w
        if !w.isEmpty, w.count <= 4, w.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(w) { return (n, 1) }
        if let n = smallNumbers[w] { return (n, 1) }
        if let n = tensNumbers[w] {
            if i + 1 < t.count, let u = smallNumbers[t[i + 1].w], u < 10 { return (n + u, 2) }
            return (n, 1)
        }
        return nil
    }

    private static func isDigits(_ w: String) -> Bool { !w.isEmpty && w.allSatisfy { $0.isASCII && $0.isNumber } }

    /// "1st", "third", "twenty first" → day of the month.
    static func ordinal(_ t: [Token], _ i: Int) -> (Int, Int)? {
        guard i >= 0, i < t.count else { return nil }
        let w = t[i].w
        if w.range(of: #"^\d{1,2}(st|nd|rd|th)$"#, options: .regularExpression) != nil,
           let n = Int(w.prefix(while: { $0.isNumber })), (1...31).contains(n) { return (n, 1) }
        if let n = ordinalWords[w] { return (n, 1) }
        if let tens = tensNumbers[w], tens <= 30, i + 1 < t.count, let u = ordinalWords[t[i + 1].w], u < 10 {
            return (tens + u, 2)
        }
        return nil
    }

    /// An ordinal, or plain digits 1–31, as a day of the month.
    static func dayOfMonth(_ t: [Token], _ i: Int) -> (Int, Int)? {
        if let o = ordinal(t, i) { return o }
        guard i >= 0, i < t.count, isDigits(t[i].w), t[i].w.count <= 2, let n = Int(t[i].w), (1...31).contains(n) else { return nil }
        return (n, 1)
    }

    /// Seconds in one unit word.
    static func unitSeconds(_ w: String) -> Double? {
        switch w {
        case "second", "seconds", "sec", "secs": return 1
        case "minute", "minutes", "min", "mins": return 60
        case "hour", "hours", "hr", "hrs": return 3600
        default: return nil
        }
    }

    /// A length of time at i: "20 minutes", "an hour and a half", "half an hour", "1 hour 30 minutes",
    /// "two and a half hours", "a quarter of an hour", "90 mins". Seconds and tokens used.
    static func durationAt(_ t: [Token], _ i: Int) -> (TimeInterval, Int)? {
        let n = t.count
        func w(_ k: Int) -> String { k >= 0 && k < n ? t[k].w : "" }
        guard i >= 0, i < n else { return nil }
        if w(i) == "half", w(i + 1) == "an" || w(i + 1) == "a", let u = unitSeconds(w(i + 2)) { return (u / 2, 3) }
        if w(i) == "a", w(i + 1) == "quarter", w(i + 2) == "of", w(i + 3) == "an", w(i + 4) == "hour" { return (900, 5) }
        if w(i) == "quarter", w(i + 1) == "of", w(i + 2) == "an", w(i + 3) == "hour" { return (900, 4) }
        if w(i) == "a", w(i + 1) == "couple", w(i + 2) == "of", let u = unitSeconds(w(i + 3)) { return (2 * u, 4) }

        var count: Double
        var j = i
        if w(i) == "a" || w(i) == "an" { count = 1; j += 1 }
        else if w(i).range(of: #"^\d+(\.\d+)?$"#, options: .regularExpression) != nil, let d = Double(w(i)) { count = d; j += 1 }
        else if let (v, l) = number(t, i) { count = Double(v); j += l }
        else { return nil }

        var half = false
        if w(j) == "and", w(j + 1) == "a", w(j + 2) == "half" { half = true; j += 3 }
        guard let unit = unitSeconds(w(j)) else { return nil }
        var total = (count + (half ? 0.5 : 0)) * unit
        j += 1
        if !half, w(j) == "and", w(j + 1) == "a", w(j + 2) == "half" {
            total += unit / 2
            j += 3
        } else if unit > 1 {
            var k = j
            if w(k) == "and" { k += 1 }
            if let (v, l) = number(t, k), let u2 = unitSeconds(w(k + l)), u2 < unit {
                total += Double(v) * u2
                j = k + l + 1
            }
        }
        return (total, j - i)
    }

    /// Every length of time in the words, in order, with where it sits.
    static func durationMatches(_ t: [Token]) -> [(seconds: TimeInterval, start: Int, length: Int)] {
        var out: [(seconds: TimeInterval, start: Int, length: Int)] = []
        var i = 0
        while i < t.count {
            if let (s, l) = durationAt(t, i) { out.append((s, i, l)); i += l } else { i += 1 }
        }
        return out
    }

    static func durations(in text: String) -> [TimeInterval] { durationMatches(tokens(text)).map { $0.seconds } }
}

// MARK: - Parsing

extension SpokenTime {
    private struct ClockHit {
        var raw: Int           // 0–23 as said ("quarter to 7" → 6)
        var spoken: Int        // the hour word the person used ("quarter to 7" → 7), for guessing am or pm
        var minute: Int
        var ampm: Character?   // "a" or "p"
        var twentyFour = false
        var noon = false
        var midnight = false
        var period: Period?
        var start: Int
        var end: Int
    }

    /// Reads the time in the words, or nil when they say nothing about when.
    static func parse(_ text: String, now: Date, calendar cal: Calendar, prefer: Prefer = .general) -> SpokenTime? {
        let t = tokens(text)
        let n = t.count
        func w(_ k: Int) -> String { k >= 0 && k < n ? t[k].w : "" }
        var used = [Bool](repeating: false, count: n)
        func mark(_ a: Int, _ len: Int) { for k in max(0, a)..<min(n, a + len) { used[k] = true } }
        func free(_ a: Int, _ len: Int) -> Bool { a >= 0 && a + len <= n && (a..<(a + len)).allSatisfy { !used[$0] } }

        let today = cal.startOfDay(for: now)
        let todayWeekday = cal.component(.weekday, from: now)
        func addDays(_ d: Int, _ date: Date) -> Date { cal.date(byAdding: .day, value: d, to: date) ?? date.addingTimeInterval(Double(d) * 86_400) }

        var repeats: Repeat = .none
        var repeatWeekday: Int?
        var repeatPeriod: Period?
        var dayPeriod: Period?
        var phrasePeriod: Period?
        var dayStart: Date?
        var weekdayRoll = false
        var relative: TimeInterval?

        // 1. Repeats: "every night", "each day", "daily", "every Tuesday".
        for i in 0..<n where !used[i] {
            let x = w(i)
            if x == "every" || x == "each" {
                let next = w(i + 1)
                if next == "single", w(i + 2) == "day" { repeats = .daily; mark(i, 3) }
                else if next == "day" { repeats = .daily; mark(i, 2) }
                else if let p = periodWords[next] { repeats = .daily; repeatPeriod = p; mark(i, 2) }
                else if next == "week" { repeats = .weekly; mark(i, 2) }
                else if let wd = weekdays[next] { repeats = .weekly; repeatWeekday = wd; mark(i, 2) }
            } else if x == "daily" { repeats = .daily; mark(i, 1) }
            else if x == "nightly" { repeats = .daily; repeatPeriod = .night; mark(i, 1) }
            else if x == "weekly" { repeats = .weekly; mark(i, 1) }
            else if x == "on", let wd = weekdays[w(i + 1)], w(i + 1).hasSuffix("s") { repeats = .weekly; repeatWeekday = wd; mark(i, 2) }
        }

        // 2. From now: "in 20 minutes", "in an hour and a half", "10 minutes from now".
        for i in 0..<n where !used[i] && relative == nil {
            if w(i) == "in", let (s, l) = durationAt(t, i + 1), free(i, l + 1) { relative = s; mark(i, l + 1) }
            else if let (s, l) = durationAt(t, i), w(i + l) == "from", w(i + l + 1) == "now", free(i, l + 2) {
                relative = s; mark(i, l + 2)
            }
        }

        // 3. Days: today, tonight, tomorrow, this evening, next Tuesday, 1st November, 3/11, 2026-11-01, in 3 days.
        func setDay(_ d: Date) { if dayStart == nil { dayStart = cal.startOfDay(for: d) } }
        func makeDate(year: Int?, month: Int, day: Int) -> Date? {
            var c = DateComponents(year: year ?? cal.component(.year, from: now), month: month, day: day, hour: 12)
            guard let d = cal.date(from: c), cal.component(.day, from: d) == day else { return nil }
            if year == nil, cal.startOfDay(for: d) < today {
                c.year = (c.year ?? 0) + 1
                return cal.date(from: c)
            }
            return d
        }
        func yearAt(_ k: Int) -> Int? {
            guard isDigits(w(k)), w(k).count == 4, let y = Int(w(k)), (2000...2100).contains(y) else { return nil }
            return y
        }
        var i = 0
        while i < n {
            if used[i] { i += 1; continue }
            let x = w(i)
            var len = 0
            if (x == "the" && w(i + 1) == "day" && w(i + 2) == "after" && w(i + 3) == "tomorrow") {
                setDay(addDays(2, today)); len = 4
            } else if x == "day", w(i + 1) == "after", w(i + 2) == "tomorrow" {
                setDay(addDays(2, today)); len = 3
            } else if x == "today" {
                setDay(today); len = 1
            } else if x == "tonight" {
                setDay(today); dayPeriod = dayPeriod ?? .night; len = 1
            } else if x == "tomorrow" {
                setDay(addDays(1, today)); len = 1
                if let p = periodWords[w(i + 1)] { dayPeriod = dayPeriod ?? p; len = 2 }
            } else if x == "this", let p = periodWords[w(i + 1)] {
                setDay(today); dayPeriod = dayPeriod ?? p; len = 2
            } else if let wd = weekdays[x] ?? ((x == "next" || x == "this" || x == "coming" || x == "on") ? weekdays[w(i + 1)] : nil) {
                let prefixed = weekdays[x] == nil  // "next Tuesday", "on Tuesday"
                var delta = (wd - todayWeekday + 7) % 7
                if prefixed && x == "next" && delta == 0 { delta = 7 }
                if delta == 0 && !(prefixed && x == "next") { weekdayRoll = true }
                setDay(addDays(delta, today))
                len = prefixed ? 2 : 1
                if let p = periodWords[w(i + len)] { dayPeriod = dayPeriod ?? p; len += 1 }
            } else if x == "in", let (v, l) = number(t, i + 1), w(i + 1 + l) == "days" || w(i + 1 + l) == "day" {
                setDay(addDays(v, today)); len = l + 2
            } else if x == "in", w(i + 1) == "a", w(i + 2) == "week" {
                setDay(addDays(7, today)); len = 3
            } else if x == "in", w(i + 1) == "a", w(i + 2) == "fortnight" {
                setDay(addDays(14, today)); len = 3
            } else if let (d, l) = dayOfMonth(t, i) {
                // 1st November, 1 Nov, the 1st of November 2026
                var k = i + l
                if w(k) == "of" { k += 1 }
                if let m = months[w(k)], let date = makeDate(year: yearAt(k + 1), month: m, day: d) {
                    setDay(date); len = k + 1 - i + (yearAt(k + 1) != nil ? 1 : 0)
                } else if w(i - 1) == "the", ordinal(t, i) != nil {
                    // "on the 3rd": this month, or next month when the 3rd has gone
                    let c = cal.dateComponents([.year, .month], from: now)
                    if let date = makeDate(year: c.year, month: c.month ?? 1, day: d), cal.startOfDay(for: date) >= today {
                        setDay(date); len = l
                    } else if let next = cal.date(byAdding: .month, value: 1, to: today) {
                        let nc = cal.dateComponents([.year, .month], from: next)
                        if let date = makeDate(year: nc.year, month: nc.month ?? 1, day: d) { setDay(date); len = l }
                    }
                }
            } else if let m = months[x], x != "may" || dayOfMonth(t, i + 1) != nil || dayOfMonth(t, i + 2) != nil {
                // November 1st, Nov the 1st
                var k = i + 1
                if w(k) == "the" { k += 1 }
                if let (d, l) = dayOfMonth(t, k), let date = makeDate(year: yearAt(k + l), month: m, day: d) {
                    setDay(date); len = k + l - i + (yearAt(k + l) != nil ? 1 : 0)
                }
            } else if let r = x.range(of: #"^(\d{1,2})/(\d{1,2})(/(\d{2}|\d{4}))?$"#, options: .regularExpression), r.lowerBound == x.startIndex {
                // UK order: 3/11 is 3 November
                let parts = x.split(separator: "/").compactMap { Int($0) }
                if parts.count >= 2 {
                    let y: Int? = parts.count == 3 ? (parts[2] < 100 ? 2000 + parts[2] : parts[2]) : nil
                    if let date = makeDate(year: y, month: parts[1], day: parts[0]) { setDay(date); len = 1 }
                }
            } else if x.range(of: #"^\d{4}-\d{1,2}-\d{1,2}$"#, options: .regularExpression) != nil {
                let parts = x.split(separator: "-").compactMap { Int($0) }
                if parts.count == 3, let date = makeDate(year: parts[0], month: parts[1], day: parts[2]) { setDay(date); len = 1 }
            }
            if len > 0 { mark(i, len); i += len } else { i += 1 }
        }

        // 4. Parts of the day said on their own: "in the morning", "at night".
        for i in 0..<n where !used[i] {
            if w(i) == "in", w(i + 1) == "the", let p = periodWords[w(i + 2)], free(i, 3) { phrasePeriod = phrasePeriod ?? p; mark(i, 3) }
            else if w(i) == "at", w(i + 1) == "night", free(i, 2) { phrasePeriod = phrasePeriod ?? .night; mark(i, 2) }
        }

        // 5. Clock times.
        var hits: [ClockHit] = []
        i = 0
        while i < n {
            if !used[i], let hit = clockAt(t, i, prefer: prefer, bare: false), free(hit.start, hit.end - hit.start) {
                hits.append(hit); mark(hit.start, hit.end - hit.start); i = hit.end
            } else { i += 1 }
        }
        if hits.isEmpty, relative == nil {
            // A bare answer: "10", "half 8", "make it ten thirty".
            let core = (0..<n).filter { !used[$0] && !fillers.contains(w($0)) }
            if let first = core.first, let last = core.last, last - first + 1 == core.count,
               let hit = clockAt(t, first, prefer: prefer, bare: true), hit.end == last + 1 {
                hits.append(hit); mark(hit.start, hit.end - hit.start)
            }
        }

        // Nothing about time at all: let NSDataDetector have a look.
        if hits.isEmpty && dayStart == nil && relative == nil && repeats == .none && phrasePeriod == nil && dayPeriod == nil {
            return detected(in: text, now: now, calendar: cal)
        }

        // The words that were not about time: drop "at", "on", "every" that led into a time phrase.
        var k = n - 1
        while k >= 0 {
            if !used[k], absorbed.contains(w(k)), k + 1 < n, used[k + 1] { used[k] = true }
            k -= 1
        }
        let leftover = (0..<n).filter { !used[$0] }.map { t[$0].raw }

        if let rel = relative {
            let d = now.addingTimeInterval(rel)
            var r = SpokenTime(date: d, hour: cal.component(.hour, from: d), minute: cal.component(.minute, from: d))
            r.relative = rel
            r.repeats = repeats
            r.clockCount = hits.count
            r.leftover = leftover
            return r
        }

        let period = hits.first?.period ?? phrasePeriod ?? dayPeriod ?? repeatPeriod
        var h = 9, m = 0, halfSaid = false, extraDay = 0
        if let c = hits.first {
            m = c.minute
            if c.noon { h = 12; halfSaid = true }
            else if c.midnight { h = 0; halfSaid = true; extraDay = 1 }
            else if let ap = c.ampm { h = c.raw % 12 + (ap == "p" ? 12 : 0); halfSaid = true }
            else if c.twentyFour || c.raw >= 13 || c.raw == 0 { h = c.raw; halfSaid = true }
            else if let p = period {
                halfSaid = true
                switch p {
                case .morning: h = c.raw % 12
                case .afternoon, .evening: h = c.raw % 12 + 12
                case .night:
                    if c.spoken == 12 && c.raw == 12 { h = 0; extraDay = 1 }
                    else if c.spoken <= 4 { h = c.raw % 12; extraDay = 1 }
                    else { h = c.raw % 12 + 12 }
                }
            } else if c.spoken == 12 {
                h = c.raw  // "12" is midday, "quarter to 12" is 11:45
            } else {
                let afternoon = prefer == .alarm ? !(5...11).contains(c.spoken) : (1...6).contains(c.spoken)
                h = c.raw % 12 + (afternoon ? 12 : 0)
            }
        } else {
            switch period {
            case .morning?, nil: h = 9
            case .afternoon?: h = 14
            case .evening?: h = 18
            case .night?: h = 20
            }
        }

        var daySaid = dayStart != nil
        var base = dayStart ?? today
        if dayStart == nil, repeats == .weekly, let wd = repeatWeekday {
            base = addDays((wd - todayWeekday + 7) % 7, today)
            daySaid = true
            weekdayRoll = true
        }
        func at(_ hour: Int) -> Date { cal.date(bySettingHour: hour, minute: m, second: 0, of: addDays(extraDay, base)) ?? base }
        var date = at(h)
        if date <= now {
            if !daySaid {
                if !hits.isEmpty, !halfSaid, prefer == .general, repeats == .none, h < 12, at(h + 12) > now {
                    h += 12
                    date = at(h)  // "at 8" said after 8 in the morning means this evening
                } else {
                    date = addDays(repeats == .weekly ? 7 : 1, date)
                }
            } else if weekdayRoll || repeats != .none {
                date = addDays(repeats == .daily ? 1 : 7, date)
            }
        }

        var r = SpokenTime(date: date, hour: cal.component(.hour, from: date), minute: cal.component(.minute, from: date))
        r.clockSaid = !hits.isEmpty
        r.halfDaySaid = halfSaid
        r.daySaid = daySaid
        r.repeats = repeats
        r.clockCount = hits.count
        r.leftover = leftover
        return r
    }

    /// One clock time starting at token i, or nil.
    private static func clockAt(_ t: [Token], _ i: Int, prefer: Prefer, bare: Bool) -> ClockHit? {
        let n = t.count
        func w(_ k: Int) -> String { k >= 0 && k < n ? t[k].w : "" }
        let x = w(i)

        /// "tonight", "tomorrow", "this evening", "in the morning", "at night", "morning" right after a number.
        func periodAfter(_ k: Int) -> (found: Bool, period: Period?) {
            switch w(k) {
            case "tonight": return (true, .night)
            case "today", "tomorrow": return (true, periodWords[w(k + 1)])
            case "this": if let p = periodWords[w(k + 1)] { return (true, p) }
            case "in": if w(k + 1) == "the", let p = periodWords[w(k + 2)] { return (true, p) }
            case "at": if w(k + 1) == "night" { return (true, .night) }
            default: if let p = periodWords[w(k)] { return (true, p) }
            }
            return (false, nil)
        }
        func plausible(_ spoken: Int, _ p: Period?) -> Bool {
            switch p {
            case .night?, .evening?: return (5...12).contains(spoken) || spoken >= 17
            case .afternoon?: return spoken == 12 || (1...6).contains(spoken) || (12...18).contains(spoken)
            default: return true
            }
        }
        func hourAt(_ k: Int) -> (value: Int, length: Int, noon: Bool, midnight: Bool)? {
            if w(k) == "noon" || w(k) == "midday" { return (12, 1, true, false) }
            if w(k) == "midnight" { return (0, 1, false, true) }
            guard let (v, l) = number(t, k) else { return nil }
            if isDigits(w(k)) { return w(k).count <= 2 && (0...23).contains(v) ? (v, l, false, false) : nil }
            return (1...12).contains(v) ? (v, l, false, false) : nil
        }
        /// am/pm and "o'clock" after the time; a bare "morning" too.
        func finish(_ hit: ClockHit) -> ClockHit {
            var h = hit
            if !h.noon && !h.midnight {
                if h.ampm == nil, w(h.end) == "am" || w(h.end) == "pm" { h.ampm = w(h.end).first; h.end += 1 }
                if w(h.end) == "oclock" { h.end += 1 } else if w(h.end) == "o", w(h.end + 1) == "clock" { h.end += 2 }
                if h.ampm == nil, w(h.end) == "am" || w(h.end) == "pm" { h.ampm = w(h.end).first; h.end += 1 }
            }
            if let p = periodWords[w(h.end)] { h.period = p; h.end += 1 }
            return h
        }

        // noon, midday, midnight ("12 noon" is taken with the number below)
        if x == "noon" || x == "midday" { return finish(ClockHit(raw: 12, spoken: 12, minute: 0, noon: true, start: i, end: i + 1)) }
        if x == "midnight" { return finish(ClockHit(raw: 0, spoken: 12, minute: 0, midnight: true, start: i, end: i + 1)) }

        // half past 8, quarter to 3, 20 past 4, 10 minutes to 6
        var mins: Int?
        var len = 0
        if x == "half" { mins = 30; len = 1 }
        else if x == "quarter" { mins = 15; len = 1 }
        else if x == "a", w(i + 1) == "quarter" { mins = 15; len = 2 }
        else if let (v, l) = number(t, i), (1...29).contains(v) {
            if ["minute", "minutes", "min", "mins"].contains(w(i + l)) { mins = v; len = l + 1 }
            else if [5, 10, 20, 25].contains(v) { mins = v; len = l }
        }
        if let m0 = mins, w(i + len) == "past" || w(i + len) == "to" {
            let isTo = w(i + len) == "to"
            if !(isTo && (m0 == 30 || w(i - 1) == "from" || w(i - 1) == "between")), let hr = hourAt(i + len + 1) {
                var raw = hr.value
                var minute = m0
                if isTo {
                    minute = 60 - m0
                    raw = hr.midnight ? 23 : (hr.value == 1 ? 12 : (hr.value == 0 ? 23 : hr.value - 1))
                }
                var hit = ClockHit(raw: raw, spoken: hr.midnight ? 12 : hr.value, minute: minute, start: i, end: i + len + 1 + hr.length)
                hit.twentyFour = hr.value >= 13 || hr.midnight || (hr.value == 0)
                if hr.noon { hit.ampm = "p" }
                return finish(hit)
            }
        }

        // half 8 (British for 8:30)
        if x == "half", w(i + 1) != "an", w(i + 1) != "a", w(i + 1) != "past", let (hr, hl) = number(t, i + 1), (1...12).contains(hr),
           !units.contains(w(i + 1 + hl)) {
            let after = periodAfter(i + 1 + hl)
            if bare || timePrepositions.contains(w(i - 1)) || w(i - 1) == "for" || w(i + 1 + hl) == "am" || w(i + 1 + hl) == "pm" || after.found {
                return finish(ClockHit(raw: hr, spoken: hr, minute: 30, start: i, end: i + 1 + hl))
            }
        }

        // 6:30, 20:00, 08:15
        if let r = x.range(of: #"^(\d{1,2}):(\d{2})$"#, options: .regularExpression), r.lowerBound == x.startIndex {
            let parts = x.split(separator: ":").compactMap { Int($0) }
            if parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) {
                var hit = ClockHit(raw: parts[0], spoken: parts[0] % 12 == 0 ? 12 : parts[0] % 12, minute: parts[1], start: i, end: i + 1)
                hit.twentyFour = parts[0] >= 13 || parts[0] == 0 || x.hasPrefix("0")
                return finish(hit)
            }
        }

        // 8 pm, 7 30 pm, seven o'clock, at 8, at seven thirty, 8 tonight, 7 tomorrow morning
        guard let hr = hourAt(i), !hr.noon, !hr.midnight else { return nil }
        let start = i
        var end = i + hr.length
        let spoken = hr.value % 12 == 0 ? 12 : hr.value % 12
        func accepts(_ e: Int, hasMinute: Bool) -> Bool {
            let next = w(e)
            if next == "am" || next == "pm" || next == "oclock" || (next == "o" && w(e + 1) == "clock") { return true }
            if !hasMinute, hr.value == 12, next == "noon" || next == "midday" || next == "midnight" { return true }
            if units.contains(next) { return false }
            if bare { return true }
            if quantityWords.contains(w(start - 1)) { return false }
            if timePrepositions.contains(w(start - 1)) || (prefer == .alarm && w(start - 1) == "for") { return true }
            let after = periodAfter(e)
            return after.found && plausible(hr.value, after.period)
        }
        var minute = 0
        if let (mv, ml) = minuteAfterHour(t, end), accepts(end + ml, hasMinute: true) {
            minute = mv
            end += ml
        } else if !accepts(end, hasMinute: false) {
            return nil
        }
        var hit = ClockHit(raw: hr.value, spoken: spoken, minute: minute, start: start, end: end)
        hit.twentyFour = hr.value >= 13 || hr.value == 0 || (w(i).hasPrefix("0") && w(i).count == 2)
        if minute == 0, hr.value == 12, w(end) == "noon" || w(end) == "midday" { hit.noon = true; hit.end += 1 }
        else if minute == 0, hr.value == 12, w(end) == "midnight" { hit.midnight = true; hit.raw = 0; hit.end += 1 }
        return finish(hit)
    }

    /// The minutes after an hour: "30" in "7 30", "thirty" or "forty five" in "seven forty five", "oh five".
    private static func minuteAfterHour(_ t: [Token], _ i: Int) -> (Int, Int)? {
        guard i < t.count else { return nil }
        let w = t[i].w
        if w == "oh" || w == "o", let (u, l) = number(t, i + 1), l == 1, (1...9).contains(u), !isDigits(t[i + 1].w) { return (u, 2) }
        if w.count == 2, isDigits(w), let v = Int(w), (0...59).contains(v) { return (v, 1) }
        if !isDigits(w), let (v, l) = number(t, i), (10...59).contains(v) { return (v, l) }
        return nil
    }

    /// NSDataDetector's reading of the words, used only when the rules above found nothing. It always measures
    /// from the real clock, so it is skipped when `now` is not the real time (the self-test).
    private static func detected(in text: String, now: Date, calendar cal: Calendar) -> SpokenTime? {
        guard abs(now.timeIntervalSinceNow) < 600,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let ns = text as NSString
        guard let match = detector.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)),
              let found = match.date, found > now.addingTimeInterval(-60) else { return nil }
        let piece = ns.substring(with: match.range).lowercased()
        let hasClock = piece.contains(":") || piece.contains("noon")
            || piece.range(of: #"\d\s*(am|pm|a\.m|p\.m)"#, options: .regularExpression) != nil
        let date = hasClock ? found : (cal.date(bySettingHour: 9, minute: 0, second: 0, of: found) ?? found)
        var r = SpokenTime(date: date, hour: cal.component(.hour, from: date), minute: cal.component(.minute, from: date))
        r.clockSaid = hasClock
        r.halfDaySaid = hasClock
        r.daySaid = true
        r.clockCount = hasClock ? 1 : 0
        r.leftover = tokens(ns.replacingCharacters(in: match.range, with: " ")).map(\.raw)
        return r
    }
}

// MARK: - ISO strings from the model

extension SpokenTime {
    /// "2026-10-25T20:00:00+01:00", "2026-10-25T20:00", "2026-10-25 20:00" or "2026-10-25", read as that
    /// wall-clock time in the person's time zone. The offset is ignored on purpose: models get the wall time right
    /// far more often than the offset (25 Oct 2026 is the day the UK leaves BST, and a "+01:00" on "20:00" would
    /// otherwise move an evening reminder an hour).
    static func isoWallClock(_ s: String, calendar cal: Calendar) -> (date: Date, hasTime: Bool)? {
        let pattern = #"^\s*(\d{4})-(\d{1,2})-(\d{1,2})(?:[T ](\d{1,2}):(\d{2})(?::(\d{2}))?)?"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        func group(_ k: Int) -> Int? {
            guard let r = Range(m.range(at: k), in: s) else { return nil }
            return Int(s[r])
        }
        guard let y = group(1), let mo = group(2), let d = group(3) else { return nil }
        let hasTime = group(4) != nil
        var c = DateComponents(year: y, month: mo, day: d, hour: group(4) ?? 0, minute: group(5) ?? 0, second: 0)
        c.timeZone = cal.timeZone
        guard (1...12).contains(mo), (1...31).contains(d), (c.hour ?? 0) < 24, (c.minute ?? 0) < 60,
              let date = cal.date(from: c), cal.component(.day, from: date) == d else { return nil }
        return (date, hasTime)
    }

    private static func formatter(_ format: String, _ cal: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = cal.timeZone
        f.dateFormat = format
        return f
    }
    /// "2026-10-25T20:00:00+00:00"
    static func isoString(_ date: Date, calendar cal: Calendar) -> String { formatter("yyyy-MM-dd'T'HH:mm:ssxxx", cal).string(from: date) }
    /// "2026-10-25"
    static func dayString(_ date: Date, calendar cal: Calendar) -> String { formatter("yyyy-MM-dd", cal).string(from: date) }
    /// "20:00"
    static func hhmm(_ date: Date, calendar cal: Calendar) -> String { formatter("HH:mm", cal).string(from: date) }
}

// MARK: - Saying it back

extension SpokenTime {
    static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                             "October", "November", "December"]

    /// "7", "quarter past 7", "half past 3", "quarter to 8", "20 past 4", "10 to 6", "7:23".
    static func clockWords(hour h: Int, minute m: Int) -> String {
        func twelve(_ x: Int) -> Int { x % 12 == 0 ? 12 : x % 12 }
        switch m {
        case 0: return "\(twelve(h))"
        case 15: return "quarter past \(twelve(h))"
        case 30: return "half past \(twelve(h))"
        case 45: return "quarter to \(twelve(h + 1))"
        case let x where x % 5 == 0 && x < 30: return "\(x) past \(twelve(h))"
        case let x where x % 5 == 0: return "\(60 - x) to \(twelve(h + 1))"
        default: return String(format: "%d:%02d", twelve(h), m)
        }
    }

    private static func partOfDay(_ h: Int) -> String { h < 12 ? "morning" : h < 18 ? "afternoon" : h < 20 ? "evening" : "night" }

    private static func daysFromToday(_ date: Date, now: Date, calendar cal: Calendar) -> Int {
        cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 0
    }

    /// "27 October", with the year when it isn't this year.
    static func dayAndMonth(_ date: Date, now: Date, calendar cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        let base = "\(c.day ?? 1) \(monthNames[((c.month ?? 1) - 1 + 12) % 12])"
        return c.year == cal.component(.year, from: now) ? base : base + " \(c.year ?? 0)"
    }

    /// The day on its own: "today", "tomorrow (Monday)", "on Tuesday 27 October".
    static func dayPhrase(_ date: Date, now: Date, calendar cal: Calendar) -> String {
        let wd = weekdayNames[(cal.component(.weekday, from: date) + 6) % 7]
        switch daysFromToday(date, now: now, calendar: cal) {
        case 0: return "today"
        case 1: return "tomorrow (\(wd))"
        case -1: return "yesterday"
        default: return "on \(wd) \(dayAndMonth(date, now: now, calendar: cal))"
        }
    }

    /// The absolute read-back: "7 tomorrow morning (Monday)", "half past 3 this afternoon", "8 tonight",
    /// "3 on Tuesday afternoon (27 October)", "midday tomorrow (Monday)", "midnight tonight".
    static func spoken(_ date: Date, now: Date, calendar cal: Calendar) -> String {
        let h = cal.component(.hour, from: date), m = cal.component(.minute, from: date)
        let diff = daysFromToday(date, now: now, calendar: cal)
        let wd = weekdayNames[(cal.component(.weekday, from: date) + 6) % 7]
        let dm = dayAndMonth(date, now: now, calendar: cal)
        if h == 12 && m == 0 {
            switch diff {
            case 0: return "midday today"
            case 1: return "midday tomorrow (\(wd))"
            default: return "midday on \(wd) (\(dm))"
            }
        }
        if h == 0 && m == 0 {
            if diff == 1 { return "midnight tonight" }
            let before = cal.date(byAdding: .day, value: -1, to: date) ?? date
            let bwd = weekdayNames[(cal.component(.weekday, from: before) + 6) % 7]
            return "midnight on \(bwd) night (\(dayAndMonth(before, now: now, calendar: cal)))"
        }
        let clock = clockWords(hour: h, minute: m)
        let part = partOfDay(h)
        switch diff {
        case 0: return part == "night" ? "\(clock) tonight" : "\(clock) this \(part)"
        case 1: return "\(clock) tomorrow \(part) (\(wd))"
        case -1: return "\(clock) yesterday \(part)"
        default: return "\(clock) on \(wd) \(part) (\(dm))"
        }
    }

    /// For a list of the day: "3", "half past 10", "8 in the evening", "5 in the morning", "midday".
    static func shortClock(_ date: Date, calendar cal: Calendar) -> String {
        let h = cal.component(.hour, from: date), m = cal.component(.minute, from: date)
        if h == 12 && m == 0 { return "midday" }
        if h == 0 && m == 0 { return "midnight" }
        let clock = clockWords(hour: h, minute: m)
        if h < 7 { return clock + " in the morning" }
        if h >= 17 { return clock + " in the evening" }
        return clock
    }

    /// Repeating: "at 8 every night, starting tonight", "every Monday at 7 in the morning, starting tomorrow (Monday)".
    static func repeating(_ date: Date, _ rule: Repeat, now: Date, calendar cal: Calendar) -> String {
        let h = cal.component(.hour, from: date), m = cal.component(.minute, from: date)
        let clock = h == 12 && m == 0 ? "midday" : (h == 0 && m == 0 ? "midnight" : clockWords(hour: h, minute: m))
        let diff = daysFromToday(date, now: now, calendar: cal)
        let start: String
        switch diff {
        case 0: start = h >= 17 ? "tonight" : "today"
        default: start = dayPhrase(date, now: now, calendar: cal)
        }
        switch rule {
        case .weekly:
            let wd = weekdayNames[(cal.component(.weekday, from: date) + 6) % 7]
            let part = (h == 12 && m == 0) || (h == 0 && m == 0) ? "" : (h < 12 ? " in the morning" : h < 18 ? " in the afternoon" : " in the evening")
            return "every \(wd) at \(clock)\(part), starting \(start)"
        case .daily, .none:
            let noun = (h == 12 && m == 0) || (h == 0 && m == 0) ? "day" : partOfDay(h)
            return "at \(clock) every \(noun), starting \(start)"
        }
    }

    /// "10 minutes", "half an hour", "1 hour", "an hour and a half", "2 hours and 15 minutes", "30 seconds".
    static func durationWords(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return s == 1 ? "1 second" : "\(s) seconds" }
        let total = Int((seconds / 60).rounded())
        switch total {
        case 30: return "half an hour"
        case 60: return "1 hour"
        case 90: return "an hour and a half"
        case let x where x < 60: return x == 1 ? "1 minute" : "\(x) minutes"
        default:
            let h = total / 60, m = total % 60
            let hours = h == 1 ? "1 hour" : "\(h) hours"
            return m == 0 ? hours : hours + " and " + (m == 1 ? "1 minute" : "\(m) minutes")
        }
    }
}

// MARK: - Self-test

extension SpokenTime {
    /// Fixed cases with now = Sunday 25 October 2026, 09:00 in London (the day the clocks go back, so GMT).
    /// Returns one line per failure; an empty array means everything passed. Runs on macOS and iOS.
    static func selfTest() -> [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        cal.locale = Locale(identifier: "en_GB")
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 9))!
        func on(_ day: Int, _ h: Int, _ m: Int = 0, month: Int = 10) -> Date {
            cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: h, minute: m))!
        }
        var failures: [String] = []
        func show(_ d: Date) -> String { isoString(d, calendar: cal) }

        func expect(_ text: String, _ want: Date, prefer: Prefer = .general, clock: Bool? = nil, repeats: Repeat? = nil,
                    leftover: String? = nil) {
            guard let got = parse(text, now: now, calendar: cal, prefer: prefer) else {
                failures.append("\"\(text)\": found no time, wanted \(show(want))"); return
            }
            if got.date != want { failures.append("\"\(text)\": got \(show(got.date)), wanted \(show(want))") }
            if let clock, got.clockSaid != clock { failures.append("\"\(text)\": clockSaid \(got.clockSaid), wanted \(clock)") }
            if let repeats, got.repeats != repeats { failures.append("\"\(text)\": repeats \(got.repeats), wanted \(repeats)") }
            if let leftover, got.leftover.joined(separator: " ") != leftover {
                failures.append("\"\(text)\": leftover \"\(got.leftover.joined(separator: " "))\", wanted \"\(leftover)\"")
            }
        }
        func expectDuration(_ text: String, _ seconds: TimeInterval) {
            let got = durations(in: text)
            if got != [seconds] { failures.append("\"\(text)\": durations \(got), wanted [\(seconds)]") }
        }
        func expectSaid(_ got: String, _ want: String) { if got != want { failures.append("said \"\(got)\", wanted \"\(want)\"") } }

        expectDuration("set a timer for 10 minutes", 600)
        expectDuration("timer 20 minutes", 1200)
        expectDuration("an hour and a half", 5400)
        expectDuration("half an hour", 1800)
        expect("alarm at 7", on(26, 7), prefer: .alarm, clock: true)
        expect("wake me up at 6:30 tomorrow", on(26, 6, 30), prefer: .alarm, clock: true, leftover: "wake me up")
        expect("remind me to take my pills at 8 tonight", on(25, 20), clock: true, leftover: "remind me to take my pills")
        expect("remind me at 8 tonight to take my pills", on(25, 20), leftover: "remind me to take my pills")
        expect("remind me to take my pills every night", on(25, 20), clock: false, repeats: .daily)
        expect("half past eight in the morning", on(26, 8, 30))
        expect("quarter to 3", on(25, 14, 45))
        expect("quarter to 7", on(26, 6, 45), prefer: .alarm)
        expect("noon", on(25, 12))
        expect("midday tomorrow", on(26, 12))
        expect("in 20 minutes", on(25, 9, 20))
        expect("tomorrow morning", on(26, 9), clock: false)
        expect("next Tuesday at 3", on(27, 15))
        expect("next Tuesday at 3am", on(27, 3))
        expect("8pm", on(25, 20))
        expect("20:00", on(25, 20))
        expect("this evening", on(25, 18), clock: false)
        expect("at 8", on(25, 20))
        expect("remind me to ring the GP at nine tomorrow", on(26, 9), leftover: "remind me to ring the GP")
        expect("1st November at 10", on(1, 10, month: 11))
        expect("every Tuesday at 3", on(27, 15), repeats: .weekly)
        expect("half 8", on(26, 8, 30), prefer: .alarm)
        expect("8", on(26, 8), prefer: .alarm)
        if let r = parse("take 2 tonight", now: now, calendar: cal), r.clockSaid { failures.append("\"take 2 tonight\": read 2 as a time") }
        if let r = parse("put the dentist in from 10 to 12", now: now, calendar: cal), r.minute == 50 {
            failures.append("\"from 10 to 12\": read as 11:50")
        }
        if parse("text my son I'll be late", now: now, calendar: cal) != nil { failures.append("\"text my son I'll be late\": found a time") }

        expectSaid(spoken(on(26, 7), now: now, calendar: cal), "7 tomorrow morning (Monday)")
        expectSaid(spoken(on(25, 15, 30), now: now, calendar: cal), "half past 3 this afternoon")
        expectSaid(spoken(on(25, 20), now: now, calendar: cal), "8 tonight")
        expectSaid(spoken(on(27, 15), now: now, calendar: cal), "3 on Tuesday afternoon (27 October)")
        expectSaid(spoken(on(26, 0), now: now, calendar: cal), "midnight tonight")
        expectSaid(clockWords(hour: 23, minute: 45), "quarter to 12")
        expectSaid(repeating(on(25, 20), .daily, now: now, calendar: cal), "at 8 every night, starting tonight")
        expectSaid(durationWords(5400), "an hour and a half")
        if isoWallClock("2026-10-25T20:00:00+01:00", calendar: cal)?.date != on(25, 20) {
            failures.append("ISO with +01:00 was not read as 20:00 on the wall clock")
        }
        if isoWallClock("2026-11-31", calendar: cal) != nil { failures.append("ISO 31 November was accepted") }
        return failures
    }
}
