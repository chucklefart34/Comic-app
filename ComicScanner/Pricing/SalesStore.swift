import Foundation
import SwiftData

/// Saves and reads market data on the phone: completed sales, asking prices, price history, import log.
@MainActor
enum SalesStore {
    // MARK: Completed sales

    /// Adds newly seen sales for an edition, skipping ones already stored. Returns (new, duplicates).
    @discardableResult
    static func save(_ listings: [SoldListing], for spec: ComicSpec, context: ModelContext) -> (new: Int, duplicates: Int) {
        let editionKey = spec.editionKey
        let existing = Set(storedSales(for: spec, context: context).map(\.listingID))
        var added = 0
        var duplicates = 0
        var seenNow = Set<String>()
        for listing in listings {
            guard seenNow.insert(listing.id).inserted, !existing.contains(listing.id) else {
                duplicates += 1
                continue
            }
            context.insert(SaleRecord(listing: listing, editionKey: editionKey))
            added += 1
        }
        try? context.save()
        return (added, duplicates)
    }

    static func storedSales(for spec: ComicSpec, context: ModelContext) -> [SaleRecord] {
        let editionKey = spec.editionKey
        let descriptor = FetchDescriptor<SaleRecord>(predicate: #Predicate { $0.editionKey == editionKey },
                                                     sortBy: [SortDescriptor(\.soldDate, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Your approve/reject decisions for this edition, by listing ID.
    static func reviews(for spec: ComicSpec, context: ModelContext) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for record in storedSales(for: spec, context: context) {
            if let review = record.review { result[record.listingID] = review }
        }
        return result
    }

    /// Approve (true), reject (false) or reset (nil) a sale's match to this edition.
    static func setReview(_ review: Bool?, listing: SoldListing, spec: ComicSpec, context: ModelContext) {
        let key = SaleRecord.key(editionKey: spec.editionKey, listingID: listing.id)
        let descriptor = FetchDescriptor<SaleRecord>(predicate: #Predicate { $0.key == key })
        if let record = try? context.fetch(descriptor).first {
            record.review = review
        } else {
            let record = SaleRecord(listing: listing, editionKey: spec.editionKey)
            record.review = review
            context.insert(record)
        }
        try? context.save()
    }

    // MARK: Asking prices

    static func saveAsking(_ listings: [SoldListing], for spec: ComicSpec, context: ModelContext) {
        let editionKey = spec.editionKey
        let old = (try? context.fetch(FetchDescriptor<AskingRecord>(predicate: #Predicate { $0.editionKey == editionKey }))) ?? []
        old.forEach { context.delete($0) }  // asking prices are a snapshot, replaced each time
        for listing in PricingEngine.dedupe(listings) {
            context.insert(AskingRecord(listing: listing, editionKey: editionKey))
        }
        try? context.save()
    }

    static func asking(for spec: ComicSpec, context: ModelContext) -> [AskingRecord] {
        let editionKey = spec.editionKey
        let descriptor = FetchDescriptor<AskingRecord>(predicate: #Predicate { $0.editionKey == editionKey },
                                                       sortBy: [SortDescriptor(\.priceCents)])
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: History

    /// Records today's valuation (one snapshot per edition per day; later lookups that day replace it).
    static func snapshot(_ valuation: Valuation, spec: ComicSpec, context: ModelContext) {
        let day = Calendar.current.startOfDay(for: valuation.updatedAt)
        let key = "\(spec.editionKey)@\(Int(day.timeIntervalSince1970))"
        let descriptor = FetchDescriptor<PriceSnapshot>(predicate: #Predicate { $0.key == key })
        if let existing = try? context.fetch(descriptor).first {
            existing.apply(valuation, spec: spec)
        } else {
            context.insert(PriceSnapshot(spec: spec, valuation: valuation, day: day))
        }
        try? context.save()
    }

    static func history(for spec: ComicSpec, context: ModelContext) -> [PriceSnapshot] {
        let editionKey = spec.editionKey
        let descriptor = FetchDescriptor<PriceSnapshot>(predicate: #Predicate { $0.editionKey == editionKey },
                                                        sortBy: [SortDescriptor(\.day)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Latest stored valuation for an edition (works offline).
    static func latestValuation(for spec: ComicSpec, context: ModelContext) -> Valuation? {
        history(for: spec, context: context).last?.valuation
    }

    // MARK: Log

    static func log(spec: ComicSpec, diagnostics: EbayDiagnostics, new: Int, duplicates: Int, context: ModelContext) {
        context.insert(ImportLog(editionKey: spec.editionKey, title: spec.displayTitle, query: diagnostics.query,
                                 method: diagnostics.method, listingsRead: diagnostics.listingsRead,
                                 newSales: new, duplicates: duplicates, error: diagnostics.error))
        // Keep the log small.
        var descriptor = FetchDescriptor<ImportLog>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchOffset = 300
        if let old = try? context.fetch(descriptor) { old.forEach { context.delete($0) } }
        try? context.save()
    }
}
