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
        try await soldListings(query: spec.broadQuery, bot: bot, comicsOnly: comicsOnly)
    }

    @MainActor
    static func soldListings(query: String, bot: WebBot, comicsOnly: Bool) async throws -> [SoldListing] {
        try await EbayPages.listings(at: soldURL(query: query, comicsOnly: comicsOnly), query: query, bot: bot)
    }

    /// Listings (for sale or sold) for a barcode or search words.
    @MainActor
    static func listingsForBarcode(_ code: String, sold: Bool, bot: WebBot) async throws -> [SoldListing] {
        let url = sold ? soldURL(query: code, comicsOnly: true) : activeURL(query: code)
        return try await EbayPages.listings(at: url, query: code, bot: bot)
    }

    // MARK: - Page scripts

    static let readyScript = """
    (() => !!document.querySelector('ul.srp-results, .srp-river-results, .srp-save-null-search, .s-message, a[href*="/itm/"]'))()
    """

    /// Pulls every result card above eBay's "Results matching fewer words" divider.
    /// Handles both of eBay's layouts (s-card and s-item), with a generic fallback for anything else.
    static let extractScript = """
    (() => {
      const text = el => ((el && (el.innerText || el.textContent)) || '').replace(/\\s+/g, ' ').trim();
      const clean = t => t.replace(/^new listing\\s*/i, '').replace(/opens in a new window or tab/ig, '').trim();
      const imageOf = card => {
        const img = card.querySelector('img');
        if (!img) return '';
        let src = img.getAttribute('data-src') || img.getAttribute('data-defer-load') || img.getAttribute('src') || '';
        if (!src && img.getAttribute('srcset')) src = img.getAttribute('srcset').split(' ')[0];
        return /\\.gif($|\\?)/i.test(src) ? '' : src;
      };
      const out = [];
      const seen = new Set();
      const add = (card, link, titleEl, priceEl) => {
        const url = link.href || link.getAttribute('href') || '';
        const id = (url.match(/\\/itm\\/(?:[^/?]+\\/)?(\\d{9,15})/) || [])[1] || url;
        if (!url || seen.has(id)) return;
        let title = clean(text(titleEl || link));
        if (!title || /^shop on ebay$/i.test(title)) return;
        seen.add(id);
        const strike = !!(priceEl && priceEl.querySelector('.STRIKETHROUGH, s, del, [class*="strikethrough"]'));
        out.push({ title, url, price: text(priceEl), text: text(card), image: imageOf(card), strike });
      };

      const cards = document.querySelectorAll('ul.srp-results > li, li.s-item, li.s-card, div.s-card');
      let structured = 0;
      for (const card of cards) {
        const cls = card.className || '';
        const body = text(card);
        if (cls.includes('srp-river-answer') || card.querySelector('.srp-river-answer')) {
          if (/fewer words|matching fewer/i.test(body)) break;
          continue;
        }
        const link = card.querySelector('a[href*="/itm/"]');
        if (!link) continue;
        structured++;
        add(card, link,
            card.querySelector('.s-card__title, .s-item__title, [role="heading"], h3'),
            card.querySelector('.s-card__price, .s-item__price, [class*="price"]'));
      }

      // Unknown layout: start from item links and use the nearest card-like parent.
      if (structured === 0) {
        const stop = Array.from(document.querySelectorAll('li, div, h2, h3')).find(el => /results matching fewer words/i.test(el.textContent || '') && (el.textContent || '').length < 200);
        for (const link of document.querySelectorAll('a[href*="/itm/"]')) {
          if (stop && (stop.compareDocumentPosition(link) & Node.DOCUMENT_POSITION_FOLLOWING)) break;
          const card = link.closest('li') || link.closest('[class*="card"]') || link.closest('[class*="item"]') || link.parentElement;
          if (!card || !/\\$\\s?[\\d,]+/.test(text(card))) continue;
          const priceEl = Array.from(card.querySelectorAll('span, div')).find(el => /^\\$\\s?[\\d,]+(\\.\\d{2})?$/.test(text(el)));
          add(card, link, card.querySelector('[role="heading"], h3, h2') || link, priceEl);
        }
      }
      const noResults = !!document.querySelector('.srp-save-null-search') || /no exact matches found/i.test(document.body ? document.body.innerText.slice(0, 5000) : '');
      return JSON.stringify({ items: out, pageTitle: document.title || '', cards: cards.length, noResults });
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
        var pageTitle: String
        var cards: Int?
        var noResults: Bool?
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

    /// Issue number written in a listing title ("#300"), if any.
    static func issueGuess(from listingTitle: String) -> String? {
        firstMatch(#"#\s?(\d{1,4})\b"#, in: listingTitle)
    }

    private static let variantWords = ["virgin", "foil", "sketch", "blank", "newsstand", "metal", "glow", "holo", "chrome", "incentive"]

    /// Variant and exclusive wording in a listing title, e.g. ("Cover B", ""), ("Virgin", "Mile High").
    static func variantGuess(from listingTitle: String, series: String) -> (variant: String, exclusive: String) {
        let text = TitleTraits.normalize(listingTitle)
        var parts: [String] = []
        if let letter = firstMatch(#"\bcover\s+([b-z])\b"#, in: text) { parts.append("Cover \(letter.uppercased())") }
        if let ratio = firstMatch(#"\b(1:\d{2,4})\b"#, in: text) { parts.append(ratio) }
        for word in variantWords where matches(#"\b"# + word + #"\b"#, text) {
            parts.append(word.capitalized)
        }

        var exclusive = ""
        if let range = text.range(of: "exclusive") {
            let seriesWords = Set(series.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            let skip = Set(variantWords).union(["comics", "comic", "variant", "cover", "edition", "con", "the", "and"]).union(seriesWords)
            let before = text[..<range.lowerBound]
                .split(whereSeparator: { !($0.isLetter || $0.isNumber || "&'.:#".contains($0)) })
                .map(String.init)
                .filter { word in
                    !skip.contains(word) && !word.allSatisfy(\.isNumber) && word.count > 1 && !word.contains(":") && !word.hasPrefix("#")
                }
            exclusive = before.suffix(3).map(\.capitalized).joined(separator: " ")
        }
        return (parts.joined(separator: " "), exclusive)
    }

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
