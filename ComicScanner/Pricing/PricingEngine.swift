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
    /// Universal when nil (prices saved before 1.1).
    var label: SlabLabel?

    var slabLabel: SlabLabel { label ?? .universal }
    var id: String { "\(company.rawValue)-\(slabLabel.rawValue)-\(grade)" }
}

/// Median, average, range and count for one copy group over a time window.
struct WindowStats: Codable, Hashable, Identifiable {
    var days: Int
    var count: Int
    var medianCents: Int?
    var averageCents: Int?
    var lowCents: Int?
    var highCents: Int?
    var id: Int { days }
}

/// Count and median for each copy group (raw, raw signed, each slab type).
struct GroupSummary: Codable, Hashable, Identifiable {
    var groupLabel: String
    var count: Int
    var medianCents: Int?
    var id: String { groupLabel }
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
    /// Headline value for your copy's group (raw, signed raw…): recency-weighted median.
    var marketCents: Int?
    var marketBasis: PriceBasis = .none
    var rawSaleCount = 0
    var graded: [GradedPrice] = []
    var confidence: Confidence = .none
    var sources: [SourceNote] = []
    var sales: [ClassifiedSale] = []
    var estimateNote: String?
    var updatedAt = Date()
    // Added in 1.1.
    var headlineGroup: String?
    var medianCents: Int?
    var averageCents: Int?
    var lowCents: Int?
    var highCents: Int?
    var windows: [WindowStats]?
    /// Median of the last 30 days vs the 90 days before, in percent.
    var trendPercent: Double?
    var groups: [GroupSummary]?
    var reviewCount: Int?

    func band(_ band: PriceBand) -> BandValue { bands[band] ?? BandValue() }

    func graded(company: GradingCompany, label: SlabLabel) -> [GradedPrice] {
        graded.filter { $0.company == company && $0.slabLabel == label }.sorted { $0.grade > $1.grade }
    }

    /// Price for a specific condition: the band for raw copies, the exact company + label + grade for slabs.
    func value(for condition: Condition?, spec: ComicSpec) -> (cents: Int?, basis: PriceBasis, label: String) {
        if condition == .graded || (condition == nil && spec.graded) {
            let label: SlabLabel = spec.signed && spec.label == .universal ? .signatureSeries : spec.label
            let name = "\(spec.company.rawValue) \(spec.gradeText)\(label == .universal ? "" : " " + CopyGroup.shortLabel(label))"
            if let match = graded.first(where: { $0.company == spec.company && $0.slabLabel == label && abs($0.grade - spec.grade) < 0.05 }) {
                return (match.cents, match.count > 0 ? .sales : .estimate, name)
            }
            return (nil, .none, name)
        }
        if let band = condition?.band {
            let value = self.band(band)
            return (value.cents, value.basis, "\(condition?.rawValue ?? "") · \(band.rawValue)")
        }
        // No condition chosen: Mid (5.0–9.0) is the default, falling back to the market value.
        let mid = self.band(.mid)
        if let cents = mid.cents {
            return (cents, mid.basis, "Mid · \(PriceBand.mid.gradeRange)")
        }
        return (marketCents, marketBasis, headlineGroup.map { "\($0) market value" } ?? "Market value")
    }

    var hasAnyPrice: Bool { marketCents != nil || bands.values.contains { $0.cents != nil } || !graded.isEmpty }

    /// Sales of this edition in your copy's group, newest first.
    func headlineSales(for spec: ComicSpec) -> [ClassifiedSale] {
        let group = CopyGroup.of(spec)
        return sales.filter { $0.counted && $0.group == group }
    }
}

/// Turns sold listings (and optional price-guide data) into values with a confidence.
/// Raw, signed raw, and each slab company + label are kept as separate groups and never mixed.
enum PricingEngine {
    static let windowDays = [30, 90, 180, 365]

