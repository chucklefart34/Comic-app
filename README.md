# Comic Scanner

An iPhone app that scans comics and prices them from **real eBay sold listings**. It needs no accounts or API keys.

It prices the exact copy you have, not just the issue: **variants, store exclusives, later printings, signed books, and CGC / PSA (and CBCS / PGX) slabs** at their exact grade and label.

## How it works

**Raw books**
1. Point the Scan tab at the barcode. The app reads the UPC plus the small 5-digit add-on beside it (issue number, cover variant, printing). You confirm the digits.
2. The app searches eBay for listings with that barcode and suggests titles. Tap the one that matches.
3. Add anything that changes the price: variant (e.g. `Cover B`, `Virgin 1:25`, `Campbell`), exclusive (`Mile High`, `SDCC`), printing, signature.

No barcode (older books)? Tap words the camera reads off the cover, or type the title in **Look Up**.

**Slabs**
- Point the Scan tab at the **QR code on a CGC or PSA label**, or type the cert number in Look Up. The app opens the cert page and fills in title, issue, grade, label (Universal / Signature Series / Qualified / Restored), signer and variant notes. You check the details and continue.

**Pricing (the bot)**
- The app loads eBay's public sold-listings search inside a hidden Safari view, as you would by hand. It fetches one page at a time, a few seconds apart.
- It checks every sale's title against your book and **leaves out what doesn't match**: other grades, other grading companies, Qualified/Restored labels, signed vs unsigned, the wrong signer, other covers, ratio variants, exclusives, 2nd printings, lots, facsimiles and reprints.
- It shows the **typical sale** (median), the range most copies sell in, low/high, and every sale with why it was counted or left out. Tap any sale to count it or leave it out.
- Best Offer sales are left out by default because eBay hides the real price. You can change this in Settings.
- If eBay or CGC shows a "verify you're human" check, the page opens so **you** complete it, then the app carries on. The app never tries to get around these checks.

**Collection**
- Save books with their price, update every value with one tap, swipe to delete, and export to CSV.

## Build and run

You need a Mac with **Xcode 16+** and an iPhone XS/XR or newer on **iOS 17+**. The camera scanner doesn't run in the Simulator; Look Up and pricing do.

1. Open `ComicScanner.xcodeproj`.
2. Select the **ComicScanner** target → **Signing & Capabilities**, pick your Team (a free Apple ID works), and change the Bundle Identifier from `com.example.ComicScanner` to something unique.
3. Plug in your iPhone, select it, and press **Run** (⌘R). The first time, trust the developer profile on the phone under Settings → General → VPN & Device Management.

On an older Xcode, run `xcodegen generate` (from [XcodeGen](https://github.com/yonaskolb/XcodeGen)) to rebuild the project from `project.yml`.

## Good to know

- **eBay's rules:** eBay's user agreement restricts automated access to its site. This app is built for personal use at a human pace: one search at a time, a few seconds apart, with nothing done in the background. Don't publish it or run bulk jobs with it.
- **Page changes:** if eBay, CGC or PSA redesign their pages, the parts that read them may need small updates (`EbaySoldSearch.extractScript`, `CertLookup.extractScript`).
- **Matching is based on listing titles.** Sellers make mistakes, so check the "Counted" list on books that matter. Few sales means a rough number.
- **CBCS / PGX:** slabs are priced the same way, but the cert page isn't read automatically, so enter the details from the label.

## Code layout

```
ComicScanner/
  ComicScannerApp.swift          App, tabs, routes, settings keys
  Models/ComicSpec.swift         The exact book: variant, exclusive, printing, signature, grade → eBay search
  Models/ComicModels.swift       Barcode + slab cert parsing, regex helpers
  Models/CollectionItem.swift    Saved books (SwiftData)
  Services/WebBot.swift          Hidden Safari view that loads pages; hands security checks to you
  Services/EbaySoldSearch.swift  Builds sold-listing searches and reads results off the page
  Services/CompMatcher.swift     Decides which sales match your book; median, range, outliers
  Services/CertLookup.swift      Reads CGC / PSA cert pages
  Views/ScanView.swift           Camera: UPC + add-on, slab QR codes, cover text
  Views/SpecEditorView.swift     Look Up tab + comic details form
  Views/CompsView.swift          Sold prices screen
  Views/CollectionView.swift     Collection, update all, CSV export
  Views/SettingsView.swift       Pricing options, optional eBay sign-in
```
