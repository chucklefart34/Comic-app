import SwiftData
import XCTest
@testable import ComicScanner

@MainActor
final class StorageTests: XCTestCase {
    func testSalesImportSkipsDuplicates() throws {
        let context = try TestData.container().mainContext
        let spec = TestData.asm300
        let first = SalesStore.save(Array(TestData.asm300Market.prefix(5)), for: spec, context: context)
        XCTAssertEqual(first.new, 5)
        let second = SalesStore.save(TestData.asm300Market, for: spec, context: context)
        XCTAssertEqual(second.new, TestData.asm300Market.count - 5 - 1)  // last one is a duplicate within the batch
        XCTAssertEqual(SalesStore.storedSales(for: spec, context: context).count, 16)
    }

    func testReviewsAreSaved() throws {
        let context = try TestData.container().mainContext
        let listing = TestData.sale("77", "Amazing Spider-Man #300 Virgin", 100)
        SalesStore.setReview(true, listing: listing, spec: TestData.asm300, context: context)
        XCTAssertEqual(SalesStore.reviews(for: TestData.asm300, context: context)["77"], true)
        SalesStore.setReview(nil, listing: listing, spec: TestData.asm300, context: context)
        XCTAssertNil(SalesStore.reviews(for: TestData.asm300, context: context)["77"])
    }

    func testOneSnapshotPerDay() throws {
        let context = try TestData.container().mainContext
        var valuation = PricingEngine.valuation(spec: TestData.asm300, listings: TestData.asm300Market, sources: [], options: CompOptions())
        SalesStore.snapshot(valuation, spec: TestData.asm300, context: context)
        valuation.marketCents = 123
        SalesStore.snapshot(valuation, spec: TestData.asm300, context: context)
        let history = SalesStore.history(for: TestData.asm300, context: context)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.marketCents, 123)
        XCTAssertEqual(PricingAPI.trends(for: TestData.asm300, context: context).count, 1)
    }

    func testAskingPricesAreKeptApart() throws {
        let context = try TestData.container().mainContext
        SalesStore.saveAsking([TestData.sale("a1", "Amazing Spider-Man #300 NM", 999)], for: TestData.asm300, context: context)
        XCTAssertEqual(SalesStore.asking(for: TestData.asm300, context: context).count, 1)
        XCTAssertTrue(SalesStore.storedSales(for: TestData.asm300, context: context).isEmpty)
    }

    func testCollectionValueAndPerformance() throws {
        let context = try TestData.container().mainContext
        let valuation = PricingEngine.valuation(spec: TestData.asm300, listings: TestData.asm300Market, sources: [], options: CompOptions())
        let record = ComicRecord(spec: TestData.asm300, imageURL: nil, thumbnail: nil)
        record.inCollection = true
        record.purchaseCents = 50_000
        context.insert(record)
        record.setValuation(valuation)
        record.condition = .nearMint
        XCTAssertEqual(record.displayValueCents, valuation.band(.high).cents)

        let performance = PricingAPI.collectionPerformance(context: context)
        XCTAssertEqual(performance.paidCents, 50_000)
        XCTAssertEqual(performance.valueCents, record.displayValueCents)
        XCTAssertEqual(performance.profitCents, (record.displayValueCents ?? 0) - 50_000)
        XCTAssertEqual(PricingAPI.collectionValue(context: context), record.displayValueCents)

        // Updating the market value never touches the purchase price.
        record.setValuation(valuation)
        XCTAssertEqual(record.purchaseCents, 50_000)
    }

    func testPricingStatusAndSearch() throws {
        let context = try TestData.container().mainContext
        let valuation = PricingEngine.valuation(spec: TestData.asm300, listings: TestData.asm300Market, sources: [], options: CompOptions())
        SalesStore.snapshot(valuation, spec: TestData.asm300, context: context)
        SalesStore.save(TestData.asm300Market, for: TestData.asm300, context: context)
        XCTAssertEqual(PricingAPI.search("spider", context: context).count, 1)
        XCTAssertEqual(PricingAPI.search("#300", context: context).count, 1)
        XCTAssertTrue(PricingAPI.search("batman", context: context).isEmpty)
        let status = PricingAPI.pricingStatus(context: context)
        XCTAssertEqual(status.salesSaved, 16)
        XCTAssertEqual(status.editionsPriced, 1)
        XCTAssertNotNil(PricingAPI.comic(editionKey: TestData.asm300.editionKey, context: context))
    }
}
