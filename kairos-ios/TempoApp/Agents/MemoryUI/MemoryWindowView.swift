import SwiftUI

// Memory: the person's chats with Kairos and the things it remembers, in big text. Two tabs ("Chats" and
// "Remembered") and a search box. Chats are grouped by day (Today, Yesterday, a weekday, a date); a chat opens as
// a transcript with "Ask about this chat", Share and Delete. Remembered facts are grouped by what they are about,
// and can be changed, forgotten one by one, added by hand, or all forgotten at once. Everything stays on this iPhone.

struct MemoryWindowView: View {
    /// When shown over the rest of the app, this closes it (a Close button appears).
    var onClose: (() -> Void)? = nil
    /// How "Ask about this chat" asks Kairos; returns what Kairos said. Pass
    /// `{ await AgentVoice.shared.askAndSpeak($0).say }` so the answer is also spoken.
    var ask: ((String) async -> String)? = nil

    enum Tab: String, CaseIterable, Identifiable {
        case chats = "Chats", remembered = "Remembered"
        var id: String { rawValue }
    }

    @ObservedObject private var history = ConversationStore.shared
    @ObservedObject private var memory = MemoryStore.shared
    @State private var tab: Tab = .chats
    @State private var query = ""
    @State private var path: [UUID] = []
    @State private var editing: MemoryFactDraft?
    @State private var confirmDeleteHistory = false
    @State private var confirmForgetAll = false

    static let privacyLine = "Kept only on this iPhone. Kairos sends just the few memories that matter to each question to Google Gemini."

