import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// The same colours and type as the rest of Kairos (ContentView, AgentHomeView), kept here so this screen stands alone.
private enum TrustLook {
    static let paper = Color(red: 0.96, green: 0.95, blue: 0.92)
    static let green = Color(red: 0.18, green: 0.44, blue: 0.37)
    static let ink = Color(red: 0.11, green: 0.11, blue: 0.10)
    static let soft = Color(red: 0.25, green: 0.25, blue: 0.23)
    static let amber = Color(red: 0.6, green: 0.35, blue: 0.0)
    static let amberBack = Color(red: 1.0, green: 0.95, blue: 0.84)
    static let red = Color(red: 0.70, green: 0.20, blue: 0.15)
    static let mist = Color(red: 0.85, green: 0.85, blue: 0.82)
    static let lockedBack = Color(red: 0.92, green: 0.91, blue: 0.88)

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// The four big buttons on every row.
private enum TrustRowChoice: CaseIterable {
    case ask, oneHour, today, always

    var label: String {
        switch self {
        case .ask: return "Ask"
        case .oneHour: return "1 hour"
        case .today: return "Today"
        case .always: return "Always"
        }
    }
    var spoken: String {
        switch self {
        case .ask: return "ask me first"
        case .oneHour: return "allowed for one hour"
        case .today: return "allowed for today"
        case .always: return "always allowed"
        }
    }
    var duration: TrustDuration? {
        switch self {
        case .ask: return nil
        case .oneHour: return .oneHour
        case .today: return .today
        case .always: return .always
        }
    }
}

/// "What your agents can do without asking": one card per app with Ask / 1 hour / Today / Always for each kind of
/// action (anything but Ask needs Face ID), the locked rows that can never change (banks, paying, passwords, phone
/// security), a giant red "Stop everything", and what the agents did on their own.
struct TrustSettingsView: View {
    @ObservedObject private var policy = OwnerPolicy.shared
    @Environment(\.dismiss) private var dismiss
    @State private var now = Date()
    @State private var showAllApps = false
    /// The row waiting for Face ID.
    @State private var busyRow: String?
    @State private var note: String?
    @State private var noteIsGood = true
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    /// Shown even before anything is allowed: the apps people most often want help with.
    private static let featured = ["com.burbn.instagram", "com.facebook.Facebook", "net.whatsapp.WhatsApp",
                                   "com.apple.MobileSMS", "com.google.photos", "com.google.Gmail"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    stopButton
                    if let note { noteCard(note) }
                    ForEach(visibleApps) { appCard($0) }
                    moreAppsButton
                    lockedSection
                    activitySection
                }
                .padding(20)
            }
            .background(TrustLook.paper.ignoresSafeArea())
            .navigationTitle("Permissions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(TrustLook.font(20, .bold))
                }
            }
        }
        .environment(\.colorScheme, .light)
        .onAppear {
            now = Date()
            policy.refresh(now: now)
        }
        .onReceive(tick) { date in
            now = date
            policy.refresh(now: date)
        }
    }

    // MARK: - Top

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Permissions", systemImage: "lock.shield.fill")
                .font(TrustLook.font(20, .semibold))
                .foregroundStyle(TrustLook.green)
            Text("What your agents can do without asking")
                .font(TrustLook.font(32, .bold))
                .foregroundStyle(TrustLook.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Everything else, they ask you first. Allowing more needs Face ID or your passcode. Taking it back never does.")
                .font(TrustLook.font(19))
                .foregroundStyle(TrustLook.soft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stopButton: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: stopEverything) {
                Label("Stop everything", systemImage: "hand.raised.fill")
                    .font(TrustLook.font(30, .bold))
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .background(TrustLook.red, in: RoundedRectangle(cornerRadius: 26))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Takes back every permission at once. Your agents will ask you before everything again.")
            Text("One tap takes back every permission. No Face ID needed: making things safer never needs it.")
                .font(TrustLook.font(17))
                .foregroundStyle(TrustLook.soft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func noteCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: noteIsGood ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(TrustLook.font(20, .semibold))
        .foregroundStyle(noteIsGood ? TrustLook.green : TrustLook.amber)
        .padding(16)
        .background(noteIsGood ? Color.white : TrustLook.amberBack, in: RoundedRectangle(cornerRadius: 18))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Apps

    private var visibleApps: [TrustApp] {
        var out: [TrustApp] = []
        var seen = Set<String>()
        func add(_ app: TrustApp) {
            guard app.category != .banking, !app.neverTrusted, !actions(for: app).isEmpty,
                  seen.insert(app.key).inserted else { return }
            out.append(app)
        }
        for g in policy.grants { add(TrustApps.identify(bundleID: g.bundleID, name: g.appName)) }
        for id in Self.featured {
            if let app = TrustApps.catalogue.first(where: { $0.bundleID == id }) { add(app) }
        }
        if showAllApps { TrustApps.catalogue.forEach(add) }
        return out
    }

    /// The usual actions for this kind of app, plus anything the owner has already set for it.
    private func actions(for app: TrustApp) -> [ActionClass] {
        var list = app.category.everydayActions
        for g in policy.grants where g.appKey == app.key && g.action.canBeAllowed && !list.contains(g.action) {
            list.append(g.action)
        }
        return list
    }

    private func appCard(_ app: TrustApp) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: app.category.symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(TrustLook.green, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(TrustLook.font(26, .bold))
                        .foregroundStyle(TrustLook.ink)
                    Text(app.category.plainName)
                        .font(TrustLook.font(17))
                        .foregroundStyle(TrustLook.soft)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            ForEach(actions(for: app), id: \.self) { action in
                actionRow(app, action)
            }
        }
        .padding(18)
        .background(.white, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .contain)
    }

    private func actionRow(_ app: TrustApp, _ action: ActionClass) -> some View {
        let grant = policy.activeGrant(app: app, action: action, now: now)
        let current = Self.choice(for: grant)
        let rowID = app.key + "|" + action.rawValue
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(action.plainName)
                    .font(TrustLook.font(21, .semibold))
                    .foregroundStyle(TrustLook.ink)
                Spacer(minLength: 8)
                if let status = Self.status(grant, now: now) {
                    Text(status)
                        .font(TrustLook.font(16, .semibold))
                        .foregroundStyle(grant?.mode == .never ? TrustLook.red : TrustLook.green)
                        .multilineTextAlignment(.trailing)
                }
            }
            HStack(spacing: 6) {
                ForEach(TrustRowChoice.allCases, id: \.self) { choice in
                    let selected = current == choice
                    Button { choose(choice, app: app, action: action, grant: grant) } label: {
                        Text(choice.label)
                            .font(TrustLook.font(19, .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(selected ? TrustLook.green : TrustLook.mist, in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(selected ? Color.white : TrustLook.ink)
                    }
                    .buttonStyle(.plain)
                    .disabled(busyRow != nil)
                    .accessibilityLabel("\(action.plainName) in \(app.name): \(choice.spoken)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityHint(choice == .ask ? "" : "Needs Face ID or your passcode.")
                }
            }
            .opacity(busyRow == rowID ? 0.5 : 1)
        }
    }

    private var moreAppsButton: some View {
        Button { showAllApps.toggle() } label: {
            Label(showAllApps ? "Show fewer apps" : "Show more apps",
                  systemImage: showAllApps ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                .font(TrustLook.font(22, .bold))
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(.white, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(TrustLook.green, lineWidth: 2))
                .foregroundStyle(TrustLook.green)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Locked rows

    private var lockedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Always asks, or never done")
                .font(TrustLook.font(26, .bold))
                .foregroundStyle(TrustLook.ink)
                .accessibilityAddTraits(.isHeader)
            lockedCard(icon: AppCategory.banking.symbol, title: "Banks and payments",
                       text: "Banks and payments always ask you. This can't be changed.",
                       detail: "Barclays, HSBC, Lloyds, Halifax, NatWest, Santander, Nationwide, Monzo, Starling, Revolut, PayPal and every other bank, payment, wallet or investing app.")
            lockedCard(icon: "cart.fill", title: "Paying and buying",
                       text: "Paying and buying always ask you, in every app. This can't be changed.", detail: nil)
            lockedCard(icon: "key.fill", title: "Passwords, PINs and codes",
                       text: "Your agents never type these. They're always yours to type.", detail: nil)
            lockedCard(icon: "faceid", title: "Phone security and privacy",
                       text: "Your agents never change Face ID, your passcode, your Apple ID or privacy settings.", detail: nil)
        }
    }

    private func lockedCard(icon: String, title: String, text: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(TrustLook.soft)
                    .frame(width: 44, height: 44)
                    .background(TrustLook.mist, in: RoundedRectangle(cornerRadius: 12))
                Text(title)
                    .font(TrustLook.font(22, .bold))
                    .foregroundStyle(TrustLook.ink)
                Spacer(minLength: 0)
                Label("Locked", systemImage: "lock.fill")
                    .font(TrustLook.font(16, .bold))
                    .foregroundStyle(TrustLook.soft)
            }
            Text(text)
                .font(TrustLook.font(20, .semibold))
                .foregroundStyle(TrustLook.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(TrustLook.font(16))
                    .foregroundStyle(TrustLook.soft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TrustLook.lockedBack, in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Locked. \(title). \(text)")
    }

    // MARK: - Recent activity

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent activity")
                .font(TrustLook.font(26, .bold))
                .foregroundStyle(TrustLook.ink)
                .accessibilityAddTraits(.isHeader)
            Text(policy.activitySummary(now: now))
                .font(TrustLook.font(20, .medium))
                .foregroundStyle(TrustLook.ink)
                .fixedSize(horizontal: false, vertical: true)
            if policy.activity.isEmpty {
                Text("When your agents do something without asking, it shows here with the time, so you can always check.")
                    .font(TrustLook.font(17))
                    .foregroundStyle(TrustLook.soft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(policy.recentActivity.prefix(30))) { entry in
                activityRow(entry)
            }
        }
    }

    private func activityRow(_ e: TrustActivity) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: e.category.symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(TrustLook.green)
                .frame(width: 40, height: 40)
                .background(TrustLook.paper, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(e.action.done) \(e.action.preposition) \(e.appName)")
                    .font(TrustLook.font(20, .semibold))
                    .foregroundStyle(TrustLook.ink)
                if !e.detail.isEmpty {
                    Text(e.detail)
                        .font(TrustLook.font(18))
                        .foregroundStyle(TrustLook.ink)
                        .lineLimit(3)
                }
                Text("\(Self.when(e.time)) · \(e.agent) · allowed by your setting")
                    .font(TrustLook.font(16))
                    .foregroundStyle(TrustLook.soft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.white, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    private func stopEverything() {
        let n = policy.revokeAll()
        say(n == 0 ? "Nothing was allowed, so your agents already ask you before everything. I've told anything running to stop."
                   : "Stopped. Your agents will ask you before everything again.", good: true)
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }

    private func choose(_ choice: TrustRowChoice, app: TrustApp, action: ActionClass, grant: TrustGrant?) {
        let rowID = app.key + "|" + action.rawValue
        guard let duration = choice.duration else {
            if grant?.mode == .never {
                // Lifting the owner's own block gives agents more room, so it needs Face ID.
                busyRow = rowID
                Task {
                    let ok = await policy.unblock(appBundleID: app.bundleID, appName: app.name, action: action)
                    busyRow = nil
                    say(ok ? "Your agents will ask you first before they \(action.phrase) \(action.preposition) \(app.name)."
                           : TrustWording.notConfirmed, good: ok)
                }
            } else if policy.revoke(appBundleID: app.bundleID, appName: app.name, action: action) > 0 {
                say("Done. Your agents will ask you first before they \(action.phrase) \(action.preposition) \(app.name).", good: true)
            }
            return
        }
        guard Self.choice(for: grant) != choice else { return }
        busyRow = rowID
        Task {
            let result = await policy.grant(appBundleID: app.bundleID, appName: app.name, action: action, duration: duration)
            busyRow = nil
            now = Date()
            switch result {
            case .granted(let g):
                say("Done. Your agents can \(action.phrase) \(action.preposition) \(app.name) without asking, \(OwnerPolicy.durationPhrase(g.mode, now: now)).",
                    good: true)
            case .notAllowed(let reason), .ownerNotConfirmed(let reason):
                say(reason, good: false)
            }
        }
    }

    private func say(_ text: String, good: Bool) {
        note = text
        noteIsGood = good
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: text)
        #endif
    }

    // MARK: - Small helpers

    /// Which button is lit for this setting. Nil for the owner's block (none of the four).
    private static func choice(for grant: TrustGrant?) -> TrustRowChoice? {
        guard let grant else { return .ask }
        switch grant.mode {
        case .ask: return .ask
        case .never: return nil
        case .always: return .always
        case .allowUntil: return grant.duration == .today ? .today : .oneHour
        }
    }

    private static func status(_ grant: TrustGrant?, now: Date) -> String? {
        guard let grant else { return nil }
        switch grant.mode {
        case .ask: return nil
        case .never: return "Blocked by you"
        case .always: return "Doesn't ask"
        case .allowUntil(let end):
            let phrase = OwnerPolicy.untilPhrase(end, now: now)
            return phrase == "for the rest of today" ? "Rest of today" : phrase.prefix(1).uppercased() + phrase.dropFirst()
        }
    }

    /// "Today at 03:12", "Yesterday at 21:40", "Sat 24 Oct at 14:05".
    private static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today at \(OwnerPolicy.clock(date))" }
        if calendar.isDateInYesterday(date) { return "Yesterday at \(OwnerPolicy.clock(date))" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE d MMM"
        return "\(f.string(from: date)) at \(OwnerPolicy.clock(date))"
    }
}
