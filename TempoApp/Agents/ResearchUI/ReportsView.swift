import SwiftUI
import WebKit
#if canImport(UIKit)
import UIKit
#endif

// Reports: what the research team found. A big-text list (title, date, how many sources), a report page with the
// spoken summary at the top in 28 pt, the findings with their sources, tappable source links, Google's Search
// Suggestions (the grounding terms say they must be shown with the results), Share and Delete, and a "New research"
// box that asks Kairos exactly as if the person had said it.

private enum ReportsStyle {
    static let paper = Color(red: 0.96, green: 0.95, blue: 0.92)
    static let green = Color(red: 0.18, green: 0.44, blue: 0.37)
    static let ink = Color(red: 0.11, green: 0.11, blue: 0.10)
    static let soft = Color(red: 0.25, green: 0.25, blue: 0.23)
    static let red = Color(red: 0.70, green: 0.20, blue: 0.15)
    static let amberBack = Color(red: 1.0, green: 0.95, blue: 0.84)
    static let amber = Color(red: 0.6, green: 0.35, blue: 0.0)

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        let cal = Calendar.current
        if cal.isDateInToday(d) { f.dateFormat = "'Today at' HH:mm" }
        else if cal.isDateInYesterday(d) { f.dateFormat = "'Yesterday at' HH:mm" }
        else { f.dateFormat = "EEEE d MMMM, HH:mm" }
        return f.string(from: d)
    }
}

struct ReportsView: View {
    /// When shown over the rest of the app, this closes it (a Close button appears).
    var onClose: (() -> Void)? = nil
    /// How a new request is asked. Pass `{ AgentVoice.shared.ask($0) }` so the answer is spoken; without it the
    /// request goes straight to KairosAgent.shared.handle and the answer is shown here.
    var onAsk: ((String) -> Void)? = nil

    @ObservedObject private var store = ReportStore.shared
    @State private var newTopic = ""
    @State private var lastAnswer: String?
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    newResearchBox
                    if let topic = store.runningTopic { runningCard(topic) }
                    if let lastAnswer, store.runningTopic == nil {
                        Text(lastAnswer)
                            .font(ReportsStyle.font(20))
                            .foregroundStyle(ReportsStyle.ink)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white, in: RoundedRectangle(cornerRadius: 18))
                    }
                    if store.reports.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.reports) { report in
                            NavigationLink(value: report.id) { ReportRow(report: report) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
            }
            .background(ReportsStyle.paper.ignoresSafeArea())
            .navigationTitle("Reports")
            .navigationDestination(for: String.self) { id in
                if let report = store.report(id: id) { ReportDetailView(report: report) }
                else { Text("This report has been deleted.").font(ReportsStyle.font(22)).padding() }
            }
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close", action: onClose).font(ReportsStyle.font(20, .semibold))
                    }
                }
            }
        }
        .tint(ReportsStyle.green)
        .environment(\.colorScheme, .light)
        .onAppear { store.reload() }
    }

    private var newResearchBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New research")
                .font(ReportsStyle.font(24, .bold))
                .foregroundStyle(ReportsStyle.ink)
            Text("Name any topic or project. My research team will look it up and write you a short report with its sources.")
                .font(ReportsStyle.font(18))
                .foregroundStyle(ReportsStyle.soft)
            TextField("For example: the Oxford flood scheme", text: $newTopic, axis: .vertical)
                .font(ReportsStyle.font(22))
                .lineLimit(1...3)
                .padding(14)
                .background(ReportsStyle.paper, in: RoundedRectangle(cornerRadius: 14))
                .focused($typing)
                .submitLabel(.go)
                .onSubmit(start)
            Button(action: start) {
                Label("Start research", systemImage: "magnifyingglass")
                    .font(ReportsStyle.font(22, .semibold))
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
            .buttonStyle(.borderedProminent)
            .tint(ReportsStyle.green)
            .disabled(newTopic.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 || store.runningTopic != nil)
        }
        .padding(18)
        .background(.white, in: RoundedRectangle(cornerRadius: 22))
    }

    private func runningCard(_ topic: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ProgressView().controlSize(.large).tint(ReportsStyle.green)
            VStack(alignment: .leading, spacing: 6) {
                Text("Researching \(topic)")
                    .font(ReportsStyle.font(21, .semibold))
                    .foregroundStyle(ReportsStyle.ink)
                Text(store.progressLine ?? "Working on it…")
                    .font(ReportsStyle.font(19))
                    .foregroundStyle(ReportsStyle.soft)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 22))
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "magnifyingglass.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(ReportsStyle.green)
            Text("No reports yet")
                .font(ReportsStyle.font(24, .bold))
                .foregroundStyle(ReportsStyle.ink)
            Text("Type a topic above, or just say “Research the new Oxford flood scheme”.")
                .font(ReportsStyle.font(20))
                .foregroundStyle(ReportsStyle.soft)
        }
        .padding(.top, 20)
    }

    private func start() {
        let text = newTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, store.runningTopic == nil else { return }
        typing = false
        newTopic = ""
        lastAnswer = nil
        // "find out about X" stays as it is; "X" becomes "Research X".
        let words = ResearchMatcher.match(text) != nil ? text : "Research " + text
        if let onAsk {
            onAsk(words)
        } else {
            Task {
                let outcome = await KairosAgent.shared.handle(words)
                lastAnswer = outcome.say
            }
        }
    }
}

