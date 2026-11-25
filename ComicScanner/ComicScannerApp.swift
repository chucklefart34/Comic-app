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
        .modelContainer(for: [ComicRecord.self, CoverPrint.self, BarcodeMemory.self,
                             SaleRecord.self, AskingRecord.self, PriceSnapshot.self, ImportLog.self])
    }
}

struct RootView: View {
    @Environment(WebBot.self) private var bot
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
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
            PricesScreen()
                .tabItem { Label("Prices", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(2)
            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(3)
        }
        .task { await AutoUpdater.runIfDue(context: modelContext, bot: bot) }
        .task { await ComicCatalog.shared.updateIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await AutoUpdater.runIfDue(context: modelContext, bot: bot) } }
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
    static let autoUpdateDaysKey = "autoUpdateDays"
    static let lastAutoUpdateKey = "lastAutoUpdate"

    static func register() {
        UserDefaults.standard.register(defaults: [
            includeShipping: true,
            includeBestOffer: false,
            comicsOnly: true,
            autoCaptureKey: true,
            autoUpdateDaysKey: 7,
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

/// Keeps collection prices fresh: when the app opens, re-prices saved comics older than your chosen interval.
/// One lookup at a time, a moment apart, so eBay isn't hammered. (iOS doesn't let apps run web lookups reliably
/// in the background, so this happens while the app is open.)
@MainActor
enum AutoUpdater {
    static var running = false
    static var progress = ""

    static func runIfDue(context: ModelContext, bot: WebBot) async {
        let days = UserDefaults.standard.integer(forKey: Prefs.autoUpdateDaysKey)
        guard days > 0, !running, NetworkMonitor.shared.isOnline else { return }
        let last = UserDefaults.standard.double(forKey: Prefs.lastAutoUpdateKey)
        guard Date().timeIntervalSince1970 - last > 6 * 3600 else { return }  // check at most every 6 hours

        let interval = Double(days) * 86_400
        let descriptor = FetchDescriptor<ComicRecord>(predicate: #Predicate { $0.inCollection })
        let due = ((try? context.fetch(descriptor)) ?? []).filter {
            guard let pricedAt = $0.pricedAt else { return true }
            return Date().timeIntervalSince(pricedAt) > interval
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Prefs.lastAutoUpdateKey)
        guard !due.isEmpty else { return }

        running = true
        defer { running = false; progress = "" }
        for (index, record) in due.prefix(25).enumerated() {
            progress = "Updating prices \(index + 1) of \(min(due.count, 25))"
            if let valuation = try? await PricingService.valuation(for: record.spec, bot: bot, context: context, forceRefresh: true) {
                record.setValuation(valuation)
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }
}
