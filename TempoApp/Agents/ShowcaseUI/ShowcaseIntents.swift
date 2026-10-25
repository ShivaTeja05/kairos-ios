import AppIntents
import Foundation

// Present mode by voice: "Hey Siri, present Kairos" opens Kairos and starts the show (Presenter.shared, standard
// script). A Shortcut can pick the one-minute version with the Length parameter.
//
// An app may have only ONE AppShortcutsProvider (TempoShortcuts in TempoApp.swift), and the phrases must be
// written literally inside it. Paste this entry into `TempoShortcuts.appShortcuts`, straight after Talk to Kairos:
//
//        AppShortcut(intent: PresentKairosIntent(),
//                    phrases: ["Present \(.applicationName)",
//                              "\(.applicationName), introduce yourself",
//                              "Show the judges \(.applicationName)"],
//                    shortTitle: "Present Kairos",
//                    systemImageName: "play.rectangle.fill")
//
// iOS allows at most 10 AppShortcut entries per app. With Talk, Read a letter, Ask Kairos and Kairos helpers this
// is the 5th. If the list ever passes 10, keep Talk to Kairos first and Present Kairos second for demo day, and drop
// "Kairos helpers" first (it's one tap inside the app).
//
// Deployment target is iOS 17: `openAppWhenRun` covers iOS 17–25; on iOS 26 `supportedModes` is used instead.
// Both are literals so the App Intents metadata extractor can read them at build time.

/// "Present Kairos": Kairos introduces itself, shows its helpers at work, then hands over to the audience.
struct PresentKairosIntent: AppIntent {
    static let title: LocalizedStringResource = "Present Kairos"
    static let description = IntentDescription("Kairos introduces itself, shows what its helpers can do on this phone, then asks what you'd like it to do.")
    /// iOS 17–25. Deprecated in the iOS 26 SDK, where `supportedModes` below is used instead.
    static let openAppWhenRun = true
    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = .foreground
    /// The show uses the owner's calendar and helpers: from a locked phone, Face ID or the passcode first.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Length", default: .full)
    var length: KairosShowLength

    static var parameterSummary: some ParameterSummary {
        Summary("Present Kairos: \(\.$length)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // Never await the show here: it lasts minutes and the intent must return. No Siri dialog either, so Siri
        // doesn't talk over Kairos's opening line. A show already running is left alone.
        KairosShowUI.startWhenReady(length.script)
        return .result()
    }
}

/// Which show to give. Full = the standard script (about 3 minutes); quick = the short pitch (about 1 minute).
enum KairosShowLength: String, AppEnum {
    case full
    case quick

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Presentation length"
    static let caseDisplayRepresentations: [KairosShowLength: DisplayRepresentation] = [
        .full: "Full show (3 min)",
        .quick: "Quick pitch (1 min)",
    ]

    var script: ShowScript { self == .quick ? .short : .standard }
}

/// The Siri phrases for present mode, the way a person says them (for a rehearsal card or a help screen).
enum KairosShowPhrases {
    static let thingsToSay: [String] = [
        "Hey Siri, present Kairos",
        "Hey Siri, Kairos, introduce yourself",
        "Hey Siri, show the judges Kairos",
    ]
}
