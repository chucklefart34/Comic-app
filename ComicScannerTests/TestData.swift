import Foundation
import SwiftData
@testable import ComicScanner

/// Sample data only — no network.
enum TestData {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func sale(_ id: String, _ title: String, _ dollars: Double, daysAgo: Double = 5,
                     shipping: Double? = nil, bestOffer: Bool = false) -> SoldListing {
        SoldListing(id: id, title: title, priceCents: Int(dollars * 100),
                    shippingCents: shipping.map { Int($0 * 100) },
                    soldDate: now.addingTimeInterval(-daysAgo * 86_400),
                    url: URL(string: "https://www.ebay.com/itm/\(id)"), imageURL: nil, bestOffer: bestOffer)
    }

    static var asm300: ComicSpec {
        var spec = ComicSpec()
        spec.title = "Amazing Spider-Man"
        spec.issue = "300"
        spec.publisher = "Marvel"
        spec.year = "1988"
        return spec
    }

    static var asm300CGC98: ComicSpec {
        var spec = asm300
        spec.graded = true
        spec.company = .cgc
        spec.grade = 9.8
        return spec
    }

    /// A realistic mix: the target slab, the copies it must not be confused with, and noise.
    static var asm300Market: [SoldListing] {
        [
            sale("100000000001", "Amazing Spider-Man #300 CGC 9.8 White Pages 1st Venom", 4000, daysAgo: 3),
            sale("100000000002", "Amazing Spider-Man 300 CGC 9.8 1988 Marvel", 4200, daysAgo: 10),
            sale("100000000003", "Amazing Spider-Man #300 CGC 9.8 McFarlane", 3900, daysAgo: 20),
            sale("100000000004", "Amazing Spider-Man #300 CGC 9.6 White Pages", 1600, daysAgo: 4),
            sale("100000000005", "Amazing Spider-Man #300 CGC 9.6", 1500, daysAgo: 12),
            sale("100000000006", "Amazing Spider-Man #300 CBCS 9.8 White Pages", 3300, daysAgo: 6),
            sale("100000000007", "Amazing Spider-Man #300 CGC SS 9.8 Signed Todd McFarlane", 6500, daysAgo: 8),
            sale("100000000008", "Amazing Spider-Man #300 CGC 9.8 Qualified Green Label", 1800, daysAgo: 9),
            sale("100000000009", "Amazing Spider-Man #300 NM 9.4 raw 1st Venom", 900, daysAgo: 2),
            sale("100000000010", "Amazing Spider-Man #300 VF 8.0", 450, daysAgo: 15),
            sale("100000000011", "Amazing Spider-Man #300 VG 4.0 reader", 180, daysAgo: 25),
            sale("100000000012", "Amazing Spider-Man #300 2nd Printing NM", 60, daysAgo: 5),
            sale("100000000013", "Amazing Spider-Man #300 Facsimile Edition", 8, daysAgo: 5),
            sale("100000000014", "Amazing Spider-Man 298 299 300 lot", 1200, daysAgo: 5),
            sale("100000000015", "Amazing Spider-Man #3000 Variant", 20, daysAgo: 5),
            sale("100000000016", "Amazing Spider-Man #300 Signed Todd McFarlane raw VF/NM", 1400, daysAgo: 7),
            sale("100000000001", "Amazing Spider-Man #300 CGC 9.8 White Pages 1st Venom", 4000, daysAgo: 3), // duplicate
        ]
    }

    @MainActor
    static func container() throws -> ModelContainer {
        try ModelContainer(for: ComicRecord.self, CoverPrint.self, BarcodeMemory.self,
                           SaleRecord.self, AskingRecord.self, PriceSnapshot.self, ImportLog.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
}
