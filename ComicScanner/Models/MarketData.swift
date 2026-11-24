import Foundation
import SwiftData

/// A completed eBay sale, stored once per edition (unique by edition + eBay listing ID).
/// Kept even after it drops off eBay's sold search, so price history grows past eBay's ~90 days.
@Model
final class SaleRecord {
    @Attribute(.unique) var key: String
    var editionKey: String
    var listingID: String
    var title: String
    var priceCents: Int
    var shippingCents: Int?
    var currency: String
    var soldDate: Date?
    var url: String?
    var imageURL: String?
    var bestOffer: Bool
    var marketplace: String
    var firstSeen: Date
    /// Your decision on this match: true = approved, false = rejected, nil = automatic.
    var review: Bool?

    init(listing: SoldListing, editionKey: String) {
        self.key = SaleRecord.key(editionKey: editionKey, listingID: listing.id)
        self.editionKey = editionKey
        self.listingID = listing.id
        self.title = listing.title
        self.priceCents = listing.priceCents
        self.shippingCents = listing.shippingCents
        self.currency = "USD"
        self.soldDate = listing.soldDate
        self.url = listing.url?.absoluteString
        self.imageURL = listing.imageURL?.absoluteString
        self.bestOffer = listing.bestOffer
        self.marketplace = "eBay US"
        self.firstSeen = .now
    }

    static func key(editionKey: String, listingID: String) -> String { "\(editionKey)#\(listingID)" }

    var totalCents: Int { priceCents + (shippingCents ?? 0) }

    var listing: SoldListing {
        SoldListing(id: listingID, title: title, priceCents: priceCents, shippingCents: shippingCents, soldDate: soldDate,
                    url: url.flatMap { URL(string: $0) }, imageURL: imageURL.flatMap { URL(string: $0) }, bestOffer: bestOffer)
    }
}

/// A current (unsold) listing — an asking price, never treated as a sale.
@Model
final class AskingRecord {
    @Attribute(.unique) var key: String
    var editionKey: String
    var listingID: String
    var title: String
    var priceCents: Int
    var shippingCents: Int?
    var url: String?
    var imageURL: String?
    var seenAt: Date

    init(listing: SoldListing, editionKey: String) {
        self.key = SaleRecord.key(editionKey: editionKey, listingID: listing.id)
        self.editionKey = editionKey
        self.listingID = listing.id
        self.title = listing.title
        self.priceCents = listing.priceCents
        self.shippingCents = listing.shippingCents
        self.url = listing.url?.absoluteString
        self.imageURL = listing.imageURL?.absoluteString
        self.seenAt = .now
    }
}

/// The valuation of an edition on a given day — the history behind trend charts.
@Model
final class PriceSnapshot {
    @Attribute(.unique) var key: String
    var editionKey: String
    var day: Date
    var specData: Data
    var title: String
    var marketCents: Int?
    var medianCents: Int?
    var saleCount: Int
    var confidenceRaw: String
    var valuationData: Data?
    var updatedAt: Date

    init(spec: ComicSpec, valuation: Valuation, day: Date) {
        self.key = "\(spec.editionKey)@\(Int(day.timeIntervalSince1970))"
        self.editionKey = spec.editionKey
        self.day = day
        self.specData = (try? JSONEncoder().encode(spec)) ?? Data()
        self.title = spec.displayTitle
        self.saleCount = 0
        self.confidenceRaw = valuation.confidence.rawValue
        self.updatedAt = .now
        apply(valuation, spec: spec)
    }

    func apply(_ valuation: Valuation, spec: ComicSpec) {
        specData = (try? JSONEncoder().encode(spec)) ?? specData
        title = spec.displayTitle
        marketCents = valuation.marketCents
        medianCents = valuation.medianCents
        saleCount = valuation.sales.filter(\.counted).count
        confidenceRaw = valuation.confidence.rawValue
        valuationData = try? JSONEncoder().encode(valuation)
        updatedAt = .now
    }

    var spec: ComicSpec { (try? JSONDecoder().decode(ComicSpec.self, from: specData)) ?? ComicSpec() }
    var valuation: Valuation? { valuationData.flatMap { try? JSONDecoder().decode(Valuation.self, from: $0) } }
}

/// One price lookup: what was searched, how many sales came back, how many were new or duplicates, errors.
@Model
final class ImportLog {
    var date: Date
    var editionKey: String
    var title: String
    var query: String
    var method: String
    var listingsRead: Int
    var newSales: Int
    var duplicates: Int
    var error: String?

    init(editionKey: String, title: String, query: String, method: String, listingsRead: Int, newSales: Int, duplicates: Int, error: String?) {
        self.date = .now
        self.editionKey = editionKey
        self.title = title
        self.query = query
        self.method = method
        self.listingsRead = listingsRead
        self.newSales = newSales
        self.duplicates = duplicates
        self.error = error
    }
}
