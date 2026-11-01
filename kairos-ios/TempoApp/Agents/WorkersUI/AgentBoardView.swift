import SwiftUI
import UIKit

// The Agents board: every agent Kairos has sent off to do a job, like Claude Code's agent list, but big and
// plain for older eyes. One card per agent (newest first) with a status badge, the time it started, a live
// timer while it works, its last three steps with their times, and a Stop button (a Try again button once it has
// failed or finished without a source). A "New agent" box at the top asks Kairos to create one ("Create an agent
// to …"), and the card appears as soon as it starts.
//
// Reads only WorkerPool.shared (AgentsWIP7/Workers/WorkerRun.swift). Everything here is iOS 17 SwiftUI.

// MARK: - Look

/// The app's colours and rounded fonts (the same values as ContentView and AgentUIStyle), kept here so the board
/// doesn't depend on another screen's file.
enum AgentBoardStyle {
    static let paper = Color(red: 0.96, green: 0.95, blue: 0.92)
    static let green = Color(red: 0.18, green: 0.44, blue: 0.37)
    static let greenBack = Color(red: 0.88, green: 0.93, blue: 0.91)
    static let ink = Color(red: 0.11, green: 0.11, blue: 0.10)
    static let soft = Color(red: 0.25, green: 0.25, blue: 0.23)
    static let red = Color(red: 0.70, green: 0.20, blue: 0.15)
    static let redBack = Color(red: 0.98, green: 0.91, blue: 0.89)
    static let amber = Color(red: 0.6, green: 0.35, blue: 0.0)
    static let amberBack = Color(red: 1.0, green: 0.95, blue: 0.84)
    static let grey = Color(red: 0.47, green: 0.47, blue: 0.45)
    static let mist = Color(red: 0.85, green: 0.85, blue: 0.82)

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Times and timers: every digit the same width, so a ticking clock doesn't wobble.
    static func digits(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

/// Words, colours and symbols for an agent's status and its steps.
enum AgentBoardLook {
    static func word(_ status: WorkerStatus) -> String {
        switch status {
        case .queued: return "Waiting to start"
        case .running: return "Working…"
        case .done: return "Done"
        case .failed: return "Didn't finish"
        case .stopped: return "Stopped"
        }
    }

    /// The word on the finished line: "Done 03:59:02 · 0:50 · 7 steps".
    static func endWord(_ status: WorkerStatus) -> String {
        switch status {
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        default: return "Done"
        }
    }

    static func colour(_ status: WorkerStatus) -> Color {
        switch status {
        case .queued: return AgentBoardStyle.amber
        case .running, .done: return AgentBoardStyle.green
        case .failed: return AgentBoardStyle.red
        case .stopped: return AgentBoardStyle.grey
        }
    }

    static func symbol(_ status: WorkerStatus) -> String {
        switch status {
        case .queued: return "hourglass"
        case .running: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark"
        case .failed: return "xmark"
        case .stopped: return "stop.fill"
        }
    }

    static func isFinished(_ status: WorkerStatus) -> Bool {
        status == .done || status == .failed || status == .stopped
    }

    static func isActive(_ status: WorkerStatus) -> Bool {
        status == .running || status == .queued
    }

    static func stepSymbol(_ kind: String) -> String {
        switch kind.lowercased() {
        case "plan": return "list.bullet"
        case "search": return "magnifyingglass"
        case "read": return "doc.text"
        case "tool": return "gearshape"
        case "think": return "brain"
        case "result": return "checkmark"
        case "error": return "exclamationmark"
        default: return "circle.fill"
        }
    }

    static func stepWord(_ kind: String) -> String {
        switch kind.lowercased() {
        case "plan": return "Plan"
        case "search": return "Search"
        case "read": return "Reading"
        case "tool": return "Tool"
        case "think": return "Thinking"
        case "result": return "Result"
        case "error": return "Problem"
        default: return "Step"
        }
    }

    static func stepColour(_ kind: String) -> Color {
        switch kind.lowercased() {
        case "error": return AgentBoardStyle.red
        case "result": return AgentBoardStyle.green
        case "think", "plan": return AgentBoardStyle.amber
        default: return AgentBoardStyle.green
        }
    }

    /// The agent's own SF Symbol, or a sparkle when the name it was given isn't a real symbol.
    @MainActor
    static func icon(_ name: String) -> String {
        !name.isEmpty && UIImage(systemName: name) != nil ? name : "sparkles"
    }

    /// "Reading the PDF" → "reading the PDF" (but "PDF found" stays as it is).
    static func lowerFirst(_ text: String) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        let second = text.dropFirst().first
        if let second, second.isUppercase { return text }
        return first.lowercased() + text.dropFirst()
    }

    /// Adds "…" unless the line already ends in punctuation.
    static func ongoing(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".…!?:".contains(last) ? trimmed : trimmed + "…"
    }
}

/// Clock times and durations, all in the same plain form: 03:58:12 and 0:41.
enum AgentBoardTime {
    /// "03:58:12", 24-hour, the phone's own time zone.
    static func clock(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// "0:41", "12:05", "1:02:03".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// For reading aloud: "50 seconds", "2 minutes and 5 seconds", "about 12 minutes".
    static func spoken(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return s == 1 ? "1 second" : "\(s) seconds" }
        let m = s / 60, rest = s % 60
        let minutes = m == 1 ? "1 minute" : "\(m) minutes"
        if m >= 10 || rest == 0 { return m >= 10 ? "about \(minutes)" : minutes }
        return "\(minutes) and \(rest == 1 ? "1 second" : "\(rest) seconds")"
    }

