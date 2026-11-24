import SwiftUI
import WebKit

enum BotError: LocalizedError {
    case noData(String)
    case gaveUp(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noData(let site): return "Couldn't read the page from \(site). Try again in a moment."
        case .gaveUp(let site): return "\(site) kept showing a security check. Try again later."
        case .cancelled: return "Cancelled."
        }
    }
}

extension Error {
    /// True for errors caused by a task being cancelled (e.g. leaving a screen).
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let urlError = self as? URLError, urlError.code == .cancelled { return true }
        if let botError = self as? BotError, case .cancelled = botError { return true }
        return false
    }
}

/// The "bot": a real Safari web view that loads eBay / CGC / PSA pages the same way you would,
/// then reads the results off the page. One page at a time, a couple of seconds apart.
///
/// If a site shows a "are you human?" check, the web view is shown to you so you can complete it
/// yourself — the app never tries to get around those checks.
@MainActor
@Observable
final class WebBot {
    let webView: WKWebView
    private let navigator = NavigationWaiter()
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var lastLoad = Date.distantPast
    @ObservationIgnored private var userCancelled = false

    /// When true, the app shows the web view so you can complete a site's check (or sign in).
    var showingWebView = false
    var webViewMessage = ""
    /// The page shown in the visible sheet. The sheet has its own browser (sharing cookies),
    /// so the hidden one never has to move between screens.
    var visibleURL: URL?
    /// True while the sheet is showing a security check that the app is waiting on.
    var visibleIsCheck = false
    /// Set by the sheet once its page is no longer a security check.
    var visibleCleared = false
    var status = ""

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        webView.navigationDelegate = navigator
        webView.customUserAgent = EbayPages.desktopUserAgent
        webView.allowsBackForwardNavigationGestures = true
    }

    /// Loads `url`, waits until `readyScript` returns true (if given), then returns what `extractScript` returns.
    func fetch(
        _ url: URL,
        site: String,
        readyScript: String? = nil,
        extractScript: String,
        minimumGap: TimeInterval = 2.5,
        userAgent: String? = nil
    ) async throws -> String {
        while busy {
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        busy = true
        userCancelled = false
        defer {
            busy = false
            status = ""
        }

        let wait = minimumGap - Date().timeIntervalSince(lastLoad)
        if wait > 0 {
            status = "Waiting a moment between pages…"
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
        lastLoad = Date()

        status = "Loading \(site)…"
        webView.customUserAgent = userAgent ?? EbayPages.desktopUserAgent
        try await navigator.load(url, in: webView)
        try await waitOutSecurityCheck(site: site, url: url)

        if let readyScript {
            status = "Reading \(site)…"
            for _ in 0..<40 {
                if (try? await webView.evaluateJavaScript(readyScript)) as? Bool == true { break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        guard let result = try await webView.evaluateJavaScript(extractScript) as? String else {
            throw BotError.noData(site)
        }
        return result
    }

    /// Opens a page in the visible web view (used for optional eBay sign-in, or to look at a cert page).
    func show(_ url: URL, message: String) {
        webViewMessage = message
        visibleURL = url
        visibleIsCheck = false
        visibleCleared = false
        showingWebView = true
    }

    /// The user agent the visible sheet should use (a passed check is tied to it).
    var userAgent: String? { webView.customUserAgent }

    func cancelCheck() {
        if visibleIsCheck { userCancelled = true }
        showingWebView = false
        // A sign-in (or passed check) also helps the fast direct downloads.
        Task { await shareCookies() }
    }

    func clearCookies() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await store.removeData(ofTypes: types, modifiedSince: .distantPast)
    }

    // MARK: - Security checks

    static let checkScript = """
    (() => {
      const text = (document.title || '') + ' ' + (document.body ? document.body.innerText.slice(0, 2000) : '');
      return /pardon our interruption|security measure|verify (that )?you are (a )?human|verify yourself|are you a robot|checking your browser|just a moment|security check|captcha|press (and|&) hold|unusual traffic/i.test(text);
    })()
    """

    /// Copies the browser's cookies (including a passed security check) to the fast direct downloads.
    func shareCookies() async {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        for cookie in cookies where cookie.domain.contains("ebay") {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    private func onSecurityCheck() async -> Bool {
        (try? await webView.evaluateJavaScript(Self.checkScript)) as? Bool ?? false
    }

    private func waitOutSecurityCheck(site: String, url: URL) async throws {
        guard await onSecurityCheck() else { return }

        // Many checks clear by themselves after a few seconds.
        status = "\(site) is checking the connection…"
        for _ in 0..<16 {
            try await Task.sleep(nanoseconds: 500_000_000)
            if !(await onSecurityCheck()) { return }
        }

        // Still there: show you the page in the sheet so you can complete it yourself.
        webViewMessage = "\(site) wants to make sure you're a person. Complete the check and the app will carry on."
        visibleURL = webView.url ?? url
        visibleIsCheck = true
        visibleCleared = false
        showingWebView = true
        defer {
            showingWebView = false
            visibleIsCheck = false
        }
        var waited = 0
        while !visibleCleared {
            try await Task.sleep(nanoseconds: 500_000_000)
            if userCancelled { throw BotError.cancelled }
            waited += 1
            if waited > 360 { throw BotError.gaveUp(site) }  // 3 minutes
        }
        // Passed: the cookies are shared, so load the page again here.
        showingWebView = false
        try await navigator.load(url, in: webView)
        for _ in 0..<10 {
            if !(await onSecurityCheck()) {
                await shareCookies()
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw BotError.gaveUp(site)
    }
}

/// Turns WKWebView's delegate callbacks into an async "load and wait" call.
@MainActor
final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ url: URL, in webView: WKWebView) async throws {
        finish(CancellationError())
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            webView.load(URLRequest(url: url, timeoutInterval: 30))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(Self.isRedirectCancel(error) ? nil : error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(Self.isRedirectCancel(error) ? nil : error)
    }

    /// A load replaced by another (redirects, security checks) reports "cancelled"; the page is still usable.
    private static func isRedirectCancel(_ error: Error) -> Bool {
        (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled
    }

    private func finish(_ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

// MARK: - Hosting the web view in SwiftUI

/// Keeps the bot's web view inside the app's window (hidden), so pages run normally. It never moves.
final class WebViewHost: UIView {
    let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, webView.superview !== self else { return }
        webView.removeFromSuperview()
        addSubview(webView)
        webView.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    }
}

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    var hidden = true

    func makeUIView(context: Context) -> WebViewHost {
        WebViewHost(webView: webView)
    }

    func updateUIView(_ host: WebViewHost, context: Context) {}
}

/// A separate, visible browser for sign-in and security checks. It uses the same cookie store as the bot,
/// so a sign-in or a passed check counts for the bot too.
struct VisibleWebView: UIViewRepresentable {
    let url: URL
    let userAgent: String?
    let onPage: (WKWebView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPage: onPage) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = userAgent
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onPage: (WKWebView) -> Void
        init(onPage: @escaping (WKWebView) -> Void) { self.onPage = onPage }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onPage(webView)
        }

        // "Sign in with Google/Apple" and similar open popups: show them in the same view.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }

        // Page alerts must always be answered, or WebKit raises an exception.
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            completionHandler()
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            completionHandler(true)
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            completionHandler(defaultText)
        }
    }
}

/// The sheet shown when a site needs you (security check, optional sign-in).
struct BotWebSheet: View {
    @Environment(WebBot.self) private var bot
    @State private var host = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !bot.webViewMessage.isEmpty {
                    Text(bot.webViewMessage)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.yellow.opacity(0.2))
                }
                if let url = bot.visibleURL {
                    VisibleWebView(url: url, userAgent: bot.userAgent) { view in
                        host = view.url?.host() ?? ""
                        guard bot.visibleIsCheck else { return }
                        view.evaluateJavaScript(WebBot.checkScript) { result, _ in
                            if (result as? Bool) == false {
                                Task { @MainActor in bot.visibleCleared = true }
                            }
                        }
                    }
                } else {
                    Spacer()
                }
            }
            .navigationTitle(host.isEmpty ? "eBay" : host)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(bot.visibleIsCheck ? "Cancel" : "Done") { bot.cancelCheck() }
                }
            }
        }
        .interactiveDismissDisabled()
    }
}
