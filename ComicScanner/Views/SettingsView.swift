import SwiftUI

struct SettingsView: View {
    @Environment(WebBot.self) private var bot
    @AppStorage(Prefs.includeShipping) private var includeShipping = true
    @AppStorage(Prefs.includeBestOffer) private var includeBestOffer = false
    @AppStorage(Prefs.comicsOnly) private var comicsOnly = true
    @AppStorage(Prefs.buyPercentKey) private var buyPercent = 60
    @AppStorage(Prefs.tradePercentKey) private var tradePercent = 75
    @AppStorage(Prefs.roundOffersKey) private var roundOffers = true
    @AppStorage(Prefs.buysForSaleKey) private var buysForSale = true
    @AppStorage(Prefs.gradingFeeKey) private var gradingFee = 40
    @AppStorage(Prefs.returnToScannerKey) private var returnToScanner = true
    @AppStorage(Prefs.shelfPercentKey) private var shelfPercent = 100
    @AppStorage(Prefs.shelfRoundingKey) private var shelfRounding = ShelfRounding.ninetyNine.rawValue
    @Environment(\.dismiss) private var dismiss
    @State private var cleared = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Shelf price: \(shelfPercent)% of market", value: $shelfPercent, in: 50...300, step: 5)
                    Picker("Rounding", selection: $shelfRounding) {
                        ForEach(ShelfRounding.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                } header: {
                    Text("Shelf pricing")
                } footer: {
                    Text("Every price screen shows a shelf price based on the average sold price. Example: $24.10 market at 100% → $23.99.")
                }

                Section {
                    Stepper("Buy offers: \(buyPercent)% of market", value: $buyPercent, in: 0...150, step: 5)
                    Stepper("Trade credit: \(tradePercent)% of market", value: $tradePercent, in: 0...150, step: 5)
                    Toggle("Round offers down to whole dollars", isOn: $roundOffers)
                    Toggle("Bought books go straight to For sale", isOn: $buysForSale)
                    Toggle("Back to scanner after adding to a deal", isOn: $returnToScanner)
                    Stepper("Grading cost: $\(gradingFee)", value: $gradingFee, in: 0...500, step: 5)
                } header: {
                    Text("Deals")
                } footer: {
                    Text("Market value is the average sold price on eBay for that exact copy. You can always change any single price in the deal. Grading cost (fee + shipping) is used by the Worth grading? check.")
                }

                Section {
                    Toggle("Include shipping in prices", isOn: $includeShipping)
                    Toggle("Count Best Offer sales", isOn: $includeBestOffer)
                    Toggle("Search the Comics category only", isOn: $comicsOnly)
                } header: {
                    Text("Pricing")
                } footer: {
                    Text("When a Best Offer is accepted, eBay hides the real price and shows the asking price, so those sales are left out unless you turn this on.")
                }

                Section {
                    Button("Sign in to eBay (optional)") {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                            bot.show(URL(string: "https://signin.ebay.com/")!,
                                     message: "Signing in is optional. It can mean fewer security checks. Close this when you're done.")
                        }
                    }
                    Button("Sign out and clear eBay data", role: .destructive) {
                        Task {
                            await bot.clearCookies()
                            cleared = true
                        }
                    }
                    if cleared {
                        Label("Cleared", systemImage: "checkmark").foregroundStyle(.green)
                    }
                } header: {
                    Text("eBay")
                } footer: {
                    Text("No account is needed. The app reads eBay's public sold listings the same way Safari does, one page at a time. If eBay asks you to prove you're a person, the page opens so you can do it yourself.")
                }

                Section("How it works") {
                    Text("Raw books: scan the barcode. The 5-digit code next to it gives the issue, cover and printing. Then add the variant, exclusive and signature details.")
                    Text("Slabs: scan the QR code on a CGC or PSA label, or type the cert number in Look Up. The app reads the cert page for title, grade, label and signatures.")
                    Text("Prices: the app searches eBay sold listings, leaves out sales that don't match your exact book (grade, company, cover, signature, printing, lots, reprints) and shows the typical price.")
                }
                .font(.callout)
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