    static func steps(_ n: Int) -> String { n == 1 ? "1 step" : "\(n) steps" }

    /// When the agent started work (or, if it hasn't yet, when it was asked for).
    static func began(_ run: WorkerRun) -> Date { run.startedAt ?? run.createdAt }

    /// When it stopped working; nil while it is still going.
    static func ended(_ run: WorkerRun) -> Date? {
        guard AgentBoardLook.isFinished(run.status) else { return nil }
        return run.finishedAt ?? run.steps.last?.at ?? began(run)
    }

    /// How long it has been working (live while running, fixed once finished).
    static func elapsed(_ run: WorkerRun, now: Date = Date()) -> TimeInterval {
        if run.status == .queued { return 0 }
        return max(0, (ended(run) ?? now).timeIntervalSince(began(run)))
    }
}

// MARK: - Asking Kairos

/// How the board talks to Kairos. By default it calls KairosAgent.shared.handle and shows the answer; the agent
/// screen can route it through its voice instead, so the answer is spoken too:
///     AgentBoardAsk.via = { await AgentVoice.shared.askAndSpeak($0).say }
@MainActor
enum AgentBoardAsk {
    static var via: ((String) async -> String)?
    /// If Kairos answers without starting an agent (no Gemini key, or it made a saved helper instead),
    /// start one straight from the board so the person always sees it working.
    static var spawnIfKairosDidnt = true

    /// One request to Kairos, after any request already running has finished (Kairos does one at a time).
    static func send(_ words: String) async -> String {
        if let via { return await via(words) }
        var waited = 0
        while KairosAgent.shared.working, waited < 150 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            waited += 1
        }
        return await KairosAgent.shared.handle(words, source: .app).say
    }

    /// "+ New agent": asks Kairos to create an agent for this job. The card appears on the board as it starts.
    static func createAgent(_ job: String) async -> String {
        let job = cleaned(job)
        guard !job.isEmpty else { return "" }
        let before = Set(WorkerPool.shared.runs.map(\.id))
        // By id, not by count: Kairos keeps only its last 200 lines, so a count stops seeing new ones.
        let linesBefore = Set(KairosAgent.shared.lines.map(\.id))
        let say = await send("Create an agent to " + job)
        guard spawnIfKairosDidnt else { return say }
        // Give a tool that starts its agent a moment later the chance to show up first.
        if !startedOne(since: before) { try? await Task.sleep(nanoseconds: 600_000_000) }
        guard !startedOne(since: before) else { return say }
        // Kairos (or its safety gate) said no: respect that rather than going round it.
        if KairosAgent.shared.lines.contains(where: { !linesBefore.contains($0.id) && $0.kind == .refused }) { return say }
        // No name or icon: the pool picks them from the job ("Paper Reader", "News Scout"…).
        let run = WorkerPool.shared.spawn(name: "", goal: job, icon: nil)
        let started = "I've started \(run.name.isEmpty ? "an agent" : run.name) on it. You can watch it working here."
        return say.isEmpty ? started : say + "\n\n" + started
    }

