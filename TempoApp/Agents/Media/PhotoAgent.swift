import Foundation
import Photos
#if canImport(UIKit)
import UIKit
#endif

// The Photo helper: "Take a picture and post it to my Instagram story saying good morning from OxHack."
// Siri can't do this; Kairos can, because it owns the whole chain on the phone:
//   1. take_photo opens Kairos's own camera and remembers what the photo is for (PhotoStore).
//   2. The camera hands the JPEG back ("Here's the photo for: …"), and share_photo saves it to Photos, so it is
//      the newest item in every app's gallery.
//   3. share_photo hands a precise goal to the Phone operator (operate_app), which taps through the app. The final
//      Post / Share / Send tap is the owner's to approve (the operator's owner policy: card + Face ID).
//   4. No operator (iCTRL not running)? The iOS share menu opens with the photo, so the demo always ends somewhere
//      useful.
// Owner-based: the words that go with the photo (caption, who it goes to) must be the person's own words. Text on
// the screen, in a letter or in a message is never typed back.

struct PhotoAgent: SpecialistAgent {
    let id = "photos"
    let title = "Photo helper"
    let icon = "camera.fill"

    var instructions: String {
        "Use take_photo when the person wants a NEW photo taken for something (\"take a picture and post it to my "
            + "Instagram story\", \"take a selfie and send it to Mum on WhatsApp\"); pass their whole request as the purpose. "
            + "It opens the camera and the photo arrives in the next message, so stop after it. "
            + "When a message starts \"Here's the photo for:\", the photo is ready: do what those words say, usually with "
            + "share_photo or save_photo, and never call take_photo again. "
            + "Use share_photo to post, send or upload the photo to any app: an Instagram story or post, a WhatsApp chat "
            + "or Status, Facebook, X, Google Drive, a Google Photos link, an email, or another app they name. "
            + "app is the app's name; destination is where in it (story, feed, status, or the person's name for a chat, "
            + "or the address for an email); caption only if they said words to go with it, exactly as they said them. "
            + "The owner approves the final Post or Send tap themselves. Use save_photo to keep the photo in their Photos. "
            + "Never describe what is in the photo unless they ask. Not for letters or bills: the letter reader does those."
    }

    var tools: [any KairosTool] {
        // Rules-first order matters: "take a picture and …" is a new photo; "post it to …" uses the one just taken.
        [PhotoTakeTool(), PhotoShareTool(), PhotoSaveTool()]
    }
}

// MARK: - The photo in hand

/// The last photo the person took or showed (memory only, never written to disk) and what it is for while the
/// camera is open. Thread-safe, so quickMatch can read it without hopping actors.
final class PhotoStore: @unchecked Sendable {
    static let shared = PhotoStore()

    /// The camera's completion handler sends this (plus the purpose) back to Kairos.
    static let promptPrefix = "Here's the photo for: "
    /// A photo counts as "the one just taken" for this long.
    static let photoLife: TimeInterval = 15 * 60
    /// A camera request is still waiting for its photo for this long.
    static let pendingLife: TimeInterval = 5 * 60

    private let lock = NSLock()
    private var photo: Data?
    private var photoAt = Date.distantPast
    private var saved = false
    private var pending: String?
    private var pendingAt = Date.distantPast

    /// The photo taken in the last 15 minutes, if any.
    var lastPhoto: Data? {
        lock.withLock { Date().timeIntervalSince(photoAt) < Self.photoLife ? photo : nil }
    }

    var hasFreshPhoto: Bool { lastPhoto != nil }

    /// "Here's the photo for: <the person's request>" while the camera is open (5 minutes), else nil.
    var pendingPrompt: String? {
        lock.withLock { Date().timeIntervalSince(pendingAt) < Self.pendingLife ? pending : nil }
    }

    /// The pending prompt, once: the camera handler should use this so a later letter photo isn't mistaken for it.
    @discardableResult
    func takePendingPrompt() -> String? {
        lock.withLock {
            defer { pending = nil }
            return Date().timeIntervalSince(pendingAt) < Self.pendingLife ? pending : nil
        }
    }