private struct ReportRow: View {
    let report: ResearchReport

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(ReportsStyle.green)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 6) {
                Text(report.title)
                    .font(ReportsStyle.font(22, .semibold))
                    .foregroundStyle(ReportsStyle.ink)
                    .multilineTextAlignment(.leading)
                Text(ReportsStyle.date(report.createdAt))
                    .font(ReportsStyle.font(18))
                    .foregroundStyle(ReportsStyle.soft)
                Text(report.sources.count == 1 ? "1 source" : "\(report.sources.count) sources")
                    .font(ReportsStyle.font(18, .medium))
                    .foregroundStyle(ReportsStyle.green)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(ReportsStyle.soft)
                .padding(.top, 6)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 22))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the report")
    }
}

struct ReportDetailView: View {
    let report: ResearchReport
    @ObservedObject private var store = ReportStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var shareFile: URL?
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(report.title)
                        .font(ReportsStyle.font(30, .bold))
                        .foregroundStyle(ReportsStyle.ink)
                    Text(meta)
                        .font(ReportsStyle.font(17))
                        .foregroundStyle(ReportsStyle.soft)
                }

                Text(report.summary)
                    .font(ReportsStyle.font(28, .medium))
                    .foregroundStyle(ReportsStyle.ink)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white, in: RoundedRectangle(cornerRadius: 22))

                if let note = report.note {
                    Label(note, systemImage: "info.circle.fill")
                        .font(ReportsStyle.font(18))
                        .foregroundStyle(ReportsStyle.amber)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ReportsStyle.amberBack, in: RoundedRectangle(cornerRadius: 16))
                }

                section("What we found") {
                    ForEach(Array(report.findings.enumerated()), id: \.offset) { i, finding in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(i + 1).").font(ReportsStyle.font(21, .bold)).foregroundStyle(ReportsStyle.green)
                                Text(finding.text).font(ReportsStyle.font(21)).foregroundStyle(ReportsStyle.ink)
                            }
                            if !finding.sources.isEmpty { sourceChips(finding.sources) }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if !report.nextSteps.isEmpty {
                    section("What to do next") {
                        ForEach(Array(report.nextSteps.enumerated()), id: \.offset) { _, step in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: "arrow.right.circle.fill").foregroundStyle(ReportsStyle.green)
                                Text(step).font(ReportsStyle.font(21)).foregroundStyle(ReportsStyle.ink)
                            }
                        }
                    }
                }

                section("Sources") {
                    if report.sources.isEmpty {
                        Text("No sources came back for this one.").font(ReportsStyle.font(20)).foregroundStyle(ReportsStyle.soft)
                    }
                    ForEach(report.sources) { source in
                        if let url = source.link {
                            Link(destination: url) {
                                HStack(alignment: .top, spacing: 12) {
                                    Text("\(source.number)")
                                        .font(ReportsStyle.font(18, .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 34, height: 34)
                                        .background(ReportsStyle.green, in: Circle())
                                    Text(source.title)
                                        .font(ReportsStyle.font(21, .medium))
                                        .foregroundStyle(ReportsStyle.green)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.system(size: 22))
                                        .foregroundStyle(ReportsStyle.green)
                                }
                                .frame(minHeight: 48)
                            }
                            .accessibilityLabel("Source \(source.number), \(source.title)")
                            .accessibilityHint("Opens the web page")
                        }
                    }
                }

                if !report.suggestionsHTML.isEmpty || !report.searchQueries.isEmpty {
                    section("Google searches we used") {
                        if report.suggestionsHTML.isEmpty {
                            ForEach(report.searchQueries.prefix(6), id: \.self) { q in
                                Text("“\(q)”").font(ReportsStyle.font(19)).foregroundStyle(ReportsStyle.soft)
                            }
                        } else {
                            ForEach(Array(report.suggestionsHTML.prefix(4).enumerated()), id: \.offset) { _, html in
                                SearchSuggestionsView(html: html)
                                    .frame(height: 76)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                }

                buttons

                Text("Found with Google Search through Gemini. Web pages can be wrong or out of date, so check anything important.")
                    .font(ReportsStyle.font(16))
                    .foregroundStyle(ReportsStyle.soft)
            }
            .padding(20)
        }
        .background(ReportsStyle.paper.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task { shareFile = store.shareableFile(for: report) }
        .confirmationDialog("Delete this report?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete the report", role: .destructive) {
                store.delete(report.id)
                dismiss()
            }
            Button("Keep it", role: .cancel) {}
        }
    }

    private var meta: String {
        let done = report.researchers.filter { $0.status == .done }.count
        let seconds = Int(report.seconds.rounded())
        return "\(ReportsStyle.date(report.createdAt)) · \(done) researcher\(done == 1 ? "" : "s") · "
            + "\(report.sources.count) source\(report.sources.count == 1 ? "" : "s") · \(seconds) seconds"
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            if let shareFile {
                ShareLink(item: shareFile, preview: SharePreview(report.title)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(ReportsStyle.font(21, .semibold))
                        .frame(maxWidth: .infinity, minHeight: 58)
                }
                .buttonStyle(.borderedProminent)
                .tint(ReportsStyle.green)
            }
            Button(role: .destructive) { confirmDelete = true } label: {
                Label("Delete", systemImage: "trash")
                    .font(ReportsStyle.font(21, .semibold))
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .buttonStyle(.bordered)
            .tint(ReportsStyle.red)
        }
    }

    private func sourceChips(_ numbers: [Int]) -> some View {
        HStack(spacing: 8) {
            ForEach(numbers.prefix(5), id: \.self) { n in
                if let url = report.sources.first(where: { $0.number == n })?.link {
                    Link(destination: url) {
                        Text("Source \(n)")
                            .font(ReportsStyle.font(16, .semibold))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 36)
                            .background(ReportsStyle.paper, in: Capsule())
                            .foregroundStyle(ReportsStyle.green)
                    }
                    .accessibilityHint("Opens the web page")
                }
            }
        }
        .padding(.leading, 30)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(ReportsStyle.font(24, .bold))
                .foregroundStyle(ReportsStyle.ink)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 22))
    }
}