    init(onClose: (() -> Void)? = nil, ask: ((String) async -> String)? = nil, startOn: Tab = .chats) {
        self.onClose = onClose
        self.ask = ask
        _tab = State(initialValue: startOn)
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                tabPicker
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                switch tab {
                case .chats: chatList
                case .remembered: factList
                }
            }
            .background(AgentUIStyle.paper.ignoresSafeArea())
            .navigationTitle("Memory")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, prompt: tab == .chats ? "Search your chats" : "Search what I remember")
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close", action: onClose)
                            .font(AgentUIStyle.font(19, .semibold))
                            .foregroundStyle(AgentUIStyle.green)
                    }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                MemoryTranscriptView(sessionID: id, ask: ask)
            }
            .sheet(item: $editing) { draft in
                MemoryFactEditor(draft: draft)
            }
        }
        .tint(AgentUIStyle.green)
        .environment(\.colorScheme, .light)
    }

    // MARK: - Tabs

    /// A big two-part switch (the system segmented control's text is too small for the people Kairos is for).
    private var tabPicker: some View {
        HStack(spacing: 6) {
            ForEach(Tab.allCases) { t in
                Button { tab = t } label: {
                    Text(t.rawValue)
                        .font(AgentUIStyle.font(20, .bold))
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(tab == t ? AgentUIStyle.green : Color.clear, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(tab == t ? Color.white : AgentUIStyle.green)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == t ? [.isSelected, .isButton] : .isButton)
                .accessibilityHint(t == .chats ? "Your chats with Kairos" : "The things Kairos remembers about you")
            }
        }
        .padding(5)
        .background(.white, in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: - Chats

    private var chatDays: [ConversationDay] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? history.sessionsByDay : ConversationStore.group(history.search(q), calendar: .current)
    }

    private var chatList: some View {
        List {
            let days = chatDays
            if days.isEmpty {
                Section {
                    emptyNote(query.isEmpty ? "No chats yet. When you talk to Kairos, your chats appear here."
                                            : "No chats match “\(query)”.")
                }
            }
            ForEach(days) { day in
                Section {
                    ForEach(day.sessions) { session in
                        NavigationLink(value: session.id) { chatRow(session) }
                            .listRowBackground(Color.white)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { history.delete(sessionID: session.id) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text(MemoryDates.dayTitle(day.date))
                        .font(AgentUIStyle.font(20, .bold))
                        .foregroundStyle(AgentUIStyle.soft)
                        .textCase(nil)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            if !history.sessions.isEmpty {
                Section {
                    Button(role: .destructive) { confirmDeleteHistory = true } label: {
                        Label("Delete all history", systemImage: "trash")
                            .font(AgentUIStyle.font(20, .semibold))
                            .foregroundStyle(AgentUIStyle.red)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .listRowBackground(Color.white)
                }
            }
            Section { privacyFooter }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .alert("Delete all your chats?", isPresented: $confirmDeleteHistory) {
            Button("Delete all", role: .destructive) { history.deleteAll(); path = [] }
            Button("Keep them", role: .cancel) {}
        } message: {
            Text("Every chat on this iPhone will be deleted. The things Kairos remembers stay until you forget them.")
        }
    }

    private func chatRow(_ s: ConversationSession) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(spacing: 4) {
                Text(MemoryDates.time(s.startedAt))
                    .font(AgentUIStyle.font(18, .bold))
                    .foregroundStyle(AgentUIStyle.ink)
                    .monospacedDigit()
                Image(systemName: s.source.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AgentUIStyle.green)
            }
            .frame(width: 58)
            VStack(alignment: .leading, spacing: 3) {
                Text(s.title)
                    .font(AgentUIStyle.font(21, .medium))
                    .foregroundStyle(AgentUIStyle.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(MemoryDates.lineCount(s.turns.count))
                    .font(AgentUIStyle.font(16))
                    .foregroundStyle(AgentUIStyle.soft)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(MemoryDates.spokenDay(s.startedAt)) at \(MemoryDates.time(s.startedAt)), \(s.source.spoken). \(s.title). \(MemoryDates.lineCount(s.turns.count)).")
        .accessibilityHint("Opens the chat")
    }

    // MARK: - Remembered

    private var visibleFacts: [MemoryFact] {
        let wanted = MemoryText.words(query)
        guard !wanted.isEmpty else { return memory.facts }
        return memory.facts.filter { fact in
            let have = MemoryText.words(fact.text + " " + fact.category.title)
            return wanted.allSatisfy { w in have.contains { $0.hasPrefix(w) } }
        }
    }

    private var factList: some View {
        List {
            Section {
                Button { editing = MemoryFactDraft(factID: nil, text: "", category: .other) } label: {
                    Label("Add something to remember", systemImage: "plus.circle.fill")
                        .font(AgentUIStyle.font(21, .bold))
                        .foregroundStyle(AgentUIStyle.green)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                }
                .listRowBackground(Color.white)
                .accessibilityHint("Type something for Kairos to keep in mind")
            }
            let facts = visibleFacts
            if facts.isEmpty {
                Section {
                    emptyNote(query.isEmpty
                              ? "Nothing yet. Say “remember that…” to Kairos, or add something here."
                              : "Nothing I remember matches “\(query)”.")
                }
            }
            ForEach(MemoryCategory.allCases) { category in
                let inCategory = facts.filter { $0.category == category }
                if !inCategory.isEmpty {
                    Section {
                        ForEach(inCategory) { fact in
                            Button { editing = MemoryFactDraft(factID: fact.id, text: fact.text, category: fact.category) } label: {
                                factRow(fact)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.white)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { memory.delete(id: fact.id) } label: {
                                    Label("Forget", systemImage: "trash")
                                }
                            }
                            .accessibilityAction(named: "Forget this") { memory.delete(id: fact.id) }
                        }
                    } header: {
                        Label(category.title, systemImage: category.icon)
                            .font(AgentUIStyle.font(20, .bold))
                            .foregroundStyle(AgentUIStyle.soft)
                            .textCase(nil)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
            }
            if !memory.facts.isEmpty {
                Section {
                    Button(role: .destructive) { confirmForgetAll = true } label: {
                        Label("Forget everything", systemImage: "trash")
                            .font(AgentUIStyle.font(20, .semibold))
                            .foregroundStyle(AgentUIStyle.red)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .listRowBackground(Color.white)
                }
            }
            Section { privacyFooter }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .alert("Forget everything?", isPresented: $confirmForgetAll) {
            Button("Forget everything", role: .destructive) { memory.deleteAll() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Kairos will forget all \(memory.facts.count) things it remembers about you. Your chats stay.")
        }
    }

    private func factRow(_ fact: MemoryFact) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: fact.category.icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(AgentUIStyle.green)
                .frame(width: 28)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(fact.text)
                    .font(AgentUIStyle.font(21, .medium))
                    .foregroundStyle(AgentUIStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(fact.source.rawValue) · \(MemoryDates.short(fact.createdAt))")
                    .font(AgentUIStyle.font(16))
                    .foregroundStyle(AgentUIStyle.soft)
            }
            Spacer(minLength: 0)
            Image(systemName: "pencil")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AgentUIStyle.soft)
                .padding(.top, 4)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(fact.text). \(fact.source.rawValue), \(MemoryDates.short(fact.createdAt)).")
        .accessibilityHint("Double-tap to change it. Swipe up or down for Forget this.")
    }

    // MARK: - Shared bits

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(AgentUIStyle.font(20))
            .foregroundStyle(AgentUIStyle.soft)
            .padding(.vertical, 8)
            .listRowBackground(Color.white.opacity(0.6))
    }

    private var privacyFooter: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AgentUIStyle.green)
                .padding(.top, 2)
            Text(Self.privacyLine)
                .font(AgentUIStyle.font(17))
                .foregroundStyle(AgentUIStyle.soft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - One chat

struct MemoryTranscriptView: View {
    let sessionID: UUID
    var ask: ((String) async -> String)? = nil

    @ObservedObject private var history = ConversationStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var asking = false

    var body: some View {
        Group {
            if let session = history.session(id: sessionID) {
                transcript(session)
            } else {
                Text("This chat has been deleted.")
                    .font(AgentUIStyle.font(22))
                    .foregroundStyle(AgentUIStyle.soft)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AgentUIStyle.paper.ignoresSafeArea())
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func transcript(_ s: ConversationSession) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.title)
                            .font(AgentUIStyle.font(26, .bold))
                            .foregroundStyle(AgentUIStyle.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Label("\(MemoryDates.long(s.startedAt)), \(s.source.spoken)", systemImage: s.source.icon)
                            .font(AgentUIStyle.font(18))
                            .foregroundStyle(AgentUIStyle.soft)
                    }
                    .padding(.bottom, 6)
                    ForEach(s.turns) { turn in turnView(turn) }
                }
                .padding(16)
            }
            actionBar(s)
        }
        .sheet(isPresented: $asking) {
            MemoryAskSheet(session: s, ask: ask)
        }
        .alert("Delete this chat?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                history.delete(sessionID: s.id)
                dismiss()
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("It will be deleted from this iPhone.")
        }
    }

    private func actionBar(_ s: ConversationSession) -> some View {
        VStack(spacing: 10) {
            Button { asking = true } label: {
                Label("Ask about this chat", systemImage: "questionmark.bubble.fill")
                    .font(AgentUIStyle.font(22, .bold))
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(AgentUIStyle.green, in: RoundedRectangle(cornerRadius: 20))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Ask Kairos a question about this chat")
            HStack(spacing: 10) {
                ShareLink(item: history.exportMarkdown(s), subject: Text(s.title),
                          preview: SharePreview(s.title)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(AgentUIStyle.font(19, .bold))
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(.white, in: RoundedRectangle(cornerRadius: 18))
                        .foregroundStyle(AgentUIStyle.green)
                }
                .accessibilityHint("Send this chat as text")
                Button { confirmDelete = true } label: {
                    Label("Delete", systemImage: "trash")
                        .font(AgentUIStyle.font(19, .bold))
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(.white, in: RoundedRectangle(cornerRadius: 18))
                        .foregroundStyle(AgentUIStyle.red)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Deletes this chat from this iPhone")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(AgentUIStyle.paper)
    }

    @ViewBuilder
    private func turnView(_ t: ConversationTurn) -> some View {
        switch t.kind {
        case .person:
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(t.text)
                        .font(AgentUIStyle.font(21))
                        .foregroundStyle(AgentUIStyle.ink)
                        .padding(14)
                        .background(AgentUIStyle.personBubble, in: RoundedRectangle(cornerRadius: 18))
                    Text(MemoryDates.time(t.at))
                        .font(AgentUIStyle.font(15))
                        .foregroundStyle(AgentUIStyle.soft)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("At \(MemoryDates.time(t.at)) you said: \(t.text)")
        case .kairos:
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t.text)
                        .font(AgentUIStyle.font(21))
                        .foregroundStyle(AgentUIStyle.ink)
                        .padding(14)
                        .background(.white, in: RoundedRectangle(cornerRadius: 18))
                    Text("\(t.helper ?? "Kairos") · \(MemoryDates.time(t.at))")
                        .font(AgentUIStyle.font(15))
                        .foregroundStyle(AgentUIStyle.soft)
                }
                Spacer(minLength: 40)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("At \(MemoryDates.time(t.at)) \(t.helper ?? "Kairos") said: \(t.text)")
        case .done, .failed, .refused:
            actionCard(t)
        }
    }

    /// What a helper did: its icon and name, the action, the time, and a tick or a cross.
    private func actionCard(_ t: ConversationTurn) -> some View {
        let done = t.kind == .done
        let colour = done ? AgentUIStyle.green : (t.kind == .refused ? AgentUIStyle.amber : AgentUIStyle.red)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: t.icon ?? "gearshape.fill")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(AgentUIStyle.green)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(t.helper ?? "Helper") · \(MemoryDates.time(t.at))")
                    .font(AgentUIStyle.font(16, .semibold))
                    .foregroundStyle(AgentUIStyle.soft)
                Text(t.text)
                    .font(AgentUIStyle.font(19, .medium))
                    .foregroundStyle(AgentUIStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(done ? "✓" : "✗")
                .font(AgentUIStyle.font(26, .bold))
                .foregroundStyle(colour)
        }
        .padding(12)
        .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(colour.opacity(0.35), lineWidth: 1.5))
        .padding(.horizontal, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("At \(MemoryDates.time(t.at)), \(t.helper ?? "Helper"): \(t.text). \(done ? "Done." : "Not done.")")
    }
}

// MARK: - Ask about this chat

struct MemoryAskSheet: View {
    let session: ConversationSession
    var ask: ((String) async -> String)?

    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var answer: String?
    @State private var waiting = false
    @FocusState private var typing: Bool

    private let suggestions = ["Sum it up for me", "What did we decide?", "What did the helpers do?"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Ask Kairos about your chat from \(MemoryDates.long(session.startedAt).lowercasedFirst).")
                        .font(AgentUIStyle.font(21, .medium))
                        .foregroundStyle(AgentUIStyle.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("Your question", text: $question, axis: .vertical)
                        .font(AgentUIStyle.font(22))
                        .lineLimit(1...4)
                        .padding(14)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                        .focused($typing)
                        .submitLabel(.send)
                        .onSubmit { send(question) }
                        .accessibilityLabel("Your question about this chat")
                    ForEach(suggestions, id: \.self) { s in
                        Button { send(s) } label: {
                            Text(s)
                                .font(AgentUIStyle.font(20, .semibold))
                                .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                                .padding(.horizontal, 14)
                                .background(.white, in: RoundedRectangle(cornerRadius: 16))
                                .foregroundStyle(AgentUIStyle.green)
                        }
                        .buttonStyle(.plain)
                        .disabled(waiting)
                    }
                    Button { send(question) } label: {
                        Text("Ask")
                            .font(AgentUIStyle.font(22, .bold))
                            .frame(maxWidth: .infinity, minHeight: 60)
                            .background(AgentUIStyle.green, in: RoundedRectangle(cornerRadius: 18))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(waiting || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                    if waiting {
                        HStack(spacing: 12) {
                            ProgressView().controlSize(.large).tint(AgentUIStyle.green)
                            Text("Just a moment…").font(AgentUIStyle.font(20, .medium)).foregroundStyle(AgentUIStyle.soft)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if let answer {
                        Text(answer)
                            .font(AgentUIStyle.font(21))
                            .foregroundStyle(AgentUIStyle.ink)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white, in: RoundedRectangle(cornerRadius: 18))
                            .accessibilityLabel("Kairos said: \(answer)")
                    }
                }
                .padding(16)
            }
            .background(AgentUIStyle.paper.ignoresSafeArea())
            .navigationTitle("Ask about this chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(AgentUIStyle.font(19, .semibold))
                }
            }
        }
        .environment(\.colorScheme, .light)
    }

    private func send(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !waiting else { return }
        typing = false
        waiting = true
        answer = nil
        let history = ConversationStore.shared
        history.askAbout(session.id)
        let text = "About our chat from \(MemoryDates.long(session.startedAt).lowercasedFirst): \(q)"
        Task { @MainActor in
            let said: String
            if let ask { said = await ask(text) } else { said = await KairosAgent.shared.handle(text, source: .app).say }
            answer = said
            waiting = false
        }
    }
}

// MARK: - Change or add a fact

struct MemoryFactDraft: Identifiable {
    let id = UUID()
    /// Nil for a new fact.
    var factID: UUID?
    var text: String
    var category: MemoryCategory
}

struct MemoryFactEditor: View {
    @State var draft: MemoryFactDraft

    @ObservedObject private var memory = MemoryStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var problem: String?
    @State private var confirmForget = false
    @FocusState private var typing: Bool

    private var isNew: Bool { draft.factID == nil }
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(isNew ? "What should Kairos remember?" : "Change what Kairos remembers")
                        .font(AgentUIStyle.font(22, .bold))
                        .foregroundStyle(AgentUIStyle.ink)
                    TextField("For example: My GP is Dr Shah", text: $draft.text, axis: .vertical)
                        .font(AgentUIStyle.font(22))
                        .lineLimit(2...6)
                        .padding(14)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                        .focused($typing)
                        .accessibilityLabel("What to remember")
                    Text("\(draft.text.count) of \(MemoryStore.maxLength) letters")
                        .font(AgentUIStyle.font(16))
                        .foregroundStyle(draft.text.count > MemoryStore.maxLength ? AgentUIStyle.red : AgentUIStyle.soft)
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(AgentUIStyle.font(19, .medium))
                            .foregroundStyle(AgentUIStyle.amber)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AgentUIStyle.amberBack, in: RoundedRectangle(cornerRadius: 14))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("It's about")
                        .font(AgentUIStyle.font(20, .semibold))
                        .foregroundStyle(AgentUIStyle.soft)
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(MemoryCategory.allCases) { c in
                            Button { draft.category = c } label: {
                                Label(c.title, systemImage: c.icon)
                                    .font(AgentUIStyle.font(18, .semibold))
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.8)
                                    .frame(maxWidth: .infinity, minHeight: 54)
                                    .padding(.horizontal, 6)
                                    .background(draft.category == c ? AgentUIStyle.green : .white, in: RoundedRectangle(cornerRadius: 14))
                                    .foregroundStyle(draft.category == c ? .white : AgentUIStyle.green)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(draft.category == c ? [.isSelected, .isButton] : .isButton)
                        }
                    }
                    Button(action: save) {
                        Text(isNew ? "Remember this" : "Save")
                            .font(AgentUIStyle.font(22, .bold))
                            .frame(maxWidth: .infinity, minHeight: 60)
                            .background(AgentUIStyle.green, in: RoundedRectangle(cornerRadius: 18))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    if !isNew {
                        Button { confirmForget = true } label: {
                            Label("Forget this", systemImage: "trash")
                                .font(AgentUIStyle.font(20, .bold))
                                .frame(maxWidth: .infinity, minHeight: 56)
                                .background(.white, in: RoundedRectangle(cornerRadius: 18))
                                .foregroundStyle(AgentUIStyle.red)
                        }
                        .buttonStyle(.plain)
                    }
                    Text(MemoryWindowView.privacyLine)
                        .font(AgentUIStyle.font(16))
                        .foregroundStyle(AgentUIStyle.soft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
            .background(AgentUIStyle.paper.ignoresSafeArea())
            .navigationTitle(isNew ? "Add a memory" : "Change a memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .font(AgentUIStyle.font(19, .semibold))
                }
            }
            .onAppear { if isNew { typing = true } }
            .alert("Forget this?", isPresented: $confirmForget) {
                Button("Forget it", role: .destructive) {
                    if let id = draft.factID { memory.delete(id: id) }
                    dismiss()
                }
                Button("Keep it", role: .cancel) {}
            } message: {
                Text(draft.text)
            }
        }
        .environment(\.colorScheme, .light)
    }

    private func save() {
        if let id = draft.factID {
            if let reason = memory.edit(id: id, text: draft.text, category: draft.category) { problem = reason; return }
        } else {
            switch memory.add(draft.text, category: draft.category, source: .byHand) {
            case .refused(let reason): problem = reason; return
            case .added, .duplicate: break
            }
        }
        dismiss()
    }
}

// MARK: - Dates in plain words

enum MemoryDates {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = format
        return f
    }

    /// "18:40".
    static func time(_ d: Date) -> String { formatter("HH:mm").string(from: d) }

    /// "25 Oct" (with the year when it isn't this year).
    static func short(_ d: Date) -> String {
        let sameYear = Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year)
        return formatter(sameYear ? "d MMM" : "d MMM yyyy").string(from: d)
    }

    /// Section titles: "Today", "Yesterday", "Monday" (this past week), "Saturday 18 October".
    static func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day ?? 99
        if days < 7 { return formatter("EEEE").string(from: d) }
        let sameYear = cal.isDate(d, equalTo: Date(), toGranularity: .year)
        return formatter(sameYear ? "EEEE d MMMM" : "EEEE d MMMM yyyy").string(from: d)
    }

    /// For VoiceOver: "Today", "Yesterday", "Monday 20 October".
    static func spokenDay(_ d: Date) -> String {
        let t = dayTitle(d)
        return t
    }

    /// "Today at 18:40", "Saturday 18 October at 09:12".
    static func long(_ d: Date) -> String { "\(dayTitle(d)) at \(time(d))" }

    static func lineCount(_ n: Int) -> String { n == 1 ? "1 message" : "\(n) messages" }
}

private extension String {
    /// "Today at 18:40" → "today at 18:40" (a weekday or month name keeps its capital).
    var lowercasedFirst: String {
        guard let first = first else { return self }
        let word = split(separator: " ").first.map(String.init) ?? ""
        if ["Today", "Yesterday"].contains(word) { return first.lowercased() + dropFirst() }
        return self
    }
}
