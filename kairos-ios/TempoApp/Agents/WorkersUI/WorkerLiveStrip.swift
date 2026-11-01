import SwiftUI
import UIKit

// A slim bar for the top of the agent screen while agents are working:
//     ⟳ 2 agents working
//       Paper Reader: reading the PDF…                    0:41 ›
// Tap it for the Agents board. It draws nothing when no agent is working, and for 6 seconds after one finishes
// it shows "✓ Paper Reader finished" (tap for its result).

struct WorkerLiveStrip: View {
    /// Opens the board (with a run's id to go straight to that agent). Nil: the strip opens the board itself,
    /// full screen.
    var onOpen: ((UUID?) -> Void)? = nil

    @ObservedObject private var pool = WorkerPool.shared
    @State private var banner: AgentBoardBanner?
    @State private var seen: Set<UUID> = []
    @State private var primed = false
    @State private var showBoard = false
    @State private var boardRun: UUID?

    static let bannerSeconds: UInt64 = 6

    private var active: [WorkerRun] { pool.runs.filter { AgentBoardLook.isActive($0.status) } }

    var body: some View {
        VStack(spacing: 8) {
            if !active.isEmpty {
                workingBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let banner {
                bannerView(banner)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: active.map(\.id))
        .animation(.easeOut(duration: 0.25), value: banner)
        .onAppear(perform: prime)
        .onChange(of: pool.runs) { _, runs in noticeFinished(runs) }
        .fullScreenCover(isPresented: $showBoard) {
            AgentBoardView(onClose: { showBoard = false }, openRun: boardRun)
        }
    }

    // MARK: Working

    /// The agent that did something most recently (the one worth reading about).
    private var lead: WorkerRun? {
        let running = active.filter { $0.status == .running }
        let candidates = running.isEmpty ? active : running
        return candidates.max { a, b in
            (a.steps.last?.at ?? AgentBoardTime.began(a)) < (b.steps.last?.at ?? AgentBoardTime.began(b))
        }
    }

    private var headline: String {
        let running = active.filter { $0.status == .running }.count
        let waiting = active.count - running
        if running == 0 { return waiting == 1 ? "1 agent waiting to start" : "\(waiting) agents waiting to start" }
        let working = running == 1 ? "1 agent working" : "\(running) agents working"
        return waiting > 0 ? "\(working) · \(waiting) waiting" : working
    }

    private func doing(_ run: WorkerRun) -> String {
        if run.status == .queued { return "\(run.name): waiting to start" }
        guard let step = run.steps.last else { return "\(run.name): getting started…" }
        return "\(run.name): " + AgentBoardLook.ongoing(AgentBoardLook.lowerFirst(step.text))
    }

    private var workingBar: some View {
        Button { open(nil) } label: {
            HStack(spacing: 12) {
                ProgressView()
                    .tint(AgentBoardStyle.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline)
                        .font(AgentBoardStyle.font(18, .bold))
                        .foregroundStyle(AgentBoardStyle.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let lead {
                        Text(doing(lead))
                            .font(AgentBoardStyle.font(17))
                            .foregroundStyle(AgentBoardStyle.soft)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 4)
                if let lead, lead.status == .running {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(AgentBoardTime.duration(AgentBoardTime.elapsed(lead, now: context.date)))
                            .font(AgentBoardStyle.digits(18, .bold))
                            .foregroundStyle(AgentBoardStyle.green)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(AgentBoardStyle.green)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(AgentBoardStyle.green.opacity(0.35), lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(headline + (lead.map { ". " + doing($0) } ?? ""))
        .accessibilityHint("Shows the Agents board")
        .accessibilityAddTraits([.isButton, .updatesFrequently])
    }

    // MARK: Finished banner

    private func bannerView(_ b: AgentBoardBanner) -> some View {
        Button { open(b.runID) } label: {
            HStack(spacing: 12) {
                Image(systemName: b.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(b.ok ? AgentBoardStyle.green : AgentBoardStyle.red)
                Text(b.ok ? "\(b.name) finished" : "\(b.name) couldn't finish")
                    .font(AgentBoardStyle.font(19, .bold))
                    .foregroundStyle(AgentBoardStyle.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 4)
                Text(b.ok ? "See result" : "See why")
                    .font(AgentBoardStyle.font(17, .semibold))
                    .foregroundStyle(AgentBoardStyle.green)
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(b.ok ? AgentBoardStyle.greenBack : AgentBoardStyle.redBack, in: RoundedRectangle(cornerRadius: 18))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(b.ok ? "\(b.name) finished" : "\(b.name) couldn't finish")
        .accessibilityHint(b.ok ? "Shows what it found" : "Shows what went wrong")
    }

    /// Agents that had already finished before this screen appeared don't get a banner.
    private func prime() {
        guard !primed else { return }
        primed = true
        seen = Set(pool.runs.filter { AgentBoardLook.isFinished($0.status) }.map(\.id))
    }

    private func noticeFinished(_ runs: [WorkerRun]) {
        if !primed { prime(); return }
        let newlyFinished = runs.filter { AgentBoardLook.isFinished($0.status) && !seen.contains($0.id) }
        guard !newlyFinished.isEmpty else { return }
        seen.formUnion(newlyFinished.map(\.id))
        // Stopped by the person: they know already. Old news (over a minute ago): not worth a banner.
        let worth = newlyFinished.filter { run in
            run.status != .stopped && Date().timeIntervalSince(AgentBoardTime.ended(run) ?? Date()) < 60
        }
        guard let latest = worth.max(by: { (AgentBoardTime.ended($0) ?? .distantPast) < (AgentBoardTime.ended($1) ?? .distantPast) })
        else { return }
        let b = AgentBoardBanner(runID: latest.id, name: latest.name, ok: latest.status == .done)
        banner = b
        UIAccessibility.post(notification: .announcement, argument: b.ok ? "\(b.name) finished." : "\(b.name) couldn't finish.")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.bannerSeconds * 1_000_000_000)
            if banner == b { banner = nil }
        }
    }

    private func open(_ runID: UUID?) {
        if let onOpen {
            onOpen(runID)
        } else {
            boardRun = runID
            showBoard = true
        }
    }
}

/// "✓ Paper Reader finished" for a few seconds.
struct AgentBoardBanner: Equatable {
    let token = UUID()
    let runID: UUID
    let name: String
    let ok: Bool
}
