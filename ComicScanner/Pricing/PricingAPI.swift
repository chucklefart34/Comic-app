import Foundation
import SwiftData

/// The app's internal pricing API. There's no server (everything lives on the phone), so these are
/// Swift functions that play the role of the endpoints in the spec:
///
/// | Spec endpoint                     | Function                         |
/// |-----------------------------------|----------------------------------|
/// | GET /api/comics/search            | `search(_:context:)`             |
/// | GET /api/comics/{id}              | `comic(editionKey:context:)`     |
/// | GET /api/comics/{id}/prices       | `prices(for:bot:context:)`       |
/// | GET /api/comics/{id}/sales        | `sales(for:context:)`            |
/// | GET /api/comics/{id}/trends       | `trends(for:context:)`           |
/// | GET /api/comics/{id}/grades       | `grades(for:context:)`           |
/// | GET /api/collection/value         | `collectionValue(context:)`      |
/// | GET /api/collection/performance   | `collectionPerformance(context:)`|
/// | GET /api/pricing/status           | `pricingStatus(context:)`        |
@MainActor
enum PricingAPI {
    /// Editions priced before, matching title / issue / publisher / variant text.
    static func search(_ text: String, context: ModelContext) -> [ComicSpec] {
        let snapshots = (try? context.fetch(FetchDescriptor<PriceSnapshot>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        var seen = Set<String>()
        let needle = text.trimmed.lowercased()
        return snapshots.filter { seen.insert($0.editionKey).inserted }.map(\.spec).filter { spec in
            needle.isEmpty || "\(spec.title) \(spec.issue) #\(spec.issue) \(spec.publisher) \(spec.variant) \(spec.exclusive)".lowercased().contains(needle)
        }
    }

    /// The edition and its latest stored valuation.
    static func comic(editionKey: String, context: ModelContext) -> (spec: ComicSpec, valuation: Valuation?)? {
        let descriptor = FetchDescriptor<PriceSnapshot>(predicate: #Predicate { $0.editionKey == editionKey },
                                                        sortBy: [SortDescriptor(\.day, order: .reverse)])
        guard let latest = try? context.fetch(descriptor).first else { return nil }
        return (latest.spec, latest.valuation)
    }

    /// Current prices (looks up eBay if the stored value is stale).
    static func prices(for spec: ComicSpec, bot: WebBot, context: ModelContext) async throws -> Valuation {
        if let latest = SalesStore.latestValuation(for: spec, context: context),
           Date().timeIntervalSince(latest.updatedAt) < PricingService.staleAfter {
            return latest
        }
        return try await PricingService.valuation(for: spec, bot: bot, context: context)
    }

    /// Stored completed sales of the edition, newest first.
    static func sales(for spec: ComicSpec, context: ModelContext) -> [SaleRecord] {
        SalesStore.storedSales(for: spec, context: context)
    }

    /// Daily valuation history, oldest first.
    static func trends(for spec: ComicSpec, context: ModelContext) -> [PriceSnapshot] {
        SalesStore.history(for: spec, context: context)
    }

    /// Slab prices by company, label and grade from the latest valuation.
    static func grades(for spec: ComicSpec, context: ModelContext) -> [GradedPrice] {
        SalesStore.latestValuation(for: spec, context: context)?.graded ?? []
    }

    static func collectionValue(context: ModelContext) -> Int {
        collection(context).compactMap(\.displayValueCents).reduce(0, +)
    }

    struct Performance: Equatable {
        var paidCents: Int
        var valueCents: Int
        var profitCents: Int
        var percent: Double?
        var comicsTracked: Int
    }

    /// Profit/loss across comics with both a purchase price and a value.
    static func collectionPerformance(context: ModelContext) -> Performance {
        let tracked = collection(context).filter { $0.purchaseCents != nil && $0.displayValueCents != nil }
        let paid = tracked.compactMap(\.purchaseCents).reduce(0, +)
        let value = tracked.compactMap(\.displayValueCents).reduce(0, +)
        return Performance(paidCents: paid, valueCents: value, profitCents: value - paid,
                           percent: paid > 0 ? Double(value - paid) / Double(paid) * 100 : nil,
                           comicsTracked: tracked.count)
    }

    struct Status: Equatable {
        var salesSaved: Int
        var editionsPriced: Int
        var lastLookup: Date?
        var recentFailures: Int
        var staleComics: Int
    }

    static func pricingStatus(context: ModelContext) -> Status {
        let logs = (try? context.fetch(FetchDescriptor<ImportLog>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
        let snapshots = (try? context.fetch(FetchDescriptor<PriceSnapshot>())) ?? []
        return Status(salesSaved: (try? context.fetchCount(FetchDescriptor<SaleRecord>())) ?? 0,
                      editionsPriced: Set(snapshots.map(\.editionKey)).count,
                      lastLookup: logs.first?.date,
                      recentFailures: logs.prefix(50).filter { $0.error != nil }.count,
                      staleComics: collection(context).filter(\.isStale).count)
    }

    private static func collection(_ context: ModelContext) -> [ComicRecord] {
        (try? context.fetch(FetchDescriptor<ComicRecord>(predicate: #Predicate { $0.inCollection }))) ?? []
    }
}
