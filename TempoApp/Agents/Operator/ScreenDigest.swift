import Foundation

// What the Phone operator "sees": iCTRL's page_source text turned into a short numbered list of the things on the
// screen ("[7] button 'Chats'", "[12] textview 'Message'"). Only this list goes to the model, never a screenshot,
// which is what keeps one decision under a second and a half. Status bar, scroll bars, keyboard keys, empty
// containers and texts already inside a row are dropped; at most 60 lines.
//
// page_source rows look like this (iCTRL's ForegroundApp.m, two spaces per level):
//   Cell, label: 'Amma ❤️, Did you eat?, 18:30', value: '…', id: '…', {{0, 230}, {428, 76}}
// A label can hold quotes and even new lines (a chat bubble), so rows are joined until they end with the frame.

/// One thing on the screen.
struct ScreenElement: Sendable, Equatable {
    /// The [number] the model sees. Stable within one read only.
    var index: Int
    /// iCTRL's type name: Button, Cell, StaticText, TextField, SecureTextField, SearchField, TextView, NavigationBar, …
    /// "OCRText" for text read off a screenshot.
    var kind: String
    /// Its own accessibility label, or for an unlabelled row the texts inside it.
    var label: String
    var value: String = ""
    var ident: String = ""
    var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
    var depth: Int = 0
    /// The label is the element's own, so find_element can match it. False when it was put together from children.
    var ownLabel: Bool = true
    var fromOCR: Bool = false
    /// Texts inside a row or button, in order (for a chat row: name, last message, time).
    var texts: [String] = []

