import Foundation
import SwiftData
import UIKit
import Vision

/// One possible identification.
struct Candidate: Identifiable, Hashable {
    var spec: ComicSpec
    var imageURL: String?
    /// Where it came from: "Your covers", "VerseDB", "eBay listing", "Barcode".
    var source: String
    /// How much it looks like your photo (lower = closer), when that could be measured.
    var distance: Float?

    var id: String { spec.editionKey + "|" + (imageURL ?? "") }

    var lookLabel: String? {
        guard let distance else { return nil }
        switch distance {
        case ..<0.4: return "Looks the same"
        case ..<0.65: return "Looks similar"
        default: return "Looks different"
        }
    }
}

/// The result of identifying a scan.
struct Identification {
    var candidates: [Candidate]
    /// True when the top candidate is the exact edition (no need to ask).
    var confident: Bool
    var method: String
    var photo: CGImage?
    var barcode: ComicBarcode?
    var message: String?

    var best: Candidate? { candidates.first }
}

/// Works out which exact comic was scanned, using every source available, best first:
/// barcodes and covers you've confirmed before → VerseDB (optional token) → eBay listing photos ranked by look.
@MainActor
enum Identifier {
    // MARK: Barcode

    static func identify(barcode: ComicBarcode, frame: CGImage?, context: ModelContext, bot: WebBot) async -> Identification {
        let code = barcode.fullUPC ?? barcode.base
        let photo = frame.map(CoverRecognizer.cropCover)

        // 1. A barcode you've confirmed before.
        if let memory = remembered(code, context: context) {
            return Identification(candidates: [Candidate(spec: memory.spec, imageURL: memory.imageURL, source: "Your scans")],
                                  confident: true, method: "Barcode", photo: photo, barcode: barcode)
        }

        var candidates: [Candidate] = []
        var message: String?

        // 2. VerseDB barcode lookup.
        if let verseDB = VerseDBClient.shared {
            do {
                switch try await verseDB.lookUp(upc: code) {
                case .exact(let spec):
                    return Identification(candidates: [Candidate(spec: spec, imageURL: spec.coverImageURL.nilIfEmpty, source: "VerseDB")],
                                          confident: true, method: "Barcode", photo: photo, barcode: barcode)
                case .several(let specs):
                    candidates += specs.map { Candidate(spec: $0, imageURL: $0.coverImageURL.nilIfEmpty, source: "VerseDB") }
                case .notFound:
                    break
                }
            } catch {
                message = error.localizedDescription
            }
        }

        // 3. eBay listings that mention the barcode.
        var listings: [SoldListing] = []
        for sold in [false, true] {
            if let found = try? await EbaySoldSearch.listingsForBarcode(code, sold: sold, bot: bot) {
                listings = merge(listings, found)
                if sold { SoldCache.shared.prefetch(for: barcode.spec, seed: found, bot: bot) }
            }
            if listings.count >= 8 { break }
        }
        if listings.isEmpty, barcode.fullUPC != nil,
           let found = try? await EbaySoldSearch.listingsForBarcode(barcode.base, sold: false, bot: bot) {
            listings = found
        }

        let series = mostCommonSeries(in: listings, issue: barcode.issueNumber.map(String.init))
        var fromEbay = listings.compactMap { listing -> Candidate? in
            guard listing.imageURL != nil else { return nil }
            var spec = barcode.spec
            if spec.issue.isEmpty, let issue = EbaySoldSearch.issueGuess(from: listing.title) { spec.issue = issue }
            spec.title = series ?? EbaySoldSearch.seriesGuess(from: listing.title, issue: spec.issue)
            guard !spec.title.isEmpty else { return nil }
            let guess = EbaySoldSearch.variantGuess(from: listing.title, series: spec.title)
            spec.variant = guess.variant
            spec.exclusive = guess.exclusive
            spec.notes = ""
            spec.coverImageURL = listing.largeImageURL?.absoluteString ?? ""
            return Candidate(spec: spec, imageURL: spec.coverImageURL.nilIfEmpty, source: "eBay listing")
        }
        if let photo { fromEbay = await rankByLook(fromEbay, photo: photo) }
        candidates += dedupe(fromEbay)
        candidates = dedupe(candidates)

        // Regular cover, 1st printing, and most listings agree on the series → that's it.
        let agreeing = listings.filter { EbaySoldSearch.seriesGuess(from: $0.title, issue: barcode.issueNumber.map(String.init) ?? "").lowercased() == series?.lowercased() }.count
        let confident = barcode.hasAddOn && barcode.coverVariant == 1 && barcode.printing == 1 && agreeing >= 3
            && candidates.first?.spec.variant.isEmpty == true && candidates.first?.spec.exclusive.isEmpty == true

        if candidates.isEmpty {
            message = message ?? "No listings mention this barcode yet. Try the cover, or type the title."
        }
        return Identification(candidates: Array(candidates.prefix(10)), confident: confident,
                              method: "Barcode", photo: photo, barcode: barcode, message: message)
    }

    // MARK: Cover photo

