import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

// Where a worker agent goes: web pages, PDFs and arXiv. Everything it brings back is untrusted text.
//
// Fetching: https only (http is upgraded to https for arxiv.org and export.arxiv.org, nothing else), never to a bare
// IP address, localhost or a .local name (the phone's own helpers listen on 127.0.0.1), no passwords in links, at
// most 8 MB, 15 s without data (30 s in all), at most 6 redirects and each redirect checked by the same rules.
// arXiv API (https://info.arxiv.org/help/api/user-manual.html): GET export.arxiv.org/api/query with search_query or
// id_list, Atom XML back (entry: id, title, summary, published, author/name, link rel=alternate (abs) and
// link title=pdf). arXiv asks for one request every three seconds; ArxivPacer keeps to that.
// Searching without a key (for when Google's search can't be used): GET html.duckduckgo.com/html/?q=…, DuckDuckGo's
// plain results page. It gives links and short snippets only, never answers. One such search at a time from the
// whole app, at least two seconds apart (KeylessPacer). A 202 reply or an "are you a robot?" page counts as no
// results, and keyless searching then rests for ten minutes: the check is never solved.

/// A page or PDF a worker read.
struct FetchedPage: Sendable, Equatable {
    enum Kind: String, Sendable { case pdf, html, text }

    var requestedURL: String
    /// After redirects.
    var url: String
    var title: String?
    var kind: Kind
    var text: String
    /// PDFs only.
    var pageCount: Int?
    var bytes: Int
    /// The text was longer than we keep (WebReader.maxTextCharacters).
    var truncated = false

    var host: String {
        let h = URL(string: url)?.host?.lowercased() ?? ""
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    struct Chunk: Sendable, Equatable {
        var text: String
        var part: Int
        var parts: Int
        var start: Int
        var end: Int
        var total: Int
    }

    /// Where each part ends (character offsets), `size` characters at a time, cut at a paragraph or line break in
    /// the last 2,000 characters when there is one. Each part starts exactly where the one before it ended, so
    /// nothing between two parts is ever skipped.
    func partEnds(size: Int) -> [Int] {
        let total = text.count
        let size = max(1000, size)
        guard total > size else { return [total] }
        var ends: [Int] = []
        var start = text.startIndex
        var startOffset = 0
        while total - startOffset > size {
            var end = text.index(start, offsetBy: size)
            let window = text.index(end, offsetBy: -min(2000, size - 1))
            if let r = text.range(of: "\n\n", options: .backwards, range: window..<end) { end = r.upperBound }
            else if let r = text.range(of: "\n", options: .backwards, range: window..<end) { end = r.upperBound }
            startOffset += text.distance(from: start, to: end)
            start = end
            ends.append(startOffset)
        }
        ends.append(total)
        return ends
    }

    /// Part `part` (1-based) of the text, about `size` characters at a time.
    func chunk(_ part: Int, size: Int) -> Chunk {
        let total = text.count
        let ends = partEnds(size: size)
        let parts = ends.count
        let p = min(max(1, part), parts)
        let startOffset = p == 1 ? 0 : ends[p - 2]
        let endOffset = ends[p - 1]
        let startIndex = text.index(text.startIndex, offsetBy: startOffset)
        let endIndex = text.index(startIndex, offsetBy: endOffset - startOffset)
        let piece = String(text[startIndex..<endIndex])
        return Chunk(text: piece, part: p, parts: parts, start: startOffset + 1, end: endOffset, total: total)
    }
}

/// One paper from the arXiv API.
struct ArxivPaper: Sendable, Equatable {
    /// With its version, "1706.03762v7".
    var id: String
    var title: String
    var authors: [String]
    /// "2017-06-12"
    var published: String
    var summary: String
    var absURL: String
    var pdfURL: String
    var category: String?

    var baseID: String { Arxiv.baseID(id) }
    var year: String { String(published.prefix(4)) }

