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

    var grade: Double? {
        switch self {
        case .raw(let grade), .graded(_, let grade): return grade
        }
    }

    var company: GradingCompany? {
        if case .graded(let company, _) = self { return company }
        return nil
    }
}

/// Which price group a sale belongs to. Different groups are never averaged together.
enum CopyGroup: Hashable, Codable, Identifiable {
    case raw
    case rawSigned
    case slab(GradingCompany, SlabLabel)

    var id: String { label }

    var label: String {
        switch self {
        case .raw: return "Raw"
        case .rawSigned: return "Raw · signed"
        case .slab(let company, let label): return "\(company.rawValue) \(Self.shortLabel(label))"
        }
    }

    static func shortLabel(_ label: SlabLabel) -> String {
        switch label {
        case .universal: return "Universal"
        case .signatureSeries: return "Signature Series"
        case .qualified: return "Qualified"
        case .restored: return "Restored"
        }
    }

    /// The group an owned copy belongs to.
    static func of(_ spec: ComicSpec) -> CopyGroup {
        if spec.graded { return .slab(spec.company, spec.signed && spec.label == .universal ? .signatureSeries : spec.label) }
        return spec.signed ? .rawSigned : .raw
    }
}

/// One sold listing, classified against the edition being priced.
struct ClassifiedSale: Codable, Hashable, Identifiable {
    let listing: SoldListing
    let kind: SaleKind
    /// Why it isn't this edition (nil when it is).
    var excludedReason: String?
    // Added in 1.1 (optional so older saved prices still load).
    var signed: Bool?
    var label: SlabLabel?
    /// 0…1: how sure the match is. Below 0.7 is flagged for review.
    var confidence: Double?
    /// Your decision: true = approved, false = rejected, nil = automatic.
    var review: Bool?

    var id: String { listing.id }
    var counted: Bool { excludedReason == nil }
    var needsReview: Bool { counted && review == nil && (confidence ?? 1) < 0.7 }

    var group: CopyGroup {
        switch kind {
        case .raw: return signed == true ? .rawSigned : .raw
        case .graded(let company, _): return .slab(company, label ?? .universal)
        }
    }

    var kindLabel: String {
        switch kind {
        case .raw(let grade?): return "\(group.label) \(gradeLabel(grade))"
        case .raw(nil): return "\(group.label) · grade not stated"
        case .graded(_, let grade?): return "\(group.label) \(gradeLabel(grade))"
        case .graded: return "\(group.label) · grade not stated"
        }
    }
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

    /// Slab label from the title.
    static func slabLabel(traits: TitleTraits) -> SlabLabel {
        if traits.restored { return .restored }
        if traits.qualified { return .qualified }
        if traits.signed { return .signatureSeries }
        return .universal
    }

    /// Classifies every listing: same edition or not, raw or slabbed, label, grade, and how sure the match is.
    /// `reviews` are your saved approve (true) / reject (false) decisions by listing ID.
    static func classify(_ listings: [SoldListing], spec: ComicSpec, options: CompOptions,
                         ignoreCover: Bool = false, reviews: [String: Bool] = [:]) -> [ClassifiedSale] {
        listings.map { listing in
            let traits = TitleTraits(title: listing.title)
            let kind: SaleKind = traits.company.map { .graded(company: $0, grade: traits.grade) }
                ?? .raw(grade: rawGrade(in: listing.title))
            var reason = editionMismatch(listing, traits: traits, spec: spec, options: options, ignoreCover: ignoreCover)
            let review = reviews[listing.id]
            if review == true { reason = nil }
            if review == false { reason = "Rejected by you" }
            return ClassifiedSale(listing: listing, kind: kind, excludedReason: reason,
                                  signed: traits.signed,
                                  label: kind.isGraded ? slabLabel(traits: traits) : nil,
                                  confidence: reason == nil ? matchConfidence(listing, traits: traits, kind: kind, spec: spec) : 0,
                                  review: review)
        }
    }

