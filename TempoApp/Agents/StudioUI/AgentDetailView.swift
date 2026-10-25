import SwiftUI

/// One agent's page: who it is, a giant "Talk to …" button, things to try saying, what it can do (in plain
/// words), what it remembers (with Forget), ideas for automations with exact Shortcuts steps, and Share,
/// Duplicate and edit, Change and Delete. Push it inside AgentLibraryView's navigation.
struct AgentDetailView: View {
    @ObservedObject private var library = AgentLibrary.shared
    @Environment(\.dismiss) private var dismiss

    /// Changes to the copy after "Duplicate and edit", so this page then shows the person's own copy.
    @State private var shownID: String
    private let given: AgentSpec?

    @State private var chatting = false
    @State private var chatPhrase: String?
    @State private var editing: AgentSpec?
    @State private var helpFor: TriggerHelp.Item?
    @State private var phraseAfterHelp: String?
    @State private var confirmDelete = false
    @State private var forgetting: String?
    @State private var shareURL: URL?
    @State private var problem: String?
    @State private var note: String?

    init(agentID: String) {
        _shownID = State(initialValue: agentID)
        given = nil
    }

    init(spec: AgentSpec) {
        _shownID = State(initialValue: spec.id)
        given = spec
    }

    private var spec: AgentSpec? {
        library.agents.first { $0.id == shownID } ?? (given?.id == shownID ? given : nil)
    }