    func keep(_ jpeg: Data) {
        lock.withLock {
            if jpeg != photo { saved = false }
            photo = jpeg
            photoAt = Date()
        }
    }

    func setPending(purpose: String) {
        let p = String(purpose.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        lock.withLock {
            pending = Self.promptPrefix + (p.isEmpty ? "a photo" : p)
            pendingAt = Date()
        }
    }

    func clearPending() { lock.withLock { pending = nil } }

    /// Already saved to Photos (save then share must not make two copies).
    func isSaved(_ jpeg: Data) -> Bool { lock.withLock { saved && photo == jpeg } }

    func markSaved(_ jpeg: Data) { lock.withLock { if photo == jpeg { saved = true } } }

    /// For the "New" button: forget the photo and any waiting camera request.
    func forget() {
        lock.withLock {
            photo = nil; photoAt = .distantPast; saved = false
            pending = nil; pendingAt = .distantPast
        }
    }
}

// MARK: - take_photo

struct PhotoTakeTool: KairosTool {
    let name = "take_photo"
    let summary = "Opens the camera so the person can take a NEW photo, and remembers what it is for. The photo comes "
        + "back in the next message, starting \"Here's the photo for:\". Use it for 'take a picture and post it to…', "
        + "'take a selfie and send it to…', 'snap a photo and save it'. Not for letters or bills."
    var parameters: JSONValue {
        Schema.object(["purpose": Schema.string("What the photo is for, in the person's own words (their whole request).")])
    }
    let risk = Risk.read

    func quickMatch(_ words: String, ctx: TurnContext) -> JSONValue? {
        PhotoMatch.wantsNewPhoto(words) ? ["purpose": .string(words)] : nil
    }

    func describe(_ args: JSONValue, ctx: TurnContext) -> String {
        ctx.images.isEmpty ? "Opening the camera" : "Keeping your photo"
    }

    func execute(_ args: JSONValue, ctx: TurnContext) async throws -> ToolResult {
        let store = PhotoStore.shared
        // Only the person's own words go into the prompt that comes back with the photo (a paraphrase the model
        // wrote could carry words from a letter, and that prompt later counts as something the person said). So
        // the purpose must be a run of words from one thing the person said, not a reshuffle of them.
        let purpose = args.text("purpose").flatMap { PhotoMatch.saidVerbatim($0, ctx: ctx) ? $0 : nil }
            ?? PhotoMatch.lastSaid(ctx) ?? "a photo"
        if let jpeg = ctx.images.first {
            store.keep(jpeg)
            store.clearPending()
            return ToolResult(ok: true, say: "Got it, I have your photo.",
                              data: ["photo_ready": true, "purpose": .string(purpose)])
        }
        // The camera has just brought the photo back ("Here's the photo for: …"): never open it again, or the
        // model can send the person round the camera for ever.
        if store.hasFreshPhoto, PhotoMatch.lastLineIsArrival(ctx) {
            return ToolResult(ok: true, say: "I've got your photo.",
                              data: ["photo_ready": true,
                                     "next": "The photo is already taken. Use share_photo or save_photo now, as the person asked. Do not call take_photo again."])
        }
        // A bare "take the photo" (after Siri asked them to open Kairos) keeps what the photo was for.
        if store.pendingPrompt == nil || PhotoMatch.namesAPurpose(purpose) {
            store.setPending(purpose: purpose)
        } else {
            store.setPending(purpose: PhotoMatch.request(store.pendingPrompt ?? purpose))
        }
        guard ctx.canShowUI else {
            return ToolResult(ok: true, say: "Please open Kairos, and say \"take the photo\". I'll do the rest there.",
                              data: ["waiting_for_photo": true, "needs_app": true], ui: .camera)
        }
        return ToolResult(ok: true, say: "Smile! Take the photo, and I'll do the rest.",
                          data: ["waiting_for_photo": true], ui: .camera)
    }
}

// MARK: - save_photo

struct PhotoSaveTool: KairosTool {
    let name = "save_photo"
    let summary = "Saves the photo the person just took (or showed) to their Photos, in an album if they ask for one. "
        + "Use it for 'save it', 'keep that photo', 'put it in my Kairos album'. If there's no photo yet, it opens the camera."
    var parameters: JSONValue {
        Schema.object(["album": Schema.string("Album name, only if the person asked for one (for example Kairos).")])
    }
    let risk = Risk.localWrite