    /// Combines provider data into a valuation. `seriesListings` are used only when this issue has no sales.
    /// `reviews` are your approve/reject decisions by listing ID.
    static func valuation(
        spec: ComicSpec,
        listings: [SoldListing],
        seriesListings: [SoldListing] = [],
        guide: GuideData? = nil,
        sources: [SourceNote],
        options: CompOptions,
        ignoreCover: Bool = false,
        reviews: [String: Bool] = [:],
        now: Date = Date()
    ) -> Valuation {
        var result = Valuation()
        result.sources = sources
        var sales = SaleClassifier.classify(dedupe(listings), spec: spec, options: options, ignoreCover: ignoreCover, reviews: reviews)

        // Outliers, judged within each group (and each grade band), so a 9.8 slab never makes a raw copy look cheap.
        markOutliers(&sales, options: options, now: now)
        result.sales = sales.sorted { ($0.listing.soldDate ?? .distantPast) > ($1.listing.soldDate ?? .distantPast) }
        result.reviewCount = sales.filter(\.needsReview).count

        let counted = sales.filter(\.counted)
        let ownGroup = CopyGroup.of(spec)
        // Raw prices are for raw copies of your kind (signed or not).
        let rawGroup: CopyGroup = spec.signed ? .rawSigned : .raw
        let raw = counted.filter { $0.group == rawGroup }
        result.rawSaleCount = raw.count
        result.headlineGroup = ownGroup.label

        // Headline: recency- and confidence-weighted median of your copy's group.
        let headline: [ClassifiedSale] = spec.graded
            ? counted.filter { $0.group == ownGroup && ($0.kind.grade.map { abs($0 - spec.grade) < 0.05 } ?? false) }
            : raw
        if let market = weightedMedian(headline.map { point($0, options) }, now: now) {
            result.marketCents = market
            result.marketBasis = .sales
        }
        let headlinePrices = headline.map { $0.listing.totalCents(includeShipping: options.includeShipping) }.sorted()
        if !headlinePrices.isEmpty {
            result.medianCents = CompMatcher.percentile(headlinePrices, 0.5)
            result.averageCents = headlinePrices.reduce(0, +) / headlinePrices.count
            result.lowCents = headlinePrices.first
            result.highCents = headlinePrices.last
        }
        result.windows = windowDays.map { stats(for: headline, days: $0, options: options, now: now) }
        result.trendPercent = trend(headline, options: options, now: now)

        // Bands from raw sales that state a grade.
        var bands: [PriceBand: BandValue] = [:]
        for band in PriceBand.allCases {
            let inBand = raw.filter { $0.kind.grade.map { PriceBand.of(grade: $0) == band } ?? false }
            if !inBand.isEmpty, let value = weightedMedian(inBand.map { point($0, options) }, now: now) {
                let prices = inBand.map { $0.listing.totalCents(includeShipping: options.includeShipping) }.sorted()
                bands[band] = BandValue(cents: value,
                                        lowCents: prices.count >= 3 ? CompMatcher.percentile(prices, 0.25) : prices.first,
                                        highCents: prices.count >= 3 ? CompMatcher.percentile(prices, 0.75) : prices.last,
                                        count: inBand.count, basis: .sales)
            }
        }

        // Slab prices by company + label + grade.
        let slabs = counted.compactMap { sale -> (GradingCompany, SlabLabel, Double, ClassifiedSale)? in
            guard case .graded(let company, let grade?) = sale.kind else { return nil }
            return (company, sale.label ?? .universal, grade, sale)
        }
        let slabGroups = Dictionary(grouping: slabs) { "\($0.0.rawValue)|\($0.1.rawValue)|\($0.2)" }
        result.graded = slabGroups.values.compactMap { group in
            guard let first = group.first, let value = weightedMedian(group.map { point($0.3, options) }, now: now) else { return nil }
            return GradedPrice(company: first.0, grade: first.2, cents: value, count: group.count, label: first.1)
        }.sorted { ($0.company.rawValue, $0.slabLabel.rawValue, -$0.grade) < ($1.company.rawValue, $1.slabLabel.rawValue, -$1.grade) }

        // Summary per group.
        let byGroup = Dictionary(grouping: counted) { $0.group }
        result.groups = byGroup.map { group, items in
            let prices = items.map { $0.listing.totalCents(includeShipping: options.includeShipping) }.sorted()
            return GroupSummary(groupLabel: group.label, count: items.count, medianCents: prices.isEmpty ? nil : CompMatcher.percentile(prices, 0.5))
        }.sorted { $0.count > $1.count }

        // Price guide (e.g. PriceCharting) fills gaps.
        if let guide {
            if result.marketCents == nil, !spec.graded, let loose = guide.ungradedCents {
                result.marketCents = loose
                result.marketBasis = .sales
                result.estimateNote = "Market value from \(guide.source) (no matching eBay sales found)."
            }
            for guidePoint in guide.graded where !result.graded.contains(where: { $0.company == .cgc && $0.slabLabel == .universal && abs($0.grade - guidePoint.grade) < 0.05 }) {
                result.graded.append(GradedPrice(company: .cgc, grade: guidePoint.grade, cents: guidePoint.cents, count: 0, label: .universal))
            }
        }

        fillMissingBands(&bands, result: &result, spec: spec, seriesListings: seriesListings, options: options)
        result.bands = bands
        result.confidence = confidence(for: result, raw: spec.graded ? headline : raw, now: now)

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
        let universalSlabs = result.graded.filter { $0.slabLabel == .universal }
        if !universalSlabs.isEmpty {
            for band in PriceBand.allCases {
                let inBand = universalSlabs.filter { PriceBand.of(grade: $0.grade) == band }
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

    private static func confidence(for result: Valuation, raw: [ClassifiedSale], now: Date) -> Confidence {
        guard result.hasAnyPrice else { return .none }
        if result.marketBasis == .estimate || (raw.isEmpty && result.graded.allSatisfy { $0.count == 0 }) {
            return raw.isEmpty && result.graded.contains(where: { $0.count > 0 }) ? .medium : .low
        }
        // Quantity, recency and match quality.
        let recent = raw.filter { ($0.listing.soldDate ?? .distantPast) > now.addingTimeInterval(-90 * 86_400) }
        let sure = raw.filter { ($0.confidence ?? 1) >= 0.7 }
        if recent.count >= 5 && sure.count >= 4 { return .high }
        if raw.count >= 2 { return .medium }
        return .low
    }

    // MARK: Statistics

    private static func point(_ sale: ClassifiedSale, _ options: CompOptions) -> (cents: Int, date: Date?, weight: Double) {
        (sale.listing.totalCents(includeShipping: options.includeShipping), sale.listing.soldDate, sale.confidence ?? 1)
    }

    /// Median where recent sales count more (half weight every 45 days) and doubtful matches count less.
    static func weightedMedian(_ points: [(cents: Int, date: Date?, weight: Double)], now: Date = Date()) -> Int? {
        guard !points.isEmpty else { return nil }
        let weighted = points.map { point -> (Int, Double) in
            let recency: Double
            if let date = point.date {
                let days = max(0, now.timeIntervalSince(date) / 86_400)
                recency = max(0.15, pow(0.5, days / 45))
            } else {
                recency = 0.5
            }
            return (point.cents, recency * max(0.05, point.weight))
        }.sorted { $0.0 < $1.0 }
        let total = weighted.map(\.1).reduce(0, +)
        var running = 0.0
        for (cents, weight) in weighted {
            running += weight
            if running >= total / 2 { return cents }
        }
        return weighted.last?.0
    }

    static func weightedMedian(_ points: [(cents: Int, date: Date?)], now: Date = Date()) -> Int? {
        weightedMedian(points.map { (cents: $0.cents, date: $0.date, weight: 1.0) }, now: now)
    }

    /// Plain median / average / low / high over the last `days`.
    static func stats(for sales: [ClassifiedSale], days: Int, options: CompOptions, now: Date) -> WindowStats {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let prices = sales.filter { ($0.listing.soldDate ?? .distantPast) >= cutoff }
            .map { $0.listing.totalCents(includeShipping: options.includeShipping) }
            .sorted()
        guard !prices.isEmpty else { return WindowStats(days: days, count: 0) }
        return WindowStats(days: days, count: prices.count,
                           medianCents: CompMatcher.percentile(prices, 0.5),
                           averageCents: prices.reduce(0, +) / prices.count,
                           lowCents: prices.first, highCents: prices.last)
    }

    /// Change in median price: last 30 days vs the 90 days before. Needs at least 2 sales in each.
    static func trend(_ sales: [ClassifiedSale], options: CompOptions, now: Date) -> Double? {
        func median(from start: Double, to end: Double) -> Int? {
            let prices = sales.filter {
                guard let date = $0.listing.soldDate else { return false }
                let age = now.timeIntervalSince(date) / 86_400
                return age >= start && age < end
            }.map { $0.listing.totalCents(includeShipping: options.includeShipping) }.sorted()
            return prices.count >= 2 ? CompMatcher.percentile(prices, 0.5) : nil
        }
        guard let recent = median(from: 0, to: 30), let before = median(from: 30, to: 120), before > 0 else { return nil }
        return (Double(recent) - Double(before)) / Double(before) * 100
    }

    /// The same eBay item fetched twice (e.g. by two searches) only counts once.
    static func dedupe(_ listings: [SoldListing]) -> [SoldListing] {
        var seen = Set<String>()
        return listings.filter { seen.insert($0.id).inserted }
    }

    /// Leaves out prices far from the rest of their group (damaged copies, typos, shill bids).
    /// Groups: copy group + grade band, so different conditions aren't judged against each other.
    static func markOutliers(_ sales: inout [ClassifiedSale], options: CompOptions, now: Date = Date()) {
        let groups = Dictionary(grouping: sales.indices.filter { sales[$0].counted && sales[$0].review != true }) { index -> String in
            let sale = sales[index]
            let band = sale.kind.grade.map { PriceBand.of(grade: $0).rawValue } ?? "unknown"
            let grade = sale.kind.isGraded ? (sale.kind.grade.map { String($0) } ?? "?") : band
            return "\(sale.group.label)|\(grade)"
        }
        for indices in groups.values where indices.count >= 4 {
            let logs = indices.map { log(Double(max(1, sales[$0].listing.totalCents(includeShipping: options.includeShipping)))) }
            let sorted = logs.sorted()
            func quantile(_ p: Double) -> Double {
                let position = p * Double(sorted.count - 1)
                let lower = Int(position.rounded(.down))
                let upper = min(lower + 1, sorted.count - 1)
                return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
            }
            let q1 = quantile(0.25), q3 = quantile(0.75), median = quantile(0.5)
            let spread = max(q3 - q1, 0.3)
            for (offset, index) in indices.enumerated() {
                let value = logs[offset]
                if value > q3 + 1.5 * spread || value < q1 - 1.5 * spread || abs(value - median) > log(5) {
                    sales[index].excludedReason = "Price far from similar sales"
                }
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
