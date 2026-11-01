import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

// The letter reader: photograph a letter, bill or form; the Mac's agents (tempo-hub/agents) read it with Gemini
// (or the Mac's own model) and send back plain words in the person's language, plus audio when a cloud voice is
// available. Talks to the Mac through the same base URL and phone key as the voice call (/voice/agents/...).

// MARK: - what the agents service returns (agents/server.py)

struct LetterJob: Decodable {
    struct Sender: Decodable { let name: String; let type: String }
    struct Money: Decodable { let you_owe: Double?; let they_owe_you: Double?; let currency: String? }
    struct Deadline: Decodable { let date: String?; let what: String? }
    struct Document: Decodable {
        let document_type: String
        let sender: Sender
        let summary_plain: String
        let money: Money?
        let deadline: Deadline?
        let urgency: String
        let tone: String
    }
    struct Explanation: Decodable {
        let text: String; let language: String; let language_name: String; let dialect: String; let speech_lang: String
    }
    struct Audio: Decodable { let audio_b64: String; let mime: String }
    struct Safety: Decodable { let level: String; let notice: String }
    struct Memory: Decodable { let saved: Int? }
    struct Result: Decodable {
        let document: Document
        let explanation: Explanation
        let audio: Audio?
        let safety: Safety
        let memory: Memory?
    }
    let id: String
    let status: String
    let steps: [String]
    let result: Result?
    let error: String?
}

struct LetterAnswer: Decodable { let answer: String; let audio: LetterJob.Audio?; let speech_lang: String? }

enum LetterError: LocalizedError {
    case notSetUp, badPhoto, server(String)
    var errorDescription: String? {
        switch self {
        case .notSetUp: return "Kairos isn't connected to your Mac yet."
        case .badPhoto: return "I couldn't read that photo. Please try again."
        case .server(let m): return m
        }
    }
}

struct LetterClient {
    let base: URL
    let key: String

