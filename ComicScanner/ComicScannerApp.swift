import SwiftUI
import SwiftData

@main
struct ComicScannerApp: App {
    @State private var bot = WebBot()

    init() {
        Prefs.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(bot)
        }
        .modelContainer(for: CollectionItem.self)
    }
}

struct RootView: View {
    @Environment(WebBot.self) private var bot

    var body: some View {
        @Bindable var bot = bot

        TabView {
            ScanView()
                .tabItem { Label("Scan", systemImage: "barcode.viewfinder") }
            LookUpView()
                .tabItem { Label("Look Up", systemImage: "magnifyingglass") }
            CollectionView()
                .tabItem { Label("Collection", systemImage: "books.vertical") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
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

/// Screens reachable from the Scan and Look Up tabs.
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
            case .barcode, .cert, .spec:
                SpecEditorView(source: route)
            case .comps(let spec):
                CompsView(spec: spec)
            }
        }
    }
}

enum Prefs {
    static let includeShipping = "includeShipping"
    static let includeBestOffer = "includeBestOffer"
    static let comicsOnly = "comicsOnly"

    static func register() {
        UserDefaults.standard.register(defaults: [
            includeShipping: true,
            includeBestOffer: false,
            comicsOnly: true,
        ])
    }

    static var compOptions: CompOptions {
        CompOptions(
            includeShipping: UserDefaults.standard.bool(forKey: includeShipping),
            includeBestOffer: UserDefaults.standard.bool(forKey: includeBestOffer)
        )
    }

    static var searchComicsOnly: Bool { UserDefaults.standard.bool(forKey: comicsOnly) }
}
