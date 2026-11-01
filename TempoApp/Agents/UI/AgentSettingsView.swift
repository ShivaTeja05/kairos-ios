import SwiftUI
import UIKit

/// Settings for Kairos on this phone, usually set up once by a helper: the Gemini key (pasted, never shown),
/// which model thinks, the person's language, and whether answers are read out loud.
struct AgentSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var keyEnd: String? = AgentSettingsView.savedKeyEnd()
    @State private var backupEnd: String? = AgentSettingsView.savedBackupEnd()
    @State private var backupNote: String?
    @State private var backupNoteIsGood = false
    @State private var keyNote: String?
    @State private var keyNoteIsGood = false
    @State private var checking = false
    @State private var confirmRemove = false
    @State private var model = AgentSettings.model
    @State private var customModel = ""
    @State private var language = AgentLanguage.current
    @State private var speakReplies = AgentVoice.speakReplies
    @State private var listening: Bool? = AgentVoice.listeningAllowed
    @State private var abilities: [String: String] = [:]
    @ObservedObject private var mesh = MeshNode.shared
    @State private var meshHub = ""
    @State private var meshCode = ""
    @State private var meshNote: String?
    @State private var meshJoining = false
    @State private var brain = AgentSettings.brain

    static let models: [(id: String, label: String, note: String)] = [
        ("gemini-3.5-flash-lite", "Quick (recommended)", "Fast, and uses the least of your free allowance."),
        ("gemini-3.8-flash", "Careful", "A little slower. Better with hard letters."),
        ("gemini-2.5-flash", "Older model", "Use this if the others stop working."),
    ]

    static let languages: [(code: String, label: String)] = [
        ("en-GB", "English"), ("hi-IN", "हिन्दी · Hindi"), ("te-IN", "తెలుగు · Telugu"), ("ta-IN", "தமிழ் · Tamil"),
        ("bn-IN", "বাংলা · Bengali"), ("ur-PK", "اردو · Urdu"), ("pa-IN", "ਪੰਜਾਬੀ · Punjabi"),
        ("gu-IN", "ગુજરાતી · Gujarati"), ("cy-GB", "Cymraeg · Welsh"), ("pl-PL", "Polski · Polish"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    meshSection
                    brainSection
                    if brain == .gemini {
                        keySection
                        modelSection
                    }
                    languageSection
                    voiceSection
                    privacyNote
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AgentUIStyle.paper.ignoresSafeArea())
            .navigationTitle("Kairos settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(AgentUIStyle.font(20, .bold))
                }
            }
        }
        .environment(\.colorScheme, .light)
        .onAppear {
            if !Self.models.contains(where: { $0.id == model }) { customModel = model }
            refreshAbilities()
        }
        .confirmationDialog("Remove the Gemini key?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove key", role: .destructive) { removeKey() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Kairos will stop thinking until a key is added again. Alarms, timers and calls keep working.")
        }
    }

    // MARK: - Gemini key

    private var keySection: some View {
        card("Gemini key") {
            Label {
                Text(keyEnd.map { "Key saved ✓ (ends …\($0))" } ?? "No key yet")
            } icon: {
                Image(systemName: keyEnd == nil ? "key" : "checkmark.seal.fill")
            }
            .font(AgentUIStyle.font(22, .semibold))
            .foregroundStyle(keyEnd == nil ? AgentUIStyle.soft : AgentUIStyle.green)

            bigButton("Paste key from clipboard", icon: "doc.on.clipboard", filled: true) { pasteKey() }

            if keyEnd != nil {
                bigButton(checking ? "Checking…" : "Check it works", icon: "checkmark.circle", filled: false) {
                    Task { await checkKey() }
                }
                .disabled(checking)
                bigButton("Remove key", icon: "trash", filled: false, tint: AgentUIStyle.red) { confirmRemove = true }
            }

            if let keyNote {
                Text(keyNote)
                    .font(AgentUIStyle.font(19, .medium))
                    .foregroundStyle(keyNoteIsGood ? AgentUIStyle.green : AgentUIStyle.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Text("Get a free key from Google AI Studio (aistudio.google.com), copy it, then tap Paste. The key stays in this phone's keychain.")
                .font(AgentUIStyle.font(17))
                .foregroundStyle(AgentUIStyle.soft)
                .fixedSize(horizontal: false, vertical: true)

            if keyEnd != nil { backupKeyRows }
        }
    }

    /// The optional second key, under the main one.
    @ViewBuilder private var backupKeyRows: some View {
        Divider().padding(.vertical, 4)
        Text("Backup key (optional)")
            .font(AgentUIStyle.font(22, .bold))
            .foregroundStyle(AgentUIStyle.ink)
            .accessibilityAddTraits(.isHeader)
        Label {
            Text(backupEnd.map { "Backup key saved ✓ (ends …\($0))" } ?? "No backup key")
        } icon: {
            Image(systemName: backupEnd == nil ? "key" : "checkmark.seal.fill")
        }
        .font(AgentUIStyle.font(20, .semibold))
        .foregroundStyle(backupEnd == nil ? AgentUIStyle.soft : AgentUIStyle.green)

        bigButton("Paste backup key", icon: "doc.on.clipboard", filled: false) { pasteBackupKey() }
        if backupEnd != nil {
            bigButton("Remove", icon: "trash", filled: false, tint: AgentUIStyle.red) { removeBackupKey() }
        }
        if let backupNote {
            Text(backupNote)
                .font(AgentUIStyle.font(19, .medium))
                .foregroundStyle(backupNoteIsGood ? AgentUIStyle.green : AgentUIStyle.amber)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
        }
        Text("A second key from another Google project doubles how much Kairos can do per minute.")
            .font(AgentUIStyle.font(17))
            .foregroundStyle(AgentUIStyle.soft)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The last three characters of the saved key, or nil when there's no usable key.
    static func savedKeyEnd() -> String? {
        guard AgentSettings.hasKey, let key = KeyStore.get(AgentSettings.keyName) else { return nil }
        return String(key.suffix(3))
    }

    /// The last three characters of the backup key, or nil when there isn't one.
    static func savedBackupEnd() -> String? {
        AgentSettings.backupKey.map { String($0.suffix(3)) }
    }

    private func pasteBackupKey() {
        let board = UIPasteboard.general
        guard board.hasStrings, let text = board.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            tellBackup("There's nothing to paste. Copy the backup key first, then tap Paste.", good: false)
            return
        }
        guard let cleaned = AgentSettings.cleanKey(text) else {
            tellBackup("That doesn't look like a Gemini key. Copy the whole key, then tap Paste again.", good: false)
            return
        }
        guard cleaned != AgentSettings.key else {
            tellBackup("That's the same key as the main one. A backup key needs to come from another Google project.", good: false)
            return
        }
        AgentSettings.saveBackupKey(cleaned)
        board.items = []  // the key shouldn't stay on the clipboard
        backupEnd = Self.savedBackupEnd()
        tellBackup("Saved. I've cleared it from the clipboard. Kairos will use it when Google says the main key is busy.", good: true)
    }

    private func removeBackupKey() {
        AgentSettings.removeBackupKey()
        backupEnd = nil
        tellBackup("Backup key removed. Kairos keeps using the main key.", good: true)
    }

    private func tellBackup(_ text: String, good: Bool) {
        backupNote = text
        backupNoteIsGood = good
    }

    private func pasteKey() {
        let board = UIPasteboard.general
        guard board.hasStrings, let text = board.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            note("There's nothing to paste. Copy the key first, then tap Paste.", good: false)
            return
        }
        guard AgentSettings.saveKey(text) else {
            note("That doesn't look like a Gemini key. Copy the whole key, then tap Paste again.", good: false)
            return
        }
        board.items = []  // the key shouldn't stay on the clipboard
        keyEnd = Self.savedKeyEnd()
        note("Saved. I've cleared it from the clipboard. Tap “Check it works” to try it.", good: true)
    }

    private func checkKey() async {
        // This key and this model only: no backup model or key standing in, so a wrong model name still shows.
        guard let key = AgentSettings.key else {
            note(ModelError.noKey.errorDescription ?? "There's no key yet.", good: false)
            return
        }
        let provider = GeminiProvider(model: AgentSettings.model, apiKey: key, timeout: 15)
        checking = true
        defer { checking = false }
        do {
            _ = try await provider.generate(system: "Reply with the single word OK.",
                                            parts: [GeminiContent.text("Are you there?")], jsonSchema: nil)
            note("It works ✓ Kairos can think now.", good: true)
        } catch let error as ModelError {
            if case .http(404, _) = error {
                note("Gemini doesn't know the model “\(AgentSettings.model)”. Pick another one below.", good: false)
            } else {
                note(error.errorDescription ?? "That didn't work. Please try again.", good: false)
            }
        } catch {
            note("I couldn't reach Gemini. Check the internet and try again.", good: false)
        }
    }

    private func removeKey() {
        KeyStore.set(AgentSettings.keyName, "")  // KeyStore has no delete; an empty key counts as no key
        keyEnd = nil
        backupEnd = Self.savedBackupEnd()
        note("Key removed. Alarms, timers and calls still work.", good: true)
    }

    private func note(_ text: String, good: Bool) {
        keyNote = text
        keyNoteIsGood = good
    }

    // MARK: - Model

    private var modelSection: some View {
        card("Which Gemini thinks") {
            ForEach(Self.models, id: \.id) { option in
                choiceRow(option.label, detail: "\(option.note)\n\(option.id)", selected: model == option.id) {
                    pickModel(option.id)
                }
            }
            HStack(spacing: 10) {
                TextField("Another model name", text: $customModel)
                    .font(AgentUIStyle.font(20))
                    .foregroundStyle(AgentUIStyle.ink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(AgentUIStyle.paper, in: RoundedRectangle(cornerRadius: 14))
                    .submitLabel(.done)
                    .onSubmit(useCustomModel)
                Button(action: useCustomModel) {
                    Text("Use")
                        .font(AgentUIStyle.font(20, .bold))
                        .padding(.horizontal, 18)
                        .frame(minHeight: 52)
                        .background(AgentUIStyle.green, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            if !Self.models.contains(where: { $0.id == model }) {
                Text("Using “\(model)”.")
                    .font(AgentUIStyle.font(18, .medium))
                    .foregroundStyle(AgentUIStyle.green)
            }
        }
    }

    private func pickModel(_ id: String) {
        model = id
        AgentSettings.model = id
    }

    private func useCustomModel() {
        let typed = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        // Someone pasted their key here instead of with "Paste key": keep it out of the settings file, save it
        // where keys belong (as typed, case intact), and tell them.
        if typed.hasPrefix("AQ.") || typed.hasPrefix("AIza") || (typed.count >= 30 && !typed.contains("gemini")) {
            customModel = ""
            if AgentSettings.saveKey(typed) { keyEnd = AgentSettingsView.savedKeyEnd() }
            note("That looked like your Gemini key, not a model name. I've saved it as your key instead.", good: true)
            return
        }
        var name = typed.lowercased()
        if name.hasPrefix("models/") { name.removeFirst("models/".count) }
        guard AgentSettings.isModelName(name) else {
            note("That model name doesn't look right. It should look like gemini-3.5-flash-lite.", good: false)
            return
        }
        customModel = name
        pickModel(name)
    }

    // MARK: - Language

    private var languageSection: some View {
        card("Language") {
            Text("Kairos listens and answers in this language.")
                .font(AgentUIStyle.font(18))
                .foregroundStyle(AgentUIStyle.soft)
            ForEach(Self.languages, id: \.code) { option in
                choiceRow(option.label, detail: abilities[option.code], selected: language == option.code) {
                    language = option.code
                    AgentLanguage.current = option.code
                }
            }
        }
    }

    private func refreshAbilities() {
        var found: [String: String] = [:]
        for option in Self.languages {
            let listen = AgentVoice.canListen(option.code)
            let speak = AgentVoice.canSpeak(option.code)
            switch (listen, speak) {
            case (true, true): found[option.code] = "Listens ✓  Speaks ✓"
            case (true, false): found[option.code] = "Listens ✓  No voice on this phone yet"
            case (false, true): found[option.code] = "Speaks ✓  Listens in English"
            case (false, false): found[option.code] = "Written answers only on this phone"
            }
        }
        abilities = found
    }

    // MARK: - Voice

    private var voiceSection: some View {
        card("Voice") {
            Toggle(isOn: $speakReplies) {
                Text("Read answers out loud")
                    .font(AgentUIStyle.font(22, .semibold))
                    .foregroundStyle(AgentUIStyle.ink)
            }
            .tint(AgentUIStyle.green)
            .frame(minHeight: 60)
            .onChange(of: speakReplies) { _, on in AgentVoice.speakReplies = on }

            switch listening {
            case .some(true):
                Label("Kairos may listen ✓", systemImage: "mic.fill")
                    .font(AgentUIStyle.font(20, .medium))
                    .foregroundStyle(AgentUIStyle.green)
            case .some(false):
                Text("Kairos isn't allowed to listen. Turn on Microphone and Speech Recognition for Kairos in Settings.")
                    .font(AgentUIStyle.font(19, .medium))
                    .foregroundStyle(AgentUIStyle.amber)
                    .fixedSize(horizontal: false, vertical: true)
                bigButton("Open Settings", icon: "gearshape", filled: false) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            case .none:
                bigButton("Allow listening", icon: "mic", filled: false) {
                    Task {
                        _ = await AgentVoice.shared.askPermissions()
                        listening = AgentVoice.listeningAllowed
                    }
                }
            }
        }
    }

    // MARK: - Who thinks

    private var brainSection: some View {
        card("Who thinks for Kairos") {
            Text("Alarms, reminders, calls and your calendar are done by rules on this phone. For everything else:")
                .font(AgentUIStyle.font(18))
                .foregroundStyle(AgentUIStyle.soft)
                .fixedSize(horizontal: false, vertical: true)
            bigButton("Your Mac: open model, no key", icon: brain == .mac ? "checkmark.circle.fill" : "laptopcomputer",
                      filled: brain == .mac) {
                brain = .mac
                AgentSettings.brain = .mac
            }
            bigButton("Google Gemini: your key", icon: brain == .gemini ? "checkmark.circle.fill" : "sparkles",
                      filled: brain == .gemini) {
                brain = .gemini
                AgentSettings.brain = .gemini
            }
            Text(brain == .mac
                 ? "Your Mac's own model answers, over your private Tailscale network. Nothing goes to Google. Reading letters needs Gemini for now."
                 : "Gemini answers here on the phone and can use all of Kairos's helpers. Needs a free key from Google.")
                .font(AgentUIStyle.font(17))
                .foregroundStyle(AgentUIStyle.soft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Your devices (kairos-mesh)

    private var meshSection: some View {
        card("Your Mac") {
            Label(mesh.status == .ready && mesh.overTailscale ? "Connected to your Mac · private Tailscale link" : mesh.status.line,
                  systemImage: mesh.isPaired ? "laptopcomputer.and.iphone" : "link")
                .font(AgentUIStyle.font(20, .semibold))
                .foregroundStyle(mesh.isPaired ? AgentUIStyle.green : AgentUIStyle.soft)
                .fixedSize(horizontal: false, vertical: true)
            if let note = mesh.note {
                Text(note)
                    .font(AgentUIStyle.font(17))
                    .foregroundStyle(AgentUIStyle.soft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if mesh.isPaired {
                if case .offline = mesh.status {
                    bigButton("Try again", icon: "arrow.clockwise", filled: false) { mesh.retry() }
                }
                if let last = mesh.lastTask {
                    Text("Last request: \(last)")
                        .font(AgentUIStyle.font(17))
                        .foregroundStyle(AgentUIStyle.soft)
                        .lineLimit(2)
                }
                bigButton("Leave my devices", icon: "xmark.circle", filled: false, tint: AgentUIStyle.red) {
                    mesh.leave()
                }
            } else {
                Text("Easiest: on your Mac run kairos pair (or open Kairos there and tap Add a device), then point this iPhone's Camera at the code. Tailscale must be on, on both.")
                    .font(AgentUIStyle.font(17))
                    .foregroundStyle(AgentUIStyle.soft)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Mac's Tailscale name, e.g. mac.tail1234.ts.net", text: $meshHub)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(AgentUIStyle.font(20))
                    .padding(12)
                    .background(AgentUIStyle.paper, in: RoundedRectangle(cornerRadius: 14))
                TextField("6-digit code from your Mac", text: $meshCode)
                    .keyboardType(.numberPad)
                    .font(AgentUIStyle.font(20))
                    .padding(12)
                    .background(AgentUIStyle.paper, in: RoundedRectangle(cornerRadius: 14))
                bigButton(meshJoining ? "Joining…" : "Join", icon: "link.badge.plus", filled: true) {
                    meshJoining = true
                    Task {
                        do {
                            try await mesh.pair(hub: meshHub, code: meshCode)
                            meshNote = "Joined. Kairos here and on your Mac now share one conversation."
                        } catch {
                            meshNote = MeshNode.problem(error, hub: MeshNode.hubURL(meshHub))
                        }
                        meshJoining = false
                    }
                }
                .disabled(meshJoining)
            }
            if let meshNote {
                Text(meshNote)
                    .font(AgentUIStyle.font(18, .medium))
                    .foregroundStyle(mesh.isPaired ? AgentUIStyle.green : AgentUIStyle.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("One Kairos across your iPhone and Mac: one conversation, over your private Tailscale network. Your Mac can ask this iPhone for help (your calendar, a reminder, a text) while Kairos is open. Anything that calls, messages or pays still needs Face ID here.")
                .font(AgentUIStyle.font(17))
                .foregroundStyle(AgentUIStyle.soft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var privacyNote: some View {
        Label {
            Text((brain == .gemini
                 ? "What you ask and photos of letters go to Google Gemini using your key."
                 : "What the rules here can't do goes to the open model on your own Mac, over your private Tailscale network. Nothing goes to Google.")
                 + " When this iPhone has joined your Mac, what you ask Kairos and its answers are also kept in the one conversation on your Mac (what a letter or the screen said stays here). Your contacts, reminders and calendar themselves stay on this phone.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.shield")
        }
        .font(AgentUIStyle.font(18))
        .foregroundStyle(AgentUIStyle.soft)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Building blocks

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(AgentUIStyle.font(26, .bold))
                .foregroundStyle(AgentUIStyle.ink)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 22))
    }

    private func bigButton(_ title: String, icon: String, filled: Bool, tint: Color = AgentUIStyle.green,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(AgentUIStyle.font(22, .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 70)
                .foregroundStyle(filled ? Color.white : tint)
                .background(filled ? tint : AgentUIStyle.paper, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    private func choiceRow(_ title: String, detail: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(selected ? AgentUIStyle.green : AgentUIStyle.soft.opacity(0.45))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AgentUIStyle.font(22, .semibold))
                        .foregroundStyle(AgentUIStyle.ink)
                    if let detail {
                        Text(detail)
                            .font(AgentUIStyle.font(16))
                            .foregroundStyle(AgentUIStyle.soft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
