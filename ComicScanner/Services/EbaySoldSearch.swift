import Foundation

/// Reads eBay's public sold-listings search results through the WebBot.
enum EbaySoldSearch {
    /// eBay category "Comic Books, Manga & Memorabilia".
    static let comicsCategory = "63"

    static func soldURL(query: String, comicsOnly: Bool) -> URL {
        var components = URLComponents(string: "https://www.ebay.com/sch/i.html")!
        var items = [
            URLQueryItem(name: "_nkw", value: query),
            URLQueryItem(name: "LH_Sold", value: "1"),
            URLQueryItem(name: "LH_Complete", value: "1"),
            URLQueryItem(name: "_sop", value: "13"),   // most recently ended first
            URLQueryItem(name: "_ipg", value: "240"),  // results per page
            URLQueryItem(name: "rt", value: "nc"),
        ]
        if comicsOnly { items.append(URLQueryItem(name: "_sacat", value: comicsCategory)) }
        components.queryItems = items
        return components.url!
    }

    static func activeURL(query: String) -> URL {
        var components = URLComponents(string: "https://www.ebay.com/sch/i.html")!
        components.queryItems = [
            URLQueryItem(name: "_nkw", value: query),
            URLQueryItem(name: "_sacat", value: comicsCategory),
            URLQueryItem(name: "_ipg", value: "60"),
        ]
        return components.url!
    }

    /// Sold comps for a spec.
    @MainActor
    static func soldListings(for spec: ComicSpec, bot: WebBot, comicsOnly: Bool) async throws -> [SoldListing] {
        let url = soldURL(query: spec.ebayQuery, comicsOnly: comicsOnly)
        let json = try await bot.fetch(url, site: "eBay", readyScript: readyScript, extractScript: extractScript)
        return try parse(json)
    }

    /// Titles of listings (sold or not) that match a barcode — used to guess the title of a scanned comic.
    @MainActor
    static func titlesForBarcode(_ barcode: ComicBarcode, bot: WebBot) async throws -> [String] {
        var codes: [String] = []
        if let full = barcode.fullUPC { codes.append(full) }
        codes.append(barcode.base)

        for code in codes {
            for url in [activeURL(query: code), soldURL(query: code, comicsOnly: true)] {
                let json = try await bot.fetch(url, site: "eBay", readyScript: readyScript, extractScript: extractScript)
                let titles = try parsePage(json).items.map(\.title)
                if !titles.isEmpty { return Array(titles.prefix(8)) }
            }
        }
        return []
    }

    // MARK: - Page scripts

    static let readyScript = """
    (() => !!document.querySelector('ul.srp-results, .srp-river-results, .srp-save-null-search, .s-message'))()
    """

    /// Pulls every result card above eBay's "Results matching fewer words" divider.
    static let extractScript = """
    (() => {
      const out = [];
      const cards = document.querySelectorAll('ul.srp-results > li, li.s-item, li.s-card');
      for (const li of cards) {
        const text = (li.innerText || '').trim();
        if ((li.className || '').includes('srp-river-answer') || li.querySelector('.srp-river-answer')) {
          if (/fewer words|matching fewer/i.test(text)) break;
          continue;
        }
        const link = li.querySelector('a[href*="/itm/"]');
        if (!link) continue;
        const titleEl = li.querySelector('.s-card__title, .s-item__title, [role="heading"], h3');
        let title = (titleEl ? titleEl.innerText : '').replace(/^new listing\\s*/i, '').replace(/opens in a new window or tab/i, '').trim();
        if (!title || /^shop on ebay$/i.test(title)) continue;
        const priceEl = li.querySelector('.s-card__price, .s-item__price');
        const strike = !!(priceEl && priceEl.querySelector('.STRIKETHROUGH, s, del, [class*="strikethrough"]'));
        const img = li.querySelector('img');
        let image = '';
        if (img) {
          image = img.getAttribute('data-src') || img.getAttribute('data-defer-load') || img.currentSrc || img.src || '';
          if (/\\.gif($|\\?)/i.test(image)) image = '';
        }
        out.push({ title, url: link.href, price: priceEl ? priceEl.innerText : '', text, image, strike });
      }
      return JSON.stringify({ items: out, pageTitle: document.title || '' });
    })()
    """

    // MARK: - Parsing

    struct RawCard: Decodable {
        let title: String
        let url: String
        let price: String
        let text: String
        let image: String
        let strike: Bool
    }

    struct RawPage: Decodable {
        let items: [RawCard]
        let pageTitle: String
    }

    static func parsePage(_ json: String) throws -> RawPage {
        guard let data = json.data(using: .utf8) else { throw BotError.noData("eBay") }
        return try JSONDecoder().decode(RawPage.self, from: data)
    }

    static func parse(_ json: String) throws -> [SoldListing] {
        var seen = Set<String>()
        return try parsePage(json).items.compactMap(listing(from:)).filter { seen.insert($0.id).inserted }
    }

    static func listing(from card: RawCard) -> SoldListing? {
        // Skip ranges ("$10.00 to $20.00") and other currencies.
        if card.price.lowercased().contains(" to ") { return nil }
        if matches(#"^\s*[a-z]{1,3}\s?\$|£|€"#, card.price) { return nil }
        guard let priceText = firstMatch(#"\$\s?([\d,]+(?:\.\d{2})?)"#, in: card.price.isEmpty ? card.text : card.price),
              let price = cents(priceText), price > 0 else { return nil }

        var shipping: Int?
        if matches(#"free (shipping|delivery|postage)"#, card.text) {
            shipping = 0
        } else if let ship = firstMatch(#"\+?\s?\$([\d,]+\.\d{2})\s*(?:shipping|delivery|postage)"#, in: card.text) {
            shipping = cents(ship)
        }

        var soldDate: Date?
        if let dateText = firstMatch(#"(?:sold|ended)\s+([a-z]{3}\s+\d{1,2},\s+\d{4})"#, in: card.text) {
            soldDate = dateFormatter.date(from: dateText.capitalized)
        }

        let id = firstMatch(#"/itm/(?:[^/?]+/)?(\d{9,15})"#, in: card.url) ?? card.url
        let bestOffer = card.strike || matches(#"best offer accepted"#, card.text)

        return SoldListing(
            id: id,
            title: card.title,
            priceCents: price,
            shippingCents: shipping,
            soldDate: soldDate,
            url: URL(string: card.url),
            imageURL: card.image.isEmpty ? nil : URL(string: card.image),
            bestOffer: bestOffer
        )
    }

    static func cents(_ text: String) -> Int? {
        guard let value = Double(text.replacingOccurrences(of: ",", with: "")) else { return nil }
        return Int((value * 100).rounded())
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    /// Best guess at the series title from a listing title, cutting at the issue number.
    static func seriesGuess(from listingTitle: String, issue: String) -> String {
        var title = listingTitle
        if let number = firstMatch(#"^\s*(\d+)"#, in: issue), let value = Int(number),
           let regex = try? NSRegularExpression(pattern: #"(?<![\w.$:/,])#?\s?0*"# + String(value) + #"(?!\d)"#, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
           let range = Range(match.range, in: title) {
            title = String(title[..<range.lowerBound])
        } else if let range = title.range(of: #"#\s?\d"#, options: .regularExpression) {
            title = String(title[..<range.lowerBound])
        }
        title = replacing(#"^(marvel|dc|image|boom!?|idw|dark horse)\s+comics?\s+"#, in: title, with: "")
        return title.trimmingCharacters(in: CharacterSet(charactersIn: " -–:#|,")).trimmed
    }
}