    /// Everything that makes a sale a different book (edition, printing, cover, signer) or unusable.
    /// Raw vs slab, company, label and grade are NOT reasons — those become separate price groups.
    static func editionMismatch(_ listing: SoldListing, traits: TitleTraits, spec: ComicSpec, options: CompOptions, ignoreCover: Bool = false) -> String? {
        let title = TitleTraits.normalize(listing.title)
        if traits.lot { return "Lot or more than one book" }
        if traits.reprint && !spec.mentionsReprint { return "Facsimile or reprint" }
        if !CompMatcher.issueMatches(spec.issue, in: title) { return "Different issue number" }
        if !seriesMatches(spec, title: title) { return "Different series" }

        if spec.signed, traits.signed, let last = spec.signerLastName, !title.contains(last) {
            return "Signed by someone else"
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

        let newsstand = matches(#"\bnewsstand\b"#, title)
        if spec.printEdition == .newsstand && !newsstand { return "Not a newsstand copy" }
        if spec.printEdition == .direct && newsstand { return "Newsstand copy" }

        if spec.printing <= 1 {
            if let printing = traits.laterPrinting { return "\(ordinal(printing)) printing" }
        } else if traits.laterPrinting != spec.printing {
            return "Not a \(ordinal(spec.printing)) printing"
        }

        if listing.bestOffer && !options.includeBestOffer {
            return "Best Offer — real price hidden"
        }
        if listing.priceCents < 100 { return "Under $1 — likely not a real sale" }
        return nil
    }

    /// How sure we are that a same-edition sale really is this book (0…1).
    private static let stopWords: Set<String> = ["the", "and", "of", "a", "an", "vol", "volume", "comic", "comics"]

    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// The words of the series name a sale must contain ("Superman/Wonder Woman" → superman, wonder, woman).
    static func seriesWords(_ spec: ComicSpec) -> [String] {
        tokens(spec.searchTitle).filter { !stopWords.contains($0) && ($0.count > 1 || $0.first?.isNumber == true) }
    }

    /// True when the sale names the same series: every word, the words run together ("spiderman"),
    /// or the usual initials ("ASM" for Amazing Spider-Man). Stops "Wonder Woman #1" counting for "Superman/Wonder Woman #1".
    static func seriesMatches(_ spec: ComicSpec, title: String) -> Bool {
        let words = seriesWords(spec)
        guard !words.isEmpty else { return true }
        let saleWords = tokens(title)
        let saleSet = Set(saleWords)
        if words.allSatisfy(saleSet.contains) { return true }
        let compact = saleWords.joined()
        let missing = words.filter { !saleSet.contains($0) }
        // Words run together: "Spiderman", "Xmen".
        if !missing.isEmpty, compact.contains(words.joined()) { return true }
        if missing.allSatisfy({ word in
            guard let index = words.firstIndex(of: word) else { return false }
            let pairs = [index > 0 ? words[index - 1] + word : nil, index + 1 < words.count ? word + words[index + 1] : nil]
            return pairs.contains { $0.map(saleSet.contains) ?? false }
        }) { return true }
        // Initials: "ASM", "TMNT", "FF".
        let initials = String(tokens(spec.searchTitle).filter { !["the", "of", "and"].contains($0) }.compactMap(\.first))
        if initials.count >= 2, saleSet.contains(initials) { return true }
        return false
    }

    static func matchConfidence(_ listing: SoldListing, traits: TitleTraits, kind: SaleKind, spec: ComicSpec) -> Double {
        let title = TitleTraits.normalize(listing.title)
        var score = 1.0

        // Title words: how many of the series' words the listing contains.
        let words = seriesWords(spec)
        if !words.isEmpty {
            let saleWords = Set(tokens(title))
            let present = words.filter { saleWords.contains($0) }.count
            score -= 0.4 * (1 - Double(present) / Double(words.count))
        }
        // "#300" is clearer than a bare "300".
        if !spec.searchIssue.isEmpty, !matches(#"#\s?0*"# + NSRegularExpression.escapedPattern(for: spec.searchIssue) + #"(?!\d)"#, title) {
            score -= 0.1
        }
        // Several issue numbers in one title ("#299 #300") might be a mislabeled lot.
        let issueMentions = (try? NSRegularExpression(pattern: #"#\s?\d+"#))?
            .numberOfMatches(in: title, range: NSRange(title.startIndex..., in: title)) ?? 0
        if issueMentions > 1 { score -= 0.25 }
        // A slab without a stated grade can't be placed in a grade.
        if kind.isGraded && kind.grade == nil { score -= 0.2 }
        // Words that often mean "not the book itself".
        if matches(#"\b(poster|art print|cover only|coverless|no cover|incomplete|missing pages|pages only|statue|figure|t-shirt|sticker)\b"#, title) {
            score -= 0.4
        }
        if matches(#"\b(damaged|water damage|torn|detached)\b"#, title) { score -= 0.15 }
        if listing.soldDate == nil { score -= 0.1 }
        if listing.bestOffer { score -= 0.1 }
        return max(0.05, min(1, score))
    }
}
