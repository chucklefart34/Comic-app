import Foundation
import SwiftData

/// A scanned comic. Every scan lands in History; saving it puts it in your Collection.
@Model
final class ComicRecord {
    var ref: UUID
    var specData: Data
    var title: String
    var issue: String
    var publisher: String
    var year: String
    var editionLine: String
    var imageURL: String?
    /// Your own photo of the cover (small JPEG).
    var thumbnail: Data?
    var conditionRaw: String?
    var purchaseCents: Int?
    /// A price you typed in yourself; overrides the market value.
    var manualValueCents: Int?
    var valuationData: Data?
    var valueCents: Int?
    var confidenceRaw: String?
    var scannedAt: Date
    var pricedAt: Date?
    var inCollection: Bool
    var notes: String

    init(spec: ComicSpec, imageURL: String?, thumbnail: Data?) {
        self.ref = UUID()
        self.specData = (try? JSONEncoder().encode(spec)) ?? Data()
        self.title = spec.title
        self.issue = spec.issue
        self.publisher = spec.publisher
        self.year = spec.year
        self.editionLine = spec.detailLine
        self.imageURL = imageURL
        self.thumbnail = thumbnail
        self.scannedAt = .now
        self.inCollection = false
        self.notes = ""
    }

    var spec: ComicSpec {
        (try? JSONDecoder().decode(ComicSpec.self, from: specData)) ?? ComicSpec()
    }

    func update(spec: ComicSpec) {
        specData = (try? JSONEncoder().encode(spec)) ?? specData
        title = spec.title
        issue = spec.issue
        publisher = spec.publisher
        year = spec.year
        editionLine = spec.detailLine
        if !spec.coverImageURL.isEmpty { imageURL = spec.coverImageURL }
        refreshValue()
    }

    var condition: Condition? {
        get { conditionRaw.flatMap(Condition.init(rawValue:)) }
        set {
            conditionRaw = newValue?.rawValue
            refreshValue()
        }
    }

    var valuation: Valuation? {
        valuationData.flatMap { try? JSONDecoder().decode(Valuation.self, from: $0) }
    }

    func setValuation(_ valuation: Valuation) {
        valuationData = try? JSONEncoder().encode(valuation)
        confidenceRaw = valuation.confidence.rawValue
        pricedAt = valuation.updatedAt
        refreshValue()
    }

    /// Value used for totals and sorting: your own price, or the market value for your condition.
    var displayValueCents: Int? { manualValueCents ?? valueCents }

    var confidence: Confidence? { confidenceRaw.flatMap(Confidence.init(rawValue:)) }

    var displayTitle: String { issue.isEmpty ? title : "\(title) #\(issue)" }

    func refreshValue() {
        valueCents = valuation?.value(for: condition, spec: spec).cents
    }
}

/// Barcodes you've confirmed, so the same barcode is identified instantly next time.
@Model
final class BarcodeMemory {
    var code: String
    var specData: Data
    var imageURL: String?
    var savedAt: Date

    init(code: String, spec: ComicSpec, imageURL: String?) {
        self.code = code
        self.specData = (try? JSONEncoder().encode(spec)) ?? Data()
        self.imageURL = imageURL
        self.savedAt = .now
    }

    var spec: ComicSpec {
        (try? JSONDecoder().decode(ComicSpec.self, from: specData)) ?? ComicSpec()
    }
}
