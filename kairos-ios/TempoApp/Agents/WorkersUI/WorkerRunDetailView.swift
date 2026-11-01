import SwiftUI
import AVFoundation

// One agent's page: what it was asked to do, when it started and finished, how long it took, and — once it's
// done — what it found, in big words at the top (summary, findings, more detail, and the web pages it used).
// Below that, every step it took with the time of each one. "Read it to me" reads the result in a British
// voice; "Ask about this" sends a question to Kairos; Share sends the whole report as text; Stop ends it; "Try
// again" (on a run that failed or found no sources) sends the same job off again as a new agent.

struct WorkerRunDetailView: View {
    let runID: UUID
    /// When shown on its own (not inside the board), this closes it. Inside the board, Back goes to the list.
    var onClose: (() -> Void)? = nil

    @ObservedObject private var pool = WorkerPool.shared
    @StateObject private var reader = AgentBoardReader()
    @Environment(\.dismiss) private var dismiss
    @State private var showDetails = false
    @State private var asking = false
    @State private var question = ""
    @State private var askBusy = false
    @State private var answer: String?
    /// The new run "Try again" started, when this page is shown on its own.
    @State private var retried: WorkerRun?
    @FocusState private var questionFocused: Bool

    init(runID: UUID, onClose: (() -> Void)? = nil) {
        self.runID = runID
        self.onClose = onClose
    }

    init(run: WorkerRun, onClose: (() -> Void)? = nil) {
        self.init(runID: run.id, onClose: onClose)
    }

    /// Always the live copy, so steps and the result appear as they happen.
    private var run: WorkerRun? { pool.runs.first { $0.id == runID } }

