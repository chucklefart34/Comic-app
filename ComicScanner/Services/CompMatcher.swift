import Foundation

/// One sold eBay listing.
struct SoldListing: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let priceCents: Int
    let shippingCents: Int?
    let soldDate: Date?
    let url: URL?
    let imageURL: URL?
    /// "Best offer accepted": eBay shows the asking price, the real price was lower.
    let bestOffer: Bool

    func totalCents(includeShipping: Bool) -> Int {
        priceCents + (includeShipping ? (shippingCents ?? 0) : 0)
    }
}

/// What a listing title says about the copy that sold.
struct TitleTraits: Equatable {
    var company: GradingCompany?
    var grade: Double?
    var signed = false
    var qualified = false
    var restored = false
    var lot = false
    var reprint = false
    var variant = false
    var laterPrinting: Int?

    static let gradeWords = #"ss|signature series|sig series|qualified|restored|universal|graded|grade|slabbed|slab|yellow label|blue label|green label|yellow|blue|green|nm/mt|nm/m|nm\+|nm-|nm|vf/nm|vf\+|vf-|vf|fn/vf|fn\+|fn-|fn|vg/fn|vg\+|vg-|vg|gd/vg|gd|near mint|gem mint|mint|[-:#|]"#
    static let companyPattern = #"\b(cgc|cbcs|pgx|psa)\b"#