    var authorLine: String {
        switch authors.count {
        case 0: return "unknown authors"
        case 1: return authors[0]
        case 2: return "\(authors[0]) and \(authors[1])"
        case 3: return "\(authors[0]), \(authors[1]) and \(authors[2])"
        default: return "\(authors[0]) and \(authors.count - 1) others"
        }
    }
}

/// One result from a search without a key: a link to read, not an answer.
struct KeylessHit: Sendable, Equatable {
    var title: String
    /// The real page (DuckDuckGo's redirect taken off), already checked by WebReader.vet.
    var url: String
    /// A line or two from the page, as the search shows it (web text).
    var snippet: String
}

enum WebReadError: LocalizedError, Equatable {
    case notAllowed(String)
    case tooBig
    case http(Int)
    case timedOut
    case offline
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .notAllowed(let why): return why
        case .tooBig: return "That file is too big for me to read on the phone (over 8 MB)."
        case .http(404): return "That page doesn't exist (error 404)."
        case .http(403), .http(401): return "That site wouldn't let me in (error \(self == .http(401) ? 401 : 403))."
        case .http(429): return "That site says it's had too many requests just now."
        case .http(let code): return "That site sent an error (\(code))."
        case .timedOut: return "That site took too long to answer."
        case .offline: return "I can't reach the internet right now."
        case .unreadable(let why): return why
        }
    }
}

struct WebReader: Sendable {
    /// Seconds without any data before giving up (URLRequest timeout).
    var timeout: TimeInterval = 15
    /// Seconds for the whole download.
    var resourceTimeout: TimeInterval = 30
    var maxBytes = 8 * 1024 * 1024
    var maxRedirects = 6
    /// Text kept from one page or PDF (ten parts of 60,000).
    var maxTextCharacters = 600_000
    /// arXiv's API etiquette: one request every three seconds.
    var arxivSpacing: TimeInterval = 3
    var arxivPacer: ArxivPacer = .shared
    /// Seconds between one keyless search ending and the next starting.
    var keylessSpacing: TimeInterval = 2
    var keylessPacer: KeylessPacer = .shared
    /// Tests return a configuration with their own URLProtocol.
    var configuration: @Sendable () -> URLSessionConfiguration = { URLSessionConfiguration.ephemeral }
    var userAgent = "Kairos/1.0 (iPhone worker agent reading for its owner)"

    // MARK: Which links a worker may open

    static let arxivHosts: Set<String> = ["arxiv.org", "www.arxiv.org", "export.arxiv.org"]

