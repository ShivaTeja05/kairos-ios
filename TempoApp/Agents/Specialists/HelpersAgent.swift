import Foundation
#if canImport(UIKit)
import UIKit
import AVFoundation
#endif

// The everyday helper: directions (Apple Maps), the weather (free Open-Meteo: no key, no location permission),
// simple step-by-step help with the phone's settings, the person's own Shortcuts, the time and date, this iPhone's
// battery and its torch.
// Every answer is built here in plain words from real data; the model only picks the tool.

struct HelpersAgent: SpecialistAgent {
    let id = "helpers"
    let title = "Everyday helper"
    let icon = "sparkles"

    var instructions: String {
        var s = "Use get_directions when the person wants to go somewhere or asks the way (walking unless they mention "
            + "a car, driving, a bus or a train). Use get_weather for the weather, rain, cold or what to wear outside, today or "
            + "tomorrow; leave the place out to use their home town, but when they name a town or say they're going "
            + "somewhere (\"I'm going to Manchester, what's it like there?\") pass that place. Use phone_battery when they "
            + "ask how much battery this iPhone has left, and torch to turn this iPhone's torch on or off. "
            + "Use open_phone_setting when they ask how to change something on the phone (bigger writing, Wi-Fi, Bluetooth, "
            + "notifications) or what Kairos is allowed to use; it only explains kairos_settings, text_size, wifi, bluetooth "
            + "and notifications, with simple steps. When they ask you to find a setting and change it for them (Auto-Lock, "
            + "the screen going dark too soon), use operate_app with app Settings. Kairos can't control the heating, lights, "
            + "TV or other things in the home: say so kindly, with no tool, and say how they can do it themselves. "
            + "Use run_my_shortcut only when the person asks you to run one of their own Shortcuts by name. Use "
            + "what_time_and_date for the time, the day or the date here. For general questions (facts, spellings, meanings, "
            + "recipes) answer directly in a sentence or two, without tools."
        let allowed = HelpersSettings.allowedShortcuts
        if !allowed.isEmpty {
            s += " The only Shortcuts you may run are: " + allowed.map { "\"\($0)\"" }.joined(separator: ", ") + "."
        }
        return s
    }

    var tools: [any KairosTool] {
        // Order matters for the rules-first match: the most exact phrases first.
        [HelpersTimeTool(), HelpersBatteryTool(), HelpersTorchTool(), HelpersWeatherTool(), HelpersPhoneSettingTool(),
         HelpersDirectionsTool(), HelpersShortcutTool()]
    }
}

// MARK: - What the helper remembers on this phone

enum HelpersSettings {
    static let homePlaceKey = "kairos.helpers.home_place"
    static let shortcutsKey = "kairos.helpers.shortcuts"
    static let placeCacheKey = "kairos.helpers.place_cache"
    static let defaultHomePlace = "Oxford"