    func quickMatch(_ words: String, ctx: TurnContext) -> JSONValue? {
        guard PhotoStore.shared.hasFreshPhoto, PhotoMatch.wantsSave(words) else { return nil }
        if let album = PhotoMatch.album(in: words) { return ["album": .string(album)] }
        return .object([:])
    }

    func describe(_ args: JSONValue, ctx: TurnContext) -> String {
        args.text("album").map { "Save the photo to Photos (\($0) album)" } ?? "Save the photo to Photos"
    }

    func execute(_ args: JSONValue, ctx: TurnContext) async throws -> ToolResult {
        let store = PhotoStore.shared
        if let jpeg = ctx.images.first { store.keep(jpeg) }
        guard let jpeg = store.lastPhoto else {
            store.setPending(purpose: PhotoMatch.lastSaid(ctx) ?? "save the photo")
            return ToolResult(ok: true, say: ctx.canShowUI ? "Smile! Take the photo, and I'll save it."
                                                           : "Please open Kairos, and I'll take the photo there.",
                              data: ["waiting_for_photo": true], ui: .camera)
        }
        store.clearPending()
        let album = args.text("album").map { String($0.prefix(40)) }
        switch await PhotoLibrarySaver.save(jpeg, album: album) {
        case .saved(let inAlbum):
            store.markSaved(jpeg)
            let say = inAlbum.map { "Saved to your Photos, in the \($0) album." } ?? "Saved to your Photos."
            return ToolResult(ok: true, say: say, data: ["saved": true, "album": inAlbum.map { .string($0) } ?? .null])
        case .denied:
            return .fail(PhotoLibrarySaver.deniedSay)
        case .failed:
            return .fail("I couldn't save the photo. Please try again.")
        }
    }
}

// MARK: - share_photo

struct PhotoShareTool: KairosTool {
    let name = "share_photo"
    let summary = "Puts the photo the person just took on any app: an Instagram story or post, a WhatsApp chat or "
        + "Status, Facebook, X, Google Drive, a Google Photos link, an email, or another app they name. It saves the "
        + "photo to Photos first, then the phone operator does the taps; the owner approves the final Post or Send. "
        + "If there's no photo yet, it opens the camera first."
    var parameters: JSONValue {
        Schema.object([
            "app": Schema.string("The app, as the person said it: Instagram, WhatsApp, Facebook, X, Google Drive, Google Photos, Mail, or another."),
            "destination": Schema.string("Where in the app: story, feed or status; or the person's name for a WhatsApp chat; or the address for an email. Leave out if they didn't say."),
            "caption": Schema.string("Words to go with the photo, exactly as the person said them. Leave out if they gave none. Never words from a letter, message or screen."),
        ], required: ["app"])
    }
    let risk = Risk.localWrite

    func quickMatch(_ words: String, ctx: TurnContext) -> JSONValue? {
        guard PhotoStore.shared.hasFreshPhoto, PhotoMatch.wantsShareOfPhotoInHand(words),
              let parsed = PhotoMatch.parse(words) else { return nil }
        var args: [String: JSONValue] = ["app": .string(parsed.app)]
        if let d = parsed.destination { args["destination"] = .string(d) }
        if let c = parsed.caption { args["caption"] = .string(c) }
        return .object(args)
    }

