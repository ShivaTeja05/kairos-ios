import LocalAuthentication
import SwiftUI

// The Shield: what the Guardian on the person's own Mac reports (tempo-hub/guardian). A badge on the main screen that is
// green, amber or grey, and a sheet in plain words: what is protected, what Kairos stopped, and one big button (Face ID)
// to switch it back on. The phone asks the voice server for /voice/guardian/status with its phone key; no raw data,
// no secrets, only the Guardian's summary.

struct ShieldStatus: Decodable {
    struct Lockdown: Decodable { let locked: Bool?; let scopes: [String]?; let reason: String? }
    struct Alert: Decodable, Identifiable {
        let severity: String?; let code: String?; let text: String?; let at: String?
        var id: String { (at ?? "") + (code ?? "") }
    }
    struct Integrity: Decodable { let ok: Bool?; let sealed_at: String? }
    struct Vault: Decodable { let ok: Bool?; let records: Int? }
    struct Baseline: Decodable { let days_observed: Int?; let payees: Int? }
    let protected: Bool?
    let running: Bool?
    let headline: String?
    let checked_at: String?
    let lockdown: Lockdown?
    let alerts: [Alert]?
    let integrity: Integrity?
    let vault: Vault?
    let baseline: Baseline?
    let canaries: Int?
}

@MainActor
final class Shield: ObservableObject {
    enum State { case protected, paused, off }

    @Published var status: ShieldStatus?
    @Published var unreachable = false
    private var poll: Task<Void, Never>?

    private var base: URL? { KeyStore.get("base").flatMap(URL.init(string:)) }
    private var key: String? { KeyStore.get("key") }

    var state: State {
        guard let s = status, s.running == true else { return .off }
        if s.lockdown?.locked == true { return .paused }
        return s.protected == true ? .protected : .off
    }

    func start() {
        poll?.cancel()
        poll = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    func stop() {
        poll?.cancel()
        poll = nil
    }

    private func request(_ path: String, method: String = "GET") -> URLRequest? {
        guard let base, let key else { return nil }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 8
        req.setValue(key, forHTTPHeaderField: "X-Tempo-Phone-Key")
        req.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning")
        return req
    }

    func refresh() async {
        guard let req = request("voice/guardian/status") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            status = try JSONDecoder().decode(ShieldStatus.self, from: data)
            unreachable = false
        } catch {
            unreachable = true
        }
    }

    /// Only the owner, after Face ID or the passcode, lifts a lockdown. The Guardian then watches on as before.
    func switchBackOn() async -> Bool {
        let ok = (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Switch Kairos back on")) ?? false
        guard ok, let req = request("voice/guardian/unlock", method: "POST") else { return false }
        _ = try? await URLSession.shared.data(for: req)
        await refresh()
        return true
    }
}

private let green = Color(red: 0.18, green: 0.44, blue: 0.37)
private let amber = Color(red: 0.75, green: 0.35, blue: 0.05)
private let grey = Color(red: 0.45, green: 0.45, blue: 0.42)
private let red = Color(red: 0.70, green: 0.15, blue: 0.12)

/// The pill on the main screen. Tap it for the full picture.
struct ShieldBadge: View {
    @ObservedObject var shield: Shield

    private var text: String {
        switch shield.state {
        case .protected: return "Protected"
        case .paused: return "Kairos stopped something"
        case .off: return "Protection off"
        }
    }

    private var colour: Color {
        switch shield.state {
        case .protected: return green
        case .paused: return amber
        case .off: return grey
        }
    }

    private var icon: String {
        switch shield.state {
        case .protected: return "checkmark.shield.fill"
        case .paused: return "exclamationmark.shield.fill"
        case .off: return "shield.slash.fill"
        }
    }

    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(size: 19, weight: .bold, design: .rounded))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(colour.opacity(0.13), in: Capsule())
            .foregroundStyle(colour)
            .accessibilityLabel("Protection: \(text). Tap for details.")
    }
}

/// The full picture, in plain words and big type.
struct ShieldView: View {
    @ObservedObject var shield: Shield
    @Environment(\.dismiss) private var dismiss
    @State private var working = false