    /// The town used for the weather when the person doesn't name one. Kairos never asks for location permission.
    static var homePlace: String {
        get {
            let s = UserDefaults.standard.string(forKey: homePlaceKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return s.isEmpty ? defaultHomePlace : s
        }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: homePlaceKey) }
    }

    /// Optional list a helper (carer) sets: the only Shortcuts Kairos may run, spelled exactly as in the Shortcuts app.
    /// Empty means any Shortcut the person names out loud.
    static var allowedShortcuts: [String] {
        get {
            (UserDefaults.standard.stringArray(forKey: shortcutsKey) ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        set { UserDefaults.standard.set(newValue, forKey: shortcutsKey) }
    }
}

// MARK: - The time and date

struct HelpersTimeTool: KairosTool {
    let name = "what_time_and_date"
    let summary = "Tells the person the time, the day and the date, in plain words: here on this phone, or in another "
        + "city or country (place: 'Hyderabad', 'New York'). Use it for 'what time is it', 'what time is it in "
        + "Hyderabad', 'what day is it' or 'what's the date'."
    var parameters: JSONValue {
        Schema.object(["include_year": Schema.boolean("True when the person asked for the date or the year."),
                       "place": Schema.string("A city or country somewhere else, only when the person named one.")])
    }
    let risk = Risk.read

    func quickMatch(_ words: String, ctx: TurnContext) -> JSONValue? {
        // "What time is it in Hyderabad right now?": the clock somewhere else.
        if let place = WorldClock.askedPlace(words) { return ["place": .string(place), "include_year": false] }
        guard let ask = HelpersMatch.timeQuestion(words) else { return nil }
        return ["include_year": .bool(ask == .date)]
    }

    func describe(_ args: JSONValue, ctx: TurnContext) -> String {
        args.text("place").map { "The time in \($0)" } ?? "The time and date"
    }

    func execute(_ args: JSONValue, ctx: TurnContext) async throws -> ToolResult {
        var calendar = ctx.calendar
        var zone = ctx.timeZone
        var prefix = ""
        if let place = args.text("place") {
            guard let there = WorldClock.zone(for: place) else {
                return ToolResult(ok: true, say: "I don't know the time zone for \(place). Which country is it in?", isAnswer: true)
            }
            zone = there
            calendar.timeZone = there
            prefix = "In \(place.capitalized) "
        }
        var say = HelpersSpeech.timeAndDate(ctx.now, calendar: calendar, includeYear: args["include_year"]?.bool ?? false)
        // "It's 10 past 3, on Saturday…" -> "In Hyderabad it's 10 past 3, on Saturday…" (no clock-change note there).
        if !prefix.isEmpty {
            let body = say.hasPrefix("It's ") ? String(say.dropFirst(5)) : say
            let first = body.components(separatedBy: ". ").first ?? body
            say = prefix + "it's " + first + (first.hasSuffix(".") ? "" : ".")
        }
        let iso = ISO8601DateFormatter()
        iso.timeZone = zone
        return ToolResult(ok: true, say: say,
                          data: ["now": .string(iso.string(from: ctx.now)), "time_zone": .string(zone.identifier)],
                          isAnswer: HelpersSpeech.speaksEnglish(ctx))
    }
}

/// The time somewhere else: the cities and countries the people Kairos is for call most, then any city that names
/// an iOS time zone ("Karachi" -> Asia/Karachi). Countries with several zones (USA, Australia, Canada) need a city.
enum WorldClock {
    static let zones: [String: String] = [
        "india": "Asia/Kolkata", "hyderabad": "Asia/Kolkata", "secunderabad": "Asia/Kolkata", "mumbai": "Asia/Kolkata",
        "bombay": "Asia/Kolkata", "delhi": "Asia/Kolkata", "new delhi": "Asia/Kolkata", "chennai": "Asia/Kolkata",
        "madras": "Asia/Kolkata", "bangalore": "Asia/Kolkata", "bengaluru": "Asia/Kolkata", "kolkata": "Asia/Kolkata",
        "calcutta": "Asia/Kolkata", "pune": "Asia/Kolkata", "ahmedabad": "Asia/Kolkata", "vijayawada": "Asia/Kolkata",
        "visakhapatnam": "Asia/Kolkata", "vizag": "Asia/Kolkata", "warangal": "Asia/Kolkata", "guntur": "Asia/Kolkata",
        "tirupati": "Asia/Kolkata", "amritsar": "Asia/Kolkata", "chandigarh": "Asia/Kolkata", "kerala": "Asia/Kolkata",
        "goa": "Asia/Kolkata", "punjab": "Asia/Kolkata", "gujarat": "Asia/Kolkata", "andhra": "Asia/Kolkata",
        "telangana": "Asia/Kolkata", "tamil nadu": "Asia/Kolkata",
        "pakistan": "Asia/Karachi", "lahore": "Asia/Karachi", "islamabad": "Asia/Karachi", "karachi": "Asia/Karachi",
        "mirpur": "Asia/Karachi", "bangladesh": "Asia/Dhaka", "dhaka": "Asia/Dhaka", "sylhet": "Asia/Dhaka",
        "sri lanka": "Asia/Colombo", "colombo": "Asia/Colombo", "nepal": "Asia/Kathmandu",
        "poland": "Europe/Warsaw", "warsaw": "Europe/Warsaw", "krakow": "Europe/Warsaw", "wales": "Europe/London",
        "cardiff": "Europe/London", "scotland": "Europe/London", "edinburgh": "Europe/London", "uk": "Europe/London",
        "england": "Europe/London", "london": "Europe/London", "ireland": "Europe/Dublin", "dublin": "Europe/Dublin",
        "dubai": "Asia/Dubai", "abu dhabi": "Asia/Dubai", "uae": "Asia/Dubai", "qatar": "Asia/Qatar", "doha": "Asia/Qatar",
        "saudi": "Asia/Riyadh", "saudi arabia": "Asia/Riyadh", "riyadh": "Asia/Riyadh", "jeddah": "Asia/Riyadh",
        "singapore": "Asia/Singapore", "malaysia": "Asia/Kuala_Lumpur", "kuala lumpur": "Asia/Kuala_Lumpur",
        "hong kong": "Asia/Hong_Kong", "china": "Asia/Shanghai", "beijing": "Asia/Shanghai", "shanghai": "Asia/Shanghai",
        "japan": "Asia/Tokyo", "tokyo": "Asia/Tokyo", "philippines": "Asia/Manila", "manila": "Asia/Manila",
        "new york": "America/New_York", "boston": "America/New_York", "washington": "America/New_York",
        "new jersey": "America/New_York", "atlanta": "America/New_York", "chicago": "America/Chicago",
        "dallas": "America/Chicago", "houston": "America/Chicago", "texas": "America/Chicago", "denver": "America/Denver",
        "los angeles": "America/Los_Angeles", "san francisco": "America/Los_Angeles", "seattle": "America/Los_Angeles",
        "california": "America/Los_Angeles", "bay area": "America/Los_Angeles", "toronto": "America/Toronto",
        "vancouver": "America/Vancouver", "sydney": "Australia/Sydney", "melbourne": "Australia/Melbourne",
        "perth": "Australia/Perth", "brisbane": "Australia/Brisbane", "new zealand": "Pacific/Auckland",
        "auckland": "Pacific/Auckland", "nigeria": "Africa/Lagos", "lagos": "Africa/Lagos", "kenya": "Africa/Nairobi",
        "nairobi": "Africa/Nairobi", "south africa": "Africa/Johannesburg", "johannesburg": "Africa/Johannesburg",
        "egypt": "Africa/Cairo", "cairo": "Africa/Cairo", "germany": "Europe/Berlin", "berlin": "Europe/Berlin",
        "france": "Europe/Paris", "paris": "Europe/Paris", "spain": "Europe/Madrid", "madrid": "Europe/Madrid",
        "italy": "Europe/Rome", "rome": "Europe/Rome",
    ]

    static func zone(for place: String) -> TimeZone? {
        let key = place.folded.replacingOccurrences(of: #"^(the|in) "#, with: "", options: .regularExpression)
        if let id = zones[key], let z = TimeZone(identifier: id) { return z }
        let city = key.replacingOccurrences(of: " ", with: "_")
        let id = TimeZone.knownTimeZoneIdentifiers.first { $0.split(separator: "/").last?.lowercased() == city }
        return id.flatMap(TimeZone.init(identifier:))
    }

    /// "What time is it in Hyderabad (right now)?", "What's the time in New York?" -> the place, when it's a known one.
    static func askedPlace(_ words: String) -> String? {
        let f = words.folded
        guard f.range(of: #"\b(time|what day|date)\b"#, options: .regularExpression) != nil,
              let m = f.range(of: #"\b(?:in|over in|out in)\s+([a-z ]{2,30}?)(?:\s+(?:right now|now|today|at the moment|currently|just now))?$"#,
                              options: .regularExpression) else { return nil }
        let place = String(f[m]).replacingOccurrences(of: #"^(?:over in|out in|in)\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(?:right now|now|today|at the moment|currently|just now)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // "What time is it in the morning there" or "in an hour" are not places.
        guard !place.isEmpty, zone(for: place) != nil else { return nil }
        return place
    }
}

// MARK: - This iPhone's battery

/// "How much battery has my phone got left?": read from the iPhone itself, nothing changed.
struct HelpersBatteryTool: KairosTool {
    let name = "phone_battery"
    let summary = "Says how much battery this iPhone has left and whether it's charging. Only this iPhone: for the "
        + "person's Mac or laptop use ask_my_mac."
    var parameters: JSONValue { Schema.none }
    let risk = Risk.read

    func quickMatch(_ words: String, ctx: TurnContext) -> JSONValue? {
        HelpersMatch.batteryQuestion(words) ? .object([:]) : nil
    }

    func describe(_ args: JSONValue, ctx: TurnContext) -> String { "Check this iPhone's battery" }

    func execute(_ args: JSONValue, ctx: TurnContext) async throws -> ToolResult {
        let reading = await HelpersBattery.read()
        let english = HelpersSpeech.speaksEnglish(ctx)
        guard let percent = reading.percent else {
            return ToolResult(ok: false, say: HelpersBattery.whereToLook,
                              data: ["error": "The battery level isn't available on this phone right now.",
                                     "where_to_look": .string(HelpersBattery.whereToLook)],
                              isAnswer: english)
        }
        var say = "Your iPhone has \(percent) per cent battery left"
        if reading.full {
            say += ", it's fully charged."
        } else if reading.charging {
            say += ", and it's charging."
        } else {
            say += "."
            if percent <= 20 { say += " It's getting low, so it's a good idea to plug it in soon." }
        }
        return ToolResult(ok: true, say: say,
                          data: ["percent": .number(Double(percent)), "charging": .bool(reading.charging),
                                 "full": .bool(reading.full), "device": "this iPhone"],
                          isAnswer: english)
    }
}

enum HelpersBattery {
    struct Reading: Sendable { var percent: Int?; var charging: Bool; var full: Bool }

    static let whereToLook = "I can't read the battery just now. You can see it in the top right corner of the screen: "
        + "swipe down from there to see how much is left. Or open Settings, then tap Battery."

    @MainActor static func read() -> Reading {
        #if canImport(UIKit)
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true   // the level reads -1 until this is on
        let level = device.batteryLevel
        let state = device.batteryState
        let percent = level < 0 ? nil : Int((Double(level) * 100).rounded())
        return Reading(percent: percent, charging: state == .charging, full: state == .full)
        #else
        return Reading(percent: nil, charging: false, full: false)
        #endif
    }
}

// MARK: - The torch

/// "Put the torch on", "turn the torch off". Only while Kairos is open on the screen: iOS doesn't let an app in the
/// background use the camera's light.
struct HelpersTorchTool: KairosTool {
    let name = "torch"
    let summary = "Turns this iPhone's torch (flashlight) on or off. Only while Kairos is open on the screen."
    var parameters: JSONValue {
        Schema.object(["state": Schema.string("On or off.", oneOf: ["on", "off"])], required: ["state"])
    }
    let risk = Risk.localWrite

    func quickMatch(_ words: String, ctx: TurnContext) -> JSONValue? {
        guard let on = HelpersMatch.torchRequest(words) else { return nil }
        return ["state": .string(on ? "on" : "off")]
    }

    func describe(_ args: JSONValue, ctx: TurnContext) -> String {
        HelpersTorch.wantsOn(args) ? "Turn the torch on" : "Turn the torch off"
    }

    func execute(_ args: JSONValue, ctx: TurnContext) async throws -> ToolResult {
        let on = HelpersTorch.wantsOn(args)
        guard ctx.canShowUI else { return .fail(HelpersTorch.notOpen) }
        switch await HelpersTorch.set(on) {
        case .done:
            let say = on ? "I've turned the torch on. Say \"turn the torch off\" when you're done."
                         : "I've turned the torch off."
            return ToolResult(ok: true, say: say, data: ["torch": .string(on ? "on" : "off")])
        case .notOpen:
            return .fail(HelpersTorch.notOpen)
        case .noTorch:
            return .fail("This iPhone hasn't got a torch I can use. " + HelpersTorch.yourself)
        case .failed:
            return .fail("The torch didn't \(on ? "come on" : "go off") just now. " + HelpersTorch.yourself)
        }
    }
}

enum HelpersTorch {
    enum Outcome: Sendable { case done, notOpen, noTorch, failed }

    static let yourself = "Swipe down from the top right corner of the screen and tap the torch button, or ask Siri to "
        + "\"turn on the torch\"."
    static let notOpen = "I can only use the torch while Kairos is open on the screen. " + yourself

    static func wantsOn(_ args: JSONValue) -> Bool { args.text("state")?.folded != "off" }

    @MainActor static func set(_ on: Bool) -> Outcome {
        #if canImport(UIKit)
        guard UIApplication.shared.applicationState == .active else { return .notOpen }
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return .noTorch }
        guard !on || device.isTorchAvailable else { return .failed }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if on {
                try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            } else {
                device.torchMode = .off
            }
            return .done
        } catch {
            return .failed
        }
        #else
        return .noTorch
        #endif
    }
}

// MARK: - Directions

struct HelpersDirectionsTool: KairosTool {
    let name = "get_directions"
    let summary = "Opens Apple Maps with directions from where the person is now to a place: an address, a postcode, "
        + "a shop or a kind of place like 'the GP surgery'."
    var parameters: JSONValue {
        Schema.object([
            "destination": Schema.string("Where they want to go, e.g. 'the GP surgery', 'Tesco', 'OX1 2JD'."),
            "mode": Schema.string("How they are travelling. Walking unless they say otherwise.",
                                  oneOf: ["walking", "driving", "transit"]),
        ], required: ["destination"])
    }
    let risk = Risk.read

    func quickMatch(_ words: String, ctx: TurnContext) -> JSONValue? {
        let t = HelpersMatch.tokens(words)
        // "Directions to Boots and put my flu jab in for 3pm": two requests, so the model does both.
        guard (3...20).contains(t.count), !HelpersMatch.asksForOtherThings(t), !PlannerWords.severalRequests(words),
              let found = HelpersDirections.parse(words) else { return nil }
        return ["destination": .string(found.destination), "mode": .string(HelpersDirections.mode(from: found.rest))]
    }

    func validate(_ args: JSONValue, ctx: TurnContext) -> Validation {
        guard let dest = args.text("destination"), !dest.folded.isEmpty else { return .clarify("Where would you like to go?") }
        if dest.count > 200 { return .clarify("Where would you like to go? Just the name of the place is fine.") }
        return .ok
    }

    func describe(_ args: JSONValue, ctx: TurnContext) -> String {
        let dest = HelpersSpeech.yours(args.text("destination") ?? "your destination")
        return "\(HelpersDirections.kind(HelpersDirections.mode(args)).helpersCapitalizedFirst) to \(dest)"
    }

    func execute(_ args: JSONValue, ctx: TurnContext) async throws -> ToolResult {
        guard let dest = args.text("destination") else { return .fail("Where would you like to go?") }
        let mode = HelpersDirections.mode(args)
        let flag = mode == "driving" ? "d" : (mode == "transit" ? "r" : "w")
        let query = HelpersDirections.mapsQuery(dest)
        guard let url = URL(string: "https://maps.apple.com/?daddr=\(HelpersURL.encode(query))&dirflg=\(flag)") else {
            return .fail("Sorry, I couldn't open Maps for that place. Could you say it another way?")
        }
        let spoken = HelpersSpeech.yours(dest)
        let say = ctx.canShowUI
            ? "I've opened Maps with \(HelpersDirections.kind(mode)) to \(spoken). Tap Go when you're ready to set off."
            : "I can show you the way to \(spoken) on the map. Please open Kairos and ask me again."
        return ToolResult(ok: true, say: say,
                          data: ["destination": .string(dest), "mode": .string(mode), "opened": "Apple Maps"],
                          ui: .openURL(url), isAnswer: HelpersSpeech.speaksEnglish(ctx))
    }
}

enum HelpersDirections {
    static func mode(_ args: JSONValue) -> String {
        let m = args.text("mode")?.lowercased() ?? "walking"
        switch m {
        case "driving", "drive", "car": return "driving"
        case "transit", "bus", "train", "public transport": return "transit"
        default: return "walking"
        }
    }

    static func kind(_ mode: String) -> String {
        switch mode {
        case "driving": return "driving directions"
        case "transit": return "bus and train directions"
        default: return "walking directions"
        }
    }

    /// How they travel, from the words around the place (so "the bus station" stays a walk).
    static func mode(from rest: String) -> String {
        let t = Set(rest.folded.split(separator: " ").map(String.init))
        if !t.isDisjoint(with: ["drive", "driving", "car"]) { return "driving" }
        if !t.isDisjoint(with: ["bus", "train", "tube", "tram", "coach", "transport", "transit"]) { return "transit" }
        return "walking"
    }

    /// "my GP surgery" means nothing to Maps; "GP surgery" finds the nearest one.
    static func mapsQuery(_ dest: String) -> String {
        var q = dest.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["my nearest ", "the nearest ", "nearest ", "my local ", "my "] where q.lowercased().hasPrefix(prefix) {
            q = String(q.dropFirst(prefix.count))
            break
        }
        return q.isEmpty ? dest : q
    }

    private static let patterns: [String] = [
        #"^(?:(?:please|kairos|hey kairos|ok kairos)[ ,]+)?(?:can you |could you |will you |would you )?(?:please )?(?:give me |show me |get me |find me |find |i need |i want )?(?:the )?(?:walking |driving |bus |train )?(?:directions|the way|way|route)(?: to get)? to (.+)$"#,
        #"^(?:(?:please|kairos|hey kairos|ok kairos)[ ,]+)?(?:how do i|how can i|how would i|how should i|how do we|how can we) (?:get|walk|drive|go|travel) to (.+)$"#,
    ]
    private static let tails = [" please", " from here", " by car", " in the car", " by bus", " on the bus", " by train",
                                " on the train", " on foot", " walking", " driving", " by public transport",
                                " on public transport", " by transit", " for me", " right now", " now"]
    private static let notPlaces: Set<String> = ["sleep", "bed", "the end", "the next", "the top", "the bottom", "the point",
                                                 "it", "this", "that", "them", "him", "her", "there", "know", "level"]
    private static let phoneWords: Set<String> = ["settings", "setting", "wifi", "bluetooth", "screen", "menu", "app", "apps",
                                                  "page", "website", "email", "photos", "camera", "kairos", "shortcut"]

    /// "Directions to the GP surgery", "how do I get to Tesco by bus" → the place, and the words around it.
    static func parse(_ words: String) -> (destination: String, rest: String)? {
        let s = words.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".?!")))
        for pattern in patterns {
            guard let captured = HelpersMatch.capture(pattern, in: s) else { continue }
            var dest = captured
            var rest = String(s.dropLast(captured.count))
            var trimmed = true
            while trimmed {
                trimmed = false
                for tail in tails where dest.lowercased().hasSuffix(tail) {
                    dest = String(dest.dropLast(tail.count))
                    rest += tail
                    trimmed = true
                }
            }
            dest = dest.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.?!")))
            let f = dest.folded
            let t = f.split(separator: " ").map(String.init)
            guard !t.isEmpty, t.count <= 10, !notPlaces.contains(f), phoneWords.isDisjoint(with: t) else { return nil }
            return (dest, rest)
        }
        return nil
    }
}