    /// The link as it will be fetched, or why not.
    static func vet(_ raw: String) -> Result<URL, WebReadError> {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>\"'")))
        if !s.contains("://"), s.contains("."), !s.contains(" ") { s = "https://" + s }
        guard var parts = URLComponents(string: s), let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(), !host.isEmpty else {
            return .failure(.notAllowed("That doesn't look like a web link."))
        }
        if scheme == "http" {
            guard arxivHosts.contains(host) else { return .failure(.notAllowed("I only open secure (https) links.")) }
            parts.scheme = "https"
        } else if scheme != "https" {
            return .failure(.notAllowed("I only open secure (https) links."))
        }
        if parts.user != nil || parts.password != nil { return .failure(.notAllowed("I won't open links with a password in them.")) }
        if let port = parts.port, port != 443 { return .failure(.notAllowed("I only open ordinary web links.")) }
        if isPrivate(host) { return .failure(.notAllowed("I won't open addresses on this phone or its network.")) }
        parts.fragment = nil
        guard let url = parts.url else { return .failure(.notAllowed("That doesn't look like a web link.")) }
        return .success(url)
    }

    /// localhost, .local names and any bare IP address (real pages have names).
    static func isPrivate(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") || h.hasSuffix(".internal") || h.hasSuffix(".lan") { return true }
        if h.contains(":") { return true }  // IPv6 literal
        let pieces = h.split(separator: ".")
        if !pieces.isEmpty, pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) { return true }  // IPv4 literal
        if h.hasPrefix("0x") || !h.contains(".") { return true }  // hex or single-label hosts
        return false
    }

    // MARK: Reading

    /// Fetches a page or PDF and turns it into plain text.
    func read(_ url: URL) async throws -> FetchedPage {
        let (data, response, final) = try await fetch(url, accept: "text/html,application/xhtml+xml,application/pdf;q=0.9,text/plain;q=0.8,*/*;q=0.5")
        let type = (response.mimeType ?? "").lowercased()
        let isPDF = type == "application/pdf" || data.starts(with: Array("%PDF".utf8))
        var page: FetchedPage
        if isPDF {
            page = try Self.pdfPage(data, requested: url, final: final)
        } else if type.hasPrefix("image/") || type.hasPrefix("video/") || type.hasPrefix("audio/") || type == "application/zip"
                    || type == "application/octet-stream" && !Self.looksLikeText(data) {
            throw WebReadError.unreadable("That link is a picture, a video or a file I can't read.")
        } else {
            let raw = Self.decode(data, encodingName: response.textEncodingName)
            guard let raw, !raw.isEmpty else { throw WebReadError.unreadable("I couldn't read the text on that page.") }
            let html = type.contains("html") || (!type.hasPrefix("text/plain") && raw.prefix(2000).lowercased().contains("<html"))
            if html {
                let (title, text) = HTMLText.extract(raw)
                page = FetchedPage(requestedURL: url.absoluteString, url: final.absoluteString, title: title, kind: .html,
                                   text: text, pageCount: nil, bytes: data.count)
            } else {
                page = FetchedPage(requestedURL: url.absoluteString, url: final.absoluteString, title: nil, kind: .text,
                                   text: HTMLText.collapse(raw), pageCount: nil, bytes: data.count)
            }
        }
        if page.text.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
            throw WebReadError.unreadable(page.kind == .pdf ? "That PDF has no text I can read; it may be a scan."
                                                            : "That page has almost no text I can read (it may need a full browser).")
        }
        if page.text.count > maxTextCharacters {
            page.text = String(page.text.prefix(maxTextCharacters))
            page.truncated = true
        }
        return page
    }

    static func pdfPage(_ data: Data, requested: URL, final: URL) throws -> FetchedPage {
        #if canImport(PDFKit)
        guard let doc = PDFDocument(data: data) else { throw WebReadError.unreadable("I couldn't open that PDF.") }
        if doc.isLocked { throw WebReadError.unreadable("That PDF is locked with a password.") }
        var pages: [String] = []
        var count = 0
        for i in 0..<doc.pageCount {
            guard let s = doc.page(at: i)?.string else { continue }
            let clean = PDFTextCleaner.clean(s)
            guard !clean.isEmpty else { continue }
            pages.append("[Page \(i + 1)]\n" + clean)
            count += clean.count
            if count > 800_000 { break }
        }
        let title = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return FetchedPage(requestedURL: requested.absoluteString, url: final.absoluteString,
                           title: (title?.isEmpty ?? true) ? nil : title, kind: .pdf,
                           text: pages.joined(separator: "\n\n"), pageCount: doc.pageCount, bytes: data.count)
        #else
        throw WebReadError.unreadable("I can't read PDFs on this device.")
        #endif
    }

    static func decode(_ data: Data, encodingName: String?) -> String? {
        if let name = encodingName {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let s = String(data: data, encoding: enc) { return s }
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
    }

    static func looksLikeText(_ data: Data) -> Bool {
        let head = data.prefix(1024)
        guard !head.isEmpty else { return false }
        let printable = head.filter { $0 == 9 || $0 == 10 || $0 == 13 || ($0 >= 32 && $0 != 127) }.count
        return Double(printable) / Double(head.count) > 0.95
    }

    // MARK: arXiv

    /// Up to `max` papers for a title or topic. Tries the words as a title first, then all the words anywhere.
    func findPapers(_ query: String, max: Int = 5) async throws -> [ArxivPaper] {
        let limit = Swift.min(5, Swift.max(1, max))
        if let id = Arxiv.id(from: query) {
            return try await paper(id: id).map { [$0] } ?? []
        }
        var found: [ArxivPaper] = []
        if let titleURL = Arxiv.titleQueryURL(query, max: limit) {
            found = try await arxivFeed(titleURL)
        }
        if found.isEmpty, let wordsURL = Arxiv.wordsQueryURL(query, max: limit) {
            found = try await arxivFeed(wordsURL)
        }
        var seen = Set<String>()
        return Array(found.filter { seen.insert($0.baseID).inserted }.prefix(limit))
    }

    /// One paper's details by id ("1706.03762").
    func paper(id: String) async throws -> ArxivPaper? {
        guard let url = Arxiv.idQueryURL(id) else { return nil }
        let base = Arxiv.baseID(id)
        return try await arxivFeed(url).first { $0.baseID == base }
    }

    private func arxivFeed(_ url: URL) async throws -> [ArxivPaper] {
        try await arxivPacer.wait(spacing: arxivSpacing)
        let (data, _, _) = try await fetch(url, accept: "application/atom+xml")
        return Arxiv.parse(data)
    }

    // MARK: Searching without a key

    /// False while keyless searching is resting (DuckDuckGo asked us to slow down): no request would be sent.
    func keylessAvailable() async -> Bool {
        await !keylessPacer.isResting()
    }

    /// Up to 8 web results for `query` from DuckDuckGo's plain results page: links and snippets to read, not answers.
    /// Waits its turn (one at a time, a little apart). A 202 reply, a refusal or an "are you a robot?" page gives no
    /// results, and keyless searching rests for a while; the check is never solved. Throws only when the phone is
    /// offline, the page took too long, or the search was cancelled.
    func keylessSearch(_ query: String) async throws -> [KeylessHit] {
        guard let url = KeylessSearch.url(query.trimmingCharacters(in: .whitespacesAndNewlines)) else { return [] }
        guard try await keylessPacer.begin(spacing: keylessSpacing) else { return [] }
        let reply: (Data, HTTPURLResponse, URL)
        do {
            reply = try await fetch(url, accept: "text/html,application/xhtml+xml")
        } catch WebReadError.http(let code) {
            // Refused (403, 429): DuckDuckGo wants a rest, so it is left alone for a while.
            await keylessPacer.end(rest: code == 403 || code == 429 ? KeylessPacer.restAfterRefusal : 0)
            return []
        } catch {
            await keylessPacer.end()
            throw error
        }
        let (data, response, _) = reply
        let html = Self.decode(data, encodingName: response.textEncodingName) ?? ""
        // 202 is DuckDuckGo's "are you a robot?" reply; the same page can come with 200. No results, and a rest.
        if response.statusCode != 200 || KeylessSearch.isChallenge(html) {
            await keylessPacer.end(rest: KeylessPacer.restAfterRefusal)
            return []
        }
        await keylessPacer.end()
        return KeylessSearch.parse(html)
    }

    // MARK: HTTP

    /// GET with the rules above. Returns the body, the response and the final URL after redirects.
    func fetch(_ url: URL, accept: String) async throws -> (Data, HTTPURLResponse, URL) {
        let vetted: URL
        switch Self.vet(url.absoluteString) {
        case .success(let u): vetted = u
        case .failure(let e): throw e
        }
        let config = configuration()
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = resourceTimeout
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        let delegate = WebFetchDelegate(maxBytes: maxBytes, maxRedirects: maxRedirects)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: vetted, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request)

        let (data, response) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<(Data, URLResponse), Error>) in
                delegate.begin(c, task: task)
            }
        } onCancel: {
            task.cancel()
        }
        guard let http = response as? HTTPURLResponse else { throw WebReadError.unreadable("That site sent something I didn't understand.") }
        guard (200..<300).contains(http.statusCode) else { throw WebReadError.http(http.statusCode) }
        return (data, http, http.url ?? vetted)
    }
}