    static func identify(cover: CGImage, context: ModelContext, bot: WebBot) async -> Identification {
        var candidates: [Candidate] = []
        var message: String?

        // 1. Covers you've confirmed before.
        let learned = (try? await CoverRecognizer.matches(forCover: cover, context: context)) ?? []
        if let best = learned.first, best.distance < 0.35,
           learned.count == 1 || learned[1].distance - best.distance > 0.12 {
            return Identification(candidates: learned.map { Candidate(spec: $0.print.spec, imageURL: $0.print.imageURL, source: "Your covers", distance: $0.distance) },
                                  confident: true, method: "Cover", photo: cover)
        }
        candidates += learned.filter { $0.distance < 0.8 }
            .map { Candidate(spec: $0.print.spec, imageURL: $0.print.imageURL, source: "Your covers", distance: $0.distance) }

        // 2. VerseDB cover lookup.
        if let verseDB = VerseDBClient.shared, let jpeg = jpeg(cover, maxSide: 1024) {
            do {
                let result = try await verseDB.lookUp(coverJPEG: jpeg)
                var found = result.candidates
                if result.clearMatch, var top = found.first {
                    if let variantID = top.verseDBVariantID { await verseDB.applyVariant(variantID, to: &top) }
                    if let detailed = try? await verseDB.issue(id: top.verseDBIssueID ?? -1) {
                        top = merged(top, with: detailed)
                    }
                    found[0] = top
                    return Identification(candidates: found.map { Candidate(spec: $0, imageURL: $0.coverImageURL.nilIfEmpty, source: "VerseDB") },
                                          confident: true, method: "Cover", photo: cover)
                }
                candidates += found.map { Candidate(spec: $0, imageURL: $0.coverImageURL.nilIfEmpty, source: "VerseDB") }
            } catch {
                message = error.localizedDescription
            }
        }

        // 3. Read the cover's text, search eBay, rank the listing photos by look.
        let text = coverText(cover)
        if !text.query.isEmpty, let listings = try? await EbaySoldSearch.listingsForBarcode(text.query, sold: false, bot: bot) {
            let issue = text.issue ?? mostCommonIssue(in: listings)
            let series = mostCommonSeries(in: listings, issue: issue)
            var fromEbay = listings.compactMap { listing -> Candidate? in
                guard listing.imageURL != nil else { return nil }
                var spec = ComicSpec()
                spec.issue = issue ?? EbaySoldSearch.issueGuess(from: listing.title) ?? ""
                spec.title = series ?? EbaySoldSearch.seriesGuess(from: listing.title, issue: spec.issue)
                guard !spec.title.isEmpty else { return nil }
                let guess = EbaySoldSearch.variantGuess(from: listing.title, series: spec.title)
                spec.variant = guess.variant
                spec.exclusive = guess.exclusive
                spec.coverImageURL = listing.largeImageURL?.absoluteString ?? ""
                return Candidate(spec: spec, imageURL: spec.coverImageURL.nilIfEmpty, source: "eBay listing")
            }
            fromEbay = await rankByLook(Array(fromEbay.prefix(16)), photo: cover)
            candidates += fromEbay
        }

        candidates = dedupe(candidates).sorted { ($0.distance ?? 0.9) < ($1.distance ?? 0.9) }
        if candidates.isEmpty {
            message = message ?? "Couldn't read this cover. Try the barcode, or type the title."
        }
        return Identification(candidates: Array(candidates.prefix(10)), confident: false, method: "Cover", photo: cover, message: message)
    }

    // MARK: Typed search

    static func search(_ text: String, bot: WebBot) async -> [Candidate] {
        var candidates: [Candidate] = []
        if let verseDB = VerseDBClient.shared, let found = try? await verseDB.search(text) {
            candidates += found.map { Candidate(spec: $0, imageURL: $0.coverImageURL.nilIfEmpty, source: "VerseDB") }
        }
        let typed = ComicSpec(searchText: text)
        if let listings = try? await EbaySoldSearch.listingsForBarcode(text, sold: false, bot: bot) {
            candidates += listings.compactMap { listing in
                var spec = typed
                if spec.issue.isEmpty { spec.issue = EbaySoldSearch.issueGuess(from: listing.title) ?? "" }
                let guess = EbaySoldSearch.variantGuess(from: listing.title, series: spec.title)
                spec.variant = guess.variant
                spec.exclusive = guess.exclusive
                spec.coverImageURL = listing.largeImageURL?.absoluteString ?? ""
                return listing.imageURL == nil ? nil : Candidate(spec: spec, imageURL: spec.coverImageURL.nilIfEmpty, source: "eBay listing")
            }
        }
        return dedupe(candidates)
    }

    // MARK: Learning

