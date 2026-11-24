import Foundation

enum GradingCompany: String, CaseIterable, Codable, Identifiable {
    case cgc = "CGC"
    case cbcs = "CBCS"
    case psa = "PSA"
    case pgx = "PGX"

    var id: String { rawValue }
}

enum SlabLabel: String, CaseIterable, Codable, Identifiable {
    case universal = "Universal (blue)"
    case signatureSeries = "Signature Series (yellow)"
    case qualified = "Qualified (green)"
    case restored = "Restored (purple)"

    var id: String { rawValue }
}

enum SignatureProof: String, CaseIterable, Codable, Identifiable {
    case none = "Not authenticated"
    case coa = "COA / witnessed (JSA, Beckett, PSA/DNA…)"

    var id: String { rawValue }
}

/// The exact edition of a comic (series, issue, cover, printing) plus what's known about it.
struct ComicSpec: Codable, Hashable {
    // Identity
    var title = ""
    var issue = ""
    var year = ""
    var publisher = ""
    var volume = ""
    var releaseDate = ""

    /// Cover / variant description, e.g. "Cover B", "Virgin 1:25", "Campbell".
    var variant = ""
    /// Store or convention exclusive, e.g. "Mile High", "SDCC".
    var exclusive = ""
    var printing = 1
    var isReprint = false

    // Credits and key info
    var writer = ""
    var coverArtist = ""
    var keyNotes: [String] = []
    var variantCount: Int?

    // A specific copy (signature / slab)
    var signed = false
    var signer = ""
    var signatureProof: SignatureProof = .none
    var graded = false
    var company: GradingCompany = .cgc
    var grade: Double = 9.8
    var label: SlabLabel = .universal
    var pageQuality = ""
    var certNumber = ""

    // Codes and links
    var upc = ""
    var isbn = ""
    var notes = ""
    var coverImageURL = ""
    var verseDBIssueID: Int?
    var verseDBVariantID: Int?

    /// Used when the user edits the eBay search by hand.
    var customQuery = ""

    var isEmpty: Bool { title.trimmed.isEmpty }

    var gradeText: String {
        grade == grade.rounded() && grade >= 10 ? String(Int(grade)) : String(format: "%.1f", grade)
    }

    var signerLastName: String? {
        guard let last = signer.split(separator: " ").last.map(String.init), last.count >= 3 else { return nil }
        return last.lowercased()
    }

    /// Same book regardless of grade/signature: used for caching prices and learned covers.
    var editionKey: String {
        [title, issue, variant, exclusive, String(printing)]
            .map { $0.trimmed.lowercased() }
            .joined(separator: "|")
    }

    // MARK: Display

    var displayTitle: String {
        var text = title.trimmed.isEmpty ? "Untitled comic" : title.trimmed
        if !issue.trimmed.isEmpty { text += " #\(issue.trimmed)" }
        return text
    }

    /// "Marvel · 1988 · Vol 1"
    var publicationLine: String {
        var parts: [String] = []
        if !publisher.trimmed.isEmpty { parts.append(publisher.trimmed) }
        if !year.trimmed.isEmpty { parts.append(year.trimmed) }
        if !volume.trimmed.isEmpty { parts.append("Vol \(volume.trimmed)") }
        return parts.joined(separator: " · ")
    }

    /// "Virgin 1:25 · Mile High exclusive · 2nd printing"
    var editionLine: String {
        var parts: [String] = []
        if !variant.trimmed.isEmpty { parts.append(variant.trimmed) } else { parts.append("Regular cover") }
        if !exclusive.trimmed.isEmpty { parts.append("\(exclusive.trimmed) exclusive") }
        if printing > 1 { parts.append("\(ordinal(printing)) printing") }
        if isReprint { parts.append("Reprint") }
        return parts.joined(separator: " · ")
    }

