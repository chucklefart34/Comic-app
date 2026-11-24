import Foundation

enum Confidence: String, Codable {
    case high = "High"
    case medium = "Medium"
    case low = "Low"
    case none = "None"

    var explanation: String {
        switch self {
        case .high: return "Several recent sales of this exact edition."
        case .medium: return "A few sales, or prices from a price guide or slab sales."
        case .low: return "Estimate based mostly on similar comics."
        case .none: return "Not enough information for a responsible price."
        }
    }
}

/// How a band's price was arrived at.
enum PriceBasis: String, Codable {
    case sales = "Sold"
    case estimate = "Estimate"
    case none = "N/A"
}

struct BandValue: Codable, Hashable {
    var cents: Int?
    var lowCents: Int?
    var highCents: Int?
    var count = 0
    var basis: PriceBasis = .none
    var note: String?
}

struct GradedPrice: Codable, Hashable, Identifiable {
    var company: GradingCompany
    var grade: Double
    var cents: Int
    var count: Int
    var id: String { "\(company.rawValue)-\(grade)" }
}

struct SourceNote: Codable, Hashable, Identifiable {
    var name: String
    var detail: String
    var used: Bool
    var id: String { name }
}

/// Everything known about what an edition is worth.
struct Valuation: Codable, Hashable {
    var bands: [PriceBand: BandValue] = [:]
    /// Typical raw sale, any condition.
    var marketCents: Int?
    var marketBasis: PriceBasis = .none
    var rawSaleCount = 0
    var graded: [GradedPrice] = []
    var confidence: Confidence = .none
    var sources: [SourceNote] = []
    var sales: [ClassifiedSale] = []
    var estimateNote: String?
    var updatedAt = Date()

    func band(_ band: PriceBand) -> BandValue { bands[band] ?? BandValue() }

    /// Price for a specific condition: the band for raw copies, the exact grade for slabs.
    func value(for condition: Condition?, spec: ComicSpec) -> (cents: Int?, basis: PriceBasis, label: String) {
        if condition == .graded || (condition == nil && spec.graded) {
            if let match = graded.first(where: { $0.company == spec.company && abs($0.grade - spec.grade) < 0.05 }) {
                return (match.cents, .sales, "\(spec.company.rawValue) \(spec.gradeText)")
            }
            return (nil, .none, "\(spec.company.rawValue) \(spec.gradeText)")
        }
        if let band = condition?.band {
            let value = self.band(band)
            return (value.cents, value.basis, "\(condition?.rawValue ?? "") · \(band.rawValue)")
        }
        return (marketCents, marketBasis, "Market value")
    }

    var hasAnyPrice: Bool { marketCents != nil || bands.values.contains { $0.cents != nil } || !graded.isEmpty }
}

