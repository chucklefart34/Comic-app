import Foundation

/// What kind of copy a sale was.
enum SaleKind: Codable, Hashable {
    /// Unslabbed, with the seller's grade guess if the title gives one.
    case raw(grade: Double?)
    /// In a slab.
    case graded(company: GradingCompany, grade: Double?)

    var isGraded: Bool {
        if case .graded = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .raw(let grade?): return "Raw \(gradeLabel(grade))"
        case .raw(nil): return "Raw · grade not stated"
        case .graded(let company, let grade?): return "\(company.rawValue) \(gradeLabel(grade))"
        case .graded(let company, nil): return "\(company.rawValue) slab"
        }
    }
}

/// One sold listing, classified against the edition being priced.
struct ClassifiedSale: Codable, Hashable, Identifiable {
    let listing: SoldListing
    let kind: SaleKind
    /// Why it isn't counted (nil when it is).
    var excludedReason: String?

    var id: String { listing.id }
    var counted: Bool { excludedReason == nil }
}

enum SaleClassifier {
    /// Grades a seller can write. "9.4", "NM 9.4", "VF/NM 9.0", "raw 8.5".
    static let gradePattern = #"(?<![\d.$/:#,])(10\.0|9\.[024689]|[0-8]\.[05]|1\.8)(?![\d.%,])"#

    /// Grade words, longest first, with the number they usually mean.
    static let gradeWords: [(String, Double)] = [
        ("nm/mt", 9.8), ("nm/m", 9.8), ("near mint plus", 9.6), ("near mint minus", 9.2), ("nm+", 9.6), ("nm-", 9.2),
        ("vf/nm", 9.0), ("near mint", 9.4), ("nm", 9.4),
        ("very fine plus", 8.5), ("very fine+", 8.5), ("vf+", 8.5), ("vf-", 7.5), ("very fine", 8.0), ("vf", 8.0),
        ("fn/vf", 7.0), ("fine plus", 6.5), ("fine+", 6.5), ("fn+", 6.5), ("fn-", 5.5), ("fine", 6.0), ("fn", 6.0),
        ("vg/fn", 5.0), ("vg+", 4.5), ("vg-", 3.5), ("very good", 4.0), ("vg", 4.0),
        ("gd/vg", 3.0), ("gd+", 2.5), ("gd-", 1.8), ("gd", 2.0),
        ("reader copy", 2.0), ("low grade", 3.0), ("fair", 1.0), ("fr", 1.0), ("poor", 0.5), ("pr", 0.5),
    ]

    /// The seller's grade guess for a raw copy, from the title.
    static func rawGrade(in title: String) -> Double? {
        let text = TitleTraits.normalize(title)
        if let number = firstMatch(gradePattern, in: text), let value = Double(number) {
            return value
        }
        for (word, value) in gradeWords {
            let pattern = #"(?<![a-z/])"# + NSRegularExpression.escapedPattern(for: word) + #"(?![a-z/+\-])"#
            if matches(pattern, text) { return value }
        }
        return nil
    }

    /// Classifies every listing: same edition or not, raw or slabbed, and at what grade.
    static func classify(_ listings: [SoldListing], spec: ComicSpec, options: CompOptions, ignoreCover: Bool = false) -> [ClassifiedSale] {
        listings.map { listing in
            let traits = TitleTraits(title: listing.title)
            let kind: SaleKind = traits.company.map { .graded(company: $0, grade: traits.grade) }
                ?? .raw(grade: rawGrade(in: listing.title))
            return ClassifiedSale(listing: listing, kind: kind,
                                  excludedReason: editionMismatch(listing, traits: traits, spec: spec, options: options, ignoreCover: ignoreCover))
        }
    }

    /// Everything that makes a sale a different book or an unusable comp (grade aside).
    static func editionMismatch(_ listing: SoldListing, traits: TitleTraits, spec: ComicSpec, options: CompOptions, ignoreCover: Bool = false) -> String? {
        let title = TitleTraits.normalize(listing.title)
        if traits.lot { return "Lot or more than one book" }
        if traits.reprint && !spec.mentionsReprint { return "Facsimile or reprint" }
        if !CompMatcher.issueMatches(spec.issue, in: title) { return "Different issue number" }
        if traits.qualified || traits.restored { return traits.restored ? "Restored copy" : "Qualified (green) label" }

        if spec.signed {
            if !traits.signed { return "Not signed" }
            if let last = spec.signerLastName, !title.contains(last) { return "Different or unnamed signer" }
        } else if traits.signed {
            return "Signed copy"
        }

        if ignoreCover {
            // Fallback when nothing mentions the exact cover: any cover of the issue counts.
        } else if spec.variant.trimmed.isEmpty && spec.exclusive.trimmed.isEmpty {
            if traits.variant { return "Variant or exclusive cover" }
        } else {
            for token in CompMatcher.variantTokens(spec) where !CompMatcher.tokenMatches(token, in: title) {
                return "Doesn't mention \"\(token.replacingOccurrences(of: "cover:", with: "cover "))\""
            }
        }

        if spec.printing <= 1 {
            if let printing = traits.laterPrinting { return "\(ordinal(printing)) printing" }
        } else if traits.laterPrinting != spec.printing {
            return "Not a \(ordinal(spec.printing)) printing"
        }

        if listing.bestOffer && !options.includeBestOffer {
            return "Best Offer — real price hidden"
        }
        return nil
    }
}
