import XCTest
@testable import ComicScanner

final class PricingTests: XCTestCase {
    private let options = CompOptions(includeShipping: false, includeBestOffer: false)

    private func value(_ spec: ComicSpec, _ listings: [SoldListing] = TestData.asm300Market) -> Valuation {
        PricingEngine.valuation(spec: spec, listings: listings, sources: [], options: options, now: TestData.now)
    }

    /// The spec's own example: CGC 9.8 must not be mixed with 9.6, CBCS 9.8, raw, 2nd printing or signed.
    func testCGC98IsNeverMixedWithOtherCopies() {
        let valuation = value(TestData.asm300CGC98)
        let cgc98 = valuation.graded.first { $0.company == .cgc && $0.slabLabel == .universal && $0.grade == 9.8 }
        XCTAssertEqual(cgc98?.count, 3)
        XCTAssertEqual(valuation.medianCents, 400_000)
        XCTAssertEqual(valuation.lowCents, 390_000)
        XCTAssertEqual(valuation.highCents, 420_000)
        XCTAssertEqual(valuation.graded.first { $0.company == .cbcs && $0.grade == 9.8 }?.count, 1)
        XCTAssertEqual(valuation.graded.first { $0.company == .cgc && $0.grade == 9.6 }?.count, 2)
        XCTAssertEqual(valuation.graded.first { $0.slabLabel == .signatureSeries }?.count, 1)
        XCTAssertEqual(valuation.graded.first { $0.slabLabel == .qualified }?.count, 1)
        XCTAssertEqual(valuation.value(for: .graded, spec: TestData.asm300CGC98).cents, valuation.marketCents)
    }

    func testRawValueUsesOnlyUnsignedRawSales() {
        let valuation = value(TestData.asm300)
        XCTAssertEqual(valuation.rawSaleCount, 3)  // 9.4, 8.0, 4.0 — not the signed copy, 2nd print, facsimile or lot
        XCTAssertEqual(valuation.headlineGroup, "Raw")
        XCTAssertEqual(valuation.band(.high).cents, 90_000)
        XCTAssertEqual(valuation.band(.mid).cents, 45_000)
        XCTAssertEqual(valuation.band(.low).cents, 18_000)
        XCTAssertEqual(valuation.band(.high).basis, .sales)
    }

    func testSignedRawIsItsOwnGroup() {
        var signed = TestData.asm300
        signed.signed = true
        let valuation = value(signed)
        XCTAssertEqual(valuation.headlineGroup, "Raw · signed")
        XCTAssertEqual(valuation.rawSaleCount, 1)
        XCTAssertEqual(valuation.marketCents, 140_000)
    }

    func testDuplicatesCountOnce() {
        let valuation = value(TestData.asm300CGC98)
        XCTAssertEqual(valuation.sales.filter { $0.id == "100000000001" }.count, 1)
    }

    func testMedianAndPercentiles() {
        XCTAssertEqual(CompMatcher.percentile([100, 200, 300], 0.5), 200)
        XCTAssertEqual(CompMatcher.percentile([100, 200, 300, 400], 0.5), 250)
        XCTAssertEqual(PricingEngine.weightedMedian([(cents: 100, date: TestData.now), (cents: 200, date: TestData.now), (cents: 900, date: TestData.now)],
                                                    now: TestData.now), 200)
    }

    func testRecentSalesWeighMore() {
        let old = (1...4).map { TestData.sale("o\($0)", "Amazing Spider-Man #300 NM", 100, daysAgo: 300) }
        let recent = (1...3).map { TestData.sale("r\($0)", "Amazing Spider-Man #300 NM", 200, daysAgo: 1) }
        XCTAssertEqual(value(TestData.asm300, old + recent).marketCents, 20_000)
    }

    func testOutlierIsLeftOut() {
        var listings = (1...6).map { TestData.sale("n\($0)", "Amazing Spider-Man #300 NM 9.4", Double(90 + $0), daysAgo: Double($0)) }
        listings.append(TestData.sale("x", "Amazing Spider-Man #300 NM 9.4", 2500, daysAgo: 2))
        let valuation = value(TestData.asm300, listings)
        XCTAssertEqual(valuation.sales.first { $0.id == "x" }?.excludedReason, "Price far from similar sales")
        XCTAssertLessThan(valuation.highCents ?? 0, 20_000)
    }

