import Foundation

/// VerseDB (https://versedb.com) — optional. A free account token adds cover-photo identification against
/// its whole catalog, UPC lookup, variants, creators and key-issue notes. Personal use only on the free plan.
struct VerseDBClient {
    let token: String

    /// nil when there's no token, or while VerseDB is paused after hitting its free-plan limit.
    static var shared: VerseDBClient? {
        guard !isPaused else { return nil }
        return Tokens.verseDB.map { VerseDBClient(token: $0) }
    }

    // MARK: Rate limit

    private static let pausedKey = "verseDBPausedUntil"

    /// When VerseDB can be used again after hitting its limit.
    static var pausedUntil: Date? {
        get { UserDefaults.standard.object(forKey: pausedKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: pausedKey) }
    }

    static var isPaused: Bool { (pausedUntil ?? .distantPast) > Date() }

    /// Called when VerseDB answers "too many requests": wait as long as it says (or an hour).
    static func pause(after response: HTTPURLResponse?) {
        var seconds: TimeInterval = 3600
        if let retry = response?.value(forHTTPHeaderField: "Retry-After"), let value = TimeInterval(retry.trimmed) {
            seconds = value
        } else if let reset = response?.value(forHTTPHeaderField: "X-RateLimit-Reset"), let value = TimeInterval(reset.trimmed) {
            // Either seconds from now or a Unix time.
            seconds = value > 1_000_000_000 ? value - Date().timeIntervalSince1970 : value
        }
        pausedUntil = Date().addingTimeInterval(min(max(seconds, 60), 86_400))
    }

    static func resume() { pausedUntil = nil }

    /// Issue details already fetched this session (they don't change), so the same issue is never asked for twice.
    @MainActor private static var issueCache: [Int: ComicSpec] = [:]

    private static let base = "https://versedb.com/api/v1"

    // MARK: Lookups

    enum UPCResult {
        case exact(ComicSpec)
        case several([ComicSpec])
        case notFound
    }

    /// Barcode lookup (token needs the lookup:barcode ability).
    func lookUp(upc: String) async throws -> UPCResult {
        let (data, status) = try await request("/lookup/upc/\(upc)")
        guard let json = JSONValue.parse(data) else { throw ServiceError.badData("VerseDB") }
        switch status {
        case 200:
            guard let issue = json["data"] else { return .notFound }
            var spec = Self.spec(fromIssue: issue)
            let suggested = json["suggested_variant_id"]?.int
            let variants = json["variants"]?.array ?? []
            if let variant = variants.first(where: { $0["variant_id"]?.int == suggested }) ?? (variants.count == 1 ? variants.first : nil) {
                Self.apply(variant: variant, to: &spec)
            }
            spec.upc = upc
            return .exact(spec)
        case 409:
            let matches = json["matches"]?.array ?? []
            return .several(matches.map { match in
                var spec = ComicSpec()
                spec.title = match["series_name"]?.string ?? ""
                spec.issue = match["issue_number"]?.string ?? ""
                spec.publisher = match["publisher_name"]?.string ?? ""
                spec.year = match["start_year"]?.string ?? Self.year(match["release_date"]?.string)
                spec.coverImageURL = match["cover_url"]?.string ?? ""
                spec.verseDBIssueID = match["issue_id"]?.int
                if let name = match["variant_name"]?.string, !Self.isRegular(name) { spec.variant = name }
                spec.upc = upc
                return spec
            })
        case 404:
            return .notFound
        default:
            throw Self.error(for: status)
        }
    }

    struct CoverResult {
        var clearMatch: Bool
        var candidates: [ComicSpec]
    }

