import Foundation
import SwiftData

/// A cover the app has learned: a visual fingerprint of one photo, plus the exact book it shows.
@Model
final class CoverPrint {
    var ref: UUID
    /// Identifies the book (title + details), so several photos can point at the same book.
    var bookKey: String
    var specData: Data
    var title: String
    var details: String
    var imageURL: String?
    /// Small JPEG for showing matches without the network.
    var thumbnail: Data?
    /// Archived VNFeaturePrintObservation.
    var printData: Data
    var source: String
    var addedAt: Date

    init(spec: ComicSpec, imageURL: String?, thumbnail: Data?, printData: Data, source: String) {
        self.ref = UUID()
        self.bookKey = CoverPrint.key(for: spec)
        self.specData = (try? JSONEncoder().encode(spec)) ?? Data()
        self.title = spec.displayTitle
        self.details = spec.detailLine
        self.imageURL = imageURL
        self.thumbnail = thumbnail
        self.printData = printData
        self.source = source
        self.addedAt = .now
    }

    var spec: ComicSpec {
        (try? JSONDecoder().decode(ComicSpec.self, from: specData)) ?? ComicSpec()
    }

    func update(spec: ComicSpec) {
        bookKey = CoverPrint.key(for: spec)
        specData = (try? JSONEncoder().encode(spec)) ?? specData
        title = spec.displayTitle
        details = spec.detailLine
    }

    /// The cover itself doesn't change with grade or signature, so those aren't part of the key.
    static func key(for spec: ComicSpec) -> String {
        [spec.title, spec.issue, spec.variant, spec.exclusive, String(spec.printing)]
            .map { $0.trimmed.lowercased() }
            .joined(separator: "|")
    }
}