/// Collects one download, enforcing the size cap and checking every redirect.
final class WebFetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let maxBytes: Int
    private let maxRedirects: Int
    private var data = Data()
    private var redirects = 0
    private var failure: WebReadError?
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var done = false

    init(maxBytes: Int, maxRedirects: Int) {
        self.maxBytes = maxBytes
        self.maxRedirects = maxRedirects
    }

    func begin(_ c: CheckedContinuation<(Data, URLResponse), Error>, task: URLSessionDataTask) {
        lock.lock()
        continuation = c
        lock.unlock()
        task.resume()
    }

    private func fail(_ error: WebReadError, task: URLSessionTask) {
        lock.lock()
        if failure == nil { failure = error }
        lock.unlock()
        task.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if dataTask.countOfBytesExpectedToReceive > Int64(maxBytes) { fail(.tooBig, task: dataTask); return }
        lock.lock()
        let over = self.data.count + data.count > maxBytes
        if !over { self.data.append(data) }
        lock.unlock()
        if over { fail(.tooBig, task: dataTask) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        lock.lock()
        redirects += 1
        let tooMany = redirects > maxRedirects
        lock.unlock()
        guard !tooMany else {
            fail(.notAllowed("That link kept sending me somewhere else, so I stopped."), task: task)
            completionHandler(nil)
            return
        }
        guard let target = request.url, case .success(let vetted) = WebReader.vet(target.absoluteString) else {
            fail(.notAllowed("That link tried to send me somewhere I won't go."), task: task)
            completionHandler(nil)
            return
        }
        var next = request
        next.url = vetted
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !done, let c = continuation else { lock.unlock(); return }
        done = true
        continuation = nil
        let failure = self.failure
        let body = data
        lock.unlock()
        if let failure { c.resume(throwing: failure); return }
        if let error {
            let code = (error as? URLError)?.code
            switch code {
            case .cancelled?: c.resume(throwing: CancellationError())
            case .timedOut?: c.resume(throwing: WebReadError.timedOut)
            case .notConnectedToInternet?, .networkConnectionLost?, .dataNotAllowed?, .internationalRoamingOff?:
                c.resume(throwing: WebReadError.offline)
            case .cannotFindHost?, .dnsLookupFailed?, .cannotConnectToHost?:
                c.resume(throwing: WebReadError.unreadable("I couldn't find that site."))
            case .serverCertificateUntrusted?, .serverCertificateHasBadDate?, .serverCertificateNotYetValid?,
                 .serverCertificateHasUnknownRoot?, .secureConnectionFailed?, .appTransportSecurityRequiresSecureConnection?:
                c.resume(throwing: WebReadError.notAllowed("That site's security doesn't check out, so I didn't open it."))
            default:
                c.resume(throwing: WebReadError.unreadable("I couldn't open that link."))
            }
            return
        }
        guard let response = task.response else { c.resume(throwing: WebReadError.unreadable("That site sent nothing back.")); return }
        c.resume(returning: (body, response))
    }
}