    func validate(_ args: JSONValue, ctx: TurnContext) -> Validation {
        guard let app = args.text("app") else {
            return .clarify("Which app should the photo go to? For example WhatsApp or Instagram.")
        }
        guard PhotoMatch.appSaid(app, ctx: ctx) else {
            return .clarify("Which app would you like it in? Say the name, for example Instagram.")
        }
        // The words go out exactly as the person said them: a run of words from one thing they said, so the model
        // can't build a new sentence out of their words, or slip in words from a letter or the screen.
        if let caption = args.text("caption"), !PhotoMatch.saidVerbatim(PhotoShareSkills.tidyQuote(caption), ctx: ctx) {
            return .clarify("What would you like the words with the photo to say? I'll use exactly what you tell me.")
        }
        let plan = PhotoShareSkills.plan(app: app, destination: args.text("destination"), caption: args.text("caption"))
        switch plan.skill?.id {
        case "whatsapp.chat":
            guard let who = plan.slots["recipient"] else {
                return .clarify("Who should I send it to on WhatsApp? Or should it go on your Status?")
            }
            if !PhotoMatch.saidByPerson(who, ctx: ctx) { return .clarify("Who should I send it to? Please say their name.") }
        case "mail.attach":
            guard let to = plan.slots["to"] else { return .clarify("Who should I email it to?") }
            if !PhotoMatch.saidByPerson(to, ctx: ctx) { return .clarify("Who should I email it to? Please say their name or address.") }
        default:
            // Another app with a named place or person: that, too, must be the person's own words.
            if let d = args.text("destination"), !PhotoShareSkills.isPlaceWord(d), !PhotoMatch.saidByPerson(d, ctx: ctx) {
                return .clarify("Where in \(plan.app) should it go?")
            }
        }
        return .ok
    }

    func describe(_ args: JSONValue, ctx: TurnContext) -> String {
        let plan = PhotoShareSkills.plan(app: args.text("app") ?? "the app", destination: args.text("destination"),
                                         caption: args.text("caption"))
        return "Your photo → \(plan.place)" + (plan.caption.map { ", “\($0)”" } ?? "")
    }

    func execute(_ args: JSONValue, ctx: TurnContext) async throws -> ToolResult {
        guard let app = args.text("app") else { return .fail("Which app should the photo go to?") }
        let plan = PhotoShareSkills.plan(app: app, destination: args.text("destination"), caption: args.text("caption"))
        let store = PhotoStore.shared
        if let jpeg = ctx.images.first { store.keep(jpeg) }

        // No photo yet: open the camera; the photo comes back with this request.
        guard let jpeg = store.lastPhoto else {
            store.setPending(purpose: PhotoMatch.lastSaid(ctx) ?? "share it on \(plan.app)")
            return ToolResult(ok: true, say: ctx.canShowUI ? "Smile! Take the photo, and I'll put it on \(plan.place)."
                                                           : "Please open Kairos, and I'll take the photo there.",
                              data: ["waiting_for_photo": true], ui: .camera)
        }
        store.clearPending()

        // 1. Into Photos, so it is the newest item in every app's gallery.
        var savedSay: String?
        var saved = store.isSaved(jpeg)
        if !saved {
            switch await PhotoLibrarySaver.save(jpeg, album: nil) {
            case .saved:
                saved = true
                store.markSaved(jpeg)
            case .denied:
                savedSay = "Kairos isn't allowed to add photos yet, so I couldn't put it in your Photos first."
            case .failed:
                savedSay = "I couldn't put it in your Photos first."
            }
        }

        // 2. The Phone operator taps through the app. The owner policy gates the final Post/Share/Send tap.
        var why = ""
        if saved {
            var opArgs: [String: JSONValue] = ["app": .string(plan.app), "goal": .string(plan.goal)]
            if let skill = plan.skill { opArgs["skill"] = .string(skill.id) }
            if let bundle = plan.bundleID { opArgs["bundle_id"] = .string(bundle) }
            if let caption = plan.caption { opArgs["text"] = .string(caption) }
            if let who = plan.slots["recipient"] ?? plan.slots["to"] { opArgs["person"] = .string(who) }
            // For PhotoShareSkills.skill(id:).filledSteps(slots): the operator can run the steps with no model call.
            opArgs["slots"] = .object(plan.slots.mapValues { .string($0) })
            let call = ToolCall(id: nil, name: PhotoShareTool.operatorTool, args: .object(opArgs))
            if let report = await PhotoShareTool.runOperator(call, source: ctx.source) {
                switch PhotoShareTool.verdict(report) {
                case .done:
                    return ToolResult(ok: true, say: report.say ?? "All done in \(plan.app).",
                                      data: ["saved_to_photos": true, "operator": report.data, "app": .string(plan.app)])
                case .waiting:
                    return ToolResult(ok: true, say: report.say ?? "It's ready. Open Kairos to approve it.",
                                      data: ["saved_to_photos": true, "status": "waiting for the owner to approve it"])
                case .declined:
                    return ToolResult(ok: false, say: report.say.map { $0 + " Your photo is safe in Photos." }
                                          ?? "OK, I haven't posted it. Your photo is safe in Photos.",
                                      data: ["posted": false, "status": "the owner said no; do not try again"])
                case .unavailable:
                    why = "I can't tap through \(plan.app) for you right now, so "
                }
            } else {
                why = "I can't use other apps for you at the moment, so "
            }
        }

        // 3. Fallback: the iOS share menu with the photo. The person picks the app and taps the last button.
        let presented = ctx.canShowUI ? await PhotoShareSheet.present(jpeg, caption: plan.caption) : false
        if presented {
            var say = (savedSay.map { $0 + " " } ?? "") + why
            say += "I've opened the share menu with your photo. Tap \(plan.app), then \(plan.publishButton)."
            if plan.caption != nil { say += " Your words are copied, so you can paste them in." }
            return ToolResult(ok: true, say: PhotoShareTool.capitalisedStart(say),
                              data: ["posted": false, "share_menu_open": true, "saved_to_photos": .bool(saved)])
        }
        if saved {
            return ToolResult(ok: true,
                              say: "Your photo is in your Photos. To post it, open Photos, tap the photo, tap Share, then pick \(plan.app).",
                              data: ["posted": false, "saved_to_photos": true])
        }
        return .fail((savedSay.map { $0 + " " } ?? "") + "Please open Kairos and ask me again, and I'll open the share menu for you.")
    }