    var body: some View {
        ZStack {
            AgentBoardStyle.paper.ignoresSafeArea()
            if let run {
                page(run)
            } else {
                gone
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .environment(\.colorScheme, .light)
        .onDisappear { reader.stop() }
    }

    private func page(_ run: WorkerRun) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                backButton
                header(run)
                if run.status == .failed, let error = run.error, !error.isEmpty { problem(error) }
                if let result = run.result {
                    resultSection(run, result)
                } else if AgentBoardLook.isActive(run.status) {
                    stillWorking(run)
                }
                if let retried { retriedNote(retried) } else if pool.canRetry(run) { tryAgainButton(run) }
                actions(run)
                if asking { askBox(run) }
                if let answer { answerBubble(answer) }
                timeline(run)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: Top

    private var backButton: some View {
        Button { back() } label: {
            Label(onClose == nil ? "All agents" : "Close", systemImage: onClose == nil ? "chevron.left" : "xmark")
                .font(AgentBoardStyle.font(20, .semibold))
                .padding(.horizontal, 16)
                .frame(minHeight: 54)
                .background(.white, in: Capsule())
                .foregroundStyle(AgentBoardStyle.green)
        }
        .buttonStyle(.plain)
        .padding(.top, 10)
    }

    private func header(_ run: WorkerRun) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                AgentBoardBadge(status: run.status, size: 58)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Image(systemName: AgentBoardLook.icon(run.icon))
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(AgentBoardStyle.green)
                        Text(run.name)
                            .font(AgentBoardStyle.font(30, .bold))
                            .foregroundStyle(AgentBoardStyle.ink)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Text(AgentBoardLook.word(run.status))
                        .font(AgentBoardStyle.font(21, .semibold))
                        .foregroundStyle(AgentBoardLook.colour(run.status))
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Its job")
                    .font(AgentBoardStyle.font(16, .semibold))
                    .foregroundStyle(AgentBoardStyle.soft)
                Text(run.goal)
                    .font(AgentBoardStyle.font(21, .medium))
                    .foregroundStyle(AgentBoardStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Divider()

            if run.status == .running {
                TimelineView(.periodic(from: .now, by: 1)) { context in facts(run, now: context.date) }
            } else {
                facts(run, now: Date())
            }
        }
        .padding(18)
        .background(.white, in: RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
    }

    private func facts(_ run: WorkerRun, now: Date) -> some View {
        let began = AgentBoardTime.began(run)
        let took = AgentBoardTime.duration(AgentBoardTime.elapsed(run, now: now))
        return VStack(alignment: .leading, spacing: 8) {
            if run.status == .queued {
                fact("Asked at", AgentBoardTime.clock(run.createdAt))
                fact("Started", "Not yet")
            } else {
                fact("Started", AgentBoardTime.clock(began))
                if let ended = AgentBoardTime.ended(run) {
                    fact(run.status == .done ? "Finished" : AgentBoardLook.endWord(run.status), AgentBoardTime.clock(ended))
                    fact("Took", took)
                } else {
                    fact("Finished", "Still working")
                    fact("Working for", took, strong: true)
                }
            }
            fact("Steps", "\(run.steps.count)")
            fact("Calls to the AI", "\(run.modelCalls)")
        }
    }

    private func fact(_ label: String, _ value: String, strong: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(AgentBoardStyle.font(19))
                .foregroundStyle(AgentBoardStyle.soft)
            Spacer(minLength: 8)
            Text(value)
                .font(AgentBoardStyle.digits(strong ? 24 : 20, strong ? .bold : .semibold))
                .foregroundStyle(strong ? AgentBoardStyle.green : AgentBoardStyle.ink)
        }
        .accessibilityElement(children: .combine)
    }

    private func problem(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text("What went wrong")
                    .font(AgentBoardStyle.font(18, .bold))
                Text(error)
                    .font(AgentBoardStyle.font(20, .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(AgentBoardStyle.red)
        .padding(16)
        .background(AgentBoardStyle.redBack, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }

    private func stillWorking(_ run: WorkerRun) -> some View {
        HStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(AgentBoardStyle.green)
            Text(run.status == .queued
                 ? "\(run.name) is waiting to start. Its answer will appear here."
                 : "\(run.name) is still working. Its answer will appear here as soon as it's done.")
                .font(AgentBoardStyle.font(20, .medium))
                .foregroundStyle(AgentBoardStyle.soft)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// "Try again": the same job as a new agent. Inside the board it goes back to the list, where the new card is
    /// at the top, working; shown on its own, it says where to find it.
    private func tryAgainButton(_ run: WorkerRun) -> some View {
        Button {
            guard let next = pool.retry(run.id) else { return }
            reader.stop()
            if onClose == nil {
                dismiss()
            } else {
                withAnimation { retried = next }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.clockwise")
                Text("Try again")
            }
            .font(AgentBoardStyle.font(26, .bold))
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(AgentBoardStyle.green, in: RoundedRectangle(cornerRadius: 20))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Try \(run.name) again")
        .accessibilityHint("Starts the same job again as a new agent")
    }

    private func retriedNote(_ next: WorkerRun) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 26, weight: .semibold))
            Text("\(next.name) has started again. You'll find it at the top of the Agents board.")
                .font(AgentBoardStyle.font(20, .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(AgentBoardStyle.green)
        .padding(16)
        .background(AgentBoardStyle.greenBack, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }

    // MARK: Result

    private func resultSection(_ run: WorkerRun, _ result: WorkerResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(run.status == .done ? "What it found" : "What it found before it stopped", systemImage: "checkmark.seal.fill")
                .font(AgentBoardStyle.font(22, .bold))
                .foregroundStyle(AgentBoardStyle.green)
                .accessibilityAddTraits(.isHeader)

            if !result.summary.isEmpty {
                Text(result.summary)
                    .font(AgentBoardStyle.font(26, .medium))
                    .foregroundStyle(AgentBoardStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if !result.findings.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(result.findings.enumerated()), id: \.offset) { index, finding in
                        HStack(alignment: .top, spacing: 14) {
                            Text("\(index + 1)")
                                .font(AgentBoardStyle.digits(19, .bold))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(AgentBoardStyle.green, in: Circle())
                            Text(AgentBoardMarkdown.inline(finding))
                                .font(AgentBoardStyle.font(22))
                                .foregroundStyle(AgentBoardStyle.ink)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .background(AgentBoardStyle.paper, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            if !result.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { withAnimation(.easeOut(duration: 0.2)) { showDetails.toggle() } } label: {
                    HStack {
                        Text(showDetails ? "Hide the detail" : "Show more detail")
                            .font(AgentBoardStyle.font(21, .semibold))
                        Spacer()
                        Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                            .font(.system(size: 18, weight: .bold))
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 58)
                    .background(AgentBoardStyle.greenBack, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(AgentBoardStyle.green)
                }
                .buttonStyle(.plain)
                if showDetails {
                    AgentBoardMarkdown(text: result.details)
                        .padding(.horizontal, 4)
                        .transition(.opacity)
                }
            }

            if !result.sources.isEmpty { sources(result.sources) }
        }
        .padding(18)
        .background(.white, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(AgentBoardStyle.green.opacity(0.3), lineWidth: 2))
    }

    private func sources(_ list: [WorkerSource]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where it looked")
                .font(AgentBoardStyle.font(20, .bold))
                .foregroundStyle(AgentBoardStyle.ink)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(list.enumerated()), id: \.offset) { index, source in
                let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = HStack(alignment: .center, spacing: 12) {
                    Text("\(index + 1)")
                        .font(AgentBoardStyle.digits(17, .bold))
                        .foregroundStyle(AgentBoardStyle.green)
                        .frame(width: 30, height: 30)
                        .background(AgentBoardStyle.greenBack, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title.isEmpty ? "A web page" : title)
                            .font(AgentBoardStyle.font(20, .semibold))
                            .foregroundStyle(AgentBoardStyle.ink)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                        Text("Opens in your web browser")
                            .font(AgentBoardStyle.font(15))
                            .foregroundStyle(AgentBoardStyle.soft)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(AgentBoardStyle.green)
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                .background(AgentBoardStyle.paper, in: RoundedRectangle(cornerRadius: 14))

                if let url = URL(string: source.url), url.scheme?.hasPrefix("http") == true {
                    Link(destination: url) { label }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Source \(index + 1): \(title.isEmpty ? "a web page" : title)")
                        .accessibilityHint("Opens in your web browser")
                } else {
                    label.accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: Buttons

    private func actions(_ run: WorkerRun) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            Button { toggleReading(run) } label: {
                bigLabel(reader.speaking ? "Stop reading" : "Read it to me",
                         reader.speaking ? "stop.circle.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(.plain)
            .accessibilityHint("Reads what \(run.name) found out loud")

            Button {
                withAnimation(.easeOut(duration: 0.2)) { asking.toggle() }
                questionFocused = asking
            } label: {
                bigLabel("Ask about this", "questionmark.bubble.fill")
            }
            .buttonStyle(.plain)
            .accessibilityHint("Ask Kairos a question about what \(run.name) found")

            ShareLink(item: AgentBoardExport.markdown(run),
                      subject: Text(run.name),
                      message: Text("What \(run.name) found, from Kairos")) {
                bigLabel("Share", "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .accessibilityHint("Send this report to someone, or save it")

            if AgentBoardLook.isActive(run.status) {
                Button { pool.stop(run.id) } label: {
                    bigLabel("Stop", "stop.fill", colour: AgentBoardStyle.red, back: AgentBoardStyle.redBack)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop \(run.name)")
            }
        }
    }

    private func bigLabel(_ title: String, _ symbol: String,
                          colour: Color = AgentBoardStyle.green, back: Color = .white) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
            Text(title)
                .font(AgentBoardStyle.font(19, .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 84)
        .background(back, in: RoundedRectangle(cornerRadius: 18))
        .foregroundStyle(colour)
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 18))
    }

    private var questionWords: String { question.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func askBox(_ run: WorkerRun) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What would you like to know about it?")
                .font(AgentBoardStyle.font(20, .semibold))
                .foregroundStyle(AgentBoardStyle.ink)
            TextField("For example: what was the main result?", text: $question, axis: .vertical)
                .font(AgentBoardStyle.font(22))
                .foregroundStyle(AgentBoardStyle.ink)
                .lineLimit(1...4)
                .padding(14)
                .background(AgentBoardStyle.paper, in: RoundedRectangle(cornerRadius: 16))
                .focused($questionFocused)
                .submitLabel(.send)
                .disabled(askBusy)
                .onChange(of: question) { _, new in
                    if new.contains("\n") {
                        question = new.replacingOccurrences(of: "\n", with: " ")
                        ask(run)
                    }
                }
            Button { ask(run) } label: {
                HStack(spacing: 10) {
                    if askBusy { ProgressView().tint(.white) } else { Image(systemName: "paperplane.fill") }
                    Text(askBusy ? "Asking Kairos…" : "Ask")
                }
                .font(AgentBoardStyle.font(24, .bold))
                .frame(maxWidth: .infinity, minHeight: 66)
                .background(AgentBoardStyle.green, in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(questionWords.isEmpty || askBusy)
            .opacity(questionWords.isEmpty && !askBusy ? 0.45 : 1)
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 22))
        .transition(.opacity)
    }

    private func answerBubble(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Kairos")
                    .font(AgentBoardStyle.font(16, .semibold))
                    .foregroundStyle(AgentBoardStyle.soft)
                Spacer()
                Button { reader.speaking ? reader.stop() : reader.read(AgentBoardExport.speakable(text)) } label: {
                    Image(systemName: reader.speaking ? "stop.circle.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(AgentBoardStyle.green)
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(reader.speaking ? "Stop reading" : "Read Kairos's answer out loud")
            }
            Text(text)
                .font(AgentBoardStyle.font(22))
                .foregroundStyle(AgentBoardStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(16)
        .background(AgentBoardStyle.greenBack, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: Timeline

    private func timeline(_ run: WorkerRun) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Every step, with its time")
                .font(AgentBoardStyle.font(24, .bold))
                .foregroundStyle(AgentBoardStyle.ink)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            if run.steps.isEmpty && !AgentBoardLook.isActive(run.status) {
                Text("No steps were recorded.")
                    .font(AgentBoardStyle.font(19))
                    .foregroundStyle(AgentBoardStyle.soft)
            }
            ForEach(Array(run.steps.enumerated()), id: \.element.id) { index, step in
                stepRow(step, joinsNext: index < run.steps.count - 1 || AgentBoardLook.isActive(run.status))
            }
            if AgentBoardLook.isActive(run.status) { liveRow(run) }
        }
        .padding(18)
        .background(.white, in: RoundedRectangle(cornerRadius: 24))
    }

    private static let timeColumn: CGFloat = 92
    private static let iconSize: CGFloat = 36
    private static let rowGap: CGFloat = 12

    private func stepRow(_ step: WorkerStep, joinsNext: Bool) -> some View {
        let colour = AgentBoardLook.stepColour(step.kind)
        return HStack(alignment: .top, spacing: Self.rowGap) {
            Text(AgentBoardTime.clock(step.at))
                .font(AgentBoardStyle.digits(18))
                .foregroundStyle(AgentBoardStyle.soft)
                .frame(width: Self.timeColumn, alignment: .leading)
                .padding(.top, 7)
            Image(systemName: AgentBoardLook.stepSymbol(step.kind))
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(colour)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .background(colour.opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(AgentBoardLook.stepWord(step.kind))
                    .font(AgentBoardStyle.font(15, .semibold))
                    .foregroundStyle(colour)
                Text(step.text)
                    .font(AgentBoardStyle.font(19))
                    .foregroundStyle(AgentBoardStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .background(alignment: .topLeading) {
            if joinsNext {
                // The thin line joining this step's circle to the next one.
                Rectangle()
                    .fill(AgentBoardStyle.mist)
                    .frame(width: 3)
                    .padding(.top, 8 + Self.iconSize + 2)
                    .padding(.leading, Self.timeColumn + Self.rowGap + Self.iconSize / 2 - 1.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("At \(AgentBoardTime.clock(step.at)), \(AgentBoardLook.stepWord(step.kind)): \(step.text)")
    }

    private func liveRow(_ run: WorkerRun) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(alignment: .center, spacing: Self.rowGap) {
                Text(AgentBoardTime.clock(context.date))
                    .font(AgentBoardStyle.digits(18))
                    .foregroundStyle(AgentBoardStyle.green)
                    .frame(width: Self.timeColumn, alignment: .leading)
                ProgressView()
                    .tint(AgentBoardStyle.green)
                    .frame(width: Self.iconSize, height: Self.iconSize)
                Text(run.status == .queued ? "Waiting to start…"
                     : "Working on it · \(AgentBoardTime.duration(AgentBoardTime.elapsed(run, now: context.date)))")
                    .font(AgentBoardStyle.digits(19, .semibold))
                    .foregroundStyle(AgentBoardStyle.green)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(run.status == .queued ? "Waiting to start" : "Still working")
    }

    // MARK: Empty and actions

    private var gone: some View {
        VStack(spacing: 18) {
            backButton
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(AgentBoardStyle.grey)
            Text("This agent has been cleared from the list.")
                .font(AgentBoardStyle.font(24, .semibold))
                .foregroundStyle(AgentBoardStyle.ink)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggleReading(_ run: WorkerRun) {
        if reader.speaking { reader.stop() } else { reader.read(AgentBoardExport.spoken(run)) }
    }

    private func ask(_ run: WorkerRun) {
        let words = questionWords
        guard !words.isEmpty, !askBusy else { return }
        questionFocused = false
        askBusy = true
        withAnimation { answer = nil }
        Task { @MainActor in
            let say = await AgentBoardAsk.send("About \(run.name)'s result: " + words)
            askBusy = false
            question = ""
            withAnimation { answer = say.isEmpty ? nil : say }
        }
    }

    private func back() {
        reader.stop()
        if let onClose { onClose() } else { dismiss() }
    }
}

// MARK: - Simple markdown

/// The result's longer write-up: headings, bullet points, numbered points and paragraphs, with bold, italics
/// and links inside a line. Enough for what the agents write, nothing clever.
struct AgentBoardMarkdown: View {
    let text: String
    var size: CGFloat = 20

    private enum Block {
        case heading(String)
        case bullet(String)
        case numbered(String, String)
        case paragraph(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let words):
                    Text(Self.inline(words))
                        .font(AgentBoardStyle.font(size + 2, .bold))
                        .foregroundStyle(AgentBoardStyle.ink)
                        .padding(.top, 4)
                        .accessibilityAddTraits(.isHeader)
                case .bullet(let words):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("•").font(AgentBoardStyle.font(size, .bold)).foregroundStyle(AgentBoardStyle.green)
                        Text(Self.inline(words)).font(AgentBoardStyle.font(size)).foregroundStyle(AgentBoardStyle.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .numbered(let number, let words):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(number).font(AgentBoardStyle.digits(size, .bold)).foregroundStyle(AgentBoardStyle.green)
                        Text(Self.inline(words)).font(AgentBoardStyle.font(size)).foregroundStyle(AgentBoardStyle.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .paragraph(let words):
                    Text(Self.inline(words))
                        .font(AgentBoardStyle.font(size))
                        .foregroundStyle(AgentBoardStyle.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
        .tint(AgentBoardStyle.green)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                flush()
                out.append(.heading(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush()
                out.append(.bullet(String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }),
                      dot > line.startIndex, line[line.startIndex..<dot].allSatisfy(\.isNumber),
                      line.index(after: dot) < line.endIndex, line[line.index(after: dot)] == " " {
                flush()
                out.append(.numbered(String(line[line.startIndex...dot]),
                                     String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)))
            } else if line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) {
                flush()   // a horizontal rule
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return out
    }

    /// Bold, italics and links inside one line; plain text if the markdown doesn't parse.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// MARK: - Export and reading aloud

/// The report as markdown (for Share) and as plain sentences (for "Read it to me").
enum AgentBoardExport {
    static func markdown(_ run: WorkerRun) -> String {
        var lines: [String] = ["# \(run.name)", "", "**Job:** \(run.goal)", ""]
        var status = ["**\(AgentBoardLook.word(run.status).replacingOccurrences(of: "…", with: ""))**"]
        if run.status != .queued { status.append("started \(AgentBoardTime.clock(AgentBoardTime.began(run)))") }
        if let ended = AgentBoardTime.ended(run) {
            status.append("finished \(AgentBoardTime.clock(ended))")
            status.append("took \(AgentBoardTime.duration(AgentBoardTime.elapsed(run)))")
        }
        status.append(AgentBoardTime.steps(run.steps.count))
        status.append(run.modelCalls == 1 ? "1 call to the AI" : "\(run.modelCalls) calls to the AI")
        lines.append(status.joined(separator: " · "))
        lines.append("")

        if let result = run.result {
            if !result.summary.isEmpty { lines += ["## Summary", "", result.summary, ""] }
            if !result.findings.isEmpty { lines += ["## What it found", ""] + result.findings.map { "- " + $0 } + [""] }
            let details = result.details.trimmingCharacters(in: .whitespacesAndNewlines)
            if !details.isEmpty { lines += ["## More detail", "", details, ""] }
            if !result.sources.isEmpty {
                lines += ["## Sources", ""]
                for (i, source) in result.sources.enumerated() {
                    let title = source.title.isEmpty ? "A web page" : source.title
                    lines.append("\(i + 1). [\(title)](\(source.url))")
                }
                lines.append("")
            }
        }
        if let error = run.error, !error.isEmpty { lines += ["## What went wrong", "", error, ""] }
        if !run.steps.isEmpty {
            lines += ["## Every step", ""]
            for step in run.steps {
                lines.append("- \(AgentBoardTime.clock(step.at)) · \(AgentBoardLook.stepWord(step.kind)) · \(step.text)")
            }
            lines.append("")
        }
        lines.append("_From Kairos, \(longDate(run.createdAt))_")
        return lines.joined(separator: "\n")
    }

    /// What "Read it to me" says.
    static func spoken(_ run: WorkerRun) -> String {
        var parts: [String] = []
        switch run.status {
        case .done:
            parts.append("\(run.name) has finished. It took \(AgentBoardTime.spoken(AgentBoardTime.elapsed(run))).")
        case .running:
            parts.append("\(run.name) is still working. It has taken \(AgentBoardTime.steps(run.steps.count)) so far.")
            if let last = run.steps.last { parts.append("Just now: \(last.text).") }
        case .queued:
            parts.append("\(run.name) is waiting to start.")
        case .failed:
            parts.append("\(run.name) couldn't finish.")
            if let error = run.error, !error.isEmpty { parts.append(error) }
        case .stopped:
            parts.append("\(run.name) was stopped before it finished.")
        }
        if let result = run.result {
            if !result.summary.isEmpty { parts.append(result.summary) }
            if !result.findings.isEmpty {
                parts.append(result.findings.count == 1 ? "Here's what it found." : "Here are the \(result.findings.count) things it found.")
                for (i, finding) in result.findings.enumerated() {
                    parts.append("\(ordinal(i + 1)): \(finding)")
                }
            }
        } else if run.status == .done {
            parts.append("It didn't leave a summary. You can see every step on the screen.")
        }
        return speakable(parts.joined(separator: " "))
    }

    /// Takes out markdown marks and "[2]" citation numbers, which sound odd read aloud.
    static func speakable(_ text: String) -> String {
        var t = text
        // [title](link) → title
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[\d+(?:\s*,\s*\d+)*\]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        for mark in ["**", "__", "`", "#", "*"] { t = t.replacingOccurrences(of: mark, with: "") }
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+([.,;:!?])"#, with: "$1", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func ordinal(_ n: Int) -> String {
        let words = ["First", "Second", "Third", "Fourth", "Fifth", "Sixth", "Seventh", "Eighth", "Ninth", "Tenth"]
        return n >= 1 && n <= words.count ? words[n - 1] : "Number \(n)"
    }

    /// "25 October 2026".
    private static func longDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMMM yyyy 'at' HH:mm"
        return f.string(from: date)
    }
}

/// "Read it to me": the phone's British English voice, a little slower than usual.
@MainActor
final class AgentBoardReader: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var speaking = false
    private let synth = AVSpeechSynthesizer()
    /// True when this reader set up the audio session (and so may hand it back). While the microphone is in use
    /// (a voice call with Kairos, or listening), it speaks through the session as it is and leaves it alone.
    private var ownsSession = false

    override init() {
        super.init()
        synth.delegate = self
    }

    func read(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord && session.category != .record {
            try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try? session.setActive(true)
            ownsSession = true
        }
        let utterance = AVSpeechUtterance(string: words)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-GB")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        utterance.preUtteranceDelay = 0.05
        speaking = true
        synth.speak(utterance)
    }

    func stop() {
        guard speaking || synth.isSpeaking else { return }
        synth.stopSpeaking(at: .immediate)
        speaking = false
        release()
    }

    private func finished() {
        guard !synth.isSpeaking else { return }
        speaking = false
        release()
    }

    private func release() {
        guard ownsSession else { return }
        ownsSession = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }
}
