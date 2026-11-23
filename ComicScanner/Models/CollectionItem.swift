import Foundation
import SwiftData

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

    init(spec: ComicSpec, stats: PriceStats?, imageURL: String?) {
        self.specData = (try? JSONEncoder().encode(spec)) ?? Data()
        self.title = spec.displayTitle
        self.details = spec.detailLine
        self.valueCents = stats?.medianCents
        self.lowCents = stats?.lowerQuartileCents
        self.highCents = stats?.upperQuartileCents
        self.compCount = stats?.count ?? 0
        self.imageURL = imageURL
        self.addedAt = .now
        self.pricedAt = stats == nil ? nil : .now
    }

    var spec: ComicSpec {
        (try? JSONDecoder().decode(ComicSpec.self, from: specData)) ?? ComicSpec()
    }

    func update(spec: ComicSpec) {
        specData = (try? JSONEncoder().encode(spec)) ?? specData
        title = spec.displayTitle
        details = spec.detailLine
    }

    func apply(_ stats: PriceStats?) {
        valueCents = stats?.medianCents
        lowCents = stats?.lowerQuartileCents
        highCents = stats?.upperQuartileCents
        compCount = stats?.count ?? 0
        pricedAt = .now
    }
}