    /// Edition plus slab/signature, e.g. "Cover B · CGC 9.8 SS · Signed by McFarlane"
    var detailLine: String {
        var parts = [editionLine]
        if graded {
            var slab = "\(company.rawValue) \(gradeText)"
            if label == .signatureSeries { slab += " SS" }
            if label == .qualified { slab += " Qualified" }
            if label == .restored { slab += " Restored" }
            parts.append(slab)
        }
        if signed {
            parts.append(signer.trimmed.isEmpty ? "Signed" : "Signed by \(signer.trimmed)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: eBay search

    /// Wide search (title + issue + cover words). The matcher then sorts out grades, slabs and variants.
    var broadQuery: String {
        if !customQuery.trimmed.isEmpty { return customQuery.trimmed }
        var words = [title.trimmed, issue.trimmed].filter { !$0.isEmpty }
        words += ["-lot", "-lots", "-bundle"]
        if !mentionsReprint { words += ["-facsimile", "-reprint"] }
        return words.joined(separator: " ")
    }

    /// Narrow search for this exact cover (only used when there's a variant or exclusive).
    var variantQuery: String? {
        guard customQuery.trimmed.isEmpty, !(variant.trimmed.isEmpty && exclusive.trimmed.isEmpty) else { return nil }
        var words = [title.trimmed, issue.trimmed, variant.trimmed, exclusive.trimmed].filter { !$0.isEmpty }
        words += ["-lot", "-lots", "-bundle"]
        return words.joined(separator: " ")
    }

    /// Searches other issues of the series, used for estimates when this issue has no sales.
    var seriesQuery: String {
        [title.trimmed, "-lot", "-lots", "-bundle", "-set", "-run", "-facsimile", "-reprint"].joined(separator: " ")
    }

    var mentionsReprint: Bool {
        let text = "\(title) \(variant)".lowercased()
        return isReprint || text.contains("facsimile") || text.contains("reprint") || text.contains("true believers")
    }
}

// Lenient decoding, so saved comics survive new fields being added.
extension ComicSpec {
    enum CodingKeys: String, CodingKey {
        case title, issue, year, publisher, volume, releaseDate, variant, exclusive, printing, isReprint
        case writer, coverArtist, keyNotes, variantCount
        case signed, signer, signatureProof, graded, company, grade, label, pageQuality, certNumber
        case upc, isbn, notes, coverImageURL, verseDBIssueID, verseDBVariantID, customQuery
    }

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        issue = (try? c.decodeIfPresent(String.self, forKey: .issue)) ?? ""
        year = (try? c.decodeIfPresent(String.self, forKey: .year)) ?? ""
        publisher = (try? c.decodeIfPresent(String.self, forKey: .publisher)) ?? ""
        volume = (try? c.decodeIfPresent(String.self, forKey: .volume)) ?? ""
        releaseDate = (try? c.decodeIfPresent(String.self, forKey: .releaseDate)) ?? ""
        variant = (try? c.decodeIfPresent(String.self, forKey: .variant)) ?? ""
        exclusive = (try? c.decodeIfPresent(String.self, forKey: .exclusive)) ?? ""
        printing = (try? c.decodeIfPresent(Int.self, forKey: .printing)) ?? 1
        isReprint = (try? c.decodeIfPresent(Bool.self, forKey: .isReprint)) ?? false
        writer = (try? c.decodeIfPresent(String.self, forKey: .writer)) ?? ""
        coverArtist = (try? c.decodeIfPresent(String.self, forKey: .coverArtist)) ?? ""
        keyNotes = (try? c.decodeIfPresent([String].self, forKey: .keyNotes)) ?? []
        variantCount = try? c.decodeIfPresent(Int.self, forKey: .variantCount)
        signed = (try? c.decodeIfPresent(Bool.self, forKey: .signed)) ?? false
        signer = (try? c.decodeIfPresent(String.self, forKey: .signer)) ?? ""
        signatureProof = (try? c.decodeIfPresent(SignatureProof.self, forKey: .signatureProof)) ?? .none
        graded = (try? c.decodeIfPresent(Bool.self, forKey: .graded)) ?? false
        company = (try? c.decodeIfPresent(GradingCompany.self, forKey: .company)) ?? .cgc
        grade = (try? c.decodeIfPresent(Double.self, forKey: .grade)) ?? 9.8
        label = (try? c.decodeIfPresent(SlabLabel.self, forKey: .label)) ?? .universal
        pageQuality = (try? c.decodeIfPresent(String.self, forKey: .pageQuality)) ?? ""
        certNumber = (try? c.decodeIfPresent(String.self, forKey: .certNumber)) ?? ""
        upc = (try? c.decodeIfPresent(String.self, forKey: .upc)) ?? ""
        isbn = (try? c.decodeIfPresent(String.self, forKey: .isbn)) ?? ""
        notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? ""
        coverImageURL = (try? c.decodeIfPresent(String.self, forKey: .coverImageURL)) ?? ""
        verseDBIssueID = try? c.decodeIfPresent(Int.self, forKey: .verseDBIssueID)
        verseDBVariantID = try? c.decodeIfPresent(Int.self, forKey: .verseDBVariantID)
        customQuery = (try? c.decodeIfPresent(String.self, forKey: .customQuery)) ?? ""
    }
}

extension ComicSpec {
    /// "Amazing Spider-Man #300" or "Amazing Spider-Man 300" → title + issue.
    init(searchText: String) {
        self.init()
        let text = searchText.trimmed
        if let hash = text.firstIndex(of: "#") {
            title = text[..<hash].trimmed
            issue = text[text.index(after: hash)...].trimmed.split(separator: " ").first.map(String.init) ?? ""
            return
        }
        let parts = text.split(separator: " ")
        if parts.count > 1, let last = parts.last, last.allSatisfy(\.isNumber) {
            title = parts.dropLast().joined(separator: " ")
            issue = String(last)
        } else {
            title = text
        }
    }
}

func ordinal(_ n: Int) -> String {
    let suffix: String
    switch (n % 100, n % 10) {
    case (11...13, _): suffix = "th"
    case (_, 1): suffix = "st"
    case (_, 2): suffix = "nd"
    case (_, 3): suffix = "rd"
    default: suffix = "th"
    }
    return "\(n)\(suffix)"
}