/// arXiv's API asks for one request every three seconds; this keeps all workers to that.
actor ArxivPacer {
    static let shared = ArxivPacer()
    private var next: Date?

    func wait(spacing: TimeInterval) async throws {
        guard spacing > 0 else { return }
        let now = Date()
        let slot = Swift.max(now, next ?? now)
        next = slot.addingTimeInterval(spacing)
        let nap = slot.timeIntervalSince(now)
        if nap > 0 { try await Task.sleep(nanoseconds: UInt64(nap * 1_000_000_000)) }
    }
}

/// Keeps keyless searching polite for the whole app: one search at a time, `spacing` seconds after the last one
/// ended, and none at all for a while after DuckDuckGo refuses or asks "are you a robot?".
actor KeylessPacer {
    static let shared = KeylessPacer()
    /// How long keyless searching rests after a refusal or a check (ten minutes).
    static let restAfterRefusal: TimeInterval = 600
    /// A search that never handed its turn back frees it after this long.
    static let leaseTimeout: TimeInterval = 45

    private var busySince: Date?
    private var lastEnd: Date?
    private var restUntil: Date?

    func isResting() -> Bool {
        guard let restUntil else { return false }
        return restUntil > Date()
    }

    /// Waits for the turn and takes it (hand it back with `end`). False at once, without a turn, while resting.
    func begin(spacing: TimeInterval) async throws -> Bool {
        while true {
            try Task.checkCancellation()
            let now = Date()
            if isResting() { return false }
            if let since = busySince, now.timeIntervalSince(since) < Self.leaseTimeout {
                try await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            let wait = lastEnd.map { spacing - now.timeIntervalSince($0) } ?? 0
            if wait > 0 {
                try await Task.sleep(nanoseconds: UInt64(min(wait, 1) * 1_000_000_000))
                continue
            }
            busySince = now
            return true
        }
    }

    /// The search is over; `rest` > 0 stops keyless searching for that many seconds.
    func end(rest: TimeInterval = 0) {
        busySince = nil
        lastEnd = Date()
        if rest > 0 { restUntil = Date().addingTimeInterval(rest) }
    }
}

// MARK: - arXiv ids, queries and the Atom feed

enum Arxiv {
    private static let newID = try? NSRegularExpression(pattern: #"(\d{4}\.\d{4,5})(v\d+)?"#)
    private static let oldID = try? NSRegularExpression(pattern: #"([a-z][a-z\-]+(?:\.[A-Z]{2})?/\d{7})(v\d+)?"#)

    /// An id the person or the model gave: "1706.03762", "arXiv:1706.03762v5", an arxiv.org abs or pdf link.
    static func id(from raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'<>.,;")))
        if s.lowercased().hasPrefix("arxiv:") { s = String(s.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        if s.contains("/"), s.contains("arxiv.org") || s.hasPrefix("http") {
            let withScheme = s.contains("://") ? s : "https://" + s
            guard let url = URL(string: withScheme), let host = url.host?.lowercased(), host.hasSuffix("arxiv.org") else { return nil }
            return id(inPath: url.path)
        }
        return whole(s, newID) ?? whole(s, oldID)
    }

    /// The id inside an arxiv.org path ("/abs/1706.03762v7", "/pdf/1706.03762v7.pdf", "/abs/hep-th/9901001").
    static func id(inPath path: String) -> String? {
        let p = path.hasSuffix(".pdf") ? String(path.dropLast(4)) : path
        for regex in [newID, oldID].compactMap({ $0 }) {
            let ns = p as NSString
            if let m = regex.firstMatch(in: p, range: NSRange(location: 0, length: ns.length)) { return ns.substring(with: m.range) }
        }
        return nil
    }

    private static func whole(_ s: String, _ regex: NSRegularExpression?) -> String? {
        guard let regex else { return nil }
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.range.length == ns.length else { return nil }
        return s
    }

    /// "1706.03762v7" → "1706.03762".
    static func baseID(_ id: String) -> String {
        guard let r = id.range(of: #"v\d+$"#, options: .regularExpression) else { return id }
        return String(id[..<r.lowerBound])
    }

    private static let filler: Set<String> = ["paper", "papers", "arxiv", "article", "preprint", "the", "a", "an", "about", "on",
                                              "find", "read", "latest", "recent", "new", "study", "studies", "research"]
    private static let stop: Set<String> = ["is", "are", "all", "you", "of", "in", "for", "to", "and", "with", "by", "at", "from",
                                            "what", "how", "why", "do", "does", "it", "its", "this", "that", "me", "my", "we", "our"]

    private static func words(_ query: String) -> [String] {
        query.folded.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    /// ti:"attention is all you need", the words with "paper", "arXiv" and the like taken out.
    static func titleQueryURL(_ query: String, max: Int) -> URL? {
        var w = words(query)
        while let first = w.first, filler.contains(first) { w.removeFirst() }
        while let last = w.last, filler.contains(last) { w.removeLast() }
        w = w.filter { $0 != "arxiv" && $0 != "paper" }
        guard !w.isEmpty, w.count <= 20 else { return nil }
        let phrase = w.joined(separator: "+")
        return URL(string: "https://export.arxiv.org/api/query?search_query=ti:%22\(phrase)%22&sortBy=relevance&sortOrder=descending&max_results=\(max)")
    }

    /// all:attention AND all:need — every meaningful word, anywhere in the record.
    static func wordsQueryURL(_ query: String, max: Int) -> URL? {
        var w = words(query).filter { !filler.contains($0) && !stop.contains($0) }
        if w.isEmpty { w = words(query) }
        guard !w.isEmpty else { return nil }
        let q = w.prefix(8).map { "all:" + $0 }.joined(separator: "+AND+")
        return URL(string: "https://export.arxiv.org/api/query?search_query=\(q)&sortBy=relevance&sortOrder=descending&max_results=\(max)")
    }

    static func idQueryURL(_ id: String) -> URL? {
        let safe = id.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-/"))) ?? id
        return URL(string: "https://export.arxiv.org/api/query?id_list=\(safe)&max_results=1")
    }

    static func parse(_ data: Data) -> [ArxivPaper] {
        let parser = XMLParser(data: data)
        let reader = ArxivAtomReader()
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        parser.parse()
        return reader.papers
    }

    /// "http://arxiv.org/abs/1706.03762v7" → "https://arxiv.org/abs/1706.03762v7".
    static func secure(_ link: String) -> String {
        link.hasPrefix("http://") ? "https://" + link.dropFirst(7) : link
    }
}

/// Reads arXiv's Atom feed. Only <entry> elements count (the feed's own <title> is the query).
final class ArxivAtomReader: NSObject, XMLParserDelegate {
    private(set) var papers: [ArxivPaper] = []
    private var inEntry = false
    private var inAuthor = false
    private var text = ""
    private var fields: [String: String] = [:]
    private var authors: [String] = []
    private var absLink: String?
    private var pdfLink: String?
    private var category: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        switch elementName {
        case "entry":
            inEntry = true
            fields = [:]; authors = []; absLink = nil; pdfLink = nil; category = nil
        case "author" where inEntry:
            inAuthor = true
        case "link" where inEntry:
            let href = attributeDict["href"] ?? ""
            if attributeDict["title"] == "pdf" || attributeDict["type"] == "application/pdf" { pdfLink = href }
            else if attributeDict["rel"] == "alternate" { absLink = href }
        case "arxiv:primary_category" where inEntry, "primary_category" where inEntry:
            category = attributeDict["term"]
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard inEntry else { return }
        let value = HTMLText.collapse(text).replacingOccurrences(of: "\n", with: " ")
        switch elementName {
        case "name" where inAuthor:
            if !value.isEmpty { authors.append(value) }
        case "author":
            inAuthor = false
        case "id", "title", "summary", "published":
            fields[elementName] = value
        case "entry":
            inEntry = false
            if let rawID = fields["id"], let id = Arxiv.id(inPath: URL(string: rawID)?.path ?? rawID),
               let title = fields["title"], !title.isEmpty, title.lowercased() != "error" {
                let abs = Arxiv.secure(absLink ?? rawID)
                papers.append(ArxivPaper(id: id, title: title, authors: authors, published: String((fields["published"] ?? "").prefix(10)),
                                         summary: fields["summary"] ?? "", absURL: abs,
                                         pdfURL: Arxiv.secure(pdfLink ?? "https://arxiv.org/pdf/\(id)"), category: category))
            }
        default:
            break
        }
        text = ""
    }
}

// MARK: - DuckDuckGo's plain results page

/// Reads https://html.duckduckgo.com/html/?q=…: each result's title link is `<a class="result__a"
/// href="//duckduckgo.com/l/?uddg=<the real link, percent-encoded>&rut=…">`, and its snippet is the next
/// `class="result__snippet"` element. Ads lead to duckduckgo.com/y.js?ad_domain=… and are left out.
enum KeylessSearch {
    static let maxResults = 8

    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    static func url(_ query: String) -> URL? {
        guard !query.isEmpty, let q = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://html.duckduckgo.com/html/?q=" + q)
    }

    /// DuckDuckGo's "are you a robot?" page instead of results.
    static func isChallenge(_ html: String) -> Bool {
        let lower = html.lowercased()
        return ["anomaly-modal", "anomaly.js", "challenge-form", "bots use duckduckgo"].contains { lower.contains($0) }
    }

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static let anchor = regex(#"<a\b([^>]*)>(.*?)</a\s*>"#)
    private static let classes = regex(#"\bclass\s*=\s*"([^"]*)""#)
    private static let href = regex(#"\bhref\s*=\s*"([^"]*)""#)
    private static let snippet = regex(#"\bclass\s*=\s*"[^"]*\bresult__snippet\b[^"]*"[^>]*>(.*?)</(?:a|div|td|span)\s*>"#)

    /// Up to 8 results, ads and DuckDuckGo's own links left out, each link one a worker may open.
    static func parse(_ html: String) -> [KeylessHit] {
        guard let anchor else { return [] }
        let ns = html as NSString
        var titles: [(range: NSRange, href: String, title: String)] = []
        for m in anchor.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let attributes = ns.substring(with: m.range(at: 1))
            guard first(classes, in: attributes)?.split(separator: " ").contains("result__a") == true,
                  let link = first(href, in: attributes) else { continue }
            titles.append((m.range, link, ns.substring(with: m.range(at: 2))))
        }
        var hits: [KeylessHit] = []
        var seen = Set<String>()
        for (i, t) in titles.enumerated() {
            guard let link = target(t.href), seen.insert(link).inserted else { continue }
            let title = text(t.title)
            guard !title.isEmpty else { continue }
            // The snippet sits between this title and the next one.
            let from = t.range.location + t.range.length
            let to = i + 1 < titles.count ? titles[i + 1].range.location : ns.length
            var words = ""
            if let snippet, to > from, let m = snippet.firstMatch(in: html, range: NSRange(location: from, length: to - from)) {
                words = text(ns.substring(with: m.range(at: 1)))
            }
            hits.append(KeylessHit(title: String(title.prefix(160)), url: link, snippet: String(words.prefix(400))))
            if hits.count == maxResults { break }
        }
        return hits
    }

    /// The real link behind DuckDuckGo's redirect (its `uddg` parameter), or nil for an ad, DuckDuckGo's own pages,
    /// or a link a worker may not open.
    static func target(_ rawHref: String) -> String? {
        var s = HTMLText.entities(rawHref).trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("//") { s = "https:" + s } else if s.hasPrefix("/") { s = "https://duckduckgo.com" + s }
        guard let parts = URLComponents(string: s) else { return nil }
        var link = s
        if let host = parts.host?.lowercased(), host == "duckduckgo.com" || host.hasSuffix(".duckduckgo.com") {
            guard let real = parts.queryItems?.first(where: { $0.name == "uddg" })?.value, !real.isEmpty else { return nil }
            link = real
        }
        guard case .success(let url) = WebReader.vet(link), let host = url.host?.lowercased(),
              host != "duckduckgo.com", !host.hasSuffix(".duckduckgo.com"),
              !url.path.hasSuffix("/y.js"), !(url.query ?? "").contains("ad_domain") else { return nil }
        return url.absoluteString
    }

    private static func first(_ regex: NSRegularExpression?, in s: String) -> String? {
        let ns = s as NSString
        guard let regex, let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func text(_ html: String) -> String {
        HTMLText.collapse(HTMLText.entities(HTMLText.strip(html))).replacingOccurrences(of: "\n", with: " ")
    }
}

// MARK: - Text from HTML and PDFs

enum HTMLText {
    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static let title = regex(#"<title[^>]*>(.*?)</title\s*>"#)
    private static let comments = regex(#"<!--.*?-->"#)
    private static let dropped = regex(#"<(script|style|nav|noscript|svg|template|iframe|footer|aside|form|button|select)\b[^>]*>.*?</\1\s*>"#)
    private static let selfClosing = regex(#"<(script|style|iframe|link|meta|input)\b[^>]*/?>"#)
    private static let headings = regex(#"<h([1-6])\b[^>]*>(.*?)</h\1\s*>"#)
    private static let listItems = regex(#"<li\b[^>]*>"#)
    private static let blocks = regex(#"</?(p|div|br|tr|section|article|main|header|ul|ol|table|blockquote|pre|dd|dt|dl|figure|figcaption|hr|li)\b[^>]*>"#)
    private static let cells = regex(#"</?(td|th)\b[^>]*>"#)
    private static let tags = regex(#"<[^>]+>"#)
    private static let numeric = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]{1,6});"#)

    /// The page's title and its readable text: headings kept as "## …", scripts, styles and menus dropped.
    static func extract(_ html: String) -> (title: String?, text: String) {
        var s = html
        var pageTitle: String?
        if let title, let m = title.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) {
            let t = collapse(entities(strip((s as NSString).substring(with: m.range(at: 1))))).replacingOccurrences(of: "\n", with: " ")
            pageTitle = t.isEmpty ? nil : String(t.prefix(200))
        }
        s = replace(comments, in: s, with: " ")
        s = replace(dropped, in: s, with: " ")
        s = replace(selfClosing, in: s, with: " ")
        if let headings {
            let ns = s as NSString
            var out = ""
            var last = 0
            for m in headings.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let level = Int(ns.substring(with: m.range(at: 1))) ?? 2
                let inner = collapse(strip(ns.substring(with: m.range(at: 2)))).replacingOccurrences(of: "\n", with: " ")
                out += "\n\n" + String(repeating: "#", count: min(level + 1, 4)) + " " + inner + "\n\n"
                last = m.range.location + m.range.length
            }
            out += ns.substring(from: last)
            s = out
        }
        s = replace(listItems, in: s, with: "\n• ")
        s = replace(blocks, in: s, with: "\n")
        s = replace(cells, in: s, with: " ")
        s = strip(s)
        s = entities(s)
        return (pageTitle, collapse(s))
    }

    static func strip(_ s: String) -> String { replace(tags, in: s, with: "") }

    private static func replace(_ regex: NSRegularExpression?, in s: String, with template: String) -> String {
        guard let regex else { return s }
        return regex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: template))
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "hellip": "…", "copy": "©", "reg": "®", "trade": "™",
        "pound": "£", "euro": "€", "deg": "°", "middot": "·", "bull": "•", "times": "×", "eacute": "é", "egrave": "è",
        "aacute": "á", "uuml": "ü", "ouml": "ö", "auml": "ä", "ccedil": "ç", "minus": "−", "plusmn": "±", "shy": "",
    ]

    static func entities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        if let numeric {
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in numeric.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let hex = ns.substring(with: m.range(at: 1)).lowercased() == "x"
                let digits = ns.substring(with: m.range(at: 2))
                if let value = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(value) {
                    result += String(Character(scalar))
                } else {
                    result += ns.substring(with: m.range)
                }
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        for (name, value) in named where out.contains("&" + name + ";") {
            out = out.replacingOccurrences(of: "&" + name + ";", with: value)
        }
        return out
    }

    /// Spaces and tabs squashed, lines trimmed, at most one blank line in a row.
    static func collapse(_ s: String) -> String {
        var lines: [String] = []
        var blank = 0
        for raw in s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" }).joined(separator: " ")
            if line.isEmpty {
                blank += 1
                if blank == 1, !lines.isEmpty { lines.append("") }
            } else {
                blank = 0
                lines.append(line)
            }
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

enum PDFTextCleaner {
    private static let hyphenBreak = try? NSRegularExpression(pattern: #"(\p{L})-\n(\p{Ll})"#)

    /// "trans-\nformer" → "transformer", spaces squashed.
    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\u{00AD}", with: "")
        if let hyphenBreak {
            t = hyphenBreak.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "$1$2")
        }
        return HTMLText.collapse(t)
    }
}