/// Turns sold listings (and optional price-guide data) into Low / Mid / High values with a confidence.
enum PricingEngine {
    /// Combines provider data into a valuation. `seriesSales` are used only when this issue has no sales.
    static func valuation(
        spec: ComicSpec,
        listings: [SoldListing],
        seriesListings: [SoldListing] = [],
        guide: GuideData? = nil,
        sources: [SourceNote],
        options: CompOptions,
        ignoreCover: Bool = false
    ) -> Valuation {
        var result = Valuation()
        result.sources = sources
        var sales = SaleClassifier.classify(listings, spec: spec, options: options, ignoreCover: ignoreCover)

        // Outliers among raw sales of this edition.
        markOutliers(&sales, options: options) { if case .raw = $0.kind { return true } else { return false } }
        markOutliers(&sales, options: options) { $0.kind.isGraded }
        result.sales = sales.sorted { ($0.listing.soldDate ?? .distantPast) > ($1.listing.soldDate ?? .distantPast) }

        let counted = sales.filter(\.counted)
        let raw = counted.filter { !$0.kind.isGraded }
        result.rawSaleCount = raw.count

        // Overall raw market (any condition).
        if let market = weightedMedian(raw.map { point($0, options) }) {
            result.marketCents = market
            result.marketBasis = .sales
        }

        // Bands from sales that state a grade.
        var bands: [PriceBand: BandValue] = [:]
        for band in PriceBand.allCases {
            let inBand = raw.filter {
                if case .raw(let grade?) = $0.kind { return PriceBand.of(grade: grade) == band }
                return false
            }
            if inBand.count >= 1, let value = weightedMedian(inBand.map { point($0, options) }) {
                let prices = inBand.map { $0.listing.totalCents(includeShipping: options.includeShipping) }.sorted()
                bands[band] = BandValue(cents: value,
                                        lowCents: prices.count >= 3 ? CompMatcher.percentile(prices, 0.25) : prices.first,
                                        highCents: prices.count >= 3 ? CompMatcher.percentile(prices, 0.75) : prices.last,
                                        count: inBand.count, basis: .sales)
            }
        }

        // Slab prices by company + grade.
        let slabs = counted.compactMap { sale -> (GradingCompany, Double, ClassifiedSale)? in
            if case .graded(let company, let grade?) = sale.kind { return (company, grade, sale) }
            return nil
        }
        let groups = Dictionary(grouping: slabs) { "\($0.0.rawValue)|\($0.1)" }
        result.graded = groups.values.compactMap { group in
            guard let first = group.first, let value = weightedMedian(group.map { point($0.2, options) }) else { return nil }
            return GradedPrice(company: first.0, grade: first.1, cents: value, count: group.count)
        }.sorted { ($0.company.rawValue, -$0.grade) < ($1.company.rawValue, -$1.grade) }

        // Price guide (e.g. PriceCharting) fills gaps.
        if let guide {
            if result.marketCents == nil, let loose = guide.ungradedCents {
                result.marketCents = loose
                result.marketBasis = .sales
                result.estimateNote = "Market value from \(guide.source) (no matching eBay sales found)."
            }
            for guidePoint in guide.graded where !result.graded.contains(where: { $0.company == .cgc && abs($0.grade - guidePoint.grade) < 0.05 }) {
                result.graded.append(GradedPrice(company: .cgc, grade: guidePoint.grade, cents: guidePoint.cents, count: 0))
            }
        }

        fillMissingBands(&bands, result: &result, spec: spec, seriesListings: seriesListings, options: options)
        result.bands = bands
        result.confidence = confidence(for: result, raw: raw)

        if ignoreCover, result.hasAnyPrice {
            // These sales may be of other covers, so everything is an estimate.
            for band in PriceBand.allCases {
                if var value = result.bands[band], value.cents != nil {
                    value.basis = .estimate
                    value.note = "From sales of any cover of this issue"
                    result.bands[band] = value
                }
            }
            if result.marketCents != nil { result.marketBasis = .estimate }
            if result.confidence == .high { result.confidence = .medium }
            result.estimateNote = "No sales mention this exact cover, so this is based on sales of every cover of the issue. Variants can sell for much more or less."
        }
        result.updatedAt = Date()
        return result
    }

    // MARK: Estimates

    /// Standard price ratios between condition bands, used only to estimate a band that has no sales.
    /// Vintage books spread wider between low and high grades than modern books.
    private static func ratios(vintage: Bool) -> (low: Double, mid: Double, high: Double) {
        vintage ? (0.3, 1.0, 3.0) : (0.35, 1.0, 1.8)
    }

