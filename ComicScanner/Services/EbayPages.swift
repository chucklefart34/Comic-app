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
    var at = Date()

    var summary: String {
        if let error { return "Failed (\(method)): \(error)" }
        if noResults { return "eBay found no sold listings for \"\(query)\"." }
        return "\(listingsRead) listings read via \(method) · \(cardsOnPage) result cards · page \"\(pageTitle)\""
    }
}

/// Loads eBay search pages and reads the results.
/// Fast path: download the page directly and read it in a lightweight parser (no images, no scripts).
/// If eBay pushes back (a security check), fall back to the full in-app browser, which can show you the check.
@MainActor
enum EbayPages {
    static var last = EbayDiagnostics()

    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 15
        configuration.httpAdditionalHeaders = [
            "User-Agent": desktopUserAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
        ]
        return URLSession(configuration: configuration)
    }()

    static func listings(at url: URL, query: String, bot: WebBot) async throws -> [SoldListing] {
        var diagnostics = EbayDiagnostics(query: query, url: url)
        defer { last = diagnostics }
        guard NetworkMonitor.shared.isOnline else {
            diagnostics.error = "Offline"
            throw ServiceError.offline
        }

        // 1. Fast path.
        if let html = try? await download(url), let page = try? await PageParser.shared.read(html: html, baseURL: url) {
            diagnostics.method = "direct"
            diagnostics.pageTitle = page.pageTitle
            diagnostics.cardsOnPage = page.cards ?? 0
            diagnostics.noResults = page.noResults ?? false
            let parsed = page.items.compactMap(EbaySoldSearch.listing(from:))
            if !parsed.isEmpty || page.noResults == true {
                diagnostics.listingsRead = parsed.count
                return parsed
            }
        }

        // 2. Full browser (handles security checks with your help).
        diagnostics.method = "browser"
        do {
            let json = try await bot.fetch(url, site: "eBay", readyScript: EbaySoldSearch.readyScript,
                                           extractScript: EbaySoldSearch.extractScript, minimumGap: 1.0)
            let page = try EbaySoldSearch.parsePage(json)
            diagnostics.pageTitle = page.pageTitle
            diagnostics.cardsOnPage = page.cards ?? 0
            diagnostics.noResults = page.noResults ?? false
            let parsed = page.items.compactMap(EbaySoldSearch.listing(from:))
            diagnostics.listingsRead = parsed.count
            return parsed
        } catch {
            diagnostics.error = error.localizedDescription
            throw error
        }
    }

    /// Downloads the page; nil if it looks like a security check instead of search results.
    private static func download(_ url: URL) async throws -> String? {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let head = html.prefix(20_000).lowercased()
        if head.contains("pardon our interruption") || head.contains("verify you are a human") || head.contains("captcha") {
            return nil
        }
        return html
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
