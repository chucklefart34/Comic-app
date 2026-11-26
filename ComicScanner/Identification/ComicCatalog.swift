import Foundation
import SQLite3

/// One issue (or variant) in the offline catalog.
struct CatalogIssue: Hashable, Identifiable {
    let id: Int
    let seriesID: Int
    let series: String
    let publisher: String
    let seriesYear: Int?
    let number: String
    let variant: String
    let parentID: Int?
    let barcode: String
    let keyDate: String
    /// Link to the GCD cover scan (empty until the weekly job has reached this series).
    var cover: String = ""

    var isVariant: Bool { parentID != nil }

    /// What the rest of the app works with. Newsstand/direct and later printings go into their own fields.
    var spec: ComicSpec {
        var spec = ComicSpec()
        spec.title = series
        spec.issue = number
        switch publisher {
        case "DC": spec.publisher = "DC Comics"
        case "Marvel": spec.publisher = "Marvel Comics"
        case "Image": spec.publisher = "Image Comics"
        case "Dark Horse": spec.publisher = "Dark Horse Comics"
        default: spec.publisher = publisher
        }
        let year = String(keyDate.prefix(4))
        spec.year = Int(year) != nil ? year : seriesYear.map(String.init) ?? ""
        spec.upc = barcode
        spec.coverImageURL = cover
        var name = variant
        let lower = name.lowercased()
        if lower.contains("newsstand") {
            spec.printEdition = .newsstand
            name = ""
        } else if lower.contains("direct") && lower.count < 20 {
            spec.printEdition = .direct
            name = ""
        }
        if let printing = firstMatch(#"(\d+)(?:st|nd|rd|th)\s+print"#, in: lower).flatMap(Int.init), printing > 1 {
            spec.printing = printing
            name = ""
        } else if lower.contains("second print") {
            spec.printing = 2
            name = ""
        }
        spec.variant = name
        return spec
    }
}

