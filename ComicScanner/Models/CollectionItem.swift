import Foundation
import SwiftData

enum ItemStatus: String, Codable, CaseIterable, Identifiable {
    case collection = "Keeping"
    case forSale = "For sale"
    case sold = "Sold"

    var id: String { rawValue }
}

/// One comic you own (or owned): market value, what you paid, your asking price, where it's stored.
@Model
final class CollectionItem {
    var specData: Data
    var title: String
    var details: String
    var valueCents: Int?
    var lowCents: Int?
    var highCents: Int?
    var compCount: Int
    var imageURL: String?
    var addedAt: Date
    var pricedAt: Date?

    // Inventory (added in 1.1 — all optional so existing collections carry over).
    var ref: UUID?
    var costCents: Int?
    var askingCents: Int?
    var box: String?
    var statusRaw: String?
    var soldCents: Int?
    var soldAt: Date?

    init(spec: ComicSpec, stats: PriceStats?, imageURL: String?) {
        self.specData = (try? JSONEncoder().encode(spec)) ?? Data()
        self.title = spec.displayTitle
        self.details = spec.detailLine
        self.valueCents = stats?.averageCents
        self.lowCents = stats?.lowerQuartileCents
        self.highCents = stats?.upperQuartileCents
        self.compCount = stats?.count ?? 0
        self.imageURL = imageURL
        self.addedAt = .now
        self.pricedAt = stats == nil ? nil : .now
        self.ref = UUID()
        self.statusRaw = ItemStatus.collection.rawValue
    }

    var spec: ComicSpec {
        (try? JSONDecoder().decode(ComicSpec.self, from: specData)) ?? ComicSpec()
    }

    /// Stable id used by deals to point at this book.
    var stableRef: UUID {
        if let ref { return ref }
        let new = UUID()
        ref = new
        return new
    }

    var status: ItemStatus {
        get { statusRaw.flatMap(ItemStatus.init(rawValue:)) ?? .collection }
        set { statusRaw = newValue.rawValue }
    }

    var boxName: String {
        get { box ?? "" }
        set { box = newValue.trimmed.isEmpty ? nil : newValue.trimmed }
    }

    /// Asking price if you set one, otherwise market value.
    var sellPriceCents: Int? { askingCents ?? valueCents }

    func update(spec: ComicSpec) {
        specData = (try? JSONEncoder().encode(spec)) ?? specData
        title = spec.displayTitle
        details = spec.detailLine
    }

    func apply(_ stats: PriceStats?) {
        valueCents = stats?.averageCents
        lowCents = stats?.lowerQuartileCents
        highCents = stats?.upperQuartileCents
        compCount = stats?.count ?? 0
        pricedAt = .now
    }
}