    init?() {
        guard let b = KeyStore.get("base").flatMap(URL.init(string:)), let k = KeyStore.get("key") else { return nil }
        base = b; key = k
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent("voice/agents/" + path))
        req.httpMethod = method
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "X-Tempo-Phone-Key")
        req.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning")
        if let body { req.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return req
    }

    /// The tunnel's older rule forwards only two POST paths, so a POST to voice/agents/... can come back as a bare
    /// 404 from ngrok (not the Mac's JSON). Then the same call goes in an envelope through voice/phone-task,
    /// which the Mac unwraps. Once the tunnel is restarted with the new rule, the direct path just works.
    private static var viaEnvelope = false

    private func envelope(for req: URLRequest) -> URLRequest? {
        guard req.httpMethod == "POST", let url = req.url, let body = req.httpBody,
              let range = url.path.range(of: "/voice/agents/") else { return nil }
        let agentPath = "/agents/" + url.path[range.upperBound...]
        let payload = (try? JSONSerialization.jsonObject(with: body)) ?? [:]
        var env = URLRequest(url: base.appendingPathComponent("voice/phone-task"))
        env.httpMethod = "POST"
        env.timeoutInterval = req.timeoutInterval
        env.allHTTPHeaderFields = req.allHTTPHeaderFields
        env.httpBody = try? JSONSerialization.data(withJSONObject: ["agent_path": agentPath, "payload": payload])
        return env
    }

    private func send<T: Decodable>(_ original: URLRequest, as type: T.Type) async throws -> T {
        var req = original
        if Self.viaEnvelope, let env = envelope(for: original) { req = env }
        var (data, resp) = try await URLSession.shared.data(for: req)
        var code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if code == 404, obj == nil, !Self.viaEnvelope, let env = envelope(for: original) {
            Self.viaEnvelope = true
            (data, resp) = try await URLSession.shared.data(for: env)
            code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        guard (200..<300).contains(code) else {
            let msg = (obj?["error"] as? String) ?? (obj?["detail"] as? String) ?? "The Mac said \(code)."
            throw LetterError.server(msg)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// The tunnel to the Mac caps a request at 64 KB, so the photo goes up in base64 slices the Mac joins, then one
    /// small request asks for the reading. `progress` gets (sent, total) per slice for the screen.
    static let sliceChars = 60_000

    func interpret(jpeg: Data, language: String, dialect: String, progress: ((Int, Int) -> Void)? = nil) async throws -> LetterJob {
        let b64 = jpeg.base64EncodedString()
        var body: [String: Any] = ["mime": "image/jpeg", "language": language, "dialect": dialect, "speak": true, "wait": 50]
        if b64.count <= Self.sliceChars {
            body["image"] = b64
        } else {
            let id = "i" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let total = (b64.count + Self.sliceChars - 1) / Self.sliceChars
            var start = b64.startIndex
            for i in 0..<total {
                let end = b64.index(start, offsetBy: Self.sliceChars, limitedBy: b64.endIndex) ?? b64.endIndex
                struct Ack: Decodable { let received: Int }
                _ = try await send(request("uploads/\(id)/\(i)", method: "POST",
                                           body: ["data": String(b64[start..<end]), "total": total, "mime": "image/jpeg"]), as: Ack.self)
                progress?(i + 1, total)
                start = end
            }
            body["upload_id"] = id
        }
        return try await send(request("document/interpret", method: "POST", body: body), as: LetterJob.self)
    }

    func job(_ id: String) async throws -> LetterJob { try await send(request("jobs/\(id)"), as: LetterJob.self) }

    func ask(_ id: String, _ question: String) async throws -> LetterAnswer {
        try await send(request("document/\(id)/ask", method: "POST", body: ["question": question, "speak": true]), as: LetterAnswer.self)
    }
}

extension UIImage {
    /// Shrunk to at most 1600 px on the long side and re-encoded as JPEG: quick over venue Wi-Fi, still legible.
    func letterJPEG(maxSide: CGFloat = 1600) -> Data? {
        let s = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: (size.width * s).rounded(), height: (size.height * s).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        return image.jpegData(compressionQuality: 0.82)
    }
}

// MARK: - the reader (state + speech)

@MainActor
final class LetterReader: NSObject, ObservableObject {
    enum Phase: Equatable { case idle, working, done, failed(String) }

    @Published var phase: Phase = .idle
    @Published var steps: [String] = []
    @Published var result: LetterJob.Result?
    @Published var answer: String?
    @Published var asking = false
    @Published var speaking = false

    /// Tells the live voice agent what the letter said, so the person can just keep talking about it.
    var onExplained: ((String) -> Void)?
    /// True while a voice call owns the audio session; then we don't change its category.
    var inCall: () -> Bool = { false }

    private var jobId: String?
    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()
    private var speechLang = "en-GB"

    override init() {
        super.init()
        synth.delegate = self
    }

    func read(_ image: UIImage, language: String, dialect: String) async {
        guard let client = LetterClient() else { phase = .failed(LetterError.notSetUp.localizedDescription); return }
        guard let jpeg = image.letterJPEG() else { phase = .failed(LetterError.badPhoto.localizedDescription); return }
        stop()
        result = nil; answer = nil; jobId = nil
        steps = ["Reading your letter…"]
        phase = .working
        do {
            var job = try await client.interpret(jpeg: jpeg, language: language, dialect: dialect) { [weak self] sent, total in
                Task { @MainActor in self?.steps = ["Sending the photo… \(sent)/\(total)"] }
            }
            steps = ["Reading your letter…"]
            while job.status == "running" || job.status == "queued" {
                steps = job.steps
                try await Task.sleep(nanoseconds: 1_200_000_000)
                job = try await client.job(job.id)
            }
            steps = job.steps
            guard job.status == "done", let res = job.result else {
                phase = .failed(job.error ?? "The letter reader couldn't finish. Please try again.")
                return
            }
            jobId = job.id
            result = res
            speechLang = res.explanation.speech_lang
            phase = .done
            speak(res.explanation.text, audio: res.audio)
            onExplained?("The user just photographed a letter. Kairos's letter reader explained it as: \"\(res.explanation.text)\". "
                         + "Facts: \(res.document.document_type) from \(res.document.sender.name); \(res.document.summary_plain). "
                         + "They may ask you about it; answer only from these facts.")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func ask(_ question: String) async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let id = jobId, let client = LetterClient() else { return }
        asking = true
        defer { asking = false }
        do {
            let a = try await client.ask(id, q)
            answer = a.answer
            speak(a.answer, audio: a.audio, lang: a.speech_lang)
            onExplained?("About the letter, the user asked \"\(q)\" and the letter reader answered: \"\(a.answer)\".")
        } catch {
            answer = "I couldn't answer that: \(error.localizedDescription)"
        }
    }

    func replay() {
        if let answer { speak(answer, audio: nil) } else if let r = result { speak(r.explanation.text, audio: r.audio) }
    }

    func speak(_ text: String, audio: LetterJob.Audio?, lang: String? = nil) {
        stop()
        if !inCall() {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        if let audio, let data = Data(base64Encoded: audio.audio_b64), let p = try? AVAudioPlayer(data: data) {
            p.delegate = self
            player = p
            speaking = true
            p.play()
            return
        }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: lang ?? speechLang) ?? AVSpeechSynthesisVoice(language: "en-GB")
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        speaking = true
        synth.speak(u)
    }

    func stop() {
        player?.stop(); player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        speaking = false
    }
}

extension LetterReader: AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.speaking = false }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }
}

