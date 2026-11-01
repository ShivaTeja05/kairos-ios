import Foundation
#if canImport(UIKit)
import UIKit
#endif

// Where the memory meets the rest of the app, set up once (AgentAppHooks.connect, and Siri's run path):
//   - the chat history listens to Kairos's lines and learns where each request came from (voice call, Present mode,
//     Siri in the background; a Shortcut's text is marked by Kairos itself);
//   - Gemini's picture of the phone (PhoneContext.providers["memory"]) gets the few remembered facts that matter to
//     the request being answered, plus the titles of the last few chats. Nothing else leaves the phone;
//   - "remember that Priya is my daughter" stays with the People helper's own rule;
//   - the relations taught to the People helper become memories once, so they show in the Memory window.

@MainActor
enum MemoryContext {
    /// The person's latest request (set by the chat history as each one arrives).
    static var lastWords = ""
    /// At most this many facts per request.
    static let factsPerRequest = 6
    static let maxChars = 700

    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let history = ConversationStore.shared
        ConversationStore.sourceProbe = {
            if VoiceContextBridge.shared.toolCallInFlight { return .voice }
            if Presenter.shared.isPresenting || KairosShowUI.isShowing { return .show }
            #if canImport(UIKit)
            if UIApplication.shared.applicationState == .background { return .siri }
            #endif
            return nil
        }
        history.onPersonWords = { words in lastWords = words }
        ConversationStore.isPastedRequest = { KairosAgent.pastedMessage($0) != nil }
        history.attach(to: KairosAgent.shared)
        MemoryRules.deferral.set { words in PeopleAgent.teachParts(words) != nil }
        MemoryStore.shared.seedOnce(from: taughtRelations())
        PhoneContext.providers["memory"] = { contextLine() }
    }

    /// For Gemini's system prompt. Nil when there's nothing to add.
    static func contextLine(now: Date = Date()) -> String? {
        // The ElevenLabs voice's start-of-call summary uses the same providers: it gets no memories.
        let bridge = VoiceContextBridge.shared
        let forVoiceSummary = bridge.isAttached && !bridge.toolCallInFlight && !KairosAgent.shared.working
        var parts: [String] = []
        if !forVoiceSummary, let facts = factsLine(for: lastWords, now: now) { parts.append(facts) }
        if let asked = ConversationStore.shared.askedAboutSession {
            parts.append("The person is asking about their chat from \(MemorySpeech.when(asked.startedAt, now: now, calendar: .current).lowercased()) \(ConversationStore.contextTitle(asked)); recall_conversation reads it.")
        }
        if !forVoiceSummary, let recent = ConversationStore.shared.recentSummary(now: now) { parts.append(recent) }
        guard !parts.isEmpty else { return nil }
        let text = parts.joined(separator: "\n")
        return text.count > maxChars ? String(text.prefix(maxChars - 1)) + "…" : text
    }

    /// "Things the person asked Kairos to remember (their own words): “My GP is Dr Shah”; …". The facts that share
    /// words with the request (and up to two likes and dislikes, which shape every answer); the most recent ones
    /// when there is no request yet.
    static func factsLine(for words: String, now: Date = Date()) -> String? {
        let store = MemoryStore.shared
        guard !store.facts.isEmpty else { return nil }
        var chosen: [MemoryFact]
        if words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chosen = store.recent(factsPerRequest)
        } else {
            chosen = store.relevant(to: words, limit: factsPerRequest - 2, now: now)
            store.touch(chosen.map(\.id), now: now)
            let likes = store.recent(store.facts.count).filter { $0.category == .preferences && !chosen.contains($0) }.prefix(2)
            chosen += likes
        }
        guard !chosen.isEmpty else { return nil }
        let items = chosen.prefix(factsPerRequest).map { "“\(MemorySpeech.clip($0.text, 120))”" }
        return "Things the person asked Kairos to remember (their own words, kept on this phone; use them when they help, don't recite them): "
            + items.joined(separator: "; ") + "."
    }

    /// The People helper's taught relations as (name, relation): the most specific words for each person.
    static func taughtRelations() -> [(name: String, relation: String)] {
        let book = PeopleDirectory.shared.taught()
        var keysByName: [String: [String]] = [:]
        for (key, entries) in book {
            for entry in entries { keysByName[entry.name, default: []].append(key) }
        }
        return keysByName.keys.sorted().compactMap { name in
            let keys = keysByName[name] ?? []
            // "eldest daughter" over "daughter"; "child" over the "son" and "daughter" it was filed under.
            let best = keys.max { a, b in
                let wa = a.split(separator: " ").count, wb = b.split(separator: " ").count
                if wa != wb { return wa < wb }
                let ca = covered(by: a, in: keys), cb = covered(by: b, in: keys)
                if ca != cb { return ca < cb }
                return a > b
            }
            return best.map { (name: name, relation: $0) }
        }
    }

    private static func covered(by key: String, in keys: [String]) -> Int {
        let groups = PeopleDirectory.relationWords[key] ?? []
        return keys.filter { $0 != key && groups.contains($0) }.count
    }
}