    // MARK: Handing over to the operator

    static let operatorTool = "operate_app"

    enum OperatorVerdict: Equatable { case done, waiting, declined, unavailable }

    /// Runs operate_app through the runner (SafetyGate + card). Nil when there's no runner or no operator tool.
    @MainActor
    static func runOperator(_ call: ToolCall, source: AgentSource) async -> StepReport? {
        guard let runner = AgentHooks.runner, runner.toolCatalog.contains(where: { $0.name == call.name }) else { return nil }
        return await runner.runToolStep(call, source: source)
    }

    /// What the operator's report means for us. A "no" from the owner (or a refusal) never falls back to the share
    /// menu: no means no.
    static func verdict(_ r: StepReport) -> OperatorVerdict {
        let blob = (r.data.compactString + " " + (r.say ?? "")).lowercased()
        if blob.contains("waiting for the owner") { return .waiting }
        if r.ok { return .done }
        let noWords = ["said no", "declined", "not approved", "refused", "won't", "won’t", "i haven't", "did not approve"]
        if noWords.contains(where: { blob.contains($0) }) { return .declined }
        return .unavailable
    }

    static func capitalisedStart(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}

// MARK: - Saving to the photo library

enum PhotoLibrarySaver {
    enum Outcome: Equatable, Sendable {
        case saved(album: String?)
        case denied
        case failed(String)
    }

    static let deniedSay = "Kairos isn't allowed to add photos yet. Open Settings, tap Kairos, tap Photos, and choose Add Photos Only."

    /// Adds the JPEG to Photos as a new photo dated now. Without an album it only asks for "add photos" permission;
    /// an album needs full access (asked only when the person wants an album), else it falls back to no album.
    static func save(_ jpeg: Data, album: String?) async -> Outcome {
        if let album, !album.isEmpty {
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            if status == .authorized || status == .limited {
                do {
                    try await write(jpeg, album: album)
                    return .saved(album: album)
                } catch {
                    // Fall through: at least save it without the album.
                }
            }
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return .denied }
        do {
            try await write(jpeg, album: nil)
            return .saved(album: nil)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func write(_ jpeg: Data, album: String?) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = Date()
            request.addResource(with: .photo, data: jpeg, options: nil)
            guard let album, let placeholder = request.placeholderForCreatedAsset else { return }
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "title = %@", album)
            let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject
            let albumRequest = existing.flatMap { PHAssetCollectionChangeRequest(for: $0) }
                ?? PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: album)
            albumRequest.addAssets([placeholder] as NSArray)
        }
    }
}