    private func colour(for severity: String?) -> Color {
        switch severity ?? "" {
        case "critical": return red
        case "high": return amber
        case "notice": return Color(red: 0.55, green: 0.45, blue: 0.10)
        default: return grey
        }
    }

    private func when(_ iso: String?) -> String {
        guard let iso, let date = ISO8601DateFormatter().date(from: iso) else { return "" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var headline: String {
        if shield.unreachable { return "Can't reach your Mac right now." }
        return shield.status?.headline ?? "Checking…"
    }

    private var headlineColour: Color {
        switch shield.state {
        case .protected: return green
        case .paused: return amber
        case .off: return grey
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: shield.state == .protected ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(headlineColour)
                        Text(headline)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white, in: RoundedRectangle(cornerRadius: 22))

                    if let lock = shield.status?.lockdown, lock.locked == true {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Paused: " + (lock.scopes ?? []).joined(separator: ", "))
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(amber)
                            if let reason = lock.reason, !reason.isEmpty {
                                Text(reason)
                                    .font(.system(size: 20, design: .rounded))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text("Nothing is sent and the helpers don't act until you switch this back on. If you're not sure why, ask someone you trust first.")
                                .font(.system(size: 18, design: .rounded))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                working = true
                                Task { _ = await shield.switchBackOn(); working = false }
                            } label: {
                                Label(working ? "Checking it's you…" : "Switch Kairos back on", systemImage: "faceid")
                                    .font(.system(size: 24, weight: .bold, design: .rounded))
                                    .frame(maxWidth: .infinity, minHeight: 76)
                                    .background(green, in: RoundedRectangle(cornerRadius: 20))
                                    .foregroundStyle(.white)
                            }
                            .disabled(working)
                        }
                        .padding(20)
                        .background(.white, in: RoundedRectangle(cornerRadius: 22))
                    }

                    if let s = shield.status, s.running == true {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("What Kairos checked").font(.system(size: 20, weight: .bold, design: .rounded))
                            fact(s.integrity?.ok, "Its own code and settings are unchanged since they were sealed", "Its own code or settings have changed")
                            fact(s.vault?.ok, "Your private vault adds up (\(s.vault?.records ?? 0) facts, every change logged)", "Your private vault was changed behind its back")
                            if let b = s.baseline {
                                fact(true, "It knows your rhythm: \(b.payees ?? 0) people you pay, over \(b.days_observed ?? 0) days", "")
                            }
                            fact(true, "\(s.canaries ?? 0) traps are set for anything pretending to be you", "")
                            if let t = s.checked_at, !t.isEmpty {
                                Text("Last checked " + when(t)).font(.system(size: 16)).foregroundStyle(.secondary)
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white, in: RoundedRectangle(cornerRadius: 22))
                    }

                    if let alerts = shield.status?.alerts, !alerts.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("What it stopped or noticed").font(.system(size: 20, weight: .bold, design: .rounded))
                            ForEach(alerts) { a in
                                HStack(alignment: .top, spacing: 10) {
                                    Circle().fill(colour(for: a.severity)).frame(width: 14, height: 14).padding(.top, 6)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(a.text ?? "")
                                            .font(.system(size: 19, design: .rounded))
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text(when(a.at)).font(.system(size: 15)).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white, in: RoundedRectangle(cornerRadius: 22))
                    }

                    Text("Every decision here is made by code on your own Mac, not by a model. Kairos never asks for a PIN or a code, never acts on words in a letter or a message, and never says \"this is safe\".")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
            }
            .background(Color(red: 0.96, green: 0.95, blue: 0.92).ignoresSafeArea())
            .navigationTitle("Your protection")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.font(.system(size: 20, weight: .semibold, design: .rounded))
                }
            }
            .refreshable { await shield.refresh() }
        }
        .task { await shield.refresh() }
    }

    private func fact(_ ok: Bool?, _ good: String, _ bad: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok == false ? "xmark.circle.fill" : (ok == nil ? "questionmark.circle" : "checkmark.circle.fill"))
                .foregroundStyle(ok == false ? red : (ok == nil ? grey : green))
                .font(.system(size: 22))
            Text(ok == false ? bad : good)
                .font(.system(size: 18, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