    func testTimeWindowsAndTrend() {
        let listings = [
            TestData.sale("a", "Amazing Spider-Man #300 NM", 200, daysAgo: 5),
            TestData.sale("b", "Amazing Spider-Man #300 NM", 220, daysAgo: 20),
            TestData.sale("c", "Amazing Spider-Man #300 NM", 100, daysAgo: 60),
            TestData.sale("d", "Amazing Spider-Man #300 NM", 110, daysAgo: 80),
            TestData.sale("e", "Amazing Spider-Man #300 NM", 105, daysAgo: 200),
        ]
        let valuation = value(TestData.asm300, listings)
        let windows = Dictionary(uniqueKeysWithValues: (valuation.windows ?? []).map { ($0.days, $0) })
        XCTAssertEqual(windows[30]?.count, 2)
        XCTAssertEqual(windows[90]?.count, 4)
        XCTAssertEqual(windows[365]?.count, 5)
        XCTAssertEqual(windows[30]?.medianCents, 21_000)
        XCTAssertNotNil(valuation.trendPercent)
        XCTAssertGreaterThan(valuation.trendPercent ?? 0, 50)
    }

    func testShippingAndBestOffer() {
        let listings = [
            TestData.sale("s", "Amazing Spider-Man #300 NM", 100, shipping: 10),
            TestData.sale("b", "Amazing Spider-Man #300 NM", 50, bestOffer: true),
        ]
        let withShipping = PricingEngine.valuation(spec: TestData.asm300, listings: listings, sources: [],
                                                   options: CompOptions(includeShipping: true, includeBestOffer: false), now: TestData.now)
        XCTAssertEqual(withShipping.marketCents, 11_000)
        XCTAssertEqual(withShipping.sales.first { $0.id == "b" }?.excludedReason, "Best Offer — real price hidden")
    }

    func testNoSalesMeansNoMarketValue() {
        let valuation = value(TestData.asm300, [TestData.sale("z", "Batman #423", 50)])
        XCTAssertNil(valuation.marketCents)
        XCTAssertEqual(valuation.confidence, .none)
        XCTAssertFalse(valuation.hasAnyPrice)
    }

    func testEstimatesAreLabelled() {
        // Only an unstated-grade raw sale: bands must be estimates, never "Sold".
        let valuation = value(TestData.asm300, [TestData.sale("u", "Amazing Spider-Man #300 Marvel 1988", 300),
                                                TestData.sale("v", "Amazing Spider-Man #300", 320)])
        for band in PriceBand.allCases {
            XCTAssertEqual(valuation.band(band).basis, .estimate)
        }
        XCTAssertEqual(valuation.marketBasis, .sales)
    }

    func testListingParsing() throws {
        let card = EbaySoldSearch.RawCard(title: "Amazing Spider-Man #300 9.4", url: "https://www.ebay.com/itm/123456789012?hash=x",
                                          price: "$1,250.00", text: "Sold  Nov 20, 2026 Amazing Spider-Man #300 $1,250.00 +$15.00 delivery",
                                          image: "", strike: false)
        let listing = try XCTUnwrap(EbaySoldSearch.listing(from: card))
        XCTAssertEqual(listing.id, "123456789012")
        XCTAssertEqual(listing.priceCents, 125_000)
        XCTAssertEqual(listing.shippingCents, 1_500)
        XCTAssertNotNil(listing.soldDate)
        XCTAssertFalse(listing.bestOffer)

        let range = EbaySoldSearch.RawCard(title: "x", url: "u", price: "$10.00 to $20.00", text: "", image: "", strike: false)
        XCTAssertNil(EbaySoldSearch.listing(from: range))
        let foreign = EbaySoldSearch.RawCard(title: "x", url: "u", price: "C $40.00", text: "", image: "", strike: false)
        XCTAssertNil(EbaySoldSearch.listing(from: foreign))
    }
}