// MARK: - The weather (Open-Meteo, free, no key)

struct HelpersWeatherTool: KairosTool {
    let name = "get_weather"
    let summary = "Gets the weather forecast for today or tomorrow and says it in plain words, with advice like taking a "
        + "coat. Leave place out to use the person's home town."
    var parameters: JSONValue {
        Schema.object([
            "place": Schema.string("A town or city, e.g. 'Manchester' or 'Paris, France'. Leave out for the person's home town."),
            "day": Schema.string("Which day. Today unless they say tomorrow.", oneOf: ["today", "tomorrow"]),
        ])
    }
    let risk = Risk.read

    func quickMatch(_ words: String, ctx: TurnContext) -> JSONValue? {
        let t = HelpersMatch.tokens(words)
        // "What's the weather tomorrow and how do I get to Bicester Village": two requests, so the model does both.
        guard (1...16).contains(t.count), !HelpersMatch.asksForOtherThings(t), !PlannerWords.severalRequests(words) else {
            return nil
        }
        let f = " " + t.joined(separator: " ") + " "
        let asks = t.contains("weather") || t.contains("forecast") || [
            " will it rain ", " is it going to rain ", " going to rain ", " is it raining ", " will it snow ",
            " is it going to snow ", " do i need an umbrella ", " do i need a coat ", " should i take a coat ",
            " should i take an umbrella ", " how cold is it ", " how warm is it ", " how hot is it ",
            " what s it like outside ", " what is it like outside ",
        ].contains(where: { f.contains($0) })
        guard asks else { return nil }
        // Only today and tomorrow here; other days go to the model, which can say so kindly.
        let otherDays: Set<String> = ["weekend", "week", "monday", "tuesday", "wednesday", "thursday", "friday",
                                      "saturday", "sunday", "yesterday", "month", "days"]
        guard otherDays.isDisjoint(with: t) else { return nil }
        var args: [String: JSONValue] = ["day": .string(t.contains("tomorrow") ? "tomorrow" : "today")]
        if let place = HelpersMatch.weatherPlace(in: words) {
            args["place"] = .string(place)
        } else if HelpersMatch.pointsAtAnotherPlace(words) {
            // "I'm going to Manchester tomorrow, what's it like there?": a place the rule can't read. The model fills
            // it in, instead of the rule answering for the home town.
            return nil
        }
        return .object(args)
    }

