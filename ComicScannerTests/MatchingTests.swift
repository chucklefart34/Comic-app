import XCTest
@testable import ComicScanner

final class MatchingTests: XCTestCase {
    private func classify(_ title: String, spec: ComicSpec = TestData.asm300) -> ClassifiedSale {
        SaleClassifier.classify([TestData.sale("1", title, 100)], spec: spec, options: CompOptions())[0]
    }

    // Grade matching
    func testSlabCompanyAndGrade() {
        let sale = classify("Amazing Spider-Man #300 CGC 9.8 White Pages")
        XCTAssertEqual(sale.kind, .graded(company: .cgc, grade: 9.8))
        XCTAssertEqual(sale.group, .slab(.cgc, .universal))
        XCTAssertEqual(classify("ASM 300 9.6 CBCS").kind, .graded(company: .cbcs, grade: 9.6))
        XCTAssertEqual(classify("Amazing Spider-Man 300 PSA 10 Gem Mint").kind, .graded(company: .psa, grade: 10))
    }

    func testSlabLabels() {
        XCTAssertEqual(classify("Amazing Spider-Man #300 CGC SS 9.8 Signed McFarlane").group, .slab(.cgc, .signatureSeries))
        XCTAssertEqual(classify("Amazing Spider-Man #300 CGC 9.8 Qualified").group, .slab(.cgc, .qualified))
        XCTAssertEqual(classify("Amazing Spider-Man #300 CGC 9.0 Restored Purple Label").group, .slab(.cgc, .restored))
    }

    func testRawGradeFromTitle() {
        XCTAssertEqual(SaleClassifier.rawGrade(in: "Amazing Spider-Man #300 9.4 NM"), 9.4)
        XCTAssertEqual(SaleClassifier.rawGrade(in: "ASM 300 VF/NM"), 9.0)
        XCTAssertEqual(SaleClassifier.rawGrade(in: "Batman 423 VG+"), 4.5)
        XCTAssertNil(SaleClassifier.rawGrade(in: "Absolute Batman #1 $9.99"))
        XCTAssertEqual(PriceBand.of(grade: 4.5), .low)
        XCTAssertEqual(PriceBand.of(grade: 9.0), .mid)
        XCTAssertEqual(PriceBand.of(grade: 9.2), .high)
    }

    func testPSADNAAutographIsNotASlab() {
        let sale = classify("Amazing Spider-Man #300 Signed McFarlane PSA/DNA COA")
        XCTAssertFalse(sale.kind.isGraded)
        XCTAssertEqual(sale.group, .rawSigned)
    }

    // Edition / variant / printing matching
    func testDifferentEditionsAreNotCounted() {
        XCTAssertEqual(classify("Amazing Spider-Man #300 2nd Printing").excludedReason, "2nd printing")
        XCTAssertEqual(classify("Amazing Spider-Man #3000").excludedReason, "Different issue number")
        XCTAssertEqual(classify("Amazing Spider-Man #300 Facsimile").excludedReason, "Facsimile or reprint")
        XCTAssertEqual(classify("Amazing Spider-Man 298 299 300 lot").excludedReason, "Lot or more than one book")
        XCTAssertEqual(classify("Amazing Spider-Man #300 Virgin Variant").excludedReason, "Variant or exclusive cover")
    }

    func testVariantMatching() {
        var spec = ComicSpec(searchText: "Absolute Batman #1")
        spec.variant = "Jim Lee 1:25"
        XCTAssertNil(classify("Absolute Batman #1 Jim Lee 1:25 Variant", spec: spec).excludedReason)
        XCTAssertNil(classify("Absolute Batman #1 Jim Lee 1 in 25 Incentive", spec: spec).excludedReason)
        XCTAssertNotNil(classify("Absolute Batman #1 Jim Lee Foil", spec: spec).excludedReason)
        spec.variant = "Cover B"
        XCTAssertNil(classify("Absolute Batman #1 Cover B Wes Craig", spec: spec).excludedReason)
        XCTAssertNotNil(classify("Absolute Batman #1 Cover C", spec: spec).excludedReason)
    }

    func testNewsstandVsDirect() {
        var spec = TestData.asm300
        spec.printEdition = .newsstand
        XCTAssertNil(classify("Amazing Spider-Man #300 Newsstand NM", spec: spec).excludedReason)
        XCTAssertEqual(classify("Amazing Spider-Man #300 NM", spec: spec).excludedReason, "Not a newsstand copy")
        spec.printEdition = .direct
        XCTAssertEqual(classify("Amazing Spider-Man #300 Newsstand", spec: spec).excludedReason, "Newsstand copy")
    }

    func testSignerMustMatch() {
        var spec = TestData.asm300
        spec.signed = true
        spec.signer = "Todd McFarlane"
        XCTAssertNil(classify("Amazing Spider-Man #300 Signed McFarlane", spec: spec).excludedReason)
        XCTAssertEqual(classify("Amazing Spider-Man #300 Signed Stan Lee", spec: spec).excludedReason, "Signed by someone else")
    }

    func testMatchConfidenceFlagsDoubtfulSales() {
        XCTAssertGreaterThanOrEqual(classify("Amazing Spider-Man #300 CGC 9.8").confidence ?? 0, 0.9)
        let doubtful = classify("Spider-Man #300 #301 poster")
        XCTAssertLessThan(doubtful.confidence ?? 1, 0.7)
        XCTAssertTrue(doubtful.needsReview)
    }

    func testReviewsOverrideTheMatcher() {
        let listing = TestData.sale("42", "Amazing Spider-Man #300 Virgin", 100)
        let approved = SaleClassifier.classify([listing], spec: TestData.asm300, options: CompOptions(), reviews: ["42": true])[0]
        XCTAssertTrue(approved.counted)
        let rejected = SaleClassifier.classify([TestData.sale("43", "Amazing Spider-Man #300 NM", 100)], spec: TestData.asm300,
                                               options: CompOptions(), reviews: ["43": false])[0]
        XCTAssertEqual(rejected.excludedReason, "Rejected by you")
    }
}
