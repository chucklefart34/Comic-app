import Foundation
import WebKit

/// What happened on the last eBay page load — shown in Settings → Test pricing, so failures aren't silent.
struct EbayDiagnostics {
    var query = ""
    var url: URL?
    var method = ""
    var pageTitle = ""
    var cardsOnPage = 0
    var listingsRead = 0
    var noResults = false
    var error: String?
    /// Every way that was tried, and what eBay sent back to each.
    var attempts: [String] = []
    var at = Date()

    var summary: String {
        var lines: [String] = []
        if let error {
            lines.append("Failed: \(error)")
        } else if noResults {
            lines.append("eBay found no sold listings for \"\(query)\" (\(method)).")
        } else {
            lines.append("\(listingsRead) listings read via \(method) · \(cardsOnPage) result cards · page \"\(pageTitle)\"")
        }
        if attempts.count > 1 || error != nil { lines += attempts.map { "  · \($0)" } }
        return lines.joined(separator: "\n")
    }
}

/// Loads eBay search pages and reads the results.
/// eBay sometimes answers with an "Error Page" or a security check depending on how the page is asked for,
/// so several ways are tried in turn; the one that works is remembered and tried first next time.
@MainActor
enum EbayPages {
    static var last = EbayDiagnostics()

    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15"
    static let iPhoneUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1"

    enum Strategy: String, CaseIterable {
        case directDesktop = "direct (desktop)"
        case directPhone = "direct (iPhone)"
        case browserPhone = "browser (iPhone)"
        case browserDesktop = "browser (desktop)"

        var isBrowser: Bool { self == .browserPhone || self == .browserDesktop }
        var userAgent: String { (self == .directDesktop || self == .browserDesktop) ? EbayPages.desktopUserAgent : EbayPages.iPhoneUserAgent }
        /// Only the first try uses the full set of URL options; the rest use the plainest possible search URL.
        var simpleURL: Bool { self != .directDesktop }
    }

    private static let preferredKey = "ebayPreferredStrategy"
    private static var preferred: Strategy? {
        get { UserDefaults.standard.string(forKey: preferredKey).flatMap(Strategy.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: preferredKey) }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 15
        configuration.httpAdditionalHeaders = [
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
        ]
        return URLSession(configuration: configuration)
    }()

    /// The plainest sold-search URL for the same words (eBay rejects some option combinations).
    static func simplified(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let keep: Set<String> = ["_nkw", "LH_Sold", "LH_Complete", "_sacat"]
        components.queryItems = components.queryItems?.filter { keep.contains($0.name) }
        return components.url ?? url
    }

    static func listings(at url: URL, query: String, bot: WebBot) async throws -> [SoldListing] {
        var diagnostics = EbayDiagnostics(query: query, url: url)
        defer { last = diagnostics }
        guard NetworkMonitor.shared.isOnline else {
            diagnostics.error = "Offline"
            throw ServiceError.offline
        }

        var order = Strategy.allCases
        if let preferred, let index = order.firstIndex(of: preferred) {
            order.remove(at: index)
            order.insert(preferred, at: 0)
        }

        var lastError: Error?
        for strategy in order {
            try Task.checkCancellation()
            let target = strategy.simpleURL ? simplified(url) : url
            do {
                let page = try await load(target, strategy: strategy, bot: bot)
                let parsed = page.items.compactMap(EbaySoldSearch.listing(from:))
                let title = page.pageTitle.trimmed
                diagnostics.attempts.append("\(strategy.rawValue): \(parsed.count) listings, page \"\(title.prefix(60))\"")
                if !parsed.isEmpty || (page.noResults == true && !looksLikeError(title)) {
                    diagnostics.method = strategy.rawValue
                    diagnostics.pageTitle = title
                    diagnostics.cardsOnPage = page.cards ?? 0
                    diagnostics.noResults = parsed.isEmpty
                    diagnostics.listingsRead = parsed.count
                    diagnostics.url = target
                    preferred = strategy
                    return parsed
                }
                diagnostics.pageTitle = title
                diagnostics.cardsOnPage = page.cards ?? 0
            } catch {
                if error.isCancellation { throw error }
                lastError = error
                diagnostics.attempts.append("\(strategy.rawValue): \(error.localizedDescription)")
            }
        }
        diagnostics.method = "all methods"
        diagnostics.error = lastError.map { $0.localizedDescription } ?? "eBay didn't return search results (\"\(diagnostics.pageTitle)\")"
        throw lastError ?? BotError.noData("eBay")
    }

    private static func looksLikeError(_ title: String) -> Bool {
        let lower = title.lowercased()
        return lower.contains("error") || lower.contains("security") || lower.contains("interruption") || lower.isEmpty
    }

    private static func load(_ url: URL, strategy: Strategy, bot: WebBot) async throws -> EbaySoldSearch.RawPage {
        if strategy.isBrowser {
            let json = try await bot.fetch(url, site: "eBay", readyScript: EbaySoldSearch.readyScript,
                                           extractScript: EbaySoldSearch.extractScript, minimumGap: 1.0,
                                           userAgent: strategy.userAgent)
            return try EbaySoldSearch.parsePage(json)
        }
        var request = URLRequest(url: url)
        request.setValue(strategy.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw BotError.noData("eBay")
        }
        let head = html.prefix(20_000).lowercased()
        if head.contains("pardon our interruption") || head.contains("verify you are a human") || head.contains("captcha") {
            throw ServiceError.badData("eBay security check (HTTP \(status))")
        }
        var page = try await PageParser.shared.read(html: html, baseURL: url)
        if status != 200 { page.pageTitle += " (HTTP \(status))" }
        return page
    }
}

/// An off-screen web view used only to read downloaded HTML: page scripts, images and styles are blocked,
/// so it parses in a fraction of a second.
@MainActor
final class PageParser: NSObject, WKNavigationDelegate {
    static let shared = PageParser()

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Void, Never>?
    private var busy = false

    private func makeWebView() async -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let rules = """
        [{"trigger":{"url-filter":".*","resource-type":["image","style-sheet","font","media","script","raw","svg-document","popup"]},"action":{"type":"block"}}]
        """
        if let list = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "parser-block-all", encodedContentRuleList: rules) {
            configuration.userContentController.add(list)
        }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 2000), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        return view
    }

    func read(html: String, baseURL: URL) async throws -> EbaySoldSearch.RawPage {
        while busy { try await Task.sleep(nanoseconds: 30_000_000) }
        busy = true
        defer { busy = false }

        let view = await makeWebView()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
            view.loadHTMLString(html, baseURL: baseURL)
            // Don't wait forever on a page that never reports finishing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.finish() }
        }
        guard let json = try await view.evaluateJavaScript(EbaySoldSearch.extractScript) as? String else {
            throw BotError.noData("eBay")
        }
        return try EbaySoldSearch.parsePage(json)
    }

    private func finish() {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish() }
}