    init(title raw: String) {
        let title = TitleTraits.normalize(raw)

        // Grading company + grade, in either order: "CGC 9.8", "CGC SS NM/M 9.8", "9.8 CGC".
        let gradeNumber = #"(10(?:\.0)?|[0-9]\.[0-9]|[1-9])"#
        if let groups = firstGroups(TitleTraits.companyPattern + #"(?:\s*(?:"# + TitleTraits.gradeWords + #"))*\s*"# + gradeNumber + #"(?![\d.])"#, in: title),
           let name = groups[1], let value = groups[2] {
            company = GradingCompany(rawValue: name.uppercased())
            grade = Double(value)
        } else if let groups = firstGroups(#"(?<![\d.])"# + #"(10(?:\.0)?|[0-9]\.[0-9])"# + #"\s*(?:ss\s*|graded\s*)?"# + TitleTraits.companyPattern, in: title),
                  let value = groups[1], let name = groups[2] {
            company = GradingCompany(rawValue: name.uppercased())
            grade = Double(value)
        } else if let name = firstMatch(TitleTraits.companyPattern, in: title) {
            // A slab without a readable grade — but "PSA/DNA" alone is an autograph certificate, not a slab.
            let psaDNAOnly = name.lowercased() == "psa" && matches(#"psa\s*/?\s*dna"#, title)
            if !psaDNAOnly { company = GradingCompany(rawValue: name.uppercased()) }
        }

        signed = matches(#"\b(signed|signature|signatures|autograph|autographed|auto|ss|sig series|sigs?|remark|remarked|jsa|coa|psa\s*/?\s*dna)\b"#, title)
        qualified = matches(#"\b(qualified|green label)\b"#, title)
        restored = matches(#"\b(restored|restoration|purple label|conserved)\b"#, title)
        lot = matches(#"\b(lot|lots|bundle|set of|complete set|full run|run of|collection|issues)\b|#?\b\d{1,4}\s?-\s?#?\d{1,4}\b"#, title)
        reprint = matches(#"\b(facsimile|reprint|reprinted|true believers|replica)\b"#, title)
        variant = matches(#"\b(variant|virgin|incentive|ratio|exclusive|foil|sketch|blank|homage|retailer|convention|metal|chrome|glow|holo|cover [b-z])\b|\b1:\d+\b|\b[b-z] cover\b"#, title)

        if let word = firstMatch(#"\b(2nd|second|3rd|third|4th|fourth|5th|fifth|6th|sixth)\s*(?:print|printing|ptg)"#, in: title) {
            switch word.lowercased() {
            case "2nd", "second": laterPrinting = 2
            case "3rd", "third": laterPrinting = 3
            case "4th", "fourth": laterPrinting = 4
            case "5th", "fifth": laterPrinting = 5
            default: laterPrinting = 6
            }
        }
    }

    /// Lowercase, and write ratios one way: "1 in 25", "1/25", "1-25" → "1:25".
    static func normalize(_ title: String) -> String {
        let lower = title.lowercased()
        return replacing(#"\b1\s*(?:in|/|-)\s*(\d{2,4})\b"#, in: lower, with: "1:$1")
    }
}

struct CompVerdict: Identifiable, Hashable {
    let listing: SoldListing
    let included: Bool
    /// Why it was left out (nil when included).
    let reason: String?
    /// True when the user flipped it by hand.
    let overridden: Bool

    var id: String { listing.id }
}

struct PriceStats: Hashable {
    let count: Int
    let medianCents: Int
    let averageCents: Int
    let lowCents: Int
    let highCents: Int
    let lowerQuartileCents: Int
    let upperQuartileCents: Int
    let newest: Date?
    let oldest: Date?
}

struct CompOptions {
    var includeShipping = true
    var includeBestOffer = false
}

/// Decides which sold listings are the same book as the spec, then summarises their prices.
enum CompMatcher {
    static func evaluate(
        _ listings: [SoldListing],
        spec: ComicSpec,
        options: CompOptions,
        overrides: [String: Bool] = [:]
    ) -> (verdicts: [CompVerdict], stats: PriceStats?) {
        var verdicts = listings.map { listing -> CompVerdict in
            let reason = exclusionReason(listing, spec: spec, options: options)
            if let forced = overrides[listing.id] {
                return CompVerdict(listing: listing, included: forced, reason: forced ? nil : (reason ?? "Excluded by you"), overridden: true)
            }
            return CompVerdict(listing: listing, included: reason == nil, reason: reason, overridden: false)
        }

        // Drop price outliers (damaged copies, typos, shill sales) unless the user kept them on purpose.
        let firstPass = verdicts.filter(\.included).map { $0.listing.totalCents(includeShipping: options.includeShipping) }
        if firstPass.count >= 4 {
            let median = percentile(firstPass.sorted(), 0.5)
            verdicts = verdicts.map { verdict in
                guard verdict.included, !verdict.overridden else { return verdict }
                let price = verdict.listing.totalCents(includeShipping: options.includeShipping)
                if price > median * 4 || price * 4 < median {
                    return CompVerdict(listing: verdict.listing, included: false, reason: "Price far from the others", overridden: false)
                }
                return verdict
            }
        }

        verdicts.sort { ($0.listing.soldDate ?? .distantPast) > ($1.listing.soldDate ?? .distantPast) }
        let included = verdicts.filter(\.included)
        return (verdicts, stats(for: included.map(\.listing), options: options))
    }

    static func exclusionReason(_ listing: SoldListing, spec: ComicSpec, options: CompOptions) -> String? {
        let traits = TitleTraits(title: listing.title)
        let title = TitleTraits.normalize(listing.title)

        if traits.lot { return "Lot or more than one book" }
        if traits.reprint && !spec.mentionsReprint { return "Facsimile or reprint" }
        if !issueMatches(spec.issue, in: title) { return "Different issue number" }

        if spec.graded {
            guard let company = traits.company else { return "Raw copy (not graded)" }
            if company != spec.company { return "Graded by \(company.rawValue)" }
            guard let grade = traits.grade else { return "Grade not in title" }
            if abs(grade - spec.grade) > 0.05 { return "Different grade (\(String(format: "%.1f", grade)))" }
            if spec.label == .qualified && !traits.qualified { return "Not a Qualified label" }
            if spec.label != .qualified && traits.qualified { return "Qualified (green) label" }
            if spec.label == .restored && !traits.restored { return "Not a Restored label" }
            if spec.label != .restored && traits.restored { return "Restored copy" }
        } else if let company = traits.company {
            return "Graded \(company.rawValue) slab"
        } else if traits.restored {
            return "Restored copy"
        }

        if spec.signed {
            if !traits.signed { return "Not signed" }
            if let last = spec.signerLastName, !title.contains(last) { return "Different or unnamed signer" }
        } else if traits.signed {
            return "Signed copy"
        }

        let tokens = variantTokens(spec)
        if spec.variant.trimmed.isEmpty && spec.exclusive.trimmed.isEmpty {
            if traits.variant { return "Variant or exclusive cover" }
        } else {
            for token in tokens where !tokenMatches(token, in: title) {
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

    // MARK: - Pieces

    /// True when the issue number appears as its own number ("#300", "300 ", not "3000", "$300", "1:300", "9.8", "1st").
    static func issueMatches(_ issue: String, in title: String) -> Bool {
        guard let number = firstMatch(#"^\s*(\d+)"#, in: issue), let value = Int(number) else { return true }
        let pattern = #"(?<![\w.$:/,])#?\s?0*"# + String(value) + #"(?!\d|:|\.\d|,\d|st\b|nd\b|rd\b|th\b)"#
        return matches(pattern, title)
    }

    private static let genericWords: Set<String> = [
        "cover", "variant", "edition", "exclusive", "comic", "comics", "the", "and", "by", "of", "a", "an", "var", "ed",
    ]

    /// Words from the variant/exclusive fields that a matching sale must mention.
    static func variantTokens(_ spec: ComicSpec) -> [String] {
        let text = TitleTraits.normalize("\(spec.variant) \(spec.exclusive)")
        var tokens: [String] = []
        if let letter = firstMatch(#"\bcover\s+([a-z])\b"#, in: text) ?? firstMatch(#"\b([a-z])\s+cover\b"#, in: text) {
            tokens.append("cover:\(letter)")
        }
        let cleaned = replacing(#"\bcover\s+[a-z]\b|\b[a-z]\s+cover\b"#, in: text, with: " ")
        for raw in cleaned.split(whereSeparator: { " ,;/()".contains($0) }) {
            let word = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".!?'\"-"))
            if word.count < 3 && !word.contains(":") { continue }
            if genericWords.contains(word) { continue }
            if !tokens.contains(word) { tokens.append(word) }
        }
        return tokens
    }

    static func tokenMatches(_ token: String, in title: String) -> Bool {
        if token.hasPrefix("cover:") {
            let letter = String(token.dropFirst(6))
            return matches(#"\bcover\s*"# + letter + #"\b|\b"# + letter + #"\s+cover\b|\b"# + letter + #"\s+variant\b"#, title)
        }
        if token == "virgin" { return title.contains("virgin") }
        return title.contains(token)
    }

    static func stats(for listings: [SoldListing], options: CompOptions) -> PriceStats? {
        let prices = listings.map { $0.totalCents(includeShipping: options.includeShipping) }.sorted()
        guard !prices.isEmpty else { return nil }
        let dates = listings.compactMap(\.soldDate)
        return PriceStats(
            count: prices.count,
            medianCents: percentile(prices, 0.5),
            averageCents: prices.reduce(0, +) / prices.count,
            lowCents: prices.first ?? 0,
            highCents: prices.last ?? 0,
            lowerQuartileCents: percentile(prices, 0.25),
            upperQuartileCents: percentile(prices, 0.75),
            newest: dates.max(),
            oldest: dates.min()
        )
    }

    /// Linear-interpolated percentile of a sorted list.
    static func percentile(_ sorted: [Int], _ p: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let position = p * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = position - Double(lower)
        return Int((Double(sorted[lower]) * (1 - fraction) + Double(sorted[upper]) * fraction).rounded())
    }
}