    private static func startedOne(since before: Set<UUID>) -> Bool {
        WorkerPool.shared.runs.contains { !before.contains($0.id) }
    }

    /// "Create an agent to Find the paper" → "find the paper"; leaves "BBC …" alone.
    static func cleaned(_ job: String) -> String {
        var text = job.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        for lead in ["please create an agent to ", "create an agent to ", "make an agent to ", "make me an agent to ",
                     "start an agent to ", "an agent to ", "please "] {
            if text.lowercased().hasPrefix(lead) { text = String(text.dropFirst(lead.count)) }
        }
        return AgentBoardLook.lowerFirst(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Which agent the board is showing in detail.
struct AgentBoardRoute: Hashable {
    let id: UUID
}

// MARK: - The board

struct AgentBoardView: View {
    /// When the board is shown over another screen, this closes it (a Close button appears either way).
    var onClose: (() -> Void)? = nil
    /// Open straight onto one agent's page (the "✓ Paper Reader finished" banner).
    var openRun: UUID? = nil

    @ObservedObject private var pool = WorkerPool.shared
    @ObservedObject private var kairos = KairosAgent.shared
    @Environment(\.dismiss) private var dismiss
    @State private var path: [AgentBoardRoute] = []
    @State private var job = ""
    @State private var sending = false
    @State private var reply: String?
    @State private var confirmClear = false
    @State private var openedFirst = false
    @FocusState private var jobFocused: Bool

    static let examples: [(text: String, icon: String)] = [
        ("Find the research paper ‘Attention Is All You Need’, read it and tell me the results", "doc.text.magnifyingglass"),
        ("Find out what UK help exists for older people’s energy bills", "sterlingsign.circle.fill"),
        ("Read today’s BBC News front page and summarise it", "newspaper.fill"),
    ]

    var body: some View {
        ZStack {
            NavigationStack(path: $path) {
                board
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationDestination(for: AgentBoardRoute.self) { route in
                        WorkerRunDetailView(runID: route.id)
                    }
            }

            // Kairos's Yes / No card must be seen even though the board covers the agent screen.
            if let card = kairos.confirmation {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                        .accessibilityHidden(true)
                    AgentConfirmCard(card: card).id(card.id)
                }
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .environment(\.colorScheme, .light)
        .interactiveDismissDisabled(kairos.confirmation != nil)
        .animation(.easeOut(duration: 0.2), value: kairos.confirmation?.id)
        .onAppear {
            guard !openedFirst else { return }
            openedFirst = true
            if let openRun, pool.runs.contains(where: { $0.id == openRun }) { path = [AgentBoardRoute(id: openRun)] }
        }
    }

    private var board: some View {
        ZStack {
            AgentBoardStyle.paper.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    newAgentBox
                    if let reply { replyBubble(reply) }
                    if pool.runs.isEmpty {
                        emptyState
                    } else {
                        ForEach(pool.runs) { run in
                            AgentBoardCard(run: run) { path.append(AgentBoardRoute(id: run.id)) }
                        }
                        if pool.runs.contains(where: { AgentBoardLook.isFinished($0.status) }) { clearButton }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .confirmationDialog("Clear the finished agents?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear finished", role: .destructive) { pool.clearFinished() }
            Button("Keep them", role: .cancel) {}
        } message: {
            Text("Their results will be taken off this list. Agents that are still working carry on.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Text("Agents")
                    .font(AgentBoardStyle.font(36, .bold))
                    .foregroundStyle(AgentBoardStyle.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button { close() } label: {
                    Text("Close")
                        .font(AgentBoardStyle.font(19, .semibold))
                        .padding(.horizontal, 16)
                        .frame(minHeight: 52)
                        .background(.white, in: Capsule())
                        .foregroundStyle(AgentBoardStyle.ink)
                }
                .buttonStyle(.plain)
            }
            Text(countsLine)
                .font(AgentBoardStyle.font(20, .semibold).monospacedDigit())
                .foregroundStyle(AgentBoardStyle.soft)
                .accessibilityAddTraits(.updatesFrequently)
        }
        .padding(.top, 10)
    }

    /// "2 working · 3 done · 1 failed" (waiting and stopped only when there are some).
    private var countsLine: String {
        guard !pool.runs.isEmpty else { return "Helpers that go off and do a job for you." }
        func count(_ s: WorkerStatus) -> Int { pool.runs.filter { $0.status == s }.count }
        var parts = ["\(count(.running)) working"]
        if count(.queued) > 0 { parts.append("\(count(.queued)) waiting") }
        parts.append("\(count(.done)) done")
        if count(.failed) > 0 { parts.append("\(count(.failed)) failed") }
        if count(.stopped) > 0 { parts.append("\(count(.stopped)) stopped") }
        return parts.joined(separator: " · ")
    }

    // MARK: New agent

    private var jobWords: String { job.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var newAgentBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("New agent", systemImage: "plus.circle.fill")
                .font(AgentBoardStyle.font(24, .bold))
                .foregroundStyle(AgentBoardStyle.green)
                .accessibilityAddTraits(.isHeader)

            TextField("What should your agent do?", text: $job, axis: .vertical)
                .font(AgentBoardStyle.font(22))
                .foregroundStyle(AgentBoardStyle.ink)
                .lineLimit(1...5)
                .padding(14)
                .background(AgentBoardStyle.paper, in: RoundedRectangle(cornerRadius: 16))
                .focused($jobFocused)
                .submitLabel(.go)
                .disabled(sending)
                .onChange(of: job) { _, new in
                    // The Go key in a growing text box types a new line: treat it as Start.
                    if new.contains("\n") {
                        job = new.replacingOccurrences(of: "\n", with: " ")
                        start()
                    }
                }
                .accessibilityLabel("What should your agent do?")

            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                Text("You can tap the microphone on the keyboard and say it.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(AgentBoardStyle.font(16, .medium))
            .foregroundStyle(AgentBoardStyle.soft)
            .accessibilityElement(children: .combine)

            Button { start() } label: {
                HStack(spacing: 12) {
                    if sending {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(sending ? "Asking Kairos…" : "Start")
                }
                .font(AgentBoardStyle.font(26, .bold))
                .frame(maxWidth: .infinity, minHeight: 72)
                .background(AgentBoardStyle.green, in: RoundedRectangle(cornerRadius: 20))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(jobWords.isEmpty || sending)
            .opacity(jobWords.isEmpty && !sending ? 0.45 : 1)
            .accessibilityLabel(sending ? "Asking Kairos" : "Start the agent")
            .accessibilityHint("Kairos creates an agent for this job. You can watch it working on this screen.")
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.07), radius: 10, y: 4)
    }

    private func replyBubble(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Kairos")
                    .font(AgentBoardStyle.font(16, .semibold))
                    .foregroundStyle(AgentBoardStyle.soft)
                Text(text)
                    .font(AgentBoardStyle.font(20))
                    .foregroundStyle(AgentBoardStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 4)
            Button { withAnimation { reply = nil } } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(AgentBoardStyle.mist)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide Kairos's answer")
        }
        .padding(14)
        .background(AgentBoardStyle.greenBack, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("No agents yet")
                .font(AgentBoardStyle.font(26, .bold))
                .foregroundStyle(AgentBoardStyle.ink)
            Text("An agent is a helper that goes off and does one job for you — like finding a research paper, reading it and telling you what it found. You can watch every step here, with the time it happened, and see the moment it's done.")
                .font(AgentBoardStyle.font(20))
                .foregroundStyle(AgentBoardStyle.soft)
                .fixedSize(horizontal: false, vertical: true)
            Text("Tap one to try it:")
                .font(AgentBoardStyle.font(20, .semibold))
                .foregroundStyle(AgentBoardStyle.ink)
                .padding(.top, 4)
            ForEach(Self.examples, id: \.text) { example in
                Button { start(example.text) } label: {
                    HStack(alignment: .center, spacing: 14) {
                        Image(systemName: example.icon)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(AgentBoardStyle.green)
                            .frame(width: 34)
                        Text("“\(example.text)”")
                            .font(AgentBoardStyle.font(21, .medium))
                            .foregroundStyle(AgentBoardStyle.ink)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(AgentBoardStyle.green)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white, in: RoundedRectangle(cornerRadius: 18))
                    .contentShape(RoundedRectangle(cornerRadius: 18))
                }
                .buttonStyle(.plain)
                .disabled(sending)
                .accessibilityLabel(example.text)
                .accessibilityHint("Starts an agent for this job")
            }
        }
        .padding(.top, 6)
    }

    private var clearButton: some View {
        Button { confirmClear = true } label: {
            Label("Clear finished", systemImage: "trash")
                .font(AgentBoardStyle.font(20, .semibold))
                .frame(maxWidth: .infinity, minHeight: 60)
                .background(.white, in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(AgentBoardStyle.soft)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .accessibilityHint("Takes the agents that have finished off this list")
    }

    // MARK: Actions

    private func start(_ text: String? = nil) {
        let words = (text ?? job).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, !sending else { return }
        job = words
        jobFocused = false
        sending = true
        withAnimation { reply = nil }
        Task { @MainActor in
            let say = await AgentBoardAsk.createAgent(words)
            sending = false
            job = ""
            withAnimation { reply = say.isEmpty ? nil : say }
        }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
}

// MARK: - One agent's card

struct AgentBoardCard: View {
    let run: WorkerRun
    let onOpen: () -> Void

    private var colour: Color { AgentBoardLook.colour(run.status) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onOpen) { summary }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Shows everything \(run.name) did")

            if AgentBoardLook.isActive(run.status) {
                Button { WorkerPool.shared.stop(run.id) } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(AgentBoardStyle.font(21, .bold))
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .background(AgentBoardStyle.redBack, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(AgentBoardStyle.red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop \(run.name)")
            }

            // A run that failed (or found no sources) can be sent off again with the same job, in one tap.
            if WorkerPool.shared.canRetry(run) {
                Button { WorkerPool.shared.retry(run.id) } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .font(AgentBoardStyle.font(21, .bold))
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .background(AgentBoardStyle.greenBack, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(AgentBoardStyle.green)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Try \(run.name) again")
                .accessibilityHint("Starts the same job again as a new agent at the top of this list")
            }
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(colour.opacity(run.status == .running ? 0.55 : 0.3), lineWidth: 2))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                AgentBoardBadge(status: run.status)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Image(systemName: AgentBoardLook.icon(run.icon))
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(AgentBoardStyle.green)
                        Text(run.name)
                            .font(AgentBoardStyle.font(24, .bold))
                            .foregroundStyle(AgentBoardStyle.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Text(AgentBoardLook.word(run.status))
                        .font(AgentBoardStyle.font(18, .semibold))
                        .foregroundStyle(colour)
                }
                Spacer(minLength: 4)
            }

            Text(run.goal)
                .font(AgentBoardStyle.font(20))
                .foregroundStyle(AgentBoardStyle.soft)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            timeLine

            if !run.steps.isEmpty {
                Divider()
                recentSteps
            }

            if run.status == .done, let found = run.result?.summary, !found.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What it found")
                        .font(AgentBoardStyle.font(16, .semibold))
                        .foregroundStyle(AgentBoardStyle.green)
                    Text(found)
                        .font(AgentBoardStyle.font(19))
                        .foregroundStyle(AgentBoardStyle.ink)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AgentBoardStyle.greenBack, in: RoundedRectangle(cornerRadius: 14))
            }

            if run.status == .failed, let error = run.error, !error.isEmpty {
                Text(error)
                    .font(AgentBoardStyle.font(18, .medium))
                    .foregroundStyle(AgentBoardStyle.red)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }

            HStack(spacing: 6) {
                Spacer()
                Text(run.status == .done ? "See the result" : "See every step")
                    .font(AgentBoardStyle.font(18, .semibold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .bold))
            }
            .foregroundStyle(AgentBoardStyle.green)
        }
        .contentShape(Rectangle())
    }

    /// "Started 03:58:12" with a live timer, or "Done 03:59:02 · 0:50 · 7 steps".
    @ViewBuilder
    private var timeLine: some View {
        let began = AgentBoardTime.began(run)
        switch run.status {
        case .running:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(alignment: .firstTextBaseline) {
                    Text("Started \(AgentBoardTime.clock(began))")
                        .font(AgentBoardStyle.digits(19))
                        .foregroundStyle(AgentBoardStyle.soft)
                    Spacer(minLength: 8)
                    Label(AgentBoardTime.duration(AgentBoardTime.elapsed(run, now: context.date)), systemImage: "timer")
                        .font(AgentBoardStyle.digits(26, .bold))
                        .foregroundStyle(AgentBoardStyle.green)
                        .accessibilityLabel("Working for \(AgentBoardTime.spoken(AgentBoardTime.elapsed(run, now: context.date)))")
                }
            }
        case .queued:
            Text("Asked at \(AgentBoardTime.clock(run.createdAt)) · waiting to start")
                .font(AgentBoardStyle.digits(19))
                .foregroundStyle(AgentBoardStyle.amber)
        case .done, .failed, .stopped:
            VStack(alignment: .leading, spacing: 2) {
                Text("Started \(AgentBoardTime.clock(began))")
                    .font(AgentBoardStyle.digits(19))
                    .foregroundStyle(AgentBoardStyle.soft)
                Text("\(AgentBoardLook.endWord(run.status)) \(AgentBoardTime.clock(AgentBoardTime.ended(run) ?? began)) · \(AgentBoardTime.duration(AgentBoardTime.elapsed(run))) · \(AgentBoardTime.steps(run.steps.count))")
                    .font(AgentBoardStyle.digits(19, .semibold))
                    .foregroundStyle(colour)
            }
        }
    }

    private var recentSteps: some View {
        let recent = Array(run.steps.suffix(3))
        let earlier = run.steps.count - recent.count
        return VStack(alignment: .leading, spacing: 8) {
            if earlier > 0 {
                Text(earlier == 1 ? "1 earlier step" : "\(earlier) earlier steps")
                    .font(AgentBoardStyle.font(16, .medium))
                    .foregroundStyle(AgentBoardStyle.grey)
            }
            ForEach(recent) { step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(AgentBoardTime.clock(step.at))
                        .font(AgentBoardStyle.digits(17))
                        .foregroundStyle(AgentBoardStyle.soft)
                    Image(systemName: AgentBoardLook.stepSymbol(step.kind))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AgentBoardLook.stepColour(step.kind))
                        .frame(width: 22)
                    Text(step.text)
                        .font(AgentBoardStyle.font(18))
                        .foregroundStyle(AgentBoardStyle.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("At \(AgentBoardTime.clock(step.at)): \(step.text)")
            }
        }
    }
}

// MARK: - Status badge

/// Spinner while working, a tick when done, a cross when it failed, a square when stopped, an hourglass while waiting.
struct AgentBoardBadge: View {
    let status: WorkerStatus
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            Circle()
                .fill(status == .running ? AgentBoardStyle.greenBack : AgentBoardLook.colour(status))
            if status == .running {
                ProgressView()
                    .tint(AgentBoardStyle.green)
                    .controlSize(size >= 44 ? .regular : .small)
            } else {
                Image(systemName: AgentBoardLook.symbol(status))
                    .font(.system(size: size * 0.44, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AgentBoardLook.word(status))
    }
}
