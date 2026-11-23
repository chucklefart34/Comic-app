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
        if case BotError.cancelled = self { return true }
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
    var status = ""

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        webView.navigationDelegate = navigator
        webView.allowsBackForwardNavigationGestures = true
    }

    /// Loads `url`, waits until `readyScript` returns true (if given), then returns what `extractScript` returns.
    func fetch(
        _ url: URL,
        site: String,
        readyScript: String? = nil,
        extractScript: String,
        minimumGap: TimeInterval = 2.5
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
        try await navigator.load(url, in: webView)
        try await waitOutSecurityCheck(site: site)

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
        guard !busy else { return }
        webViewMessage = message
        webView.load(URLRequest(url: url))
        showingWebView = true
    }

    func cancelCheck() {
        userCancelled = true
        showingWebView = false
    }

    func clearCookies() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await store.removeData(ofTypes: types, modifiedSince: .distantPast)
    }

    // MARK: - Security checks

    private static let checkScript = """
    (() => {
      const text = (document.title || '') + ' ' + (document.body ? document.body.innerText.slice(0, 2000) : '');
      return /pardon our interruption|verify you are (a )?human|are you a robot|checking your browser|just a moment|security check|captcha|press (and|&) hold|unusual traffic/i.test(text);
    })()
    """

    private func onSecurityCheck() async -> Bool {
        (try? await webView.evaluateJavaScript(Self.checkScript)) as? Bool ?? false
    }

    private func waitOutSecurityCheck(site: String) async throws {
        guard await onSecurityCheck() else { return }

        // Many checks clear by themselves after a few seconds.
        status = "\(site) is checking the connection…"
        for _ in 0..<16 {
            try await Task.sleep(nanoseconds: 500_000_000)
            if !(await onSecurityCheck()) { return }
        }

        // Still there: hand it to you.
        webViewMessage = "\(site) wants to make sure you're a person. Complete the check and the app will carry on."
        showingWebView = true
        defer { showingWebView = false }
        for _ in 0..<360 {  // up to 3 minutes
            try await Task.sleep(nanoseconds: 500_000_000)
            if userCancelled { throw BotError.cancelled }
            if !(await onSecurityCheck()) {
                try await Task.sleep(nanoseconds: 1_500_000_000)  // let the real page finish loading
                return
            }
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

/// Keeps the bot's web view inside the app's window (hidden), so pages run normally,
/// and moves it into the visible sheet when you need to see it.
final class WebViewHost: UIView {
    static weak var hidden: WebViewHost?

    let webView: WKWebView
    let isHiddenHost: Bool

    init(webView: WKWebView, hidden: Bool) {
        self.webView = webView
        self.isHiddenHost = hidden
        super.init(frame: .zero)
        if hidden { WebViewHost.hidden = self }
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            adopt()
        } else if !isHiddenHost {
            WebViewHost.hidden?.adopt()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if webView.superview === self, !isHiddenHost {
            webView.frame = bounds
        }
    }

    func adopt() {
        guard webView.superview !== self else { return }
        webView.removeFromSuperview()
        addSubview(webView)
        webView.frame = isHiddenHost ? CGRect(x: 0, y: 0, width: 390, height: 844) : bounds
        webView.autoresizingMask = isHiddenHost ? [] : [.flexibleWidth, .flexibleHeight]
    }
}

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    var hidden = false

    func makeUIView(context: Context) -> WebViewHost {
        WebViewHost(webView: webView, hidden: hidden)
    }

    func updateUIView(_ host: WebViewHost, context: Context) {
        if !hidden { host.adopt() }
    }
}

/// The sheet shown when a site needs you (security check, optional sign-in).
struct BotWebSheet: View {
    @Environment(WebBot.self) private var bot

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
                WebViewContainer(webView: bot.webView)
            }
            .navigationTitle(bot.webView.url?.host() ?? "Web")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { bot.cancelCheck() }
                }
            }
        }
        .interactiveDismissDisabled()
    }
}