    var midX: Double { x + w / 2 }
    var midY: Double { y + h / 2 }
    var isTextInput: Bool { ScreenDigest.inputKinds.contains(kind) }
    var isSecure: Bool { kind == "SecureTextField" }
    var isActionable: Bool { ScreenDigest.actionableKinds.contains(kind) || fromOCR }
    /// What a person would read on it.
    var shownText: String {
        if !label.isEmpty { return label }
        if !value.isEmpty { return value }
        return ident
    }
    /// The row's first text: the contact's name in a chat list.
    var primaryText: String {
        if let first = texts.first(where: { !$0.isEmpty }) { return first }
        return label.components(separatedBy: ", ").first ?? label
    }
    /// Everything written on it, for matching and reading.
    var fullText: String {
        var parts = [label]
        for t in texts where !label.localizedCaseInsensitiveContains(t) { parts.append(t) }
        if !value.isEmpty, value != label, !isSecure { parts.append(value) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct ScreenDigest: Sendable {
    static let maxLinesDefault = 60

    /// The app in front (bundle id), as iCTRL reports it.
    var bundleID: String
    /// The app's name from the Application row ("WhatsApp").
    var appName: String
    var elements: [ScreenElement]
    /// Indices (ScreenElement.index) of the elements listed to the model, in screen order.
    var shown: [Int]
    var keyboardTop: Double?
    var alertTitle: String?
    /// A system alert (permission prompt, "Open in…?") is covering the app.
    var systemAlert: Bool
    var loading: Bool
    var usedOCR: Bool
    var screenHeight: Double
    /// iCTRL's own hint about this read, for the model when something is off. Not shown by default.
    var hint: String?
    /// Small buttons with no label, value, identifier or text (an icon-only Send or Call): never listed to the model,
    /// but a coordinate tap must not land on one (see OperatorSafety.riskyUnder).
    var unnamedControls: [ScreenElement] = []
    /// The text the model sees: header + ≤ maxLines-1 element lines.
    private(set) var text: String
    /// Same screen ⇒ same fingerprint (for "stop if the same screen repeats 3 times").
    private(set) var fingerprint: UInt64

    static let actionableKinds: Set<String> = ["Button", "Cell", "Link", "TextField", "SecureTextField", "SearchField",
                                               "TextView", "Switch", "Slider", "SegmentedControl", "PickerWheel",
                                               "Picker", "Icon", "MenuItem", "Tab"]
    static let inputKinds: Set<String> = ["TextField", "SecureTextField", "SearchField", "TextView"]
    /// Rows that hold their texts: a StaticText inside one is part of it, not a line of its own.
    static let absorberKinds: Set<String> = ["Cell", "Button", "Link"]
    /// Structure only, never listed.
    static let containerKinds: Set<String> = ["Any", "Window", "Application", "Group", "ScrollView", "Table",
                                              "CollectionView", "WebView", "Toolbar", "TabBar", "Keyboard", "Key",
                                              "Sheet", "ScrollBar", "Map", "StatusBar"]

    // MARK: - Reading a page_source reply

    init(pageSource reply: JSONValue, maxLines: Int = ScreenDigest.maxLinesDefault) {
        let source = reply["source"]?.string ?? ""
        let rows = Self.rows(from: source)
        var keyboardTop = Self.keyboardTop(reply: reply, rows: rows)
        if keyboardTop != nil, keyboardTop! <= 0 { keyboardTop = nil }
        var appName = ""
        var screenHeight = 0.0
        for r in rows where r.kind == "Application" {
            appName = Self.clean(r.label)
            screenHeight = r.h
            break
        }
        var alertTitle = reply["system_alert_title"]?.string
        var loading = reply["loading"]?.bool ?? false
        let built = Self.build(rows, keyboardTop: keyboardTop, alertTitle: &alertTitle, loading: &loading)
        var elements = built

        // Accessibility not answering, or iCTRL already did OCR for a thin tree.
        var usedOCR = false
        if let items = reply["ocr_items"]?.array, !items.isEmpty, elements.count < 4 {
            elements += Self.ocrElements(items, startIndex: elements.count + 1)
            usedOCR = true
        }
        self.init(bundleID: reply["bundle_id"]?.string ?? reply["foreground_app"]?.string ?? "",
                  appName: appName, elements: elements, keyboardTop: keyboardTop, alertTitle: alertTitle,
                  systemAlert: reply["system_alert"]?.bool ?? false, loading: loading, usedOCR: usedOCR,
                  screenHeight: screenHeight, hint: reply["hint"]?.string, maxLines: maxLines)
        unnamedControls = Self.unnamedControls(rows, keyboardTop: keyboardTop)
    }

    init(bundleID: String, appName: String, elements: [ScreenElement], keyboardTop: Double? = nil,
         alertTitle: String? = nil, systemAlert: Bool = false, loading: Bool = false, usedOCR: Bool = false,
         screenHeight: Double = 0, hint: String? = nil, maxLines: Int = ScreenDigest.maxLinesDefault) {
        self.bundleID = bundleID
        self.appName = appName
        self.elements = elements
        self.keyboardTop = keyboardTop
        self.alertTitle = alertTitle
        self.systemAlert = systemAlert
        self.loading = loading
        self.usedOCR = usedOCR
        self.screenHeight = screenHeight
        self.hint = hint
        self.shown = []
        self.text = ""
        self.fingerprint = 0
        self.shown = choose(maxLines: maxLines)
        let lines = shown.compactMap { element($0) }.map(Self.line)
        var header = "SCREEN app=\(appName.isEmpty ? bundleID : appName)"
        if keyboardTop != nil { header += " keyboard=up" }
        if let alertTitle { header += " alert='\(Self.short(alertTitle, 60))'" } else if systemAlert { header += " alert=yes" }
        if loading { header += " loading=yes" }
        if usedOCR { header += " (read by OCR: tap by number still works)" }
        var all = [header] + lines
        let hidden = elements.count - shown.count
        if hidden > 0 { all.append("(+\(hidden) more not listed)") }
        if elements.isEmpty { all.append("(nothing readable on the screen)") }
        text = all.joined(separator: "\n")
        fingerprint = Self.fnv1a(bundleID + "\n" + lines.joined(separator: "\n"))
    }

    /// Adds text read off a screenshot (iCTRL screen_text items) to a thin screen.
    func addingOCR(_ items: [JSONValue], maxLines: Int = ScreenDigest.maxLinesDefault) -> ScreenDigest {
        let extra = Self.ocrElements(items, startIndex: elements.count + 1)
        guard !extra.isEmpty else { return self }
        var out = ScreenDigest(bundleID: bundleID, appName: appName, elements: elements + extra, keyboardTop: keyboardTop,
                               alertTitle: alertTitle, systemAlert: systemAlert, loading: loading, usedOCR: true,
                               screenHeight: screenHeight, hint: hint, maxLines: maxLines)
        out.unnamedControls = unnamedControls
        return out
    }

    /// Merges a system alert (read from SpringBoard) on top of this screen.
    func addingAlert(_ alert: ScreenDigest, maxLines: Int = ScreenDigest.maxLinesDefault) -> ScreenDigest {
        var extra: [ScreenElement] = []
        for var e in alert.elements where e.kind != "NavigationBar" {
            e.index = elements.count + extra.count + 1
            extra.append(e)
        }
        var out = ScreenDigest(bundleID: bundleID, appName: appName, elements: extra + elements, keyboardTop: keyboardTop,
                               alertTitle: alert.alertTitle ?? alertTitle ?? "System alert", systemAlert: true, loading: loading,
                               usedOCR: usedOCR, screenHeight: screenHeight, hint: hint, maxLines: maxLines)
        out.unnamedControls = unnamedControls + alert.unnamedControls
        return out
    }

    /// The thin-tree test iCTRL's own guide uses: few labelled things, or iCTRL recommends OCR.
    static func needsOCR(_ reply: JSONValue, digest: ScreenDigest) -> Bool {
        if digest.usedOCR { return false }
        if reply["channel"]?["recommended"]?.string == "ocr" { return true }
        return digest.elements.count < 4
    }

    // MARK: - Looking things up

    func element(_ index: Int) -> ScreenElement? {
        guard index >= 1, index <= elements.count, elements[index - 1].index == index else {
            return elements.first { $0.index == index }
        }
        return elements[index - 1]
    }

    var shownElements: [ScreenElement] { shown.compactMap { element($0) } }

    /// Elements whose label matches one of the aliases: exact first (case, accents and emoji ignored), then contains.
    func find(_ aliases: [String], kinds: Set<String>? = nil, exactOnly: Bool = false) -> [ScreenElement] {
        let wants = aliases.map { $0.folded }.filter { !$0.isEmpty }
        let pool = elements.filter { kinds == nil || kinds!.contains($0.kind) || ($0.fromOCR && kinds != nil) }
        let exact = pool.filter { e in wants.contains(e.label.folded) || (!e.ident.isEmpty && wants.contains(e.ident.folded)) }
        if !exact.isEmpty || exactOnly { return exact }
        return pool.filter { e in let f = e.fullText.folded; return wants.contains { f.contains($0) } }
    }

    func first(kind: String) -> ScreenElement? { elements.first { $0.kind == kind } }

    func has(_ text: String) -> Bool {
        let want = text.folded
        guard !want.isEmpty else { return false }
        return elements.contains { $0.fullText.folded.contains(want) }
    }

    /// Every text on the screen, one line per element, untruncated (for reading aloud). Secret fields are left out.
    var readableLines: [String] {
        elements.compactMap { e in
            if e.isSecure { return nil }
            let t = e.fullText
            return t.isEmpty ? nil : t
        }
    }

    /// The screen's text for a model that answers a question about it, capped.
    func screenText(limit: Int = 6000) -> String {
        var out = ""
        for line in readableLines {
            if out.count + line.count + 1 > limit { break }
            out += line + "\n"
        }
        return out
    }

    // MARK: - Choosing the lines the model sees

    private func choose(maxLines: Int) -> [Int] {
        let budget = max(4, maxLines - 2)  // header + "(+N more)"
        if elements.count <= maxLines - 1 { return elements.map(\.index) }
        var keep = Set<Int>()
        // Titles, alerts and every control that isn't a list row first; then rows and texts. A chat (it has a
        // composer) keeps its newest, lowest rows; a list keeps its first ones.
        for e in elements where e.kind == "Alert" || e.kind == "NavigationBar" { keep.insert(e.index) }
        for e in elements where e.isActionable && e.kind != "Cell" && keep.count < budget { keep.insert(e.index) }
        let chatLike = elements.contains { $0.kind == "TextView" }
        let rest = elements.filter { !keep.contains($0.index) }
        for e in (chatLike ? rest.reversed() : rest) where keep.count < budget { keep.insert(e.index) }
        return elements.map(\.index).filter { keep.contains($0) }
    }

    static func line(_ e: ScreenElement) -> String {
        let name: String
        switch e.kind {
        case "Button": name = "button"
        case "Cell": name = "row"
        case "StaticText": name = "text"
        case "TextField": name = "textfield"
        case "SecureTextField": name = "securefield"
        case "SearchField": name = "searchfield"
        case "TextView": name = "textview"
        case "NavigationBar": name = "title"
        case "Switch": name = "switch"
        case "Link": name = "link"
        case "Alert": name = "alert"
        case "Slider": name = "slider"
        case "SegmentedControl": name = "tabs"
        case "Icon": name = "app"
        case "OCRText": name = "text"
        default: name = e.kind.lowercased()
        }
        var s = "[\(e.index)] \(name) '\(short(e.kind == "Cell" ? e.fullText : e.shownText, 80))'"
        if e.kind == "Switch" {
            s += e.value == "1" ? " on" : (e.value == "0" ? " off" : "")
        } else if !e.value.isEmpty, e.value != e.label, !e.isSecure, e.kind != "Cell" {
            s += " = '\(short(e.value, 60))'"
        }
        if e.isSecure { s += " (secret: never type here)" }
        return s
    }

    // MARK: - Parsing

    struct Row: Equatable {
        var depth: Int
        var kind: String
        var label: String
        var value: String
        var ident: String
        var x: Double, y: Double, w: Double, h: Double
    }

    /// page_source text → rows. A row ends with its frame "{{x, y}, {w, h}}"; lines in between belong to a label.
    static func rows(from source: String) -> [Row] {
        var out: [Row] = []
        var buffer = ""
        for raw in source.components(separatedBy: "\n") {
            buffer = buffer.isEmpty ? raw : buffer + "\n" + raw
            let trimmed = buffer.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("}}") || trimmed.isEmpty {
                if !trimmed.isEmpty, let row = parseRow(buffer) { out.append(row) }
                buffer = ""
            } else if buffer.count > 4000 {  // never let one broken row swallow the screen
                if let row = parseRow(buffer) { out.append(row) }
                buffer = ""
            }
        }
        if !buffer.trimmingCharacters(in: .whitespaces).isEmpty, let row = parseRow(buffer) { out.append(row) }
        return out
    }

    static func parseRow(_ line: String) -> Row? {
        let spaces = line.prefix(while: { $0 == " " }).count
        var body = Substring(line.dropFirst(spaces))
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        if let open = body.range(of: "{{", options: .backwards) {
            let nums = body[open.lowerBound...].split(whereSeparator: { !"-0123456789.".contains($0) }).compactMap { Double($0) }
            if nums.count >= 4 { x = nums[0]; y = nums[1]; w = nums[2]; h = nums[3] }
            body = body[..<open.lowerBound]
            while body.hasSuffix(" ") || body.hasSuffix(",") { body = body.dropLast() }
        }
        let kindEnd = body.firstIndex(of: ",") ?? body.endIndex
        let kind = String(body[..<kindEnd]).trimmingCharacters(in: .whitespaces)
        guard !kind.isEmpty, kind.first!.isLetter, !kind.contains(" ") else { return nil }
        var rest = body[kindEnd...]
        var label = "", value = "", ident = ""
        if rest.hasSuffix("'"), let r = rest.range(of: ", id: '", options: .backwards) {
            ident = String(rest[r.upperBound..<rest.index(before: rest.endIndex)])
            rest = rest[..<r.lowerBound]
        }
        if rest.hasSuffix("'"), let r = rest.range(of: ", value: '", options: .backwards) {
            value = String(rest[r.upperBound..<rest.index(before: rest.endIndex)])
            rest = rest[..<r.lowerBound]
        }
        if rest.hasPrefix(", label: '"), rest.hasSuffix("'"), rest.count >= 11 {
            label = String(rest.dropFirst(10).dropLast())
        }
        return Row(depth: spaces / 2, kind: kind, label: label, value: value, ident: ident, x: x, y: y, w: w, h: h)
    }

    private static func keyboardTop(reply: JSONValue, rows: [Row]) -> Double? {
        if let k = reply["keyboard"], k["visible"]?.bool == true {
            if let top = k["covers_from_y"]?.double { return top }
        }
        for r in rows where r.kind == "Keyboard" && r.h > 0 { return r.y }
        return nil
    }

    private static let statusWords = ["battery", "signal", "wi-fi", "wifi", "cellular", "bars", "location tracking"]

    private static func build(_ rows: [Row], keyboardTop: Double?, alertTitle: inout String?, loading: inout Bool) -> [ScreenElement] {
        var out: [ScreenElement] = []
        var seen = Set<String>()
        /// Nearest absorbing ancestor: (depth, index into out).
        var stack: [(depth: Int, at: Int)] = []
        for r in rows {
            while let last = stack.last, last.depth >= r.depth { stack.removeLast() }
            let label = clean(r.label)
            let value = clean(r.value)
            if r.kind == "ActivityIndicator" { loading = true; continue }
            if r.kind == "Alert", !label.isEmpty, alertTitle == nil { alertTitle = label }
            if containerKinds.contains(r.kind) { continue }
            if r.w <= 1 || r.h <= 1 { continue }                                   // no hit target, not on screen
            if let top = keyboardTop, r.y >= top - 1 { continue }                    // under the keyboard
            if label.hasPrefix("Vertical scroll bar") || label.hasPrefix("Horizontal scroll bar") { continue }
            if r.y + r.h <= 54, isStatusBarText(label) { continue }
            let hasText = !label.isEmpty || !value.isEmpty || !r.ident.isEmpty
            let isTextish = r.kind == "StaticText" || r.kind == "Image" || r.kind == "Other"

            // A text inside a row or button belongs to it.
            if isTextish, let parent = stack.last {
                let t = label.isEmpty ? value : label
                if !t.isEmpty, !out[parent.at].texts.contains(t) { out[parent.at].texts.append(t) }
                continue
            }
            if r.kind == "Image" { continue }                    // icons and pictures on their own
            if r.kind == "Other" && label.isEmpty { continue }    // layout boxes
            if !hasText && !absorberKinds.contains(r.kind) && !inputKinds.contains(r.kind) { continue }

            let key = "\(r.kind)|\(label)|\(value)|\(Int(r.y))"
            if !label.isEmpty || !value.isEmpty {
                if seen.contains(key) { continue }
                seen.insert(key)
            }
            out.append(ScreenElement(index: out.count + 1, kind: r.kind, label: label, value: value, ident: r.ident,
                                     x: r.x, y: r.y, w: r.w, h: r.h, depth: r.depth, ownLabel: !label.isEmpty))
            if absorberKinds.contains(r.kind) { stack.append((r.depth, out.count - 1)) }
        }
        // Unlabelled rows and buttons take their texts as their label; ones with nothing to say go.
        var kept: [ScreenElement] = []
        for var e in out {
            if e.label.isEmpty, !e.texts.isEmpty {
                e.label = e.texts.joined(separator: ", ")
                e.ownLabel = false
            }
            if e.label.isEmpty, e.value.isEmpty, e.ident.isEmpty, !e.isTextInput { continue }
            e.index = kept.count + 1
            kept.append(e)
        }
        return kept
    }

    /// Icon-sized buttons with nothing written on or in them (build() drops these from the list).
    static func unnamedControls(_ rows: [Row], keyboardTop: Double?) -> [ScreenElement] {
        var out: [ScreenElement] = []
        for (i, r) in rows.enumerated() where ["Button", "Link", "Switch", "Icon"].contains(r.kind) {
            guard r.label.isEmpty, r.value.isEmpty, r.ident.isEmpty, r.w > 1, r.h > 1, r.w <= 80, r.h <= 80 else { continue }
            if let top = keyboardTop, r.y >= top - 1 { continue }
            var j = i + 1
            var hasText = false
            while j < rows.count, rows[j].depth > r.depth {
                if !rows[j].label.isEmpty || !rows[j].value.isEmpty { hasText = true; break }
                j += 1
            }
            if hasText { continue }
            out.append(ScreenElement(index: 0, kind: r.kind, label: "", x: r.x, y: r.y, w: r.w, h: r.h, depth: r.depth,
                                     ownLabel: false))
        }
        return out
    }

    private static func isStatusBarText(_ label: String) -> Bool {
        let l = label.lowercased()
        if l.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil { return true }
        return statusWords.contains { l.contains($0) }
    }

    /// iCTRL OCR items: label/text, confidence, x, y, width, height (points, top-left origin).
    static func ocrElements(_ items: [JSONValue], startIndex: Int) -> [ScreenElement] {
        var out: [ScreenElement] = []
        for item in items {
            let label = clean(item["label"]?.string ?? item["text"]?.string ?? "")
            guard !label.isEmpty, (item["confidence"]?.double ?? 1) >= 0.5 else { continue }
            let x = item["x"]?.double ?? 0, y = item["y"]?.double ?? 0
            let w = item["width"]?.double ?? 0, h = item["height"]?.double ?? 0
            if y + h <= 54, isStatusBarText(label) { continue }
            out.append(ScreenElement(index: startIndex + out.count, kind: "OCRText", label: label, x: x, y: y, w: w, h: h,
                                     ownLabel: false, fromOCR: true))
            if out.count >= 120 { break }
        }
        return out
    }

    // MARK: - Small text helpers

    private static let invisible: [Character: Character] = [
        "\u{200E}": " ", "\u{200F}": " ", "\u{2068}": " ", "\u{2069}": " ", "\u{202A}": " ", "\u{202C}": " ",
        "\u{00A0}": " ", "\u{FFFC}": " ",
    ]

    /// Invisible direction marks and new lines become spaces; runs of spaces become one.
    static func clean(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        let mapped = String(s.map { invisible[$0] ?? ($0.isNewline ? " " : $0) })
        return mapped.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    static func short(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }

    static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

/// Name matching for list rows (WhatsApp PROCEDURES row-match rules): case, accents, emoji and punctuation ignored.
enum ScreenNames {
    /// Emoji leave invisible marks behind (variation selector U+FE0F counts as a "mark", so "Amma ❤️" would fold to
    /// "amma \u{FE0F}"): drop them, then fold.
    static func key(_ s: String) -> String {
        let scalars = s.unicodeScalars.filter { u in
            !(0xFE00...0xFE0F).contains(u.value) && u.value != 0x200D && u.value != 0x20E3 && !(0xE0020...0xE007F).contains(u.value)
        }
        return String(String.UnicodeScalarView(scalars)).folded
    }

    /// Exact matches, else rows whose name starts with the query as a whole word ("Rahul" → "Rahul Sharma").
    static func match(_ rows: [ScreenElement], name: String) -> (exact: [ScreenElement], prefix: [ScreenElement]) {
        let want = key(name)
        guard !want.isEmpty else { return ([], []) }
        let exact = rows.filter { key($0.primaryText) == want }
        if !exact.isEmpty { return (exact, []) }
        let prefix = rows.filter { key($0.primaryText).hasPrefix(want + " ") }
        return ([], prefix)
    }

    /// A name as it should be spoken: emoji out ("Amma ❤️" → "Amma"), so the voice doesn't say "red heart".
    static func spoken(_ s: String) -> String {
        let scalars = s.unicodeScalars.filter { u in
            !(u.properties.isEmoji && !u.isASCII) && !(0xFE00...0xFE0F).contains(u.value) && u.value != 0x200D
        }
        let t = String(String.UnicodeScalarView(scalars)).split(separator: " ").joined(separator: " ")
        return t.isEmpty ? s : t
    }

    static func sameName(_ a: String, _ b: String) -> Bool {
        let ka = key(a), kb = key(b)
        guard !ka.isEmpty, !kb.isEmpty else { return false }
        return ka == kb || ka.hasPrefix(kb + " ") || kb.hasPrefix(ka + " ")
    }
}