    /// Remembers a confirmed identification: the barcode and the cover photo.
    static func remember(_ candidate: Candidate, from identification: Identification?, context: ModelContext) {
        let spec = candidate.spec
        let scannedCode = identification?.barcode.map { $0.fullUPC ?? $0.base }
        if let code = scannedCode ?? spec.upc.nilIfEmpty {
            if let existing = remembered(code, context: context) {
                existing.specData = (try? JSONEncoder().encode(spec)) ?? existing.specData
                existing.imageURL = candidate.imageURL
            } else {
                context.insert(BarcodeMemory(code: code, spec: spec, imageURL: candidate.imageURL))
            }
        }
        Task {
            if let photo = identification?.photo {
                await CoverRecognizer.learn(spec: spec, image: photo, imageURL: nil, source: "Your photo", context: context)
            }
            if let url = candidate.imageURL {
                await CoverRecognizer.learn(spec: spec, imageURL: url, context: context)
            }
        }
    }

    private static func remembered(_ code: String, context: ModelContext) -> BarcodeMemory? {
        let descriptor = FetchDescriptor<BarcodeMemory>(predicate: #Predicate { $0.code == code })
        return try? context.fetch(descriptor).first
    }

    // MARK: Helpers

    /// Orders candidates by how much their photo looks like yours.
    static func rankByLook(_ candidates: [Candidate], photo: CGImage) async -> [Candidate] {
        guard let target = await CoverRecognizer.fingerprint(photo) else { return candidates }
        var ranked: [Candidate] = []
        await withTaskGroup(of: (Int, CGImage?).self) { group in
            for (index, candidate) in candidates.prefix(12).enumerated() {
                guard let url = candidate.imageURL.flatMap({ URL(string: $0) }) else { continue }
                group.addTask {
                    guard let download = try? await URLSession.shared.data(from: url),
                          let image = UIImage(data: download.0) else { return (index, nil) }
                    return (index, CoverRecognizer.normalized(image, maxSide: 600))
                }
            }
            var images: [Int: CGImage] = [:]
            for await (index, image) in group {
                if let image { images[index] = image }
            }
            for (index, candidate) in candidates.enumerated() {
                var updated = candidate
                if let image = images[index], let print = await CoverRecognizer.fingerprint(image) {
                    updated.distance = CoverRecognizer.distance(target, print)
                }
                ranked.append(updated)
            }
        }
        return ranked.sorted { ($0.distance ?? 9) < ($1.distance ?? 9) }
    }

    private static func dedupe(_ candidates: [Candidate]) -> [Candidate] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.spec.editionKey).inserted }
    }

    private static func merged(_ base: ComicSpec, with detail: ComicSpec) -> ComicSpec {
        var spec = detail
        if !base.variant.isEmpty { spec.variant = base.variant }
        if !base.coverImageURL.isEmpty { spec.coverImageURL = base.coverImageURL }
        if !base.upc.isEmpty { spec.upc = base.upc }
        spec.verseDBVariantID = base.verseDBVariantID
        return spec
    }

    static func mostCommonSeries(in listings: [SoldListing], issue: String?) -> String? {
        var counts: [String: (count: Int, title: String)] = [:]
        for listing in listings {
            let number = issue ?? EbaySoldSearch.issueGuess(from: listing.title) ?? ""
            let series = EbaySoldSearch.seriesGuess(from: listing.title, issue: number)
            guard series.count >= 3, series.count <= 60 else { continue }
            let key = series.lowercased()
            counts[key] = ((counts[key]?.count ?? 0) + 1, counts[key]?.title ?? series)
        }
        return counts.values.max { $0.count < $1.count }?.title
    }

    private static func mostCommonIssue(in listings: [SoldListing]) -> String? {
        let issues = listings.compactMap { EbaySoldSearch.issueGuess(from: $0.title) }
        let counts = Dictionary(grouping: issues) { $0 }.mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key
    }

    /// Words big enough to be the title, plus the issue number, read off the cover.
    static func coverText(_ cover: CGImage) -> (query: String, issue: String?) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: cover, options: [:]).perform([request])
        let observations = request.results ?? []

        var issue: String?
        var lines: [(String, CGFloat)] = []
        for observation in observations {
            guard let text = observation.topCandidates(1).first?.string.trimmed, !text.isEmpty else { continue }
            if issue == nil, let number = firstMatch(#"(?:#|no\.?\s?)\s?(\d{1,4})\b"#, in: text) { issue = number }
            let letters = text.filter(\.isLetter)
            guard letters.count >= 3, !matches(#"\$|¢|direct edition|approved by|comics code|www\.|\.com"#, text) else { continue }
            lines.append((text, observation.boundingBox.height))
        }
        let skip: Set<String> = ["marvel", "dc", "image", "comics", "dark horse", "idw", "boom!", "the"]
        let title = lines.sorted { $0.1 > $1.1 }
            .map(\.0)
            .filter { !skip.contains($0.lowercased()) }
            .prefix(2)
            .joined(separator: " ")
        let query = [title, issue ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        return (title.isEmpty ? "" : query, issue)
    }

    static func jpeg(_ image: CGImage, maxSide: CGFloat) -> Data? {
        guard let scaled = CoverRecognizer.normalized(UIImage(cgImage: image), maxSide: maxSide) else { return nil }
        return UIImage(cgImage: scaled).jpegData(compressionQuality: 0.8)
    }
}

extension String {
    var nilIfEmpty: String? { trimmed.isEmpty ? nil : self }
}