// MARK: - The share menu (fallback)

enum PhotoShareSheet {
    /// Opens the iOS share menu with the photo over whatever Kairos is showing. Copies the caption so the person
    /// can paste it. False when Kairos isn't on screen.
    @MainActor
    static func present(_ jpeg: Data, caption: String?) -> Bool {
        #if canImport(UIKit)
        guard UIApplication.shared.applicationState == .active, let image = UIImage(data: jpeg),
              let top = topViewController() else { return false }
        if top is UIActivityViewController { return true }
        let sheet = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 60, width: 1, height: 1)
        }
        if let caption, !caption.isEmpty { UIPasteboard.general.string = caption }
        top.present(sheet, animated: true)
        return true
        #else
        return false
        #endif
    }

    #if canImport(UIKit)
    @MainActor
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var top = window?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
    #endif
}

// MARK: - Words

enum PhotoMatch {
    static func padded(_ s: String) -> String { " " + s.folded + " " }
    static func has(_ padded: String, _ terms: [String]) -> Bool { terms.contains { padded.contains(" " + $0 + " ") } }

    static let photoNouns = ["photo", "photos", "picture", "pictures", "pic", "pics", "selfie", "selfies", "snap",
                             "snapshot", "photograph", "image"]
    static let takeVerbs = ["take", "taking", "snap", "grab", "shoot"]
    static let shareVerbs = ["post", "send", "share", "upload", "put", "add", "tweet", "email", "whatsapp", "save",
                             "keep", "pop", "stick"]
    /// Other helpers' jobs: letters and bills (letter reader), reminders and alarms (planner).
    static let notMine = ["letter", "bill", "form", "document", "statement", "envelope", "remind", "reminder", "alarm",
                          "timer", "every day", "scam"]
    static let arrivalFolded = PhotoStore.promptPrefix.folded

    /// "Here's the photo for: …" (the camera handing a photo back).
    static func isPhotoArrival(_ words: String) -> Bool { words.folded.hasPrefix(arrivalFolded) }

