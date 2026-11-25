import SQLite3
import XCTest
@testable import ComicScanner

/// The catalog file format made by scripts/build_catalog.py, with a few real Marvel/DC rows.
final class CatalogTests: XCTestCase {
    private func makeCatalog() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let sql = """
        CREATE TABLE series(id INTEGER PRIMARY KEY, name TEXT, norm TEXT, year_began INTEGER, year_ended INTEGER, publisher TEXT, issue_count INTEGER);
        CREATE TABLE issue(id INTEGER PRIMARY KEY, series_id INTEGER, number TEXT, num INTEGER, variant TEXT DEFAULT '', parent_id INTEGER, barcode TEXT DEFAULT '', key_date TEXT DEFAULT '', price TEXT DEFAULT '');
        INSERT INTO series VALUES (100, 'The Amazing Spider-Man', 'amazing spider man', 1963, 1998, 'Marvel', 2);
        INSERT INTO series VALUES (110, 'The Amazing Spider-Man', 'amazing spider man', 2018, 2022, 'Marvel', 1);
        INSERT INTO series VALUES (200, 'Superman/Wonder Woman', 'superman wonder woman', 2013, 2016, 'DC', 2);
        INSERT INTO series VALUES (210, 'Wonder Woman', 'wonder woman', 1987, 2006, 'DC', 1);
        INSERT INTO issue VALUES (1, 100, '300', 300, '', NULL, '07148602442700311', '1988-05-00', '1.00 USD');
        INSERT INTO issue VALUES (2, 100, '300', 300, 'Newsstand', 1, '07148602442700321', '1988-05-00', '1.00 USD');
        INSERT INTO issue VALUES (3, 200, '1', 1, '', NULL, '76194131846700111', '2013-11-00', '3.99 USD');
        INSERT INTO issue VALUES (4, 200, '1', 1, 'Jim Lee 1:100', 3, '76194131846700121', '2013-11-00', '3.99 USD');
        INSERT INTO issue VALUES (5, 210, '1', 1, '', NULL, '', '1987-02-00', '0.75 USD');
        INSERT INTO issue VALUES (6, 110, '1', 1, '', NULL, '75960608936800111', '2018-09-00', '5.99 USD');
        ALTER TABLE issue ADD COLUMN cover TEXT NOT NULL DEFAULT '';
        UPDATE issue SET cover = 'https://files1.comics.org/img/gcd/covers_by_id/1/w400/3.jpg' WHERE id = 3;
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        return url
    }

    func testBarcodeFindsTheExactCover() async throws {
        let catalog = ComicCatalog()
        let opened = await catalog.useDatabase(at: try makeCatalog())
        XCTAssertTrue(opened)

        let regular = await catalog.issues(barcode: "76194131846700111")
        XCTAssertEqual(regular.map(\.id), [3])
        XCTAssertEqual(regular.first?.spec.title, "Superman/Wonder Woman")
        XCTAssertEqual(regular.first?.spec.publisher, "DC Comics")
        XCTAssertEqual(regular.first?.spec.year, "2013")
        XCTAssertEqual(regular.first?.spec.coverImageURL, "https://files1.comics.org/img/gcd/covers_by_id/1/w400/3.jpg")

        let variant = await catalog.issues(barcode: "76194131846700121")
        XCTAssertEqual(variant.first?.spec.variant, "Jim Lee 1:100")

        // Newsstand goes into its own field, not the variant name.
        let newsstand = await catalog.issues(barcode: "07148602442700321")
        XCTAssertEqual(newsstand.first?.spec.printEdition, .newsstand)
        XCTAssertEqual(newsstand.first?.spec.variant, "")

        // EAN-13 style leading zero and missing leading zero both work.
        let trimmed = await catalog.issues(barcode: "7148602442700311")
        XCTAssertEqual(trimmed.map(\.id), [1])
        let unknown = await catalog.issues(barcode: "12345678901200111")
        XCTAssertTrue(unknown.isEmpty)
    }

    func testCoverTextFindsTheSeriesAndIssue() async throws {
        let catalog = ComicCatalog()
        _ = await catalog.useDatabase(at: try makeCatalog())

        // The longer series name on the cover wins over "Wonder Woman".
        let hits = await catalog.match(coverText: ["SUPERMAN", "WONDER WOMAN", "DC COMICS", "$3.99"], issue: "1")
        XCTAssertEqual(hits.first?.id, 3)
        XCTAssertEqual(hits.first?.isVariant, false)
        XCTAssertTrue(hits.contains { $0.id == 4 })
        XCTAssertFalse(hits.contains { $0.id == 5 })

        // Both volumes of Amazing Spider-Man #1 are offered, newest first.
        let asm = await catalog.match(coverText: ["THE AMAZING", "SPIDER-MAN", "#1"], issue: "1")
        XCTAssertEqual(asm.map(\.id), [6])
        let asm300 = await catalog.match(coverText: ["AMAZING SPIDER-MAN"], issue: "300")
        XCTAssertEqual(asm300.first?.id, 1)

        // No issue number: too vague, nothing returned.
        let vague = await catalog.match(coverText: ["AMAZING SPIDER-MAN"], issue: nil)
        XCTAssertTrue(vague.isEmpty)
    }
}
