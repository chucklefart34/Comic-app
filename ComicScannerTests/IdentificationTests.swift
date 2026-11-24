import XCTest
@testable import ComicScanner

final class IdentificationTests: XCTestCase {
    func testComicBarcodeWithAddOn() throws {
        let barcode = try XCTUnwrap(ComicBarcode(payload: "75960609558200111"))
        XCTAssertEqual(barcode.base, "759606095582")
        XCTAssertEqual(barcode.issueNumber, 1)
        XCTAssertEqual(barcode.coverVariant, 1)
        XCTAssertEqual(barcode.printing, 1)
        XCTAssertEqual(barcode.fullUPC, "75960609558200111")
    }

    func testUPCReportedAsEAN13() throws {
        let barcode = try XCTUnwrap(ComicBarcode(payload: "0759606095582"))
        XCTAssertEqual(barcode.base, "759606095582")
        XCTAssertNil(barcode.fullUPC)
        XCTAssertNil(ComicBarcode(payload: "12345"))
    }

    func testSecondPrintingAndVariantFromAddOn() throws {
        let barcode = try XCTUnwrap(ComicBarcode(payload: "75960609558230022"))
        XCTAssertEqual(barcode.issueNumber, 300)
        XCTAssertEqual(barcode.coverVariant, 2)
        XCTAssertEqual(barcode.printing, 2)
        XCTAssertEqual(barcode.spec.printing, 2)
    }

    func testSlabCertFromQRCode() throws {
        let cgc = try XCTUnwrap(SlabCert(payload: "https://www.cgccomics.com/certlookup/4012345001/"))
        XCTAssertEqual(cgc.company, .cgc)
        XCTAssertEqual(cgc.number, "4012345001")
        let psa = try XCTUnwrap(SlabCert(payload: "https://www.psacard.com/cert/87654321"))
        XCTAssertEqual(psa.company, .psa)
    }

    func testTypedSearch() {
        let spec = ComicSpec(searchText: "Amazing Spider-Man #300")
        XCTAssertEqual(spec.title, "Amazing Spider-Man")
        XCTAssertEqual(spec.issue, "300")
        XCTAssertEqual(ComicSpec(searchText: "Spawn 1").issue, "1")
    }

    func testSearchWordsAreCleaned() {
        var spec = ComicSpec()
        spec.title = "The Amazing Spider-Man (2018)"
        spec.issue = "001"
        XCTAssertEqual(spec.searchTitle, "Amazing Spider-Man")
        XCTAssertEqual(spec.searchIssue, "1")
        XCTAssertTrue(spec.broadQuery.hasPrefix("Amazing Spider-Man 1 "))
        spec.title = "Batman, Vol. 3"
        XCTAssertEqual(spec.searchTitle, "Batman")
    }

    func testEditionKeySeparatesNewsstand() {
        var direct = TestData.asm300
        direct.printEdition = .direct
        var newsstand = TestData.asm300
        newsstand.printEdition = .newsstand
        XCTAssertNotEqual(direct.editionKey, newsstand.editionKey)
        XCTAssertNotEqual(TestData.asm300.editionKey, newsstand.editionKey)
    }

    @MainActor
    func testCombiningPhotosKeepsTheBarcodesIssue() async throws {
        var issue300 = TestData.asm300
        issue300.coverImageURL = "https://example.com/a.jpg"
        var issue301 = TestData.asm300
        issue301.issue = "301"
        let cover = Identification(candidates: [Candidate(spec: issue301, source: "eBay listing"), Candidate(spec: issue300, source: "eBay listing")],
                                   confident: false, method: "Cover")
        let barcode = try XCTUnwrap(ComicBarcode(payload: "75960609558230011"))
        let fromBarcode = Identification(candidates: [Candidate(spec: issue300, source: "eBay listing")],
                                         confident: false, method: "Barcode", barcode: barcode)
        let combined = await Identifier.combine(cover, fromBarcode)
        XCTAssertEqual(combined.candidates.map(\.spec.issue), ["300"])
        XCTAssertTrue(combined.confident, "Both photos agree on one edition")
    }
}
