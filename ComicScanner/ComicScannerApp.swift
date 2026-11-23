import SwiftUI
import SwiftData

@main
struct ComicScannerApp: App {
    @State private var bot = WebBot()
    @State private var cart = DealCart()
    @State private var appState = AppState()

    init() {
        Prefs.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(bot)
                .environment(cart)
                .environment(appState)
        }
        .modelContainer(for: [CollectionItem.self, Deal.self, Show.self])
    }
}

@MainActor
@Observable
final class AppState {
    enum Tab: Hashable { case scan, lookUp, deal, collection, shows }
    var tab: Tab = .scan
}

struct RootView: View {
    @Environment(WebBot.self) private var bot
    @Environment(DealCart.self) private var cart
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var bot = bot
        @Bindable var appState = appState

        TabView(selection: $appState.tab) {
            ScanView()
                .tabItem { Label("Scan", systemImage: "barcode.viewfinder") }
                .tag(AppState.Tab.scan)
            LookUpView()
                .tabItem { Label("Look Up", systemImage: "magnifyingglass") }
                .tag(AppState.Tab.lookUp)
            DealView()
                .tabItem { Label("Deal", systemImage: "arrow.left.arrow.right") }
                .badge(cart.lines.count)
                .tag(AppState.Tab.deal)
            CollectionView()
                .tabItem { Label("Inventory", systemImage: "books.vertical") }
                .tag(AppState.Tab.collection)
            ShowsView()
                .tabItem { Label("Shows", systemImage: "tent") }
                .tag(AppState.Tab.shows)
        }
        // The bot's browser lives here, invisible, so pages load and run normally.
        .background {
            WebViewContainer(webView: bot.webView, hidden: true)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .sheet(isPresented: $bot.showingWebView) {
            BotWebSheet()
        }
    }
}

/// Screens reachable from the Scan, Look Up and Inventory tabs.
enum Route: Hashable {
    case barcode(ComicBarcode)
    case cert(SlabCert)
    case spec(ComicSpec)
    case comps(ComicSpec)
}

extension View {
    func comicDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .barcode(let barcode):
                CoverPickerView(barcode: barcode)
            case .cert, .spec:
                SpecEditorView(source: route)
            case .comps(let spec):
                CompsView(spec: spec)
            }
        }
    }
}

/// Lets a screen deep in a tab jump back to the tab's first screen (e.g. back to the scanner after adding a book to a deal).
struct PopToRoot {
    let action: () -> Void
    init(_ action: @escaping () -> Void = {}) { self.action = action }
    func callAsFunction() { action() }
}

private struct PopToRootKey: EnvironmentKey {
    static let defaultValue = PopToRoot()
}

extension EnvironmentValues {
    var popToRoot: PopToRoot {
        get { self[PopToRootKey.self] }
        set { self[PopToRootKey.self] = newValue }
    }
}

enum Prefs {
    static let includeShipping = "includeShipping"
    static let includeBestOffer = "includeBestOffer"
    static let comicsOnly = "comicsOnly"
    static let buyPercentKey = "buyPercent"
    static let tradePercentKey = "tradePercent"
    static let roundOffersKey = "roundOffers"
    static let buysForSaleKey = "buysForSale"
    static let gradingFeeKey = "gradingFee"
    static let activeShowKey = "activeShow"
    static let returnToScannerKey = "returnToScanner"

    static func register() {
        UserDefaults.standard.register(defaults: [
            includeShipping: true,
            includeBestOffer: false,
            comicsOnly: true,
            buyPercentKey: 60,
            tradePercentKey: 75,
            roundOffersKey: true,
            buysForSaleKey: true,
            gradingFeeKey: 40,
            returnToScannerKey: true,
        ])
    }

    static var compOptions: CompOptions {
        CompOptions(
            includeShipping: UserDefaults.standard.bool(forKey: includeShipping),
            includeBestOffer: UserDefaults.standard.bool(forKey: includeBestOffer)
        )
    }

    static var searchComicsOnly: Bool { UserDefaults.standard.bool(forKey: comicsOnly) }
    static var buyPercent: Int { UserDefaults.standard.integer(forKey: buyPercentKey) }
    static var tradePercent: Int { UserDefaults.standard.integer(forKey: tradePercentKey) }
    static var roundOffers: Bool { UserDefaults.standard.bool(forKey: roundOffersKey) }
    static var buysGoForSale: Bool { UserDefaults.standard.bool(forKey: buysForSaleKey) }
    static var gradingFeeCents: Int { UserDefaults.standard.integer(forKey: gradingFeeKey) * 100 }
    static var returnToScanner: Bool { UserDefaults.standard.bool(forKey: returnToScannerKey) }

    static var activeShowRef: UUID? {
        get { UserDefaults.standard.string(forKey: activeShowKey).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: activeShowKey) }
    }
}
