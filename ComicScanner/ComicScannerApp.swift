import SwiftData
import SwiftUI

@main
struct ComicScannerApp: App {
    @State private var bot = WebBot()

    init() {
        Prefs.register()
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Theme.background)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(bot)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
        }
        .modelContainer(for: [ComicRecord.self, CoverPrint.self, BarcodeMemory.self])
    }
}

struct RootView: View {
    @Environment(WebBot.self) private var bot
    @State private var tab = 0

    var body: some View {
        @Bindable var bot = bot

        TabView(selection: $tab) {
            ScanScreen()
                .tabItem { Label("Scan", systemImage: "viewfinder") }
                .tag(0)
            CollectionScreen()
                .tabItem { Label("Collection", systemImage: "books.vertical.fill") }
                .tag(1)
            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(2)
        }
        // The pricing bot's browser lives here, invisible, so pages load normally.
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

enum Prefs {
    static let includeShipping = "includeShipping"
    static let includeBestOffer = "includeBestOffer"
    static let comicsOnly = "comicsOnly"
    static let autoCaptureKey = "autoCapture"

    static func register() {
        UserDefaults.standard.register(defaults: [
            includeShipping: true,
            includeBestOffer: false,
            comicsOnly: true,
            autoCaptureKey: true,
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