    private static func fillMissingBands(_ bands: inout [PriceBand: BandValue], result: inout Valuation, spec: ComicSpec,
                                         seriesListings: [SoldListing], options: CompOptions) {
        let vintage = (Int(spec.year) ?? 2000) < 1985
        let r = ratios(vintage: vintage)
        func scale(_ band: PriceBand) -> Double {
            switch band { case .low: return r.low; case .mid: return r.mid; case .high: return r.high }
        }

        // 1. From another band of this exact edition.
        if let anchor = PriceBand.allCases.compactMap({ band -> (PriceBand, Int)? in
            guard let value = bands[band], value.basis == .sales, let cents = value.cents else { return nil }
            return (band, cents)
        }).max(by: { (bands[$0.0]?.count ?? 0) < (bands[$1.0]?.count ?? 0) }) {
            let midEquivalent = Double(anchor.1) / scale(anchor.0)
            for band in PriceBand.allCases where bands[band] == nil {
                bands[band] = estimate(midEquivalent * scale(band), note: "Estimated from \(anchor.0.rawValue)-grade sales of this book")
            }
            return
        }

        // 2. From raw sales that don't state a grade (treated as a typical, mid-to-high copy).
        if let market = result.marketCents, result.marketBasis == .sales {
            let midEquivalent = Double(market) / (vintage ? 1.0 : 1.3)
            for band in PriceBand.allCases {
                bands[band] = estimate(midEquivalent * scale(band), note: "Sellers didn't state grades; estimated from \(result.rawSaleCount) raw sales")
            }
            return
        }

        // 3. From slab sales of this book (raw copies usually sell for well under slabbed ones).
        if !result.graded.isEmpty {
            for band in PriceBand.allCases {
                let inBand = result.graded.filter { PriceBand.of(grade: $0.grade) == band }
                guard !inBand.isEmpty else { continue }
                let slab = Double(inBand.map(\.cents).reduce(0, +)) / Double(inBand.count)
                bands[band] = estimate(max(slab * 0.5, slab - 3500), note: "Estimated from slabbed sales (minus grading costs)")
            }
            if let anchor = bands.first?.value.cents, let anchorBand = bands.first?.key {
                let midEquivalent = Double(anchor) / scale(anchorBand)
                for band in PriceBand.allCases where bands[band] == nil {
                    bands[band] = estimate(midEquivalent * scale(band), note: "Estimated from slabbed sales")
                }
            }
            if result.marketCents == nil, let mid = bands[.mid]?.cents {
                result.marketCents = mid
                result.marketBasis = .estimate
            }
            return
        }

        // 4. From other issues of the same series.
        let others = seriesListings.filter { listing in
            let traits = TitleTraits(title: listing.title)
            return traits.company == nil && !traits.lot && !traits.reprint && !traits.signed && !traits.variant
        }
        let prices = others.map { $0.totalCents(includeShipping: options.includeShipping) }.sorted()
        if prices.count >= 3 {
            let typical = Double(CompMatcher.percentile(prices, 0.5))
            let midEquivalent = typical / (vintage ? 1.0 : 1.3)
            let keyIssue = !spec.keyNotes.isEmpty
            for band in PriceBand.allCases {
                var value = estimate(midEquivalent * scale(band), note: "Estimated from \(prices.count) sales of other \(spec.title) issues")
                if keyIssue, let high = value.highCents { value.highCents = high * 3 }
                bands[band] = value
            }
            result.marketCents = Int(typical.rounded())
            result.marketBasis = .estimate
            result.estimateNote = keyIssue
                ? "No sales of this issue found. It's a key issue, so it likely sells above the series' typical price — treat as a floor."
                : "No sales of this issue found. Estimated from other issues in the series."
        }
    }

    private static func estimate(_ cents: Double, note: String) -> BandValue {
        let value = max(100, Int(cents.rounded()))
        return BandValue(cents: value, lowCents: Int(Double(value) * 0.7), highCents: Int(Double(value) * 1.35),
                         count: 0, basis: .estimate, note: note)
    }