// MARK: - camera

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.cameraCaptureMode = .photo
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage?) -> Void
        init(onImage: @escaping (UIImage?) -> Void) { self.onImage = onImage }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onImage(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onImage(nil) }
    }
}

// MARK: - the screen

struct LetterView: View {
    @EnvironmentObject var session: TempoSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var reader = LetterReader()
    @AppStorage("letterLanguage") private var language = "en-GB"
    @AppStorage("letterDialect") private var dialect = ""
    @State private var showCamera = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var question = ""

    static let languages: [(code: String, label: String)] = [
        ("en-GB", "English"), ("cy", "Cymraeg"), ("te", "తెలుగు"), ("hi", "हिन्दी"), ("ur", "اردو"), ("pa", "ਪੰਜਾਬੀ"),
        ("bn", "বাংলা"), ("gu", "ગુજરાતી"), ("ta", "தமிழ்"), ("pl", "Polski"), ("ro", "Română"), ("ar", "العربية"),
        ("zh", "中文"), ("es", "Español"), ("pt", "Português"), ("fr", "Français"), ("so", "Soomaali"), ("uk", "Українська"),
    ]
    private let green = Color(red: 0.18, green: 0.44, blue: 0.37)
    private let ink = Color(red: 0.11, green: 0.11, blue: 0.10)
    private var cameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Text("Take a photo of a letter, bill or form. I'll tell you what it is, what it means and what to do.")
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(ink)

                    HStack(spacing: 10) {
                        Picker("Language", selection: $language) {
                            ForEach(Self.languages, id: \.code) { Text($0.label).tag($0.code) }
                        }
                        .pickerStyle(.menu)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .tint(green)
                        TextField("Dialect (optional), e.g. Telangana", text: $dialect)
                            .font(.system(size: 18, design: .rounded))
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                    }

