import Foundation
import SwiftData

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

    /// Keeps a locally recalculated valuation (e.g. after you approve or reject a sale).
    static func remember(_ valuation: Valuation, for spec: ComicSpec) { cache[cacheKey(spec)] = valuation }

    private static func narrowListings(for spec: ComicSpec, bot: WebBot) async -> [SoldListing] {
        guard let variantQuery = spec.variantQuery else { return [] }
        return (try? await EbaySoldSearch.soldListings(query: variantQuery, bot: bot, comicsOnly: Prefs.searchComicsOnly)) ?? []
    }

    private static func guideData(for spec: ComicSpec) async -> GuideData? {
        let priceCharting = PriceChartingProvider()
        guard priceCharting.status == .active else { return nil }
        return try? await priceCharting.guide(for: spec)
    }

    /// Values an edition. With a `context`, every matching sale is stored (so history builds up past eBay's ~90 days),
    /// your approve/reject decisions are applied, the lookup is logged, and the day's value is saved for trends.
    static func valuation(for spec: ComicSpec, bot: WebBot, context: ModelContext? = nil, forceRefresh: Bool = false) async throws -> Valuation {
        let key = cacheKey(spec)
        if !forceRefresh, let hit = cache[key], Date().timeIntervalSince(hit.updatedAt) < freshFor { return hit }
        let options = Prefs.compOptions
        let reviews = context.map { SalesStore.reviews(for: spec, context: $0) } ?? [:]
        let stored = context.map { SalesStore.storedSales(for: spec, context: $0).map(\.listing) } ?? []

        guard NetworkMonitor.shared.isOnline else {
            if let hit = cache[key] { return hit }
            if !stored.isEmpty {
                // Offline: value from sales saved earlier.
                var offline = PricingEngine.valuation(spec: spec, listings: stored, sources: [], options: options, reviews: reviews)
                offline.sources = [SourceNote(name: "Saved sales", detail: "Offline — \(stored.count) sales saved on this phone", used: true)]
                return offline
            }
            throw ServiceError.offline
        }

        var sources: [SourceNote] = []

        // eBay: a wide search for this issue (prefetched while you confirmed the cover, if possible),
        // plus a narrow one for variants (which get buried in popular issues), at the same time.
        async let narrowSearch = narrowListings(for: spec, bot: bot)
        async let guideLookup = guideData(for: spec)

        var fetched: [SoldListing] = []
        var wideError: Error?
        if !forceRefresh, let prefetched = SoldCache.shared.results(for: spec), let pool = try? await prefetched.value {
            fetched = pool
        } else {
            do {
                fetched = try await EbaySoldSearch.soldListings(query: spec.broadQuery, bot: bot, comicsOnly: Prefs.searchComicsOnly)
            } catch {
                wideError = error
            }
        }
        let wideDiagnostics = EbayPages.last
        fetched = merge(fetched, await narrowSearch)
        let guide = await guideLookup

        // Store the sales that are this edition (any condition), and log the import.
        if let context {
            let sameEdition = SaleClassifier.classify(fetched, spec: spec, options: CompOptions(includeShipping: true, includeBestOffer: true))
                .filter { $0.excludedReason == nil }.map(\.listing)
            let saved = SalesStore.save(sameEdition, for: spec, context: context)
            var diagnostics = wideDiagnostics
            diagnostics.listingsRead = fetched.count
            if let wideError, fetched.isEmpty { diagnostics.error = wideError.localizedDescription }
            SalesStore.log(spec: spec, diagnostics: diagnostics, new: saved.new, duplicates: saved.duplicates, context: context)
        }

        let listings = merge(fetched, stored)
        if listings.isEmpty, guide == nil, let wideError { throw wideError }

        var result = PricingEngine.valuation(spec: spec, listings: listings, guide: guide, sources: [], options: options, reviews: reviews)

        // Nothing mentions this exact cover → use every cover of the issue, labelled as an estimate.
        if !result.hasAnyPrice, !listings.isEmpty, !(spec.variant.isEmpty && spec.exclusive.isEmpty) {
            let relaxed = PricingEngine.valuation(spec: spec, listings: listings, guide: guide, sources: [], options: options,
                                                  ignoreCover: true, reviews: reviews)
            if relaxed.hasAnyPrice { result = relaxed }
        }

        // No sales of this issue at all → look at the rest of the series for an estimate.
        if !result.hasAnyPrice, !spec.title.trimmed.isEmpty,
           let series = try? await EbaySoldSearch.soldListings(query: spec.seriesQuery, bot: bot, comicsOnly: Prefs.searchComicsOnly) {
            result = PricingEngine.valuation(spec: spec, listings: listings, seriesListings: series, guide: guide, sources: [],
                                             options: options, reviews: reviews)
        }

        let counted = result.sales.filter(\.counted).count
        sources.append(SourceNote(name: "eBay sold listings",
                                  detail: listings.isEmpty
                                      ? "No sold listings found for \"\(spec.broadQuery)\""
                                      : "\(counted) matching sales of \(listings.count) checked · completed sales only · USD",
                                  used: counted > 0))
        if !stored.isEmpty {
            sources.append(SourceNote(name: "Saved sales", detail: "\(stored.count) sales of this edition saved on this phone from earlier lookups", used: true))
        }
        if let guide {
            sources.append(SourceNote(name: guide.source, detail: "Price guide values (supporting)", used: true))
        }
        if result.marketBasis == .estimate {
            sources.append(SourceNote(name: "Estimate", detail: result.estimateNote ?? "Estimated from related sales", used: true))
        }
        result.sources = sources

        cache[key] = result
        if let context { SalesStore.snapshot(result, spec: spec, context: context) }
        return result
    }

    /// Valuations older than this are flagged as stale and refreshed when opened.
    static let staleAfter: TimeInterval = 7 * 86_400
}