    func validate(_ args: JSONValue, ctx: TurnContext) -> Validation {
        if let day = args.text("day")?.lowercased(), !["today", "tomorrow", "tonight"].contains(day) {
            return .clarify("I can tell you the weather for today or tomorrow. Which would you like?")
        }
        return .ok
    }

    func describe(_ args: JSONValue, ctx: TurnContext) -> String {
        let place = HelpersWeather.requestedPlace(args) ?? HelpersSettings.homePlace
        return "Weather \(HelpersWeather.day(args)) in \(place)"
    }

    func execute(_ args: JSONValue, ctx: TurnContext) async throws -> ToolResult {
        await HelpersWeather.report(place: HelpersWeather.requestedPlace(args), day: HelpersWeather.day(args), ctx: ctx)
    }
}

struct HelpersPlace: Sendable {
    var name: String
    var country: String
    var region: String
    var countryCode: String
    /// A bigger place abroad has the same name (Boston, Perth), so say which one we mean.
    var sharesName: Bool
    var latitude: Double
    var longitude: Double
    var timeZone: String

    /// How to say it: "Oxford", "Paris, France", "Perth, Scotland".
    func spoken(home: String) -> String {
        if !countryCode.isEmpty, countryCode != home, !country.isEmpty { return "\(name), \(country)" }
        if sharesName, !region.isEmpty { return "\(name), \(region)" }
        return name
    }
}

enum HelpersWeather {
    static func day(_ args: JSONValue) -> String { args.text("day")?.lowercased() == "tomorrow" ? "tomorrow" : "today" }

    /// The place the person named, or nil for their home town ("here", "home", "my area" count as home).
    static func requestedPlace(_ args: JSONValue) -> String? {
        guard let p = args.text("place") else { return nil }
        let f = p.folded
        let home: Set<String> = ["here", "home", "my home", "at home", "where i am", "my area", "current location",
                                 "my location", "local", "near me", "outside", "my town", "around here", "this area"]
        return f.isEmpty || home.contains(f) ? nil : String(p.prefix(80))
    }

    static func report(place requested: String?, day: String, ctx: TurnContext) async -> ToolResult {
        let timeout: TimeInterval = ctx.source == .siriBackground ? 6 : 12
        let query = requested ?? HelpersSettings.homePlace
        let place: HelpersPlace
        do {
            guard let found = try await locate(query, timeout: timeout) else {
                return .fail("I couldn't find a place called \(query). Could you tell me the nearest big town?")
            }
            place = found
        } catch {
            return .fail(problem(error))
        }

        let lat = String(format: "%.4f", place.latitude), lon = String(format: "%.4f", place.longitude)
        let link = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)"
            + "&daily=weathercode,temperature_2m_max,temperature_2m_min,precipitation_probability_max"
            + "&timezone=\(HelpersURL.encode(place.timeZone))&forecast_days=2"
        guard let url = URL(string: link) else { return .fail(problem(nil)) }
        let json: JSONValue
        do { json = try await fetchJSON(url, timeout: timeout) } catch { return .fail(problem(error)) }

        let index = day == "tomorrow" ? 1 : 0
        func value(_ key: String) -> JSONValue? {
            guard let a = json["daily"]?[key]?.array, a.count > index, a[index] != .null else { return nil }
            return a[index]
        }
        let code = (value("weathercode") ?? value("weather_code"))?.int
        let high = value("temperature_2m_max")?.double
        let low = value("temperature_2m_min")?.double
        let rain = value("precipitation_probability_max")?.int
        guard code != nil || high != nil else { return .fail(problem(nil)) }

        let spoken = place.spoken(home: homeCountry())
        let say = sentence(day: day, place: spoken, code: code, high: high.map { Int($0.rounded()) },
                           low: low.map { Int($0.rounded()) }, rainChance: rain)
        let data: JSONValue = [
            "place": .string(spoken),
            "day": .string(day),
            "date": value("time") ?? .null,
            "weather": code.map { .string(sky($0)) } ?? .null,
            "high_celsius": high.map { .number($0) } ?? .null,
            "low_celsius": low.map { .number($0) } ?? .null,
            "chance_of_rain_percent": rain.map { .number(Double($0)) } ?? .null,
            "source": "Open-Meteo",
        ]
        return ToolResult(ok: true, say: say, data: data, isAnswer: HelpersSpeech.speaksEnglish(ctx))
    }

    // MARK: Plain words

    static func sky(_ code: Int) -> String {
        switch code {
        case 0: return "sunny"
        case 1: return "mostly sunny"
        case 2: return "sunny spells"
        case 3: return "cloudy"
        case 45, 48: return "foggy"
        case 51: return "light drizzle"
        case 53, 55: return "drizzle"
        case 56, 57: return "freezing drizzle"
        case 61: return "light rain"
        case 63: return "rain"
        case 65: return "heavy rain"
        case 66, 67: return "freezing rain"
        case 71: return "light snow"
        case 73, 77: return "snow"
        case 75: return "heavy snow"
        case 80: return "a few showers"
        case 81: return "showers"
        case 82: return "heavy showers"
        case 85, 86: return "snow showers"
        case 95: return "thunderstorms"
        case 96, 99: return "thunderstorms with hail"
        default: return "mixed weather"
        }
    }

    static func degrees(_ t: Int) -> String {
        if t == 1 { return "1 degree" }
        if t == -1 { return "minus 1 degree" }
        return t < 0 ? "minus \(-t) degrees" : "\(t) degrees"
    }

    /// "Tomorrow in Oxford: light rain, 14 degrees, take a coat."
    static func sentence(day: String, place: String, code: Int?, high: Int?, low: Int?, rainChance: Int?) -> String {
        let wet: Set<Int> = [51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82, 95, 96, 99]
        let heavy: Set<Int> = [65, 82]
        let wintry: Set<Int> = [56, 57, 66, 67, 71, 73, 75, 77, 85, 86]
        let thunder: Set<Int> = [95, 96, 99]
        let fog: Set<Int> = [45, 48]
        let clear: Set<Int> = [0, 1, 2]
        let c = code ?? -1
        let cold = (high ?? 10) <= 8

        var parts: [String] = []
        if let code { parts.append(sky(code)) }
        if let high { parts.append(degrees(high)) }
        var advice: String?
        if thunder.contains(c) {
            advice = "take care if you go out"
        } else if wintry.contains(c) {
            advice = "wrap up warm and watch out for ice"
        } else if heavy.contains(c) {
            advice = "take a coat and an umbrella"
        } else if wet.contains(c) {
            advice = cold ? "take a warm coat" : "take a coat"
        } else if let p = rainChance, p >= 60 {
            parts.append("rain is likely later")
            advice = cold ? "take a warm coat" : "take a coat"
        } else if let p = rainChance, p >= 35 {
            parts.append("maybe a shower")
            advice = "an umbrella might be handy"
        } else if fog.contains(c) {
            advice = "take care if you're driving"
        } else if let high, high <= 5 {
            advice = "wrap up warm"
        } else if let low, low <= 0 {
            advice = "watch out for frost early on"
        } else if let high, high >= 27 {
            advice = "drink plenty of water and keep out of the midday sun"
        } else if clear.contains(c), let high, (15...26).contains(high) {
            advice = "a lovely day to get out"
        }
        if let advice { parts.append(advice) }
        let lead = day == "tomorrow" ? "Tomorrow" : "Today"
        return "\(lead) in \(place): \(parts.joined(separator: ", "))."
    }

    static func problem(_ error: Error?) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .cannotFindHost, .cannotConnectToHost:
                return "I can't reach the weather service right now. Please check the internet and try again in a little while."
            case .timedOut:
                return "The weather service is slow just now. Please try again in a minute."
            default: break
            }
        }
        return "The weather service didn't answer properly. Please try again in a minute."
    }

    // MARK: Network

    struct ServiceError: Error {}

    static func fetchJSON(_ url: URL, timeout: TimeInterval) async throws -> JSONValue {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let json = JSONValue.decode(data) else { throw ServiceError() }
        return json
    }

    /// Finds a town. Prefers a match in the person's own country (Perth in Scotland for a UK phone), unless they
    /// named a country ("Paris, France"). Places found once are kept, so the home town costs no lookup next time.
    static func locate(_ query: String, timeout: TimeInterval) async throws -> HelpersPlace? {
        let key = query.folded
        guard !key.isEmpty else { return nil }
        if let cached = cachedPlace(key) { return cached }

        let pieces = query.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let name = pieces.first.flatMap { $0.isEmpty ? nil : $0 } ?? query
        let hint = pieces.count > 1 ? countryHint(pieces[1]) : nil
        guard let url = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(HelpersURL.encode(name))&count=5&language=en&format=json")
        else { return nil }
        let results = try await fetchJSON(url, timeout: timeout)["results"]?.array ?? []
        guard let top = results.first else { return nil }

        let home = homeCountry()
        func cc(_ r: JSONValue) -> String { r["country_code"]?.string?.uppercased() ?? "" }
        func matchesHint(_ r: JSONValue) -> Bool {
            guard let hint else { return false }
            return [r["country_code"]?.string, r["country"]?.string, r["admin1"]?.string]
                .compactMap { $0?.folded }.contains(hint)
        }
        let pick = results.first(where: matchesHint) ?? results.first(where: { cc($0) == home }) ?? top
        guard let lat = pick["latitude"]?.double, let lon = pick["longitude"]?.double else { return nil }

        let placeName = pick["name"]?.string ?? name
        let place = HelpersPlace(name: placeName, country: pick["country"]?.string ?? "", region: pick["admin1"]?.string ?? "",
                                 countryCode: cc(pick),
                                 sharesName: pick != top && top["name"]?.string?.folded == placeName.folded,
                                 latitude: lat, longitude: lon, timeZone: pick["timezone"]?.string ?? "Europe/London")
        savePlace(place, key)
        return place
    }

    /// The person's country: the home town's (once looked up), else a UK clock means the UK, else the phone's region.
    static func homeCountry() -> String {
        if let cc = cachedPlace(HelpersSettings.homePlace.folded)?.countryCode, !cc.isEmpty { return cc }
        if TimeZone.current.identifier == "Europe/London" { return "GB" }
        return (Locale.current.region?.identifier ?? "GB").uppercased()
    }

    private static func countryHint(_ s: String) -> String {
        let f = s.folded
        switch f {
        case "uk", "u k", "united kingdom", "britain", "great britain", "gb": return "gb"
        case "usa", "us", "u s", "u s a", "america", "united states", "the states": return "us"
        default: return f
        }
    }

    private static func cachedPlace(_ key: String) -> HelpersPlace? {
        guard let all = UserDefaults.standard.dictionary(forKey: HelpersSettings.placeCacheKey),
              let p = all[key] as? [String: Any], let name = p["name"] as? String,
              let lat = p["lat"] as? Double, let lon = p["lon"] as? Double, let tz = p["tz"] as? String else { return nil }
        return HelpersPlace(name: name, country: p["country"] as? String ?? "", region: p["region"] as? String ?? "",
                            countryCode: p["cc"] as? String ?? "", sharesName: p["shares"] as? Bool ?? false,
                            latitude: lat, longitude: lon, timeZone: tz)
    }

    private static func savePlace(_ place: HelpersPlace, _ key: String) {
        var all = UserDefaults.standard.dictionary(forKey: HelpersSettings.placeCacheKey) ?? [:]
        if all.count >= 40 { all = [:] }
        all[key] = ["name": place.name, "country": place.country, "region": place.region, "cc": place.countryCode,
                    "shares": place.sharesName, "lat": place.latitude, "lon": place.longitude,
                    "tz": place.timeZone] as [String: Any]
        UserDefaults.standard.set(all, forKey: HelpersSettings.placeCacheKey)
    }
}