                    HStack(spacing: 12) {
                        if cameraAvailable {
                            bigButton("Take a photo", icon: "camera.fill", fill: green, fg: .white) { showCamera = true }
                        }
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Label("Choose a photo", systemImage: "photo.on.rectangle")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .frame(maxWidth: .infinity, minHeight: 84)
                                .background(.white, in: RoundedRectangle(cornerRadius: 22))
                                .foregroundStyle(green)
                        }
                    }
                    .disabled(reader.phase == .working)

                    switch reader.phase {
                    case .idle:
                        EmptyView()
                    case .working:
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Reading your letter…", systemImage: "doc.text.magnifyingglass")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                            ForEach(reader.steps.suffix(5), id: \.self) { Text("• " + $0).font(.system(size: 18, design: .rounded)) }
                            ProgressView().tint(green)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(.white, in: RoundedRectangle(cornerRadius: 18))
                    case .failed(let message):
                        Text(message)
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .padding(16)
                            .frame(maxWidth: .infinity)
                            .background(Color(red: 0.99, green: 0.91, blue: 0.90), in: RoundedRectangle(cornerRadius: 18))
                    case .done:
                        if let r = reader.result { resultCard(r) }
                    }

                    Text("Information, not legal or financial advice. The photo is read by Google's Gemini on your Mac's behalf and isn't kept.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
            }
            .background(Color(red: 0.96, green: 0.95, blue: 0.92).ignoresSafeArea())
            .navigationTitle("Read a letter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { reader.stop(); dismiss() }.font(.system(size: 19, weight: .bold, design: .rounded))
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                showCamera = false
                if let image { Task { await reader.read(image, language: language, dialect: dialect) } }
            }
            .ignoresSafeArea()
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    await reader.read(image, language: language, dialect: dialect)
                } else {
                    reader.phase = .failed(LetterError.badPhoto.localizedDescription)
                }
                pickerItem = nil
            }
        }
        .onAppear {
            reader.onExplained = { [weak session] text in session?.tellKairos(text) }
            reader.inCall = { [weak session] in session?.isInCall ?? false }
        }
        .onDisappear { reader.stop() }
    }

    private func bigButton(_ title: String, icon: String, fill: Color, fg: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 84)
                .background(fill, in: RoundedRectangle(cornerRadius: 22))
                .foregroundStyle(fg)
        }
    }

    @ViewBuilder
    private func resultCard(_ r: LetterJob.Result) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if r.safety.level == "high" || r.safety.level == "medium" {
                Label(r.safety.notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(red: 1.0, green: 0.93, blue: 0.80), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(Color(red: 0.48, green: 0.29, blue: 0.0))
            }
            Text(r.explanation.text)
                .font(.system(size: 26, weight: .medium, design: .rounded))
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isStaticText)

            HStack(spacing: 12) {
                Button { reader.speaking ? reader.stop() : reader.replay() } label: {
                    Label(reader.speaking ? "Stop" : "Hear it again", systemImage: reader.speaking ? "stop.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .background(reader.speaking ? ink : Color(red: 0.76, green: 0.40, blue: 0.18), in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(.white)
                }
            }

            Text(facts(r))
                .font(.system(size: 15))
                .foregroundStyle(.secondary)

            Divider()
            Text("Ask about it").font(.system(size: 20, weight: .bold, design: .rounded))
            HStack {
                TextField("e.g. what if I can't pay by then?", text: $question)
                    .font(.system(size: 18, design: .rounded))
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit { send() }
                Button(action: send) {
                    Image(systemName: "paperplane.fill").font(.system(size: 20, weight: .bold))
                        .frame(width: 52, height: 44)
                        .background(green, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                }
                .disabled(reader.asking || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if reader.asking { ProgressView().tint(green) }
            if let a = reader.answer {
                Text(a)
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(red: 0.88, green: 0.93, blue: 0.91), in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 22))
    }

    private func facts(_ r: LetterJob.Result) -> String {
        var bits = ["\(r.document.document_type.replacingOccurrences(of: "_", with: " ")) from \(r.document.sender.name.isEmpty ? "?" : r.document.sender.name)"]
        if let owe = r.document.money?.you_owe, owe > 0 { bits.append("to pay: \(r.document.money?.currency ?? "£") \(owe)") }
        if let d = r.document.deadline?.date, !d.isEmpty { bits.append("by \(d)") }
        if (r.memory?.saved ?? 0) > 0 { bits.append("remembered in your hub") }
        return bits.joined(separator: " · ")
    }

    private func send() {
        let q = question
        question = ""
        Task { await reader.ask(q) }
    }
}