    /// Cover photo lookup: 5 a minute / 100 a day on the free plan.
    func lookUp(coverJPEG: Data) async throws -> CoverResult {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"image\"; filename=\"cover.jpg\"\r\n".utf8))
        body.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
        body.append(coverJPEG)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let (data, status) = try await request("/lookup/cover", method: "POST", body: body,
                                               contentType: "multipart/form-data; boundary=\(boundary)")
        guard status == 200 else { throw Self.error(for: status) }
        guard let json = JSONValue.parse(data) else { throw ServiceError.badData("VerseDB") }

        let clear = json["clear_match"]?.bool ?? false
        var specs: [ComicSpec] = []
        for candidate in json["candidates"]?.array ?? [] {
            guard let issue = candidate["issue"] else { continue }
            var spec = Self.spec(fromIssue: issue)
            spec.verseDBVariantID = candidate["variant_id"]?.int
            specs.append(spec)
        }
        // The clear match may not be in candidates; fetch it.
        if clear, let issueID = json["issue_id"]?.int, !specs.contains(where: { $0.verseDBIssueID == issueID }) {
            var spec = try await issue(id: issueID)
            spec.verseDBVariantID = json["variant_id"]?.int
            specs.insert(spec, at: 0)
        }
        return CoverResult(clearMatch: clear, candidates: specs)
    }

    /// Full issue details: publisher, credits, key-issue reasons, UPC, ISBN.
    func issue(id: Int) async throws -> ComicSpec {
        if let cached = await Self.issueCache[id] { return cached }
        let (data, status) = try await request("/issues/\(id)")
        guard status == 200 else { throw Self.error(for: status) }
        guard let json = JSONValue.parse(data), let issue = json["data"] else { throw ServiceError.badData("VerseDB") }
        let spec = Self.spec(fromIssue: issue)
        await MainActor.run { Self.issueCache[id] = spec }
        return spec
    }

    /// Adds variant details (name, cover) for a chosen variant.
    func applyVariant(_ variantID: Int, to spec: inout ComicSpec) async {
        guard let issueID = spec.verseDBIssueID,
              let result = try? await request("/issues/\(issueID)/variants/\(variantID)"), result.1 == 200,
              let json = JSONValue.parse(result.0) else { return }
        Self.apply(variant: json["data"] ?? json, to: &spec)
    }

    /// Text search ("Amazing Spider-Man 300").
    func search(_ text: String) async throws -> [ComicSpec] {
        let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        let (data, status) = try await request("/issues?q=\(query)&limit=20")
        guard status == 200 else { throw Self.error(for: status) }
        guard let json = JSONValue.parse(data) else { throw ServiceError.badData("VerseDB") }
        return (json["data"]?.array ?? []).map(Self.spec(fromIssue:))
    }

    // MARK: Mapping

    static func spec(fromIssue issue: JSONValue) -> ComicSpec {
        var spec = ComicSpec()
        let series = issue["series"]
        spec.title = series?["name"]?.string ?? issue["name"]?.string ?? ""
        spec.issue = issue["issue_number"]?.string ?? ""
        spec.publisher = issue["publisher"]?["name"]?.string ?? series?["publisher_name"]?.string ?? ""
        spec.releaseDate = issue["release_date"]?.string ?? issue["cover_date"]?.string ?? ""
        spec.year = year(issue["cover_date"]?.string ?? issue["release_date"]?.string)
        if spec.year.isEmpty { spec.year = series?["start_year"]?.string ?? "" }
        spec.volume = series?["volume_number"]?.string ?? ""
        spec.isReprint = issue["is_reprint"]?.bool ?? false
        spec.upc = issue["upc"]?.string ?? ""
        spec.isbn = issue["isbn"]?.string ?? ""
        spec.variantCount = issue["variant_count"]?.int
        spec.verseDBIssueID = issue["id"]?.int
        spec.coverImageURL = issue["images"]?["cover_lg"]?.string
            ?? issue["images"]?["cover_md"]?.string
            ?? issue["cover_url"]?.string ?? ""

        let creators = issue["creators"]?.array ?? []
        func names(roleMatching pattern: String) -> String {
            creators.filter { matches(pattern, $0["role"]?.string ?? $0["role"]?["name"]?.string ?? "") }
                .compactMap { $0["name"]?.string }
                .prefix(3)
                .joined(separator: ", ")
        }
        spec.writer = names(roleMatching: #"writer|script|story"#)
        spec.coverArtist = names(roleMatching: #"cover"#)

        spec.keyNotes = (issue["key_issue_reasons"]?.array ?? []).compactMap { reason in
            let category = reason["category"]?.string ?? reason["name"]?.string
            let notes = reason["notes"]?.string
            switch (category, notes) {
            case let (c?, n?): return "\(c): \(n)"
            case let (c?, nil): return c
            case let (nil, n?): return n
            default: return nil
            }
        }
        return spec
    }

    static func apply(variant: JSONValue, to spec: inout ComicSpec) {
        if let name = variant["variant_name"]?.string ?? variant["name"]?.string, !isRegular(name) {
            spec.variant = name
        }
        if let cover = variant["cover_url"]?.string ?? variant["images"]?["cover_lg"]?.string { spec.coverImageURL = cover }
        if let upc = variant["upc"]?.string { spec.upc = upc }
        spec.verseDBVariantID = variant["variant_id"]?.int ?? variant["id"]?.int
    }

    static func isRegular(_ variantName: String) -> Bool {
        matches(#"^(regular|standard|main|cover a|a cover|cover a regular)\b"#, variantName.trimmed)
    }

    static func year(_ date: String?) -> String {
        guard let date else { return "" }
        return firstMatch(#"((?:18|19|20)\d{2})"#, in: date) ?? ""
    }

    // MARK: HTTP

    private func request(_ path: String, method: String = "GET", body: Data? = nil, contentType: String? = nil) async throws -> (Data, Int) {
        guard await NetworkMonitor.shared.isOnline else { throw ServiceError.offline }
        guard let url = URL(string: Self.base + path) else { throw ServiceError.badData("VerseDB") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        if http?.statusCode == 429 { Self.pause(after: http) }
        return (data, http?.statusCode ?? 0)
    }

    private static func error(for status: Int) -> ServiceError {
        switch status {
        case 401, 403: return .unauthorized("VerseDB")
        case 429: return .rateLimited("VerseDB")
        default: return .http("VerseDB", status)
        }
    }
}