// MARK: - Help with the phone's settings

struct HelpersPhoneSettingTool: KairosTool {
    let name = "open_phone_setting"
    let summary = "Helps with the phone's settings. kairos_settings opens Kairos's own page in the Settings app (to let "
        + "Kairos use the microphone, contacts and so on). text_size, wifi, bluetooth and notifications give the person "
        + "simple spoken steps, because apps are not allowed to open those pages. Only these five: not for the torch, "
        + "the battery, the heating, or changing a setting for them."
    var parameters: JSONValue {
        Schema.object([
            "setting": Schema.string("Which setting.", oneOf: HelpersPhoneSteps.offered),
        ], required: ["setting"])
    }
    let risk = Risk.read

    func quickMatch(_ words: String, ctx: TurnContext) -> JSONValue? {
        let t = HelpersMatch.tokens(words)
        guard (2...16).contains(t.count), !HelpersMatch.asksForOtherThings(t, textCanBeANoun: true) else { return nil }
        let f = " " + t.joined(separator: " ") + " "
        if t.contains("password") || t.contains("kairos") { return nil }  // left to the model
        if f.contains(" wifi ") || f.contains(" wi fi ") { return ["setting": "wifi"] }
        if t.contains("bluetooth") { return ["setting": "bluetooth"] }

        let screenish = !Set(t).isDisjoint(with: ["screen", "phone", "iphone"])
        let textHit = !Set(t).isDisjoint(with: ["writing", "text", "font", "print"])
            || (t.contains("letters") && (screenish || t.contains("make") || t.contains("how")))
        let sizeHit = !Set(t).isDisjoint(with: ["bigger", "larger", "smaller", "size", "tiny", "small", "big", "large"])
        let howHit = [" make ", " change ", " how ", " increase ", " turn up ", " enlarge ", " too small ", " too big "]
            .contains(where: { f.contains($0) })
        if textHit, sizeHit, howHit { return ["setting": "text_size"] }

        if t.contains("notifications") || t.contains("notification"),
           [" turn off ", " turn on ", " switch off ", " switch on ", " stop ", " too many ", " silence ", " mute ",
            " how ", " change ", " settings ", " keep ", " keeps ", " allow ", " annoying "].contains(where: { f.contains($0) }) {
            return ["setting": "notifications"]
        }
        return nil
    }

    func validate(_ args: JSONValue, ctx: TurnContext) -> Validation {
        HelpersPhoneSteps.setting(args) == nil
            ? .clarify("Which setting would you like help with? For example, bigger writing, Wi-Fi or Bluetooth.")
            : .ok
    }

    func describe(_ args: JSONValue, ctx: TurnContext) -> String {
        guard let s = HelpersPhoneSteps.setting(args) else { return "Help with a setting" }
        return s == "kairos_settings" ? "Open Kairos's settings" : "How to \(HelpersPhoneSteps.goal(s))"
    }

    func execute(_ args: JSONValue, ctx: TurnContext) async throws -> ToolResult {
        guard let setting = HelpersPhoneSteps.setting(args) else {
            return .fail("Which setting would you like help with? For example, bigger writing, Wi-Fi or Bluetooth.")
        }
        let english = HelpersSpeech.speaksEnglish(ctx)
        if setting == "kairos_settings" {
            #if canImport(UIKit)
            let link = await MainActor.run { UIApplication.openSettingsURLString }
            #else
            let link = "app-settings:"
            #endif
            guard let url = URL(string: link) else { return .fail("Sorry, I couldn't open Settings just now.") }
            let say = ctx.canShowUI
                ? "I've opened Kairos's page in Settings. Here you can let Kairos use things like the microphone and your contacts. To come back, tap Kairos at the top left."
                : "Please open Kairos and ask me again, and I'll take you to Kairos's page in Settings."
            return ToolResult(ok: true, say: say, data: ["opened": "Kairos's own page in the Settings app"],
                              ui: .openURL(url), isAnswer: english)
        }
        let steps = HelpersPhoneSteps.steps(setting)
        let say = "Here's how to \(HelpersPhoneSteps.goal(setting)).\n" + HelpersSpeech.numbered(steps)
        return ToolResult(ok: true, say: say,
                          data: ["setting": .string(setting), "steps": .array(steps.map { .string($0) }),
                                 "note": "Apps can't change this setting themselves; these are the steps for the person."],
                          isAnswer: english)
    }
}

/// Where things are in the Settings app on iOS 26 (the same paths as iOS 17 and 18). Each step starts with a verb.
enum HelpersPhoneSteps {
    /// What the model is offered. "general" is still understood (a plain "settings"), but it isn't offered: a
    /// "find the General settings" walk-through fits any question, so it was picked when nothing else fitted.
    static let offered = ["kairos_settings", "text_size", "wifi", "bluetooth", "notifications"]
    static let settings = offered + ["general"]

