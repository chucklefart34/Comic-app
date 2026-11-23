import SwiftUI

struct SettingsView: View {
    @Environment(WebBot.self) private var bot
    @AppStorage(Prefs.includeShipping) private var includeShipping = true
    @AppStorage(Prefs.includeBestOffer) private var includeBestOffer = false
    @AppStorage(Prefs.comicsOnly) private var comicsOnly = true
    @State private var cleared = false

    var body: some View {
        NavigationStack {
            Form {
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
                        bot.show(URL(string: "https://signin.ebay.com/")!,
                                 message: "Signing in is optional. It can mean fewer security checks. Close this when you're done.")
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
        }
    }
}
