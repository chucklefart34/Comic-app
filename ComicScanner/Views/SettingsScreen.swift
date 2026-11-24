import SwiftData
import SwiftUI

struct SettingsScreen: View {
    @Environment(WebBot.self) private var bot
    @Environment(\.modelContext) private var modelContext
    @AppStorage(Prefs.includeShipping) private var includeShipping = true
    @AppStorage(Prefs.includeBestOffer) private var includeBestOffer = false
    @AppStorage(Prefs.comicsOnly) private var comicsOnly = true
    @AppStorage(Prefs.autoCaptureKey) private var autoCapture = true

    @State private var verseDBToken = Tokens.verseDB ?? ""
    @State private var priceChartingToken = Tokens.priceCharting ?? ""
    @State private var learnedCovers = 0
    @State private var cleared = ""
    @State private var testing = false
    @State private var testResult = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Auto-capture covers", isOn: $autoCapture)
                } header: {
                    Text("Scanning")
                } footer: {
                    Text("When on, the app scans a cover as soon as it's held steady in the frame. Barcodes and slab QR codes are always read.")
                }

                Section {
                    Toggle("Include shipping in prices", isOn: $includeShipping)
                    Toggle("Count Best Offer sales", isOn: $includeBestOffer)
                    Toggle("Comics category only", isOn: $comicsOnly)
                } header: {
                    Text("Pricing")
                } footer: {
                    Text("Low = under 5.0, Mid = 5.0–9.0, High = 9.2 and up, from the grades sellers state in sold listings. Slabbed sales are priced separately. Best Offer sales show the asking price, not what it sold for, so they're left out by default.")
                }

                Section {
                    sourceRow("eBay sold listings", status: .active,
                              detail: "Completed sales only, read from eBay's public pages. No account needed.")
                    VStack(alignment: .leading, spacing: 6) {
                        sourceRow("VerseDB", status: verseDBToken.trimmed.isEmpty ? .needsToken("") : .active,
                                  detail: "Free account. Adds cover-photo identification against its whole catalog, barcode lookup, variants, creators and key-issue notes. Free plan: 5 cover lookups a minute, 100 a day; personal use.")
                        SecureField("VerseDB API token", text: $verseDBToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { Keychain.set(verseDBToken, for: Tokens.verseDBKey) }
                        Link("Create a token at versedb.com", destination: URL(string: "https://versedb.com/my/apps/custom/create")!)
                            .font(.caption)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        sourceRow("PriceCharting", status: PriceChartingProvider().status,
                                  detail: "Paid subscription. Adds price-guide values as supporting data.")
                        SecureField("PriceCharting API token", text: $priceChartingToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { Keychain.set(priceChartingToken, for: Tokens.priceChartingKey) }
                    }
                    ForEach(PlaceholderProvider.all, id: \.name) { provider in
                        sourceRow(provider.name, status: provider.status, detail: provider.reason)
                    }
                } header: {
                    Text("Data sources")
                } footer: {
                    Text("Tokens are stored in the iPhone's Keychain and sent only to that service.")
                }

                Section {
                    Button {
                        Task { await testPricing() }
                    } label: {
                        HStack {
                            Label(testing ? "Checking eBay…" : "Test eBay pricing", systemImage: "stethoscope")
                            if testing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(testing)
                    if !testResult.isEmpty {
                        Text(testResult).font(.caption).foregroundStyle(Theme.secondary).textSelection(.enabled)
                    }
                    if !EbayPages.last.query.isEmpty {
                        Text("Last search: \"\(EbayPages.last.query)\" — \(EbayPages.last.summary)")
                            .font(.caption2).foregroundStyle(Theme.tertiary).textSelection(.enabled)
                    }
                } header: {
                    Text("Troubleshooting")
                } footer: {
                    Text("Looks up sold copies of Amazing Spider-Man #300 and reports what eBay returned.")
                }

                Section {
                    LabeledContent("Covers learned", value: "\(learnedCovers)")
                    Button("Clear cached prices") {
                        PricingService.clearCache()
                        cleared = "Price cache cleared"
                    }
                    Button("Forget learned covers and barcodes", role: .destructive) {
                        try? modelContext.delete(model: CoverPrint.self)
                        try? modelContext.delete(model: BarcodeMemory.self)
                        learnedCovers = 0
                        cleared = "Learned covers forgotten"
                    }
                    if !cleared.isEmpty { Text(cleared).font(.caption).foregroundStyle(Theme.good) }
                } header: {
                    Text("Memory")
                } footer: {
                    Text("Every cover and barcode you confirm is remembered on this phone, so it's recognised instantly next time.")
                }

                Section {
                    Button("Sign in to eBay (optional)") {
                        bot.show(URL(string: "https://signin.ebay.com/")!,
                                 message: "Optional. Signing in can mean fewer security checks. Close this when you're done.")
                    }
                    Button("Clear eBay data", role: .destructive) {
                        Task { await bot.clearCookies(); cleared = "eBay data cleared" }
                    }
                } header: {
                    Text("eBay")
                } footer: {
                    Text("eBay's terms restrict automated access. The app loads one page at a time like a person browsing, for personal use. If eBay asks you to prove you're human, you'll be shown the check.")
                }

                Section("About pricing") {
                    Text("Prices come from actual sold listings of the same issue, cover and printing, with recent sales weighted more and outliers left out. When there aren't enough sales, the app shows an Estimate (from slab sales or other issues of the series) with low confidence — or N/A if there isn't enough to go on.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondary)
                }
            }
            .navigationTitle("Settings")
            .onDisappear {
                Keychain.set(verseDBToken, for: Tokens.verseDBKey)
                Keychain.set(priceChartingToken, for: Tokens.priceChartingKey)
            }
            .onChange(of: verseDBToken) { _, value in Keychain.set(value, for: Tokens.verseDBKey) }
            .onChange(of: priceChartingToken) { _, value in Keychain.set(value, for: Tokens.priceChartingKey) }
            .task { learnedCovers = CoverRecognizer.learnedCount(context: modelContext) }
        }
        .preferredColorScheme(.dark)
    }

    private func testPricing() async {
        testing = true
        defer { testing = false }
        var spec = ComicSpec()
        spec.title = "Amazing Spider-Man"
        spec.issue = "300"
        do {
            let valuation = try await PricingService.valuation(for: spec, bot: bot, forceRefresh: true)
            let counted = valuation.sales.filter(\.counted).count
            let price = valuation.marketCents.map(formatCents) ?? "N/A"
            testResult = "✓ \(EbayPages.last.summary)\n\(counted) matching sales · market \(price)"
        } catch {
            testResult = "✗ \(error.localizedDescription)\n\(EbayPages.last.summary)"
        }
    }

    private func sourceRow(_ name: String, status: ProviderStatus, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(name).font(.subheadline.weight(.semibold))
                Spacer()
                Text(status.label)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .foregroundStyle(status == .active ? Theme.good : Theme.secondary)
                    .background((status == .active ? Theme.good : Theme.tertiary).opacity(0.15), in: Capsule())
            }
            Text(detail).font(.caption).foregroundStyle(Theme.secondary)
        }
    }
}