/// The offline Marvel & DC catalog, built monthly from the Grand Comics Database by the repo's
/// "Build comic catalog" workflow and downloaded from its GitHub release. Barcodes and cover text are matched
/// against it on the phone, with no request limits.
actor ComicCatalog {
    static let shared = ComicCatalog()

    static let releaseBase = "https://github.com/chucklefart34/Comic-app/releases/download/catalog/"
    static let credit = "Catalog data from the Grand Comics Database™ (comics.org), CC BY-SA 4.0."

    struct Info: Codable, Equatable {
        var built: String
        var series: Int
        var issues: Int
        var variants: Int?
        var with_barcode: Int?
        var with_cover: Int?
        var publishers: [String]?
        var credit: String?
    }

    enum Status: Equatable {
        case notInstalled
        case downloading
        case ready(Info)
        case failed(String)
    }

    private var db: OpaquePointer?
    private var seriesIndex: [(id: Int, words: [String], compact: String)]?
    private var downloading = false

    private static var folder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Catalog", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private static var databaseURL: URL { folder.appendingPathComponent("catalog.sqlite") }
    private static var infoURL: URL { folder.appendingPathComponent("catalog.json") }

    // MARK: Status

    nonisolated static func installedInfo() -> Info? {
        guard FileManager.default.fileExists(atPath: databaseURL.path),
              let data = try? Data(contentsOf: infoURL) else { return nil }
        return try? JSONDecoder().decode(Info.self, from: data)
    }

    var isDownloading: Bool { downloading }

    // MARK: Download

    /// Once a day, checks whether a newer catalog has been published (it grows daily while it's being built,
    /// then gets new releases weekly) and downloads it if so. Quiet: failures just keep the old one.
    func updateIfNeeded() async {
        let checkedKey = "catalogCheckedAt"
        if let checked = UserDefaults.standard.object(forKey: checkedKey) as? Date,
           Date().timeIntervalSince(checked) < 20 * 3600, Self.installedInfo() != nil { return }
        guard let (data, response) = try? await URLSession.shared.data(from: URL(string: Self.releaseBase + "catalog.json")!),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let latest = try? JSONDecoder().decode(Info.self, from: data) else { return }
        UserDefaults.standard.set(Date(), forKey: checkedKey)
        if let installed = Self.installedInfo(), installed == latest { return }
        _ = try? await update()
    }

    /// Fetches the latest catalog from the repo's "catalog" release.
    @discardableResult
    func update() async throws -> Info {
        guard !downloading else { throw ServiceError.message("The catalog is already downloading.") }
        downloading = true
        defer { downloading = false }

        let session = URLSession(configuration: .default)
        let (infoData, infoResponse) = try await session.data(from: URL(string: Self.releaseBase + "catalog.json")!)
        guard (infoResponse as? HTTPURLResponse)?.statusCode == 200,
              let info = try? JSONDecoder().decode(Info.self, from: infoData) else {
            throw ServiceError.message("The catalog hasn't been built yet. Run “Build comic catalog” in the repo's Actions tab.")
        }
        let (packedURL, response) = try await session.download(from: URL(string: Self.releaseBase + "catalog.sqlite.deflate")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ServiceError.message("The catalog download failed. Try again.") }
        let packed = try Data(contentsOf: packedURL)
        let raw = try (packed as NSData).decompressed(using: .zlib) as Data
        guard raw.prefix(15) == Data("SQLite format 3".utf8) else { throw ServiceError.message("The downloaded catalog was damaged. Try again.") }

        close()
        let temp = Self.folder.appendingPathComponent("catalog.new")
        try raw.write(to: temp, options: .atomic)
        _ = try? FileManager.default.removeItem(at: Self.databaseURL)
        try FileManager.default.moveItem(at: temp, to: Self.databaseURL)
        try infoData.write(to: Self.infoURL, options: .atomic)
        var exclude = URLResourceValues()
        exclude.isExcludedFromBackup = true
        var databaseURL = Self.databaseURL
        try? databaseURL.setResourceValues(exclude)
        return info
    }

    // MARK: Lookups

    /// Issues printed with this barcode. With a 17-digit code it's the exact issue/cover/printing;
    /// with only the 12-digit base it's narrowed by the issue number from the add-on, if known.
    func issues(barcode: String, issueNumber: Int? = nil) -> [CatalogIssue] {
        guard open() else { return [] }
        let digits = barcode.filter(\.isNumber)
        guard digits.count >= 10 else { return [] }
        let trimmed = String(digits.drop { $0 == "0" })
        var found = query("barcode IN (?, ?, ?)", [digits, trimmed, "0" + trimmed])
        if found.isEmpty, digits.count > 12 || issueNumber != nil {
            // Same series base code: pick the right issue by number.
            let base = String(trimmed.prefix(digits.count >= 17 ? trimmed.count - 5 : trimmed.count))
            found = query("(barcode LIKE ? OR barcode LIKE ?)", [base + "%", "0" + base + "%"])
            if let issueNumber { found = found.filter { leadingNumber($0.number) == issueNumber } }
            if found.count > 12 { found = [] }  // too vague to be useful
        }
        return found
    }

    /// Series named on the cover (all their words appear in the cover text) with this issue number:
    /// the regular edition first, then its variants.
    func match(coverText lines: [String], issue: String?) -> [CatalogIssue] {
        guard let issue, let number = leadingNumber(issue), open() else { return [] }
        let words = Set(lines.flatMap(Self.tokens))
        let compact = lines.flatMap(Self.tokens).joined()
        guard !words.isEmpty else { return [] }

        // Longest series name found on the cover wins ("Superman/Wonder Woman" beats "Wonder Woman").
        var best: [(id: Int, length: Int)] = []
        for series in loadSeriesIndex() {
            let found = series.words.allSatisfy(words.contains) || (series.words.count > 1 && compact.contains(series.compact))
            guard found else { continue }
            best.append((series.id, series.compact.count))
        }
        guard let longest = best.map(\.length).max() else { return [] }
        let ids = best.filter { $0.length >= longest - 1 }.map(\.id).prefix(40)
        guard !ids.isEmpty else { return [] }

        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let found = query("i.series_id IN (\(placeholders)) AND i.num = ?", ids.map(String.init) + [String(number)])
        // Regular editions first, newest series first (most scans are recent books).
        return found.sorted {
            if $0.isVariant != $1.isVariant { return !$0.isVariant }
            return ($0.seriesYear ?? 0) > ($1.seriesYear ?? 0)
        }
    }

    /// Tests: read a catalog from another file.
    func useDatabase(at url: URL) -> Bool {
        close()
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return false }
        db = handle
        return true
    }

    // MARK: SQLite

    private func open() -> Bool {
        if db != nil { return true }
        guard FileManager.default.fileExists(atPath: Self.databaseURL.path) else { return false }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(Self.databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return false
        }
        db = handle
        return true
    }

    private func close() {
        if let db { sqlite3_close(db) }
        db = nil
        seriesIndex = nil
        coverColumn = nil
    }

    private var coverColumn: Bool?
    /// Catalogs from before cover links were added don't have the column.
    private var hasCoverColumn: Bool {
        if let coverColumn { return coverColumn }
        var statement: OpaquePointer?
        var found = false
        if sqlite3_prepare_v2(db, "PRAGMA table_info(issue)", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = sqlite3_column_text(statement, 1), String(cString: name) == "cover" { found = true }
            }
        }
        sqlite3_finalize(statement)
        coverColumn = found
        return found
    }

    private func loadSeriesIndex() -> [(id: Int, words: [String], compact: String)] {
        if let seriesIndex { return seriesIndex }
        var result: [(id: Int, words: [String], compact: String)] = []
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id, norm FROM series", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = Int(sqlite3_column_int64(statement, 0))
                let norm = String(cString: sqlite3_column_text(statement, 1))
                let words = norm.split(separator: " ").map(String.init)
                guard !words.isEmpty else { continue }
                result.append((id, words, words.joined()))
            }
        }
        sqlite3_finalize(statement)
        seriesIndex = result
        return result
    }

    private func query(_ condition: String, _ arguments: [String]) -> [CatalogIssue] {
        let sql = """
        SELECT i.id, i.series_id, s.name, s.publisher, s.year_began, i.number, i.variant, i.parent_id, i.barcode, i.key_date,
               \(hasCoverColumn ? "i.cover" : "''")
        FROM issue i JOIN series s ON s.id = i.series_id WHERE \(condition.replacingOccurrences(of: "barcode", with: "i.barcode")) LIMIT 60
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, argument) in arguments.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), argument, -1, transient)
        }
        func text(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
        var rows: [CatalogIssue] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(CatalogIssue(
                id: Int(sqlite3_column_int64(statement, 0)),
                seriesID: Int(sqlite3_column_int64(statement, 1)),
                series: text(2),
                publisher: text(3),
                seriesYear: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 4)),
                number: text(5),
                variant: text(6),
                parentID: sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 7)),
                barcode: text(8),
                keyDate: text(9),
                cover: text(10)
            ))
        }
        return rows
    }

    // MARK: Helpers

    /// Same word rules as the catalog builder: lowercase letters/digits, without "the", "a", "an".
    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
            .filter { !["the", "a", "an"].contains($0) }
    }

    private func leadingNumber(_ text: String) -> Int? {
        firstMatch(#"^\s*\[?(\d{1,5})"#, in: text).flatMap(Int.init)
    }

    private static func date(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: text)
    }
}