    var body: some View {
        Group {
            if let spec { page(spec) } else { gone }
        }
        .background(AgentUIStyle.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .environment(\.colorScheme, .light)
        .onAppear { refreshShareFile() }
        .onChange(of: spec) { _, _ in refreshShareFile() }
        .fullScreenCover(isPresented: $chatting, onDismiss: { AgentStudioUI.stopTalking(to: shownID) }) {
            AgentStudioUI.ChatScreen(agentID: shownID, firstPhrase: chatPhrase) { chatting = false }
        }
        .sheet(item: $editing) { draft in
            EditSheet(spec: draft) { changed in save(changed) }
        }
        .sheet(item: $helpFor, onDismiss: {
            guard let phrase = phraseAfterHelp, let spec else { return }
            phraseAfterHelp = nil
            talk(spec, saying: phrase)
        }) { item in
            TriggerHelp(item: item) {
                phraseAfterHelp = item.trigger.request
                helpFor = nil
            }
        }
    }

    // MARK: - The page

    private func page(_ spec: AgentSpec) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                topBar
                header(spec)
                if spec.origin == .imported { importedNotice(spec) }
                talkButton(spec)
                if !spec.starterPhrases.isEmpty { phrases(spec) }
                abilities(spec)
                if !spec.routines.isEmpty { routines(spec) }
                memory(spec)
                if !spec.triggers.isEmpty { automations(spec) }
                actions(spec)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 40)
        }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Label("Your agents", systemImage: "chevron.left")
                    .font(AgentUIStyle.font(20, .semibold))
                    .padding(.horizontal, 16)
                    .frame(minHeight: 54)
                    .background(.white, in: Capsule())
                    .foregroundStyle(AgentUIStyle.green)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to your agents")
            Spacer()
        }
        .padding(.top, 6)
    }

    private func header(_ spec: AgentSpec) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentStudioUI.Badge(spec: spec, size: 96)
            Text(spec.name)
                .font(AgentUIStyle.font(34, .bold))
                .foregroundStyle(AgentUIStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(spec.tagline)
                .font(AgentUIStyle.font(22))
                .foregroundStyle(AgentUIStyle.soft)
                .fixedSize(horizontal: false, vertical: true)
            Text(originWords(spec))
                .font(AgentUIStyle.font(18, .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.white, in: Capsule())
                .foregroundStyle(AgentUIStyle.soft)
        }
    }

    private func originWords(_ spec: AgentSpec) -> String {
        if spec.origin == .builtin { return "Ready-made" }
        if spec.origin == .imported { return "Sent to you" }
        return "Made by you"
    }

    private func importedNotice(_ spec: AgentSpec) -> some View {
        Label {
            Text("Someone sent you this agent. Read what it can do below before you talk to it. Anything that rings, texts or pays someone still needs your yes.")
                .font(AgentUIStyle.font(20, .medium))
                .foregroundStyle(AgentUIStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(AgentUIStyle.amber)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentUIStyle.amberBack, in: RoundedRectangle(cornerRadius: 20))
    }

    private func talkButton(_ spec: AgentSpec) -> some View {
        Button { talk(spec) } label: {
            Label("Talk to \(spec.name)", systemImage: "mic.fill")
                .font(AgentUIStyle.font(28, .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 88)
                .background(AgentStudioUI.color(spec.colorHex), in: RoundedRectangle(cornerRadius: 26))
                .foregroundStyle(AgentStudioUI.textColour(on: spec.colorHex))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityHint("\(spec.name) takes charge until you go back to Kairos")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(AgentUIStyle.font(26, .bold))
            .foregroundStyle(AgentUIStyle.ink)
            .accessibilityAddTraits(.isHeader)
    }

    private func phrases(_ spec: AgentSpec) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Try saying")
            ForEach(spec.starterPhrases, id: \.self) { phrase in
                Button { talk(spec, saying: phrase) } label: {
                    HStack(spacing: 12) {
                        Text("“\(phrase)”")
                            .font(AgentUIStyle.font(22, .medium))
                            .foregroundStyle(AgentUIStyle.ink)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(AgentStudioUI.color(spec.colorHex))
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Say: \(phrase)")
                .accessibilityHint("Sends this to \(spec.name)")
            }
        }
    }

    private func abilities(_ spec: AgentSpec) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("What it can do")
            if spec.allowedTools.isEmpty {
                Text("It only talks with you. It can't change anything on your phone.")
                    .font(AgentUIStyle.font(21))
                    .foregroundStyle(AgentUIStyle.soft)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(spec.allowedTools.enumerated()), id: \.offset) { index, name in
                        let words = AgentStudioUI.toolWords(name)
                        HStack(spacing: 14) {
                            Image(systemName: words.icon)
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(AgentStudioUI.color(spec.colorHex))
                                .frame(width: 36)
                                .accessibilityHidden(true)
                            Text(words.text)
                                .font(AgentUIStyle.font(21, .medium))
                                .foregroundStyle(AgentUIStyle.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                        if index < spec.allowedTools.count - 1 { Divider().padding(.leading, 66) }
                    }
                }
                .background(.white, in: RoundedRectangle(cornerRadius: 20))
            }
            Text("While \(spec.name) is in charge, it can only do these things. Anything that rings, texts or pays someone always asks you first.")
                .font(AgentUIStyle.font(19))
                .foregroundStyle(AgentUIStyle.soft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func routines(_ spec: AgentSpec) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Its routines")
            ForEach(spec.routines, id: \.self) { routine in
                HStack(spacing: 12) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(AgentStudioUI.color(spec.colorHex))
                        .accessibilityHidden(true)
                    Text(routine)
                        .font(AgentUIStyle.font(22, .medium))
                        .foregroundStyle(AgentUIStyle.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button { talk(spec, saying: Self.runPhrase(routine)) } label: {
                        Text("Run")
                            .font(AgentUIStyle.font(20, .bold))
                            .padding(.horizontal, 20)
                            .frame(minHeight: 52)
                            .background(AgentUIStyle.green, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Run \(routine)")
                }
                .padding(14)
                .background(.white, in: RoundedRectangle(cornerRadius: 20))
            }
        }
    }

    private func memory(_ spec: AgentSpec) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("What it remembers")
            if spec.memory.isEmpty {
                Text("Nothing yet. Tell it things like “Ravi is my son” and it will remember them.")
                    .font(AgentUIStyle.font(21))
                    .foregroundStyle(AgentUIStyle.soft)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(spec.memory, id: \.self) { fact in
                    HStack(spacing: 12) {
                        Text(fact)
                            .font(AgentUIStyle.font(21, .medium))
                            .foregroundStyle(AgentUIStyle.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button { forgetting = fact } label: {
                            Text("Forget")
                                .font(AgentUIStyle.font(19, .bold))
                                .padding(.horizontal, 16)
                                .frame(minHeight: 50)
                                .background(AgentUIStyle.mist.opacity(0.6), in: Capsule())
                                .foregroundStyle(AgentUIStyle.red)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Forget: \(fact)")
                    }
                    .padding(14)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20))
                }
            }
        }
        .alert("Forget this?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
               presenting: forgetting) { fact in
            Button("Forget it", role: .destructive) { forget(fact) }
            Button("Keep it", role: .cancel) {}
        } message: { fact in
            Text("\(spec.name) will no longer remember “\(fact)”.")
        }
    }

    private func automations(_ spec: AgentSpec) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Make it happen by itself")
            Text("Ideas for things \(spec.name) can do without you asking. You set each one up once.")
                .font(AgentUIStyle.font(19))
                .foregroundStyle(AgentUIStyle.soft)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(spec.triggers.enumerated()), id: \.offset) { index, trigger in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: Self.triggerIcon(trigger.kind))
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(AgentStudioUI.color(spec.colorHex))
                            .frame(width: 34)
                            .accessibilityHidden(true)
                        Text(trigger.detail)
                            .font(AgentUIStyle.font(22, .bold))
                            .foregroundStyle(AgentUIStyle.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(Self.triggerOutcome(trigger, agentName: spec.name))
                        .font(AgentUIStyle.font(20))
                        .foregroundStyle(AgentUIStyle.soft)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        helpFor = TriggerHelp.Item(id: index, trigger: trigger, agentName: spec.name)
                    } label: {
                        Label("How to set this up", systemImage: "questionmark.circle.fill")
                            .font(AgentUIStyle.font(20, .bold))
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(AgentUIStyle.green, in: RoundedRectangle(cornerRadius: 16))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
                .background(.white, in: RoundedRectangle(cornerRadius: 20))
            }
        }
    }

    private func actions(_ spec: AgentSpec) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let shareURL {
                ShareLink(item: shareURL,
                          subject: Text(spec.name),
                          message: Text("Here's my Kairos agent, “\(spec.name)”. Open the file on your iPhone and tap Kairos to add it."),
                          preview: SharePreview(spec.name, image: Image(systemName: AgentStudioUI.symbol(spec.icon)))) {
                    actionLabel("Share \(spec.name)", icon: "square.and.arrow.up", colour: AgentUIStyle.green)
                }
                Text("The copy you share leaves out what it remembers about you.")
                    .font(AgentUIStyle.font(18))
                    .foregroundStyle(AgentUIStyle.soft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if spec.origin == .builtin {
                Button { duplicate(spec) } label: {
                    actionLabel("Duplicate and edit", icon: "doc.on.doc.fill", colour: AgentUIStyle.green)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Makes your own copy of \(spec.name) that you can change")
            } else {
                Button { editing = spec } label: {
                    actionLabel("Change \(spec.name)", icon: "pencil", colour: AgentUIStyle.green)
                }
                .buttonStyle(.plain)
                Button { confirmDelete = true } label: {
                    actionLabel("Delete \(spec.name)", icon: "trash.fill", colour: AgentUIStyle.red)
                }
                .buttonStyle(.plain)
            }
            if let note {
                Label(note, systemImage: "checkmark.circle.fill")
                    .font(AgentUIStyle.font(20, .medium))
                    .foregroundStyle(AgentUIStyle.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(AgentUIStyle.font(20, .medium))
                    .foregroundStyle(AgentUIStyle.ink)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AgentUIStyle.amberBack, in: RoundedRectangle(cornerRadius: 18))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 6)
        .alert("Delete \(spec.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { deleteNow() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("It will be gone from this phone. You can't undo this.")
        }
    }

    private func actionLabel(_ title: String, icon: String, colour: Color) -> some View {
        Label(title, systemImage: icon)
            .font(AgentUIStyle.font(22, .bold))
            .lineLimit(2)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 66)
            .background(.white, in: RoundedRectangle(cornerRadius: 20))
            .foregroundStyle(colour)
    }

    private var gone: some View {
        VStack(alignment: .leading, spacing: 20) {
            topBar
            Text("This agent isn't here any more.")
                .font(AgentUIStyle.font(28, .bold))
                .foregroundStyle(AgentUIStyle.ink)
            Spacer()
        }
        .padding(.horizontal, 18)
    }

    // MARK: - Actions

    private func talk(_ spec: AgentSpec, saying phrase: String? = nil) {
        AgentStudioUI.startTalking(to: spec)
        chatPhrase = phrase
        chatting = true
    }

    private func refreshShareFile() {
        shareURL = spec.flatMap { AgentStudioUI.shareFile(for: $0) }
    }

    /// Saves and returns nil, or returns the problem in plain words.
    @discardableResult
    private func save(_ changed: AgentSpec) -> String? {
        do {
            // The library refreshes the helper in charge with the saved (vetted) version; the draft itself never
            // goes in charge, or tools the library took out would still be offered.
            let saved = try library.save(changed)
            if library.focused?.id == saved.id { library.focused = saved }
            problem = nil
            return nil
        } catch {
            let words = AgentStudioUI.plainWords(error, fallback: "I couldn't save that. Please try again.")
            problem = words
            return words
        }
    }

    private func forget(_ fact: String) {
        guard var changed = spec else { return }
        changed.memory.removeAll { $0 == fact }
        if save(changed) == nil { note = "Forgotten." }
    }

    private func duplicate(_ original: AgentSpec) {
        // The library picks a fresh id and a free name ("My Medicine Buddy 2" the second time), and keeps a shared
        // helper's copy marked as shared.
        do {
            let copy = try library.duplicate(original)
            problem = nil
            shownID = copy.id
            note = "This is your own copy. Change anything you like."
            editing = copy
        } catch {
            problem = AgentStudioUI.plainWords(error, fallback: "I couldn't make a copy. Please try again.")
        }
    }

    private func deleteNow() {
        let id = shownID
        AgentStudioUI.stopTalking(to: id)
        library.delete(id: id)
        dismiss()
    }

    /// "Run my Morning routine": the shape the routine matcher knows, so it runs without a model call.
    static func runPhrase(_ routine: String) -> String {
        let name = routine.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.lowercased().hasSuffix("routine") ? "Run my \(name)" : "Run my \(name) routine"
    }

    // MARK: - Shortcuts steps

    static func triggerIcon(_ kind: String) -> String {
        switch kind.lowercased() {
        case "time": return "clock.fill"
        case "arrive": return "location.fill"
        case "leave": return "figure.walk"
        case "message": return "message.fill"
        case "charger": return "battery.100.bolt"
        case "notification": return "bell.fill"
        default: return "bolt.fill"
        }
    }

    /// Exact steps in Apple's Shortcuts app for one suggested automation, ending with Kairos's
    /// "Ask an agent" action set to this agent and request.
    static func shortcutSteps(for trigger: AgentTrigger, agentName: String) -> [String] {
        let detail = trigger.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        var steps = [
            "Open the Shortcuts app on your iPhone.",
            "Tap Automation at the bottom of the screen.",
            "Tap + at the top right. (If you have no automations yet, tap New Automation instead.)",
        ]
        switch trigger.kind.lowercased() {
        case "time":
            steps.append("Tap Time of Day.")
            if let time = clockTime(in: detail) {
                steps.append("Tap the time and set it to \(time).")
            } else {
                steps.append("Tap the time and set it to the one you want (\(detail)).")
            }
            steps.append(repeatStep(detail))
        case "arrive":
            steps.append("Tap Arrive.")
            steps.append("Tap Choose next to Location, find the place (\(detail)), then tap Done.")
        case "leave":
            steps.append("Tap Leave.")
            steps.append("Tap Choose next to Location, find the place (\(detail)), then tap Done.")
        case "message":
            steps.append("Tap Message.")
            steps.append("Tap Choose next to Sender and pick the person (\(detail)). Or tap Message Contains and type a word to look for.")
        case "charger":
            steps.append("Tap Charger.")
            steps.append("Choose Is Connected.")
        case "notification":
            steps.append("If you see Notification in the list, tap it and choose the app (\(detail)). If not, tap App, choose that app and pick Is Opened.")
        default:
            steps.append("Scroll down the list and tap the one that fits: \(detail).")
        }
        steps += [
            "Tap Run Immediately, then tap Next at the top.",
            "Tap New Blank Automation, then tap Add Action.",
        ]
        if trigger.kind.lowercased() == "message" {
            // The message is someone else's words: it goes to "Tell Kairos", which treats it as information only.
            // Put into a helper's request it would count as the owner's own words.
            steps += [
                "In the search box, type Tell Kairos, and tap it. It has the Kairos icon.",
                "Tap the word Text and choose Shortcut Input. That is the message.",
                "Tap Done at the top. Kairos will look at each message and tell you if anything needs you. It never does what a message says.",
            ]
            return steps
        }
        steps += [
            // The titles of AskAgentIntent and its parameters (AgentIntents+Studio.swift).
            "In the search box, type Ask a Kairos helper, and tap it. It has the Kairos icon.",
            "Tap the word Helper and choose \(agentName).",
            "Tap the word Request and type: “\(trigger.request)”",
            "Tap Done at the top. That's it: from now on it happens by itself.",
        ]
        return steps
    }

    /// What the automation card says will happen.
    static func triggerOutcome(_ trigger: AgentTrigger, agentName: String) -> String {
        trigger.kind.lowercased() == "message"
            ? "Kairos will look at each message and tell you if anything needs you."
            : "It will ask \(agentName): “\(trigger.request)”"
    }

    /// "Every day at 19:00" → "19:00"; "7am" → "07:00". Nil when there's no clear time.
    static func clockTime(in text: String) -> String? {
        let lower = text.lowercased()
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        if let r = lower.range(of: #"\b([01]?[0-9]|2[0-3])[:.]([0-5][0-9])(?![0-9])"#, options: .regularExpression) {
            let parts = lower[r].split(whereSeparator: { $0 == ":" || $0 == "." })
            guard parts.count == 2, var hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
            let after = lower[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if after.hasPrefix("pm"), hour < 12 { hour += 12 }
            if after.hasPrefix("am"), hour == 12 { hour = 0 }
            // "7.30 tonight", "6:15 in the evening"
            let late = ["tonight", "evening", "at night"].contains(where: { lower.contains($0) })
            if late, !after.hasPrefix("am"), (1...11).contains(hour) { hour += 12 }
            return "\(two(hour)):\(two(minute))"
        }
        if let r = lower.range(of: #"\b(1[0-2]|0?[1-9]) ?(am|pm)\b"#, options: .regularExpression) {
            let said = String(lower[r])
            guard let n = Int(said.filter(\.isNumber)) else { return nil }
            let hour = said.hasSuffix("pm") ? (n == 12 ? 12 : n + 12) : (n == 12 ? 0 : n)
            return "\(two(hour)):00"
        }
        if lower.contains("noon") || lower.contains("midday") { return "12:00" }
        return nil
    }

    static func repeatStep(_ detail: String) -> String {
        let d = detail.lowercased()
        let dayWords = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
                        "weekday", "weekend", "week"]
        if dayWords.contains(where: { d.contains($0) }) {
            return "Under Repeat, choose Weekly and tick the days you want (\(detail))."
        }
        if d.contains("month") { return "Under Repeat, choose Monthly and pick the day." }
        return "Under Repeat, choose Daily."
    }

    // MARK: - "How to set this up"

    private struct TriggerHelp: View {
        struct Item: Identifiable {
            let id: Int
            let trigger: AgentTrigger
            let agentName: String
        }

        let item: Item
        var onTry: () -> Void

        @Environment(\.dismiss) private var dismiss
        @Environment(\.openURL) private var openURL

        private var steps: [String] { AgentDetailView.shortcutSteps(for: item.trigger, agentName: item.agentName) }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Spacer()
                        Button("Close") { dismiss() }
                            .font(AgentUIStyle.font(20, .semibold))
                            .foregroundStyle(AgentUIStyle.ink)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 52)
                            .background(.white, in: Capsule())
                            .buttonStyle(.plain)
                    }
                    Text("How to set this up")
                        .font(AgentUIStyle.font(30, .bold))
                        .foregroundStyle(AgentUIStyle.ink)
                        .accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.trigger.detail)
                            .font(AgentUIStyle.font(22, .bold))
                            .foregroundStyle(AgentUIStyle.ink)
                        Text(AgentDetailView.triggerOutcome(item.trigger, agentName: item.agentName))
                            .font(AgentUIStyle.font(20))
                            .foregroundStyle(AgentUIStyle.soft)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20))
                    Text("You do this once, in Apple's Shortcuts app. It takes about two minutes.")
                        .font(AgentUIStyle.font(20))
                        .foregroundStyle(AgentUIStyle.soft)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 14) {
                            Text("\(index + 1)")
                                .font(AgentUIStyle.font(20, .bold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(AgentUIStyle.green, in: Circle())
                                .accessibilityHidden(true)
                            Text(step)
                                .font(AgentUIStyle.font(22))
                                .foregroundStyle(AgentUIStyle.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Step \(index + 1). \(step)")
                    }

                    Button {
                        if let url = URL(string: "shortcuts://") { openURL(url) }
                    } label: {
                        Label("Open the Shortcuts app", systemImage: "arrow.up.forward.app.fill")
                            .font(AgentUIStyle.font(22, .bold))
                            .frame(maxWidth: .infinity, minHeight: 66)
                            .background(AgentUIStyle.green, in: RoundedRectangle(cornerRadius: 20))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)

                    Button(action: onTry) {
                        Label("Try it now", systemImage: "play.fill")
                            .font(AgentUIStyle.font(22, .bold))
                            .frame(maxWidth: .infinity, minHeight: 66)
                            .background(.white, in: RoundedRectangle(cornerRadius: 20))
                            .foregroundStyle(AgentUIStyle.green)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Asks \(item.agentName) the same thing once, now")

                    Text("Tip: ask someone you trust to sit with you the first time.")
                        .font(AgentUIStyle.font(19))
                        .foregroundStyle(AgentUIStyle.soft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            .background(AgentUIStyle.paper.ignoresSafeArea())
            .environment(\.colorScheme, .light)
        }
    }

    // MARK: - Change an agent

    private struct EditSheet: View {
        /// Returns nil when saved, else the problem in plain words.
        var onSave: (AgentSpec) -> String?

        @Environment(\.dismiss) private var dismiss
        @State private var draft: AgentSpec
        @State private var phrasesText: String
        @State private var problem: String?
        private let original: AgentSpec

        static let icons = ["sparkles", "pills.fill", "heart.fill", "cross.case.fill", "cart.fill", "fork.knife",
                            "figure.walk", "house.fill", "car.fill", "bus.fill", "book.fill", "envelope.fill",
                            "phone.fill", "person.2.fill", "leaf.fill", "sun.max.fill", "moon.stars.fill",
                            "shield.fill", "sterlingsign.circle.fill", "calendar"]
        static let colours = ["#2E7060", "#2F5D8A", "#8A3B2E", "#6B4C9A", "#B0611F", "#3D6B2E", "#7A5C1E", "#4A4A48"]

        init(spec: AgentSpec, onSave: @escaping (AgentSpec) -> String?) {
            self.onSave = onSave
            original = spec
            _draft = State(initialValue: spec)
            _phrasesText = State(initialValue: spec.starterPhrases.joined(separator: "\n"))
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Button("Cancel") { dismiss() }
                            .font(AgentUIStyle.font(20, .semibold))
                            .foregroundStyle(AgentUIStyle.ink)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 52)
                            .background(.white, in: Capsule())
                            .buttonStyle(.plain)
                        Spacer()
                        Button("Save") { trySave() }
                            .font(AgentUIStyle.font(20, .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 22)
                            .frame(minHeight: 52)
                            .background(AgentUIStyle.green, in: Capsule())
                            .buttonStyle(.plain)
                    }
                    Text("Change \(original.name)")
                        .font(AgentUIStyle.font(30, .bold))
                        .foregroundStyle(AgentUIStyle.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)

                    line("Its name", text: $draft.name, example: "For example: Medicine Buddy")
                    line("In one line, what it does", text: $draft.tagline, example: "For example: Keeps my tablets on time")
                    box("What it should do, and how it should talk", text: $draft.instructions, height: 210)
                    box("Things you can say to it (one on each line)", text: $phrasesText, height: 150)
                    iconPicker
                    colourPicker
                    toolPicker

                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(AgentUIStyle.font(20, .medium))
                            .foregroundStyle(AgentUIStyle.ink)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AgentUIStyle.amberBack, in: RoundedRectangle(cornerRadius: 18))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button { trySave() } label: {
                        Text("Save")
                            .font(AgentUIStyle.font(26, .bold))
                            .frame(maxWidth: .infinity, minHeight: 76)
                            .background(AgentUIStyle.green, in: RoundedRectangle(cornerRadius: 22))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AgentUIStyle.paper.ignoresSafeArea())
            .environment(\.colorScheme, .light)
        }

        private func label(_ title: String) -> some View {
            Text(title)
                .font(AgentUIStyle.font(22, .semibold))
                .foregroundStyle(AgentUIStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
        }

        private func line(_ title: String, text: Binding<String>, example: String) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                label(title)
                TextField(example, text: text)
                    .font(AgentUIStyle.font(24))
                    .foregroundStyle(AgentUIStyle.ink)
                    .padding(14)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
            }
        }

        private func box(_ title: String, text: Binding<String>, height: CGFloat) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                label(title)
                TextEditor(text: text)
                    .font(AgentUIStyle.font(22))
                    .foregroundStyle(AgentUIStyle.ink)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: height)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
            }
        }

        private var iconPicker: some View {
            VStack(alignment: .leading, spacing: 10) {
                label("Its picture")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                    ForEach(Self.icons, id: \.self) { icon in
                        let chosen = draft.icon == icon
                        Button { draft.icon = icon } label: {
                            Image(systemName: icon)
                                .font(.system(size: 26, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 60)
                                .background(chosen ? AgentStudioUI.color(draft.colorHex) : .white,
                                            in: RoundedRectangle(cornerRadius: 14))
                                .foregroundStyle(chosen ? AgentStudioUI.textColour(on: draft.colorHex) : AgentUIStyle.soft)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(icon.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " "))
                        .accessibilityAddTraits(chosen ? .isSelected : [])
                    }
                }
            }
        }

        private var colourPicker: some View {
            VStack(alignment: .leading, spacing: 10) {
                label("Its colour")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(Array(Self.colours.enumerated()), id: \.offset) { index, hex in
                        let chosen = draft.colorHex.uppercased() == hex.uppercased()
                        Button { draft.colorHex = hex } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(AgentStudioUI.color(hex))
                                    .frame(minHeight: 60)
                                if chosen {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 26, weight: .bold))
                                        .foregroundStyle(AgentStudioUI.textColour(on: hex))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Colour \(index + 1)")
                        .accessibilityAddTraits(chosen ? .isSelected : [])
                    }
                }
            }
        }

        private var toolPicker: some View {
            VStack(alignment: .leading, spacing: 10) {
                label("What it's allowed to do")
                VStack(spacing: 0) {
                    let names = AgentStudioUI.allToolNames(including: original.allowedTools)
                    ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                        let words = AgentStudioUI.toolWords(name)
                        Toggle(isOn: allowed(name)) {
                            HStack(spacing: 12) {
                                Image(systemName: words.icon)
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(AgentUIStyle.green)
                                    .frame(width: 32)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(words.text)
                                        .font(AgentUIStyle.font(20, .medium))
                                        .foregroundStyle(AgentUIStyle.ink)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if AgentStudioUI.asksFirst(name) {
                                        Text("Always asks you first")
                                            .font(AgentUIStyle.font(16, .medium))
                                            .foregroundStyle(AgentUIStyle.amber)
                                    }
                                }
                            }
                        }
                        .toggleStyle(.switch)
                        .tint(AgentUIStyle.green)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        if index < names.count - 1 { Divider().padding(.leading, 58) }
                    }
                }
                .background(.white, in: RoundedRectangle(cornerRadius: 18))
            }
        }

        private func allowed(_ name: String) -> Binding<Bool> {
            Binding(
                get: { draft.allowedTools.contains(name) },
                set: { on in
                    if on { if !draft.allowedTools.contains(name) { draft.allowedTools.append(name) } }
                    else { draft.allowedTools.removeAll { $0 == name } }
                })
        }

        private func trySave() {
            var changed = draft
            changed.name = AgentStudioUI.clip(changed.name, 40)
            changed.tagline = AgentStudioUI.clip(changed.tagline, 90)
            changed.instructions = AgentStudioUI.clip(changed.instructions, 4000)
            let quotes = CharacterSet(charactersIn: "\"“”'‘’").union(.whitespaces)
            changed.starterPhrases = Array(phrasesText
                .split(whereSeparator: \.isNewline)
                .map { AgentStudioUI.clip(String($0).trimmingCharacters(in: quotes), 80) }
                .filter { !$0.isEmpty }
                .prefix(6))
            guard !changed.name.isEmpty else { problem = "Please give it a name."; return }
            guard changed.instructions.count >= 10 else { problem = "Please say a little about what it should do."; return }
            changed.version = original.version + 1
            if let words = onSave(changed) { problem = words } else { dismiss() }
        }
    }
}