    private static func confidence(for result: Valuation, raw: [ClassifiedSale]) -> Confidence {
        guard result.hasAnyPrice else { return .none }
        if result.marketBasis == .estimate || (raw.isEmpty && result.graded.allSatisfy { $0.count == 0 }) {
            return raw.isEmpty && result.graded.contains(where: { $0.count > 0 }) ? .medium : .low
        }
        let recent = raw.filter { ($0.listing.soldDate ?? .distantPast) > Date().addingTimeInterval(-90 * 86_400) }
        if recent.count >= 5 { return .high }
        if raw.count >= 2 { return .medium }
        return .low
    }

    // MARK: Statistics

    private static func point(_ sale: ClassifiedSale, _ options: CompOptions) -> (cents: Int, date: Date?) {
        (sale.listing.totalCents(includeShipping: options.includeShipping), sale.listing.soldDate)
    }

    /// Median where recent sales count more (half weight every 45 days).
    static func weightedMedian(_ points: [(cents: Int, date: Date?)]) -> Int? {
        guard !points.isEmpty else { return nil }
        let now = Date()
        let weighted = points.map { point -> (Int, Double) in
            guard let date = point.date else { return (point.cents, 0.5) }
            let days = max(0, now.timeIntervalSince(date) / 86_400)
            return (point.cents, max(0.15, pow(0.5, days / 45)))
        }.sorted { $0.0 < $1.0 }
        let total = weighted.map(\.1).reduce(0, +)
        var running = 0.0
        for (cents, weight) in weighted {
            running += weight
            if running >= total / 2 { return cents }
        }
        return weighted.last?.0
    }

    /// Leaves out prices far from the rest (damaged copies, typos, shill bids).
    private static func markOutliers(_ sales: inout [ClassifiedSale], options: CompOptions, where include: (ClassifiedSale) -> Bool) {
        let indices = sales.indices.filter { sales[$0].counted && include(sales[$0]) }
        guard indices.count >= 3 else { return }
        let logs = indices.map { log(Double(max(1, sales[$0].listing.totalCents(includeShipping: options.includeShipping)))) }
        let sorted = logs.sorted()
        func quantile(_ p: Double) -> Double {
            let position = p * Double(sorted.count - 1)
            let lower = Int(position.rounded(.down))
            let upper = min(lower + 1, sorted.count - 1)
            return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
        }
        let q1 = quantile(0.25), q3 = quantile(0.75), median = quantile(0.5)
        let spread = max(q3 - q1, 0.35)
        for (offset, index) in indices.enumerated() {
            let value = logs[offset]
            // Graded sales span many grades, so only drop extreme ones there.
            let limit = sales[index].kind.isGraded ? 3.0 : 1.5
            if value > q3 + limit * spread || value < q1 - limit * spread || abs(value - median) > log(6) {
                sales[index].excludedReason = "Price far from the others"
            }
        }
    }
}

/// Prices from a price guide (e.g. PriceCharting) — supporting data, not individual sales.
struct GuideData: Codable, Hashable {
    var source: String
    var ungradedCents: Int?
    var graded: [(grade: Double, cents: Int)] = []

    static func == (a: GuideData, b: GuideData) -> Bool {
        a.source == b.source && a.ungradedCents == b.ungradedCents && a.graded.map(\.cents) == b.graded.map(\.cents)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(source)
        hasher.combine(ungradedCents)
    }

    enum CodingKeys: String, CodingKey { case source, ungradedCents, grades, cents }

    init(source: String, ungradedCents: Int?, graded: [(grade: Double, cents: Int)]) {
        self.source = source
        self.ungradedCents = ungradedCents
        self.graded = graded
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source)
        ungradedCents = try c.decodeIfPresent(Int.self, forKey: .ungradedCents)
        let grades = try c.decodeIfPresent([Double].self, forKey: .grades) ?? []
        let cents = try c.decodeIfPresent([Int].self, forKey: .cents) ?? []
        graded = zip(grades, cents).map { ($0, $1) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(ungradedCents, forKey: .ungradedCents)
        try c.encode(graded.map(\.grade), forKey: .grades)
        try c.encode(graded.map(\.cents), forKey: .cents)
    }
}
