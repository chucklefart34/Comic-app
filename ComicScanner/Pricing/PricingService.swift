import Foundation

/// A place prices can come from. New providers can be added here without touching the rest of the app.
protocol PricingProvider {
    var name: String { get }
    /// Shown in Settings → Data sources.
    var status: ProviderStatus { get }
}

enum ProviderStatus: Equatable {
    case active
    case needsToken(String)
    case notAvailable(String)

    var label: String {
        switch self {
        case .active: return "Active"
        case .needsToken: return "Add token"
        case .notAvailable: return "Not connected"
        }
    }

    var detail: String {
        switch self {
        case .active: return ""
        case .needsToken(let text), .notAvailable(let text): return text
        }
    }
}

struct EbaySoldProvider: PricingProvider {
    let name = "eBay sold listings"
    var status: ProviderStatus { .active }
}

struct PriceChartingProvider: PricingProvider {
    let name = "PriceCharting"
    var status: ProviderStatus {
        Tokens.priceCharting == nil ? .needsToken("Paid subscription; add your API token in Settings.") : .active
    }

    /// Ungraded and graded guide prices for an issue.
    func guide(for spec: ComicSpec) async throws -> GuideData? {
        guard let token = Tokens.priceCharting else { return nil }
        guard await NetworkMonitor.shared.isOnline else { throw ServiceError.offline }

        func get(_ path: String, _ items: [URLQueryItem]) async throws -> JSONValue? {
            var components = URLComponents(string: "https://www.pricecharting.com/api/\(path)")!
            components.queryItems = [URLQueryItem(name: "t", value: token)] + items
            let (data, response) = try await URLSession.shared.data(from: components.url!)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { throw ServiceError.unauthorized(name) }
            guard status == 200 else { return nil }
            return JSONValue.parse(data)
        }

        var product: JSONValue?
        if !spec.upc.isEmpty { product = try await get("product", [URLQueryItem(name: "upc", value: spec.upc)]) }
        if product?["id"] == nil {
            let query = [spec.title, spec.issue.isEmpty ? "" : "#\(spec.issue)", spec.variant].filter { !$0.isEmpty }.joined(separator: " ")
            let results = try await get("products", [URLQueryItem(name: "q", value: query)])?["products"]?.array ?? []
            let comic = results.first { ($0["console-name"]?.string ?? "").lowercased().contains("comic") } ?? results.first
            guard let id = comic?["id"]?.string else { return nil }
            try await Task.sleep(nanoseconds: 1_100_000_000)  // PriceCharting allows 1 call a second
            product = try await get("product", [URLQueryItem(name: "id", value: id)])
        }
        guard let product, product["status"]?.string != "error" else { return nil }

        // PriceCharting's generic price fields, as they apply to comics.
        let gradeFields: [(String, Double)] = [
            ("condition-13-price", 3.0), ("cib-price", 4.0), ("condition-14-price", 5.0), ("new-price", 6.0),
            ("condition-15-price", 7.0), ("graded-price", 8.0), ("condition-16-price", 9.0), ("box-only-price", 9.2),
            ("condition-17-price", 9.4), ("condition-10-price", 9.6), ("manual-only-price", 9.8), ("bgs-10-price", 10.0),
        ]
        let graded = gradeFields.compactMap { entry -> (grade: Double, cents: Int)? in
            guard let cents = product[entry.0]?.int, cents > 0 else { return nil }
            return (entry.1, cents)
        }
        let loose = product["loose-price"]?.int.flatMap { $0 > 0 ? $0 : nil }
        guard loose != nil || !graded.isEmpty else { return nil }
        return GuideData(source: name, ungradedCents: loose, graded: graded)
    }
}

/// Sources that have no public API, or need an approved account — listed so it's clear they aren't used.
struct PlaceholderProvider: PricingProvider {
    let name: String
    let reason: String
    var status: ProviderStatus { .notAvailable(reason) }

    static let all: [PlaceholderProvider] = [
        PlaceholderProvider(name: "GoCollect", reason: "Has an API, but access must be requested and approved with a GoCollect account. Ready to plug in once approved."),
        PlaceholderProvider(name: "CovrPrice", reason: "API access is through partner deals and a paid Premium plan. Not connected."),
        PlaceholderProvider(name: "Key Collector Comics", reason: "No public API."),
        PlaceholderProvider(name: "ComicBookRealm", reason: "No public API."),
    ]
}

/// Gets a valuation for an edition: cache first, then eBay sold listings (+ PriceCharting if set up).
@MainActor
enum PricingService {
    private static var cache: [String: Valuation] = [:]
    private static let freshFor: TimeInterval = 6 * 3600

    static func cacheKey(_ spec: ComicSpec) -> String {
        "\(spec.editionKey)|signed:\(spec.signed)|\(spec.signerLastName ?? "")|\(spec.customQuery)"
    }

    static func cached(_ spec: ComicSpec) -> Valuation? { cache[cacheKey(spec)] }

    static func clearCache() { cache.removeAll() }

    static func valuation(for spec: ComicSpec, bot: WebBot, forceRefresh: Bool = false) async throws -> Valuation {
        let key = cacheKey(spec)
        if !forceRefresh, let hit = cache[key], Date().timeIntervalSince(hit.updatedAt) < freshFor { return hit }
        guard NetworkMonitor.shared.isOnline else {
            if let hit = cache[key] { return hit }
            throw ServiceError.offline
        }

        let options = Prefs.compOptions
        var sources: [SourceNote] = []

        // eBay: a wide search for this issue (prefetched while you confirmed the cover, if possible)…
        var listings: [SoldListing] = []
        if let prefetched = SoldCache.shared.results(for: spec), let pool = try? await prefetched.value {
            listings = pool
        } else {
            listings = try await EbaySoldSearch.soldListings(query: spec.broadQuery, bot: bot, comicsOnly: Prefs.searchComicsOnly)
        }
        // …plus a narrow one for variants, which get buried in popular issues.
        if let variantQuery = spec.variantQuery,
           let narrow = try? await EbaySoldSearch.soldListings(query: variantQuery, bot: bot, comicsOnly: Prefs.searchComicsOnly) {
            listings = merge(listings, narrow)
        }

        // Price guide, if a token is set.
        var guide: GuideData?
        let priceCharting = PriceChartingProvider()
        if priceCharting.status == .active {
            guide = try? await priceCharting.guide(for: spec)
        }

        var result = PricingEngine.valuation(spec: spec, listings: listings, guide: guide, sources: [], options: options)

        // No sales of this issue at all → look at the rest of the series for an estimate.
        if !result.hasAnyPrice, !spec.title.trimmed.isEmpty,
           let series = try? await EbaySoldSearch.soldListings(query: spec.seriesQuery, bot: bot, comicsOnly: Prefs.searchComicsOnly) {
            result = PricingEngine.valuation(spec: spec, listings: listings, seriesListings: series, guide: guide, sources: [], options: options)
        }

        let counted = result.sales.filter(\.counted).count
        sources.append(SourceNote(name: "eBay sold listings",
                                  detail: "\(counted) matching sales of \(listings.count) checked · completed sales only",
                                  used: counted > 0))
        if let guide {
            sources.append(SourceNote(name: guide.source, detail: "Price guide values (supporting)", used: true))
        }
        if result.marketBasis == .estimate {
            sources.append(SourceNote(name: "Estimate", detail: result.estimateNote ?? "Estimated from related sales", used: true))
        }
        result.sources = sources

        cache[key] = result
        return result
    }
}
