import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

// The Agent Studio screens: "Your agents" (this file), one agent's page (AgentDetailView.swift) and
// "Make a new agent" (NewAgentView.swift). Built for people who are not confident with phones: huge cards,
// big rounded words, one clear button per job. The agents themselves live in AgentLibrary (AgentsWIP3/Studio);
// these screens only read and save AgentSpecs and hand requests to KairosAgent.

/// "Your agents": the ready-made agents, the person's own ones, a giant "Make a new agent" card and Import.
/// Show it full screen or in a sheet; it brings its own navigation. Pass `onClose` to get a Close button.
struct AgentLibraryView: View {
    var onClose: (() -> Void)? = nil

    @ObservedObject private var library = AgentLibrary.shared
    @State private var path: [AgentStudioUI.Route] = []
    @State private var showImport = false

    private var readyMade: [AgentSpec] { library.agents.filter { $0.origin == .builtin } }
    private var yours: [AgentSpec] { library.agents.filter { $0.origin != .builtin } }
    private let columns = [GridItem(.flexible(), spacing: 14, alignment: .top),
                           GridItem(.flexible(), spacing: 14, alignment: .top)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    topBar
                    Text("Your agents")
                        .font(AgentUIStyle.font(34, .bold))
                        .foregroundStyle(AgentUIStyle.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("Each agent is a helper for one job. Tap one to see what it does and talk to it.")
                        .font(AgentUIStyle.font(21))
                        .foregroundStyle(AgentUIStyle.soft)
                        .fixedSize(horizontal: false, vertical: true)
                    if let focused = library.focused { inChargeBanner(focused) }
                    NavigationLink(value: AgentStudioUI.Route.newAgent) { newAgentCard }
                        .buttonStyle(.plain)
                    section("Ready-made", readyMade,
                            empty: "The ready-made agents will appear here.")
                    section("Made by you", yours,
                            empty: "Agents you make, or that someone sends you, will appear here.")
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 32)
            }
            .background(AgentUIStyle.paper.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: AgentStudioUI.Route.self) { route in
                switch route {
                case .agent(let id): AgentDetailView(agentID: id)
                case .newAgent: NewAgentView()
                }
            }
        }
        .environment(\.colorScheme, .light)
        .sheet(isPresented: $showImport) {
            ImportSheet { spec in path.append(.agent(spec.id)) }
        }
    }

    // MARK: - Pieces

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { showImport = true } label: {
                Label("Import", systemImage: "square.and.arrow.down")
                    .font(AgentUIStyle.font(20, .semibold))
                    .padding(.horizontal, 16)
                    .frame(minHeight: 54)
                    .background(.white, in: Capsule())
                    .foregroundStyle(AgentUIStyle.green)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Add an agent someone sent you")
            Spacer(minLength: 4)
            if let onClose {
                Button(action: onClose) {
                    Text("Close")
                        .font(AgentUIStyle.font(20, .semibold))
                        .padding(.horizontal, 16)
                        .frame(minHeight: 54)
                        .background(.white, in: Capsule())
                        .foregroundStyle(AgentUIStyle.ink)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 6)
    }

    private var newAgentCard: some View {
        HStack(spacing: 18) {
            Image(systemName: "plus")
                .font(.system(size: 40, weight: .bold))
                .frame(width: 76, height: 76)
                .background(.white.opacity(0.22), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text("Make a new agent")
                    .font(AgentUIStyle.font(30, .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                Text("Say what you need. Kairos builds it for you.")
                    .font(AgentUIStyle.font(20, .medium))
                    .opacity(0.92)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        .background(AgentUIStyle.green, in: RoundedRectangle(cornerRadius: 28))
        .shadow(color: .black.opacity(0.15), radius: 14, y: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Make a new agent")
        .accessibilityHint("Tell Kairos what you need and it builds the agent for you")
        .accessibilityAddTraits(.isButton)
    }

    private func section(_ title: String, _ specs: [AgentSpec], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(AgentUIStyle.font(28, .bold))
                .foregroundStyle(AgentUIStyle.ink)
                .accessibilityAddTraits(.isHeader)
            if specs.isEmpty {
                Text(empty)
                    .font(AgentUIStyle.font(21))
                    .foregroundStyle(AgentUIStyle.soft)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 22))
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(specs) { spec in
                        NavigationLink(value: AgentStudioUI.Route.agent(spec.id)) {
                            AgentStudioUI.Card(spec: spec, inCharge: library.focused?.id == spec.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// An agent is still in charge (Siri, or a chat left open elsewhere): say so, and offer the way back.
    private func inChargeBanner(_ spec: AgentSpec) -> some View {
        HStack(spacing: 12) {
            AgentStudioUI.Badge(spec: spec, size: 48)
            Text("\(spec.name) is in charge")
                .font(AgentUIStyle.font(21, .semibold))
                .foregroundStyle(AgentUIStyle.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Button { AgentStudioUI.backToKairos() } label: {
                Text("Back to Kairos")
                    .font(AgentUIStyle.font(19, .bold))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 52)
                    .background(AgentUIStyle.green, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(AgentUIStyle.amberBack, in: RoundedRectangle(cornerRadius: 22))
        .accessibilityElement(children: .contain)
    }

    // MARK: - Import

    /// Paste an agent someone sent (PasteButton: no "Allow Paste?" prompt) or open the .json file.
    private struct ImportSheet: View {
        var onImported: (AgentSpec) -> Void

        @Environment(\.dismiss) private var dismiss
        @State private var picking = false
        @State private var problem: String?

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Spacer()
                        Button("Cancel") { dismiss() }
                            .font(AgentUIStyle.font(20, .semibold))
                            .foregroundStyle(AgentUIStyle.ink)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 52)
                            .background(.white, in: Capsule())
                            .buttonStyle(.plain)
                    }
                    Text("Add an agent someone sent you")
                        .font(AgentUIStyle.font(30, .bold))
                        .foregroundStyle(AgentUIStyle.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("If they sent it in a message, press on it, tap Copy, then come back and tap Paste. If they sent a file, tap Open a file.")
                        .font(AgentUIStyle.font(21))
                        .foregroundStyle(AgentUIStyle.soft)
                        .fixedSize(horizontal: false, vertical: true)

                    PasteButton(payloadType: String.self) { strings in
                        let text = strings.first ?? ""
                        Task { @MainActor in importText(text) }
                    }
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .labelStyle(.titleAndIcon)
                    .tint(AgentUIStyle.green)
                    .frame(maxWidth: .infinity)
                    .accessibilityHint("Adds the agent you copied")

                    Button { picking = true } label: {
                        Label("Open a file", systemImage: "doc.fill")
                            .font(AgentUIStyle.font(24, .bold))
                            .frame(maxWidth: .infinity, minHeight: 72)
                            .background(.white, in: RoundedRectangle(cornerRadius: 22))
                            .foregroundStyle(AgentUIStyle.green)
                    }
                    .buttonStyle(.plain)

                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(AgentUIStyle.font(21, .medium))
                            .foregroundStyle(AgentUIStyle.ink)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AgentUIStyle.amberBack, in: RoundedRectangle(cornerRadius: 20))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("Nothing runs yet. You'll see exactly what it can do before you use it.")
                        .font(AgentUIStyle.font(19))
                        .foregroundStyle(AgentUIStyle.soft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            .background(AgentUIStyle.paper.ignoresSafeArea())
            .environment(\.colorScheme, .light)
            .fileImporter(isPresented: $picking, allowedContentTypes: [.json, .plainText],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    do { finish(try AgentStudioUI.importAgentFile(at: url)) }
                    catch { problem = AgentStudioUI.plainWords(error, fallback: AgentStudioUI.notAnAgent) }
                case .failure:
                    problem = "I couldn't open that file. Please try again."
                }
            }
        }

        private func importText(_ text: String) {
            do { finish(try AgentStudioUI.importAgentText(text)) }
            catch { problem = AgentStudioUI.plainWords(error, fallback: AgentStudioUI.notAnAgent) }
        }

        private func finish(_ spec: AgentSpec) {
            problem = nil
            dismiss()
            // Let the sheet go before the agent's page is pushed.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                onImported(spec)
            }
        }
    }
}

// MARK: - Shared pieces for the Studio screens

/// Everything the three Studio screens share. One namespace, so nothing clashes with the app's own types.
enum AgentStudioUI {

    /// Where the Studio's navigation can go.
    enum Route: Hashable {
        case agent(String)  // AgentSpec.id
        case newAgent
    }

    // MARK: Talking to an agent (focus mode)

    /// Puts this agent in charge. A different agent means a fresh conversation, so one agent's history
    /// never steers another.
    @MainActor
    static func startTalking(to spec: AgentSpec) {
        let library = AgentLibrary.shared
        // Always the library's own (vetted) copy, never the one a screen happens to hold.
        guard let saved = library.spec(id: spec.id) else { return }
        if library.focused?.id == saved.id { library.focused = saved; return }
        AgentVoice.shared.stopAll()
        if !KairosAgent.shared.working { KairosAgent.shared.reset() }
        library.focused = saved
    }

    /// Kairos takes over again if this agent was in charge.
    @MainActor
    static func stopTalking(to id: String) {
        guard AgentLibrary.shared.focused?.id == id else { return }
        backToKairos()
    }

    @MainActor
    static func backToKairos() {
        let library = AgentLibrary.shared
        guard library.focused != nil else { return }
        AgentVoice.shared.stopAll()
        library.focused = nil
        if !KairosAgent.shared.working { KairosAgent.shared.reset() }
    }

    /// The agent's chat: the normal Kairos screen with a banner saying who is in charge.
    /// `firstPhrase` is sent (and the answer spoken) once the screen is up.
    struct ChatScreen: View {
        let agentID: String
        var firstPhrase: String? = nil
        var onClose: () -> Void

        @ObservedObject private var library = AgentLibrary.shared
        @ObservedObject private var agent = KairosAgent.shared
        @State private var sentFirst = false

        private var spec: AgentSpec? {
            library.agents.first { $0.id == agentID } ?? (library.focused?.id == agentID ? library.focused : nil)
        }
        private var inCharge: Bool { library.focused?.id == agentID }

        var body: some View {
            VStack(spacing: 0) {
                if let spec { banner(spec) }
                AgentHomeView(onClose: onClose)
            }
            .background(AgentUIStyle.paper.ignoresSafeArea())
            .environment(\.colorScheme, .light)
            .task {
                guard !sentFirst else { return }
                sentFirst = true
                if let firstPhrase, !firstPhrase.isEmpty { AgentVoice.shared.ask(firstPhrase) }
            }
        }

        private func banner(_ spec: AgentSpec) -> some View {
            let back = AgentStudioUI.color(spec.colorHex)
            let fore = AgentStudioUI.textColour(on: spec.colorHex)
            return HStack(spacing: 12) {
                if inCharge {
                    AgentStudioUI.Badge(spec: spec, size: 46, inverted: true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Talking to")
                            .font(AgentUIStyle.font(17, .medium))
                            .opacity(0.9)
                        Text(spec.name)
                            .font(AgentUIStyle.font(23, .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: 4)
                    Button { AgentStudioUI.backToKairos() } label: {
                        Text("Back to Kairos")
                            .font(AgentUIStyle.font(19, .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 52)
                            .background(.white, in: Capsule())
                            .foregroundStyle(AgentUIStyle.ink)
                    }
                    .buttonStyle(.plain)
                    .disabled(agent.working)
                    .accessibilityHint("Kairos takes over again, with all its helpers")
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 24, weight: .semibold))
                    Text("Talking to Kairos")
                        .font(AgentUIStyle.font(22, .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    Button { AgentStudioUI.startTalking(to: spec) } label: {
                        Text("Back to \(spec.name)")
                            .font(AgentUIStyle.font(19, .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 52)
                            .background(.white, in: Capsule())
                            .foregroundStyle(AgentUIStyle.ink)
                    }
                    .buttonStyle(.plain)
                    .disabled(agent.working)
                }
            }
            .foregroundStyle(inCharge ? fore : .white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background((inCharge ? back : AgentUIStyle.green).ignoresSafeArea(edges: .top))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(inCharge ? "Talking to \(spec.name)" : "Talking to Kairos")
        }
    }

    // MARK: Cards and badges

    /// The agent's icon in its colour.
    struct Badge: View {
        let spec: AgentSpec
        var size: CGFloat = 60
        /// White disc with the colour inside, for use on a coloured background.
        var inverted = false

        var body: some View {
            let colour = AgentStudioUI.color(spec.colorHex)
            Image(systemName: AgentStudioUI.symbol(spec.icon))
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(inverted ? colour : AgentStudioUI.textColour(on: spec.colorHex))
                .frame(width: size, height: size)
                .background(inverted ? Color.white : colour, in: Circle())
                .accessibilityHidden(true)
        }
    }

    /// One big card in the grid: icon, name, tagline.
    struct Card: View {
        let spec: AgentSpec
        var inCharge = false

        var body: some View {
            let colour = AgentStudioUI.color(spec.colorHex)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Badge(spec: spec, size: 62)
                    Spacer(minLength: 0)
                    if inCharge {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(AgentUIStyle.green)
                    }
                }
                Text(spec.name)
                    .font(AgentUIStyle.font(24, .bold))
                    .foregroundStyle(AgentUIStyle.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                Text(spec.tagline)
                    .font(AgentUIStyle.font(19, .medium))
                    .foregroundStyle(AgentUIStyle.soft)
                    .lineLimit(4)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
            .background(.white, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(colour.opacity(inCharge ? 0.9 : 0.35),
                                                                lineWidth: inCharge ? 3 : 2))
            .shadow(color: .black.opacity(0.07), radius: 10, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 24))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(spec.name). \(spec.tagline)\(inCharge ? ". In charge now." : "")")
            .accessibilityHint("Opens \(spec.name)")
            .accessibilityAddTraits(.isButton)
        }
    }

    // MARK: Colours and icons

    /// "#2E7060" → (r, g, b) in 0…1. Nil if it isn't a colour.
    static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    /// The agent's colour, or the app's green if the colour is broken.
    static func color(_ hex: String) -> Color {
        guard let c = rgb(hex) else { return AgentUIStyle.green }
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    /// White on dark colours, near-black on light ones, so words on the agent's colour can be read.
    static func textColour(on hex: String) -> Color {
        guard let c = rgb(hex) else { return .white }
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
        // Contrast against white vs against ink (luminance ≈ 0.01).
        return (1.05 / (luminance + 0.05)) >= ((luminance + 0.05) / 0.06) ? .white : AgentUIStyle.ink
    }

    /// The SF Symbol if this phone has it, else sparkles (agents someone sent may name one we don't have).
    static func symbol(_ name: String) -> String {
        #if canImport(UIKit)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && UIImage(systemName: trimmed) != nil ? trimmed : "sparkles"
        #else
        return name.isEmpty ? "sparkles" : name
        #endif
    }

    // MARK: Tools in plain words

    /// What a tool lets an agent do, said the way a person would say it, with an icon.
    static func toolWords(_ name: String) -> (text: String, icon: String) {
        switch name {
        case "set_alarm": return ("Set alarms", "alarm.fill")
        case "set_timer": return ("Start timers", "timer")
        case "create_reminder": return ("Make reminders", "checklist")
        case "add_calendar_event": return ("Put things in your calendar", "calendar.badge.plus")
        case "get_calendar_events": return ("Tell you what's on your calendar", "calendar")
        case "find_contact": return ("Find people in your contacts", "person.crop.circle")
        case "call_contact": return ("Ring your people (you say yes first)", "phone.fill")
        case "message_contact": return ("Write texts for you to send", "message.fill")
        case "remember_relation": return ("Remember who's who in your family", "person.2.fill")
        case "read_letter": return ("Read letters and bills from a photo", "doc.text.viewfinder")
        case "ask_letter": return ("Answer questions about a letter", "questionmark.bubble.fill")
        case "check_scam": return ("Check messages and calls for scams", "exclamationmark.shield.fill")
        case "call_159": return ("Ring 159 to reach your bank safely", "phone.arrow.up.right")
        case "prepare_payment": return ("Get a payment ready in your bank's app (you check it and pay)", "sterlingsign.circle.fill")
        case "money_question": return ("Answer questions about money", "sterlingsign.circle")
        case "what_time_and_date": return ("Tell you the time and date", "clock.fill")
        case "get_directions": return ("Give you directions", "map.fill")
        case "get_weather": return ("Tell you the weather", "cloud.sun.fill")
        case "open_phone_setting": return ("Open the right phone setting", "gearshape.fill")
        case "run_my_shortcut": return ("Run your own Shortcuts", "wand.and.stars")
        case "operate_app": return ("Use other apps for you while you watch", "hand.tap.fill")
        case "read_screen": return ("Read out what's on your screen", "text.viewfinder")
        case "create_routine": return ("Make routines: several jobs in one go", "list.bullet.rectangle")
        case "run_routine": return ("Run your routines", "play.circle.fill")
        case "save_last_as_routine": return ("Save what it just did as a routine", "square.and.arrow.down.fill")
        case "list_routines": return ("Tell you which routines you have", "list.bullet")
        case "delete_routine": return ("Remove a routine you don't want", "trash")
        case "create_agent": return ("Make new agents", "sparkles")
        default:
            // "remember_fact" → "Remember fact"
            let words = name.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
            let text = words.isEmpty ? "A helper tool" : words.prefix(1).uppercased() + words.dropFirst()
            return (text, "gearshape.2.fill")
        }
    }

    /// Every tool an agent could be given: the runner's catalog plus every specialist's tools (unfiltered by
    /// focus mode), plus any extra names, without repeats, in a stable order.
    @MainActor
    static func allToolNames(including extra: [String] = []) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        let catalog = AgentHooks.runner?.toolCatalog.map(\.name) ?? []
        let specialists = KairosAgent.shared.specialists.flatMap { $0.tools.map(\.name) }
        // The Studio's own tools are never an agent's to have (the library takes them out), so they aren't offered.
        let never = StudioToolNames.all.union(StudioToolNames.alwaysOn)
        for name in specialists + catalog + extra where !name.isEmpty && !seen.contains(name) && !never.contains(name) {
            seen.insert(name)
            names.append(name)
        }
        return names
    }

    /// True when the tool calls, texts or pays someone (the owner always approves those on a card).
    @MainActor
    static func asksFirst(_ name: String) -> Bool {
        if let risk = AgentHooks.runner?.toolCatalog.first(where: { $0.name == name })?.risk { return risk >= .reachesPerson }
        if let risk = KairosAgent.shared.lookup(name)?.tool.risk { return risk >= .reachesPerson }
        return false
    }

    // MARK: Import and export

    static let notAnAgent = "That doesn't look like a Kairos agent. Ask the person to send it to you again."
    static let largestFile = 512_000

    enum ImportProblem: LocalizedError {
        case empty, tooBig, unreadable
        var errorDescription: String? {
            switch self {
            case .empty: return "There's nothing copied just now. Copy the agent first, then tap Paste."
            case .tooBig: return "That's far too big to be a Kairos agent, so I left it alone."
            case .unreadable: return "I couldn't open that file. Please try again."
            }
        }
    }

    /// Pasted text may have words around the agent ("Here's my agent: {…}"): keep the JSON object only.
    static func jsonPart(of text: String) -> String {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return text }
        return String(text[start...end])
    }

    /// Adds an agent from pasted text. Throws with plain words when it isn't one.
    @MainActor
    static func importAgentText(_ text: String) throws -> AgentSpec {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportProblem.empty }
        let data = Data(jsonPart(of: trimmed).utf8)
        guard data.count <= largestFile else { throw ImportProblem.tooBig }
        return try AgentLibrary.shared.importJSON(data)
    }

    /// Adds an agent from a file (the file picker, or a .kairos-agent.json opened in Kairos from Messages,
    /// Mail or AirDrop: call this from the app's .onOpenURL).
    @MainActor
    static func importAgentFile(at url: URL) throws -> AgentSpec {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > largestFile {
            throw ImportProblem.tooBig
        }
        guard let data = try? Data(contentsOf: url) else { throw ImportProblem.unreadable }
        guard data.count <= largestFile else { throw ImportProblem.tooBig }
        return try AgentLibrary.shared.importJSON(data)
    }

    /// A file to share, in a temporary folder: "<name>.kairos-agent.json". What the agent remembers about
    /// the person is left out: those facts are theirs, not the agent's.
    @MainActor
    static func shareFile(for spec: AgentSpec) -> URL? {
        var clean = spec
        clean.memory = []
        let data = AgentLibrary.shared.exportJSON(clean)
        guard !data.isEmpty else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Kairos agents", isDirectory: true)
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        var base = spec.name.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "Agent" }
        let url = folder.appendingPathComponent(String(base.prefix(60)) + ".kairos-agent.json")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: Words

    /// The error's own plain words if it has them, else the fallback.
    static func plainWords(_ error: Error, fallback: String) -> String {
        if let words = (error as? LocalizedError)?.errorDescription, !words.isEmpty { return words }
        return fallback
    }

    static func clip(_ s: String, _ limit: Int) -> String {
        String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    /// "user-1a2b3c4d": the id for an agent the person makes or copies.
    static func newID() -> String {
        "user-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
    }
}
