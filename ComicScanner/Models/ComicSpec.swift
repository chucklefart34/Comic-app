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

/// Everything that decides what a specific copy of a comic sells for.
struct ComicSpec: Codable, Hashable {
    var title = ""
    var issue = ""
    var year = ""
    var publisher = ""

    /// Cover / variant description, e.g. "Cover B", "Virgin 1:25", "Campbell".
    var variant = ""
    /// Store or convention exclusive, e.g. "Mile High", "SDCC".
    var exclusive = ""
    var printing = 1

    var signed = false
    var signer = ""
    var signatureProof: SignatureProof = .none

    var graded = false
    var company: GradingCompany = .cgc
    var grade: Double = 9.8
    var label: SlabLabel = .universal
    var pageQuality = ""
    var certNumber = ""

    var upc = ""
    var notes = ""
    var coverImageURL = ""

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

    // MARK: Display

    var displayTitle: String {
        var text = title.trimmed.isEmpty ? "Untitled comic" : title.trimmed
        if !issue.trimmed.isEmpty { text += " #\(issue.trimmed)" }
        if !year.trimmed.isEmpty { text += " (\(year.trimmed))" }
        return text
    }

    /// e.g. "Virgin 1:25 · Mile High exclusive · 2nd printing · CGC 9.8 SS · signed McFarlane"
    var detailLine: String {
        var parts: [String] = []
        if !variant.trimmed.isEmpty { parts.append(variant.trimmed) }
        if !exclusive.trimmed.isEmpty { parts.append("\(exclusive.trimmed) exclusive") }
        if printing > 1 { parts.append("\(ordinal(printing)) printing") }
        if graded {
            var slab = "\(company.rawValue) \(gradeText)"
            if label == .signatureSeries { slab += " SS" }
            if label == .qualified { slab += " Qualified" }
            if label == .restored { slab += " Restored" }
            parts.append(slab)
        } else {
            parts.append("Raw")
        }
        if signed {
            parts.append(signer.trimmed.isEmpty ? "Signed" : "Signed by \(signer.trimmed)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: eBay search

    /// The keywords sent to eBay. Words starting with "-" are excluded by eBay.
    var ebayQuery: String {
        if !customQuery.trimmed.isEmpty { return customQuery.trimmed }

        var words: [String] = [title.trimmed]
        if !issue.trimmed.isEmpty { words.append(issue.trimmed) }
        if !variant.trimmed.isEmpty { words.append(variant.trimmed) }
        if !exclusive.trimmed.isEmpty { words.append(exclusive.trimmed) }
        if printing > 1 { words.append(ordinal(printing)) }
        if graded {
            words.append(company.rawValue)
            words.append(gradeText)
        }
        if signed, let last = signerLastName {
            words.append(last)
        }

        var excluded: [String] = ["lot", "lots", "bundle"]
        if !graded { excluded += ["cgc", "cbcs", "pgx", "graded", "slab", "slabbed"] }
        if !signed { excluded += ["signed", "autographed", "remarked"] }
        if !mentionsReprint { excluded += ["facsimile", "reprint"] }

        return (words.filter { !$0.isEmpty } + excluded.map { "-\($0)" }).joined(separator: " ")
    }

    /// Wide search (just title + issue) used to fetch sales ahead of time; the matcher narrows it down.
    var broadQuery: String {
        var words = [title.trimmed, issue.trimmed].filter { !$0.isEmpty }
        words += ["-lot", "-lots", "-bundle"]
        if !mentionsReprint { words += ["-facsimile", "-reprint"] }
        return words.joined(separator: " ")
    }

    var mentionsReprint: Bool {
        let text = "\(title) \(variant)".lowercased()
        return text.contains("facsimile") || text.contains("reprint") || text.contains("true believers")
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