/// Google's Search Suggestions chip exactly as Gemini returned it (searchEntryPoint.renderedContent). Tapping a
/// suggestion opens Google in Safari.
struct SearchSuggestionsView: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.alwaysBounceVertical = false
        view.accessibilityLabel = "Google search suggestions"
        load(view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        if context.coordinator.loaded != html { load(view, coordinator: context.coordinator) }
    }

    private func load(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.loaded = html
        let page = "<!doctype html><html><head><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"></head>"
            + "<body style=\"margin:0;background:transparent\">" + html + "</body></html>"
        view.loadHTMLString(page, baseURL: nil)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                await UIApplication.shared.open(url)
                return .cancel
            }
            return .allow
        }
    }
}

/// The system share sheet for a report's Markdown file (share_report asks for it through ReportStore.shareRequest).
struct ReportActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Shows the share sheet when share_report asks for one. Put `.researchShareSheet()` on Kairos's main screen.
struct ResearchShareSheetModifier: ViewModifier {
    @ObservedObject private var store = ReportStore.shared

    func body(content: Content) -> some View {
        content.sheet(item: $store.shareRequest) { request in
            ReportActivitySheet(items: [request.file])
                .presentationDetents([.medium, .large])
        }
    }
}

extension View {
    func researchShareSheet() -> some View { modifier(ResearchShareSheetModifier()) }
}
