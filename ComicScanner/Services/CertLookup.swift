import Foundation

/// Reads a CGC or PSA certification page and turns it into a ComicSpec.
enum CertLookup {
    struct Result {
        var spec: ComicSpec
        /// Every label/value pair found on the page, shown so you can check the reading.
        var fields: [(String, String)]
    }

    @MainActor
    static func lookUp(_ cert: SlabCert, bot: WebBot) async throws -> Result {
        guard let url = cert.lookupURL else { throw BotError.noData(cert.company.rawValue) }
        let site = cert.company == .cgc ? "CGC" : "PSA"
        let ready = """
        (() => !!document.body && document.body.innerText.includes('\(cert.number)') && /grade/i.test(document.body.innerText))()
        """
        let json = try await bot.fetch(url, site: site, readyScript: ready, extractScript: extractScript, minimumGap: 1.0)
        guard let data = json.data(using: .utf8),
              let page = try? JSONDecoder().decode(RawCertPage.self, from: data) else {
            throw BotError.noData(site)
        }
        return parse(page, cert: cert)
    }

    struct RawCertPage: Decodable {
        let pairs: [[String]]
        let text: String
        let images: [String]
    }

    static let extractScript = """
    (() => {
      const clean = s => (s || '').replace(/\\s+/g, ' ').trim();
      const pairs = [];
      document.querySelectorAll('dt').forEach(dt => {
        const dd = dt.nextElementSibling;
        if (dd && dd.tagName === 'DD') pairs.push([clean(dt.innerText), clean(dd.innerText)]);
      });
      document.querySelectorAll('tr').forEach(tr => {
        const cells = tr.querySelectorAll('th, td');
        if (cells.length === 2) pairs.push([clean(cells[0].innerText), clean(cells[1].innerText)]);
      });
      const images = Array.from(document.querySelectorAll('img'))
        .map(i => i.currentSrc || i.src || '')
        .filter(s => /^https?:/.test(s) && !/logo|icon|sprite|badge|flag|avatar/i.test(s))
        .filter(s => /cert|image|cloudfront|cdn|scan|graded/i.test(s))
        .slice(0, 4);
      return JSON.stringify({ pairs, text: document.body ? document.body.innerText.slice(0, 20000) : '', images });
    })()
    """

    static func parse(_ page: RawCertPage, cert: SlabCert) -> Result {
        var fields: [(String, String)] = page.pairs.compactMap { pair in
            guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty, pair[0].count < 40 else { return nil }
            return (pair[0].trimmingCharacters(in: CharacterSet(charactersIn: ": ")), pair[1])
        }

        // Also read "Label: value" lines and "Label" / "value" line pairs from the page text.
        let lines = page.text.components(separatedBy: .newlines).map(\.trimmed).filter { !$0.isEmpty }
        for (index, line) in lines.enumerated() {
            if let colon = line.firstIndex(of: ":"), line.distance(from: line.startIndex, to: colon) < 30 {
                let key = line[..<colon].trimmed
                let value = line[line.index(after: colon)...].trimmed
                if !key.isEmpty, !value.isEmpty { fields.append((key, value)) }
            } else if knownKeys.contains(line.lowercased()), index + 1 < lines.count {
                fields.append((line, lines[index + 1]))
            }
        }

        func value(_ keys: [String]) -> String? {
            for key in keys {
                if let hit = fields.first(where: { $0.0.lowercased() == key }) { return hit.1 }
            }
            return nil
        }

        let text = page.text
        var spec = ComicSpec()
        spec.graded = true
        spec.company = cert.company
        spec.certNumber = cert.number

        spec.title = value(["title", "item title", "item", "series", "book title", "comic title"]) ?? ""
        spec.issue = value(["issue", "issue #", "issue number", "issue no.", "issue no", "number"]) ?? ""
        spec.issue = spec.issue.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if spec.issue.isEmpty, let fromTitle = firstMatch(#"#\s?(\d+[a-z]?)"#, in: spec.title) {
            spec.issue = fromTitle
        }
        // Keep "Amazing Spider-Man" rather than "Amazing Spider-Man #300".
        if let hash = spec.title.range(of: #"\s*#\s?\d"#, options: .regularExpression) {
            spec.title = String(spec.title[..<hash.lowerBound])
        }
        spec.publisher = value(["publisher"]) ?? ""
        spec.year = value(["issue year", "year", "issue date", "publication year", "published"]).flatMap {
            firstMatch(#"((?:18|19|20)\d{2})"#, in: $0) ?? $0
        } ?? ""
        spec.pageQuality = value(["page quality", "pages"]) ?? ""

        let gradeText = value(["grade", "cgc grade", "item grade", "psa grade", "final grade", "numeric grade"])
            ?? firstMatch(#"grade\s*[:\-]?\s*([a-z/+\- ]{0,12}(?:10(?:\.0)?|\d\.\d|\d))"#, in: text)
            ?? ""
        if let number = firstMatch(#"(10(?:\.0)?|\d\.\d|\b\d\b)"#, in: gradeText), let grade = Double(number) {
            spec.grade = grade
        }

        let label = (value(["label", "label type", "label category"]) ?? "") + " " + String(text.prefix(4000))
        if matches(#"signature series"#, label) {
            spec.label = .signatureSeries
        } else if matches(#"\bqualified\b"#, label) {
            spec.label = .qualified
        } else if matches(#"\brestored\b"#, label) {
            spec.label = .restored
        }

        var signatureText = value(["signatures", "signature", "signed by", "autograph", "autographs", "signer"]) ?? ""
        if ["none", "no", "n/a", "-", "--"].contains(signatureText.lowercased().trimmed) { signatureText = "" }
        let signer = firstMatch(#"signed by\s+([^,;.\n]+?)(?:\s+(?:on|at|in)\s|[,;.\n]|$)"#, in: signatureText + " " + text)
            ?? (signatureText.isEmpty ? nil : signatureText)
        if spec.label == .signatureSeries || signer != nil || matches(#"\bautograph grade\b|\bauthentic autograph\b"#, text) {
            spec.signed = true
            spec.signer = signer?.trimmed ?? ""
        }

        let keyComments = value(["key comments", "key comment", "variant", "variant description", "comments", "notes", "description"]) ?? ""
        spec.notes = keyComments
        if let clause = variantClause(in: keyComments) {
            spec.variant = clause
        }
        if let printing = firstMatch(#"\b(2nd|second|3rd|third|4th|fourth)\s+print"#, in: keyComments) {
            spec.printing = ["2nd": 2, "second": 2, "3rd": 3, "third": 3][printing.lowercased()] ?? 4
        }

        spec.coverImageURL = page.images.first ?? ""
        return Result(spec: spec, fields: fields)
    }

    private static let knownKeys: Set<String> = [
        "title", "issue", "issue date", "issue year", "publisher", "grade", "page quality", "key comments",
        "signatures", "signed by", "label", "label type", "variant", "year",
    ]

    /// "Mile High Comics Edition. 1st appearance of…" → "Mile High Comics Edition"
    static func variantClause(in comments: String) -> String? {
        let clauses = comments.components(separatedBy: CharacterSet(charactersIn: ".;\n"))
        for clause in clauses {
            let trimmed = clause.trimmed
            if matches(#"\b(variant|edition|exclusive|virgin|cover|1:\d+|incentive|sketch|foil|newsstand)\b"#, trimmed),
               !matches(#"\b(appearance|origin|death|story)\b"#, trimmed) {
                return String(trimmed.prefix(60))
            }
        }
        return nil
    }
}