    /// The setting asked for, tolerating the model's own spellings ("text size", "Wi-Fi", "kairos").
    static func setting(_ args: JSONValue) -> String? {
        guard let raw = args.text("setting") else { return nil }
        let f = raw.folded.replacingOccurrences(of: " ", with: "_")
        if settings.contains(f) { return f }
        switch f {
        case "wi_fi", "wireless", "internet": return "wifi"
        case "text", "font", "font_size", "writing", "larger_text", "bigger_text": return "text_size"
        case "notification", "alerts": return "notifications"
        case "kairos", "app", "app_settings", "permissions", "privacy", "microphone", "contacts": return "kairos_settings"
        case "settings", "general_settings": return "general"
        default: return nil
        }
    }

    static func goal(_ setting: String) -> String {
        switch setting {
        case "text_size": return "make the writing bigger"
        case "wifi": return "turn on Wi-Fi"
        case "bluetooth": return "turn on Bluetooth"
        case "notifications": return "turn notifications on or off"
        case "general": return "find the General settings"
        default: return "open Kairos's settings"
        }
    }

    static let openSettings = "open Settings. It's the grey cog on your Home Screen."

    static func steps(_ setting: String) -> [String] {
        switch setting {
        case "text_size":
            return [openSettings, "tap Display and Brightness.", "tap Text Size.",
                    "drag the slider to the right to make the writing bigger, or to the left to make it smaller."]
        case "wifi":
            return [openSettings, "tap Wi-Fi, near the top.",
                    "tap the switch next to Wi-Fi so it turns green. Green means it's on.",
                    "tap the name of your home network. If it asks for a password, it's often on a sticker on your router."]
        case "bluetooth":
            return [openSettings, "tap Bluetooth, near the top.",
                    "tap the switch next to Bluetooth so it turns green. Green means it's on.",
                    "tap the name of your headphones, hearing aids or car in the list to connect them."]
        case "notifications":
            return [openSettings, "tap Notifications.", "scroll down and tap the app you want to change.",
                    "tap the switch next to Allow Notifications. Green means on, grey means off."]
        default:
            return [openSettings, "scroll down a little and tap General. It has a grey cog too.",
                    "look in there for About, Software Update, Date and Time, and Keyboard."]
        }
    }
}

// MARK: - The person's own Shortcuts

struct HelpersShortcutTool: KairosTool {
    let name = "run_my_shortcut"
    let summary = "Runs one of the person's own Shortcuts from Apple's Shortcuts app by its name, and can pass it some "
        + "text. Only when the person asks for it by name. A Shortcut can do anything, so the person approves it first."
    var parameters: JSONValue {
        Schema.object([
            "name": Schema.string("The Shortcut's name, as the person said it."),
            "input": Schema.string("Optional text to give the Shortcut."),
        ], required: ["name"])
    }
    let risk = Risk.reachesPerson

    func quickMatch(_ words: String, ctx: TurnContext) -> JSONValue? {
        // Only with a helper's list of allowed Shortcuts, so the exact spelling is known.
        guard !HelpersSettings.allowedShortcuts.isEmpty else { return nil }
        var t = HelpersMatch.tokens(words)
        while let first = t.first, ["please", "kairos", "can", "could", "you"].contains(first) { t.removeFirst() }
        guard let verb = t.first, ["run", "start"].contains(verb) else { return nil }
        t.removeFirst()
        let filler: Set<String> = ["my", "the", "shortcut", "shortcuts", "called", "please", "now"]
        while let w = t.first, filler.contains(w) { t.removeFirst() }
        while let w = t.last, filler.contains(w) { t.removeLast() }
        guard !t.isEmpty, t.count <= 8, let name = HelpersShortcuts.resolve(t.joined(separator: " ")) else { return nil }
        return ["name": .string(name)]
    }

    func validate(_ args: JSONValue, ctx: TurnContext) -> Validation {
        guard let asked = args.text("name") else { return .clarify("Which of your Shortcuts should I run? Please tell me its name.") }
        let allowed = HelpersSettings.allowedShortcuts
        guard let name = HelpersShortcuts.resolve(asked) else {
            let list = allowed.map { "\"\($0)\"" }.joined(separator: ", ")
            return .clarify("I can run these Shortcuts for you: \(list). Which one would you like?")
        }
        if asked.count > 80 { return .clarify("Which of your Shortcuts should I run? Please tell me its name.") }
        // A Shortcut can do anything, so its name has to come from the person, never from a letter or a message.
        guard HelpersShortcuts.saidByPerson(name, ctx: ctx, loose: !allowed.isEmpty) else {
            if HelpersShortcuts.inDocuments(name, ctx: ctx) {
                return .block("That Shortcut was named in the letter or message, not by you, so I won't run it. If you want it, tell me its name yourself.")
            }
            return .clarify("Which of your Shortcuts should I run? Please tell me its name.")
        }
        // With no list from a helper, any name would do, so the person has to have asked for a Shortcut: "In Google
        // Maps, find…" is the Google Maps app, and "turn the heating up" isn't a Shortcut they named.
        if allowed.isEmpty {
            let latest = " " + (ctx.userWords.components(separatedBy: "\n").last ?? "").folded + " "
            if !latest.contains(" shortcut") {
                if let bundle = OperatorAppCatalog.knownBundle(name) {
                    let app = OperatorAppCatalog.displayName(bundle, fallback: name)
                    return .clarify("Do you mean one of your Shortcuts, or the \(app) app?")
                }
                if ![" run ", " start "].contains(where: { latest.contains($0) }) {
                    return .clarify("Do you mean one of your Shortcuts? If so, say \"run my shortcut\" and its name.")
                }
            }
        }
        return .ok
    }

    func describe(_ args: JSONValue, ctx: TurnContext) -> String {
        let asked = args.text("name") ?? "Shortcut"
        let name = HelpersShortcuts.resolve(asked) ?? asked
        var s = "Run your Shortcut \u{201C}\(name)\u{201D}"
        if let input = args.text("input") { s += " with \u{201C}\(String(input.prefix(120)))\u{201D}" }
        return s
    }

    func execute(_ args: JSONValue, ctx: TurnContext) async throws -> ToolResult {
        guard let asked = args.text("name"), let name = HelpersShortcuts.resolve(asked) else {
            return .fail("Which of your Shortcuts should I run? Please tell me its name.")
        }
        var link = "shortcuts://x-callback-url/run-shortcut?name=\(HelpersURL.encode(name))"
        if let input = args.text("input") { link += "&input=text&text=\(HelpersURL.encode(String(input.prefix(2000))))" }
        // A single-use code, so only a Shortcut Kairos itself started can hand text back (any web page can open
        // kairos:// links).
        let nonce = UUID().uuidString
        HelpersShortcuts.pending = (nonce, Date())
        link += "&x-success=\(HelpersURL.encode("kairos://agent/shortcut-done?n=" + nonce))"
            + "&x-cancel=\(HelpersURL.encode("kairos://agent/shortcut-cancelled"))"
            + "&x-error=\(HelpersURL.encode("kairos://agent/shortcut-failed"))"
        guard let url = URL(string: link) else { return .fail("Sorry, I couldn't start that Shortcut.") }
        let say = "I'm asking the Shortcuts app to run \u{201C}\(name)\u{201D} now. It will bring you back to Kairos when it's finished."
        return ToolResult(ok: true, say: say, data: ["shortcut": .string(name), "status": "handed to the Shortcuts app"],
                          ui: .openURL(url))
    }
}

enum HelpersShortcuts {
    /// The Shortcut Kairos started last and hasn't heard back from: its one-time code and when.
    nonisolated(unsafe) static var pending: (nonce: String, at: Date)?

    /// The exact spelling to run: the allowed list's entry when a helper set one, else the name as given.
    static func resolve(_ name: String) -> String? {
        let f = name.folded
        guard !f.isEmpty else { return nil }
        let allowed = HelpersSettings.allowedShortcuts
        guard !allowed.isEmpty else { return name.trimmingCharacters(in: .whitespacesAndNewlines) }
        let squashed = f.replacingOccurrences(of: " ", with: "")
        if let exact = allowed.first(where: { $0.folded == f || $0.folded.replacingOccurrences(of: " ", with: "") == squashed }) {
            return exact
        }
        let partial = allowed.filter { !$0.folded.isEmpty && ($0.folded.contains(f) || f.contains($0.folded)) }
        return partial.count == 1 ? partial[0] : nil
    }