    /// The request without the "Here's the photo for:" prefix.
    static func request(_ words: String) -> String {
        guard isPhotoArrival(words), let colon = words.firstIndex(of: ":") else { return words }
        return String(words[words.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Take a picture and post it to my Instagram story", "snap a selfie and send it to Mum". Also a bare
    /// "take the photo" while a camera request is waiting (Siri asked the person to open Kairos).
    static func wantsNewPhoto(_ words: String) -> Bool {
        guard !isPhotoArrival(words) else { return false }
        let w = padded(words)
        guard has(w, takeVerbs), has(w, photoNouns), !has(w, notMine) else { return false }
        if has(w, shareVerbs) || PhotoShareSkills.knownApp(in: words) != nil { return true }
        return PhotoStore.shared.pendingPrompt != nil
    }

    /// "Post it to Instagram", "send that photo to Mum on WhatsApp", or the camera's "Here's the photo for: …".
    static func wantsShareOfPhotoInHand(_ words: String) -> Bool {
        if isPhotoArrival(words) { return true }
        let w = padded(words)
        guard has(w, shareVerbs), !has(w, takeVerbs), !has(w, notMine) else { return false }
        // "post it", "send that", or the photo by name; not "send Mum a WhatsApp saying it's raining".
        return has(w, photoNouns) || has(w, pronounAfter(shareVerbs))
    }

    /// "post it", "send that", "save this", "share them".
    static func pronounAfter(_ verbs: [String]) -> [String] {
        verbs.flatMap { v in ["it", "that", "this", "them"].map { v + " " + $0 } }
    }

    /// Other things people save or keep that aren't photos.
    static let notSaveWords = ["calendar", "diary", "contact", "contacts", "number", "note", "notes", "routine",
                               "shortcut", "address", "message", "messages", "password"]

    /// "Save it", "keep that photo", "put it in my Kairos album" (no app named: that's share_photo).
    static func wantsSave(_ words: String) -> Bool {
        let req = request(words)
        let w = padded(req)
        guard !has(w, notMine), !has(w, notSaveWords), has(w, ["save", "keep", "album"]) else { return false }
        if !isPhotoArrival(words), has(w, takeVerbs) { return false }
        guard PhotoShareSkills.knownApp(in: req) == nil else { return false }
        return has(w, ["album", "camera roll", "gallery"] + photoNouns) || has(w, pronounAfter(["save", "keep"]))
    }

    private static let albumPattern = try! NSRegularExpression(
        pattern: #"\b(?:in|to|into|on)\s+(?:my\s+|the\s+|a\s+)?([\p{L}\p{N}][\p{L}\p{N} '\-]{0,30}?)\s+album\b"#,
        options: [.caseInsensitive])

    /// "my Kairos album" → "Kairos"; just "an album" → "Kairos".
    static func album(in words: String) -> String? {
        let req = request(words)
        guard has(padded(req), ["album"]) else { return nil }
        if let m = albumPattern.firstMatch(in: req, range: NSRange(req.startIndex..., in: req)),
           let r = Range(m.range(at: 1), in: req) {
            let name = req[r].trimmingCharacters(in: .whitespaces)
            if !["new", "an", "a", "photo", "photos", "my"].contains(name.folded) { return name }
        }
        return "Kairos"
    }

    struct Parsed: Equatable {
        var app: String
        var destination: String?
        var caption: String?
    }

    /// App, place or person, and the person's own words for the caption.
    static func parse(_ words: String) -> Parsed? {
        let text = request(words)
        let caption = self.caption(in: text)
        var rest = text
        if let caption, let r = rest.range(of: caption, options: [.caseInsensitive, .backwards]) { rest.removeSubrange(r) }
        guard let app = PhotoShareSkills.knownApp(in: rest) else { return nil }
        let w = padded(rest)
        var destination: String?
        switch app.name {
        case "Instagram":
            if has(w, ["story", "stories"]) { destination = "story" }
            else if has(w, ["feed", "grid", "profile"]) { destination = "feed" }
        case "WhatsApp":
            destination = has(w, ["status"]) ? "status" : recipient(in: rest)
        case "Mail":
            destination = emailAddress(in: rest) ?? recipient(in: rest)
        default:
            break
        }
        return Parsed(app: app.name, destination: destination, caption: caption)
    }

    private static let captionMarkers = [" with the caption ", " with caption ", " with a caption ", " captioned ",
                                         " caption it ", " and caption ", " caption ", " saying ", " that says ",
                                         " which says ", " and say ", " and write ", " with the words ", " with the text ",
                                         " with text ", " and the words ", " with the message ", " and put "]
    private static let quotePairs: [(String, String)] = [("“", "”"), ("\"", "\""), ("«", "»"), ("‘", "’")]
    private static let trailingPlace = try! NSRegularExpression(
        pattern: #"\s+(?:on|to|in|onto|into|via|for)\s+(?:my\s+|the\s+|our\s+)?(?:instagram|insta|whatsapp|whats app|facebook|fb|twitter|x|google drive|drive|google photos|email|mail|story|stories|status|feed)\b.*$"#,
        options: [.caseInsensitive])

    /// Quoted words first; else what follows "saying", "with the caption", "that says"…, with any trailing
    /// "on Instagram" taken off.
    static func caption(in text: String) -> String? {
        for (open, close) in quotePairs {
            if let a = text.range(of: open), let b = text.range(of: close, range: a.upperBound..<text.endIndex),
               a.upperBound < b.lowerBound {
                let t = PhotoShareSkills.tidyQuote(String(text[a.upperBound..<b.lowerBound]))
                if t.count >= 2 { return t }
            }
        }
        let padded = " " + text + " "
        var best: Range<String.Index>?
        for marker in captionMarkers {
            if let r = padded.range(of: marker, options: .caseInsensitive), best == nil || r.lowerBound < best!.lowerBound {
                best = r
            }
        }
        guard let start = best else { return nil }
        var t = String(padded[start.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = NSRange(t.startIndex..., in: t)
        if let m = trailingPlace.firstMatch(in: t, range: ns), let r = Range(m.range, in: t) { t.removeSubrange(r) }
        for tail in [" please", " thanks", " thank you"] where t.lowercased().hasSuffix(tail) { t = String(t.dropLast(tail.count)) }
        t = PhotoShareSkills.tidyQuote(t)
        return (2...300).contains(t.count) ? t : nil
    }

    private static let stopWords: Set<String> = ["on", "via", "with", "saying", "and", "caption", "captioned", "that",
                                                 "which", "in", "using", "please", "now", "through", "at", "for", "from",
                                                 "so", "then", "as", "but"]
    private static let notPeople: Set<String> = ["it", "this", "that", "them", "me", "myself", "photo", "picture", "pic",
                                                 "selfie", "status", "story", "stories", "feed", "everyone", "everybody",
                                                 "a", "an", "chat", "group", "inbox", "photos", "gallery"]

    /// "send it to (my) Mum on WhatsApp" → "Mum".
    static func recipient(in text: String) -> String? {
        let tokens = text.folded.split(separator: " ").map(String.init)
        for (i, token) in tokens.enumerated() where token == "to" {
            var j = i + 1
            while j < tokens.count, ["my", "our", "the"].contains(tokens[j]) { j += 1 }
            var name: [String] = []
            while j < tokens.count, name.count < 3, !stopWords.contains(tokens[j]) { name.append(tokens[j]); j += 1 }
            while let last = name.last, notPeople.contains(last) || PhotoShareSkills.knownApp(named: last) != nil {
                name.removeLast()
            }
            if name.isEmpty || name.contains(where: { notPeople.contains($0) || PhotoShareSkills.knownApp(named: $0) != nil }) {
                continue
            }
            return name.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
        return nil
    }

    private static let emailPattern = try! NSRegularExpression(pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#,
                                                               options: [.caseInsensitive])

    static func emailAddress(in text: String) -> String? {
        guard let m = emailPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text) else { return nil }
        return String(text[r])
    }

    /// Every word of `text` appears in what the person said or typed (case, accents, punctuation, emoji ignored).
    static func saidByPerson(_ text: String, ctx: TurnContext) -> Bool {
        let want = text.folded.split(separator: " ")
        guard !want.isEmpty else { return true }
        let have = Set(ctx.userWords.folded.split(separator: " "))
        return want.allSatisfy { have.contains($0) }
    }

    /// `text` is a run of whole words from ONE thing the person said or typed (case, accents and punctuation
    /// ignored): their exact words, not their words reshuffled or mixed with anyone else's.
    static func saidVerbatim(_ text: String, ctx: TurnContext) -> Bool {
        let want = text.folded
        guard !want.isEmpty else { return true }
        return ctx.userWords.split(separator: "\n").contains { line in
            (" " + String(line).folded + " ").contains(" " + want + " ")
        }
    }

    /// The person's latest line is the camera handing a photo back.
    static func lastLineIsArrival(_ ctx: TurnContext) -> Bool {
        ctx.userWords.split(separator: "\n").last.map { isPhotoArrival(String($0)) } ?? false
    }

    /// The words say what to do with the photo (post, send, save…, or an app), not just "take the photo".
    static func namesAPurpose(_ words: String) -> Bool {
        has(padded(request(words)), shareVerbs) || PhotoShareSkills.knownApp(in: request(words)) != nil
    }

    /// The person named this app themselves ("insta" counts for Instagram, "Twitter" for X).
    static func appSaid(_ app: String, ctx: TurnContext) -> Bool {
        let said = padded(ctx.userWords)
        if let known = PhotoShareSkills.knownApp(named: app) {
            return has(said, known.aliases + [known.name.folded])
        }
        let f = app.folded
        return !f.isEmpty && said.contains(" " + f + " ")
    }

    /// The person's latest line, without the camera's "Here's the photo for:" prefix.
    static func lastSaid(_ ctx: TurnContext) -> String? {
        guard let line = ctx.userWords.split(separator: "\n").last.map(String.init) else { return nil }
        let t = request(line).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