    /// For the app's onOpenURL: the Shortcuts app coming back via kairos://agent/shortcut-done (?result=…),
    /// shortcut-cancelled or shortcut-failed. Returns what to tell the person, and the Shortcut's own text output,
    /// which is untrusted (hand it to Kairos as source .automation, never as the person's words).
    static func callback(_ url: URL) -> (say: String, output: String?)? {
        guard url.scheme == "kairos", url.host == "agent" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.path {
        case "/shortcut-done":
            guard let p = pending, items.first(where: { $0.name == "n" })?.value == p.nonce,
                  Date().timeIntervalSince(p.at) < 600 else { return nil }
            pending = nil
            let output = items.first(where: { $0.name == "result" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ("Your Shortcut has finished.", (output?.isEmpty ?? true) ? nil : String(output!.prefix(4000)))
        case "/shortcut-cancelled":
            return ("The Shortcut was stopped before it finished.", nil)
        case "/shortcut-failed":
            return ("The Shortcut didn't work this time. Its name may be different in the Shortcuts app.", nil)
        default:
            return nil
        }
    }

    static func significantWords(_ s: String) -> [String] {
        let skip: Set<String> = ["my", "the", "a", "an", "shortcut", "shortcuts", "run", "please"]
        return s.folded.split(separator: " ").map(String.init).filter { !skip.contains($0) }
    }

    /// The person said this name (all of its words, or, from a helper's list, at least one of them).
    static func saidByPerson(_ name: String, ctx: TurnContext, loose: Bool) -> Bool {
        let words = significantWords(name)
        guard !words.isEmpty else { return false }
        let said = " " + ctx.userWords.folded + " "
        if said.replacingOccurrences(of: " ", with: "").contains(words.joined()) { return true }
        let hits = words.filter { said.contains(" \($0) ") }
        return loose ? !hits.isEmpty : hits.count == words.count
    }

    static func inDocuments(_ name: String, ctx: TurnContext) -> Bool {
        let words = significantWords(name)
        guard !words.isEmpty else { return false }
        return ctx.documents.joined(separator: " ").folded.replacingOccurrences(of: " ", with: "").contains(words.joined())
    }
}

// MARK: - Shared helpers

enum HelpersURL {
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Strict percent-encoding for one query value (spaces, &, +, / and accents all encoded).
    static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
}

enum HelpersSpeech {
    static func speaksEnglish(_ ctx: TurnContext) -> Bool { ctx.language.lowercased().hasPrefix("en") }

    /// "my GP surgery" → "your GP surgery", for saying back.
    static func yours(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("my ") { return "your " + t.dropFirst(3) }
        return t
    }

    /// Steps in prose, one per line: "First, open Settings. … Next, tap … Last, …".
    static func numbered(_ steps: [String]) -> String {
        steps.enumerated().map { i, step in
            let lead = i == 0 ? "First, " : (i == steps.count - 1 ? "Last, " : (i == 1 ? "Next, " : "Then "))
            return lead + step
        }.joined(separator: "\n")
    }

    static func ordinal(_ n: Int) -> String {
        let suffix: String
        if (11...13).contains(n % 100) {
            suffix = "th"
        } else {
            switch n % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(n)\(suffix)"
    }

    /// British clock words: "9 o'clock", "20 past 9", "quarter to 10", "23 minutes past 4", "midnight".
    static func clock(_ hour: Int, _ minute: Int) -> String {
        func named(_ h: Int) -> String {
            let x = ((h % 24) + 24) % 24
            if x == 0 { return "midnight" }
            let twelve = x % 12
            return String(twelve == 0 ? 12 : twelve)
        }
        func minutes(_ m: Int) -> String { m % 5 == 0 ? "\(m)" : (m == 1 ? "1 minute" : "\(m) minutes") }
        switch minute {
        case 0:
            if hour % 24 == 0 { return "midnight" }
            if hour == 12 { return "midday" }
            return "\(named(hour)) o'clock"
        case 15: return "quarter past \(named(hour))"
        case 30: return "half past \(named(hour))"
        case 45: return "quarter to \(named(hour + 1))"
        case 1...29: return "\(minutes(minute)) past \(named(hour))"
        default: return "\(minutes(60 - minute)) to \(named(hour + 1))"
        }
    }

    /// "20 past 9 in the morning", "half past 3 in the afternoon", "quarter to midnight".
    static func spokenClock(hour: Int, minute: Int) -> String {
        let phrase = clock(hour, minute)
        if phrase.contains("midnight") || phrase.contains("midday") { return phrase }
        switch hour {
        case 5..<12: return phrase + " in the morning"
        case 12..<18: return phrase + " in the afternoon"
        case 18..<22: return phrase + " in the evening"
        default: return phrase + " at night"
        }
    }

    /// "It's 20 past 9 in the morning, on Sunday the 25th of October." Mentions a clock change on the day it happens.
    static func timeAndDate(_ now: Date, calendar cal: Calendar, includeYear: Bool) -> String {
        let c = cal.dateComponents([.hour, .minute, .day, .year], from: now)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = cal.timeZone
        f.dateFormat = "EEEE"
        let weekday = f.string(from: now)
        f.dateFormat = "MMMM"
        let month = f.string(from: now)
        var date = "\(weekday) the \(ordinal(c.day ?? 1)) of \(month)"
        if includeYear, let year = c.year { date += ", \(year)" }
        var say = "It's \(spokenClock(hour: c.hour ?? 0, minute: c.minute ?? 0)), on \(date)."
        if let note = clockChange(now, calendar: cal) { say += " " + note }
        return say
    }

    /// The clocks going back or forward today or tonight (they go back in the UK on Sunday 25 October 2026).
    static func clockChange(_ now: Date, calendar cal: Calendar) -> String? {
        let tz = cal.timeZone
        let today = cal.startOfDay(for: now)
        let before = tz.secondsFromGMT(for: today.addingTimeInterval(-12 * 3600))  // yesterday around midday
        let current = tz.secondsFromGMT(for: now)
        let after = tz.secondsFromGMT(for: today.addingTimeInterval(36 * 3600))   // tomorrow around midday
        func amount(_ d: Int) -> String? { abs(d) == 3600 ? "an hour" : (abs(d) == 1800 ? "half an hour" : nil) }
        if current != before, let a = amount(current - before) {
            return "The clocks went \(current < before ? "back" : "forward") \(a) last night. Your iPhone changed by itself, so this time is right."
        }
        if after != current, let a = amount(after - current) {
            return "Remember, the clocks go \(after < current ? "back" : "forward") \(a) tonight. Your iPhone will change by itself."
        }
        return nil
    }
}

enum HelpersTimeAsk: Equatable { case time, day, date }

enum HelpersMatch {
    static func tokens(_ words: String) -> [String] { words.folded.split(separator: " ").map(String.init) }

    /// The words also ask for something another helper does (a text, a call, a reminder): leave it to the model.
    /// "tell me" is fine; "text" is fine as a noun ("the text is too small") when textCanBeANoun.
    static func asksForOtherThings(_ t: [String], textCanBeANoun: Bool = false) -> Bool {
        let jobs: Set<String> = ["remind", "reminder", "text", "call", "ring", "message", "send", "email", "whatsapp",
                                 "alarm", "timer", "pay", "tell", "and then"]
        for (i, w) in t.enumerated() where jobs.contains(w) {
            let next = i + 1 < t.count ? t[i + 1] : ""
            let prev = i > 0 ? t[i - 1] : ""
            if w == "tell", next == "me" { continue }
            if w == "text", textCanBeANoun,
               ["the", "my", "of"].contains(prev) || ["size", "is", "bigger", "larger", "smaller"].contains(next) { continue }
            return true
        }
        return t.joined(separator: " ").contains("and then")
    }

    /// The first capture group of a pattern (case-insensitive unless asked).
    static func capture(_ pattern: String, in s: String, caseSensitive: Bool = false) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    /// "what's the weather like in Bath tomorrow" → "Bath". Times ("in the afternoon") are not places.
    static func weatherPlace(in words: String) -> String? {
        let s = words.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".?!")))
        let word = #"(?!(?:in|for|at|near|around)\b)[A-Za-z][A-Za-z.'\-]*"#
        let trailing = #"(?:\s+(?:today|tomorrow|tonight|this morning|this afternoon|this evening|later|please|now|right now|then|like))*"#
        let pattern = #"\b(?:in|for|at|near|around)\s+("# + word + #"(?:\s+"# + word + #"){0,4}?(?:,\s*"# + word
            + #"(?:\s+"# + word + #"){0,2}?)?)"# + trailing + #"[\s,.?!]*$"#
        guard let raw = capture(pattern, in: s) else { return nil }
        let t = raw.folded.split(separator: " ").map(String.init)
        guard let first = t.first else { return nil }
        let timeWords: Set<String> = ["morning", "afternoon", "evening", "night", "day", "weekend", "moment", "week",
                                      "minute", "hour", "while", "next"]
        let notPlaces: Set<String> = ["today", "tomorrow", "tonight", "later", "now", "home", "here", "lunchtime", "lunch",
                                      "teatime", "dinner", "bedtime", "noon", "midday", "midnight", "outside", "all",
                                      "church", "work", "school", "shopping", "golf", "bowls", "the shops", "the park",
                                      "the doctor", "the doctors", "the doctor s", "the dentist", "the hospital", "the walk",
                                      "the match", "the garden", "the bus", "the beach", "the school run", "the funeral",
                                      "the wedding", "the party", "the market"]
        if ["a", "an", "my", "your", "this", "that", "all", "our"].contains(first) { return nil }
        // "wake me up at half six", "at seven": a time, not a place.
        if clockWords.contains(first) || first.first?.isNumber == true { return nil }
        if first == "the", t.count >= 2, timeWords.contains(t[1]) { return nil }
        if notPlaces.contains(t.joined(separator: " ")) || (t.count == 1 && timeWords.contains(first)) { return nil }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "How much battery has my phone got left?", "what's my battery at?": this iPhone's battery level. Not another
    /// device's battery, not how to save battery, and not a reminder about it.
    static func batteryQuestion(_ words: String) -> Bool {
        let t = tokens(words)
        guard (2...16).contains(t.count), !asksForOtherThings(t), !PlannerWords.severalRequests(words) else { return false }
        let f = " " + t.joined(separator: " ") + " "
        let about = t.contains("battery") || [" is my phone charged ", " is my iphone charged ", " how much charge "]
            .contains(where: { f.contains($0) })
        guard about else { return false }
        let level = [" how much ", " left ", " level ", " percent ", " per cent ", " battery at ", " battery on ",
                     " how s my battery ", " how is my battery ", " what s my battery ", " what is my battery ",
                     " check my battery ", " check the battery ", " battery status ", " is my phone charged ",
                     " is my iphone charged ", " how much charge ", " running low ", " battery low "]
        guard level.contains(where: { f.contains($0) }) else { return false }
        let otherThings: Set<String> = ["mac", "macs", "macbook", "laptop", "computer", "ipad", "watch", "airpods", "headphones",
                                        "earphones", "earbuds", "hearing", "aid", "aids", "car", "mouse", "keyboard", "torch",
                                        "remote", "smoke", "doorbell", "scooter", "wheelchair", "camera", "save", "saver",
                                        "saving", "health", "replace", "replacement", "drain", "draining", "dying", "longer",
                                        "setting", "settings", "why", "batteries"]
        return otherThings.isDisjoint(with: t)
    }

    /// "Put the torch on", "turn off the flashlight", "torch on please": true for on, false for off, nil otherwise.
    static func torchRequest(_ words: String) -> Bool? {
        let t = tokens(words)
        guard (2...24).contains(t.count), !asksForOtherThings(t), !PlannerWords.severalRequests(words) else { return nil }
        let f = " " + t.joined(separator: " ") + " "
        let torch = #"(?:torch|torchlight|flashlight|flash light)"#
        guard f.range(of: " " + torch + " ", options: .regularExpression) != nil,
              Set(t).isDisjoint(with: ["battery", "camera", "app", "buy", "shortcut", "where", "charge", "charger"]) else { return nil }
        let patterns: [(String, Bool)] = [
            (#" (?:turn|switch|put|flick|pop|stick) (?:the |my |your |phone s |iphone s )?"# + torch + #" (?:on|off) "#, true),
            (#" (?:turn|switch|put) (?:on|off) (?:the |my |your |phone s |iphone s )?"# + torch + " ", true),
            (" " + torch + #" (?:on|off) "#, true),
            (#" (?:need|want|use) (?:the |a |my |your )?"# + torch + " ", false),
        ]
        for (pattern, saysOnOff) in patterns {
            guard let r = f.range(of: pattern, options: .regularExpression) else { continue }
            guard saysOnOff else { return true }
            return !f[r].contains(" off ")
        }
        return nil
    }

    /// Words that start a time of day ("half six", "quarter past", "seven o'clock").
    static let clockWords: Set<String> = ["half", "quarter", "one", "two", "three", "four", "five", "six", "seven", "eight",
                                          "nine", "ten", "eleven", "twelve", "twenty", "thirty", "forty", "fifty"]

    /// The words name a place weatherPlace can't read: "I'm going to Manchester tomorrow", "visiting Leeds", "what's
    /// it like there". Then the model picks the place, not the rule.
    static func pointsAtAnotherPlace(_ words: String) -> Bool {
        let notNames: Set<String> = ["today", "tomorrow", "tonight", "monday", "tuesday", "wednesday", "thursday", "friday",
                                     "saturday", "sunday", "i", "the"]
        if let name = capture(#"\b(?:to|visiting|in|at|from|near)\s+([A-Z][a-z]+)"#, in: words, caseSensitive: true),
           !notNames.contains(name.lowercased()) {
            return true
        }
        let f = " " + words.folded + " "
        let patterns = [
            #" (?:off|trip|travelling|traveling|heading|heading off|flying|driving|going up|going down|going over) to [a-z]"#,
            #" visiting [a-z]"#,
            // Only someone going somewhere ("I'm going to Leeds"): "what's the weather going to look like" stays home.
            #"(?:^| i m| im| i am| we re| we are| were| i ll be| i will be| we ll be| we will be| he s| she s| they re) going to (?!(?:rain|snow|be|get|stay|freeze|stop|start|clear|brighten|pour|hail|thunder|need|have|take|wear|go|do|bring|feel|turn|warm|cool|heat|dry|the|a|my|bed|sleep|church|work|school|town|be) )[a-z]+ "#,
            #" (?:like|over|up|down) there "#,
            #" there (?:today|tomorrow|tonight|later|this) "#,
            #" there $"#,
        ]
        return patterns.contains { f.range(of: $0, options: .regularExpression) != nil }
    }

    /// "what time is it", "what's the date", "what day is it today": the whole request, nothing more.
    static func timeQuestion(_ words: String) -> HelpersTimeAsk? {
        var s = " " + words.folded + " "
        for filler in [" please ", " kairos ", " hey ", " hi ", " hello ", " ok ", " okay ", " sorry ", " right now ",
                       " now ", " just ", " again ", " exactly ", " oh ", " um ", " so ", " then "] {
            while s.contains(filler) { s = s.replacingOccurrences(of: filler, with: " ") }
        }
        s = s.trimmingCharacters(in: .whitespaces)
        for prefix in ["can you tell me ", "could you tell me ", "would you tell me ", "will you tell me ", "do you know ",
                       "tell me ", "can i have ", "can i ask "] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            break
        }
        if ["what s today", "whats today", "what is today", "which day is today"].contains(s) { return .day }
        if s.hasSuffix(" today") { s = String(s.dropLast(" today".count)) }
        let time: Set<String> = ["what time is it", "what s the time", "whats the time", "what is the time", "what time it is",
                                 "the time", "time", "what time", "have you got the time", "what s the time and date",
                                 "what is the time and date", "what s the date and time", "what is the date and time",
                                 "what time and day is it", "what s the time and day"]
        let day: Set<String> = ["what day is it", "what day it is", "what day is", "what s the day", "whats the day",
                                "what is the day", "which day is it", "what day", "what day of the week is it",
                                "what day of the week it is"]
        let date: Set<String> = ["what s the date", "whats the date", "what is the date", "what date is it", "what date it is",
                                 "what date is", "what s today s date", "what is today s date", "whats todays date",
                                 "todays date", "today s date", "the date", "date", "what year is it", "what month is it",
                                 "what s the year", "what is the year", "what year it is", "what month it is"]
        if time.contains(s) { return .time }
        if day.contains(s) { return .day }
        if date.contains(s) { return .date }
        return nil
    }
}

private extension String {
    var helpersCapitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
