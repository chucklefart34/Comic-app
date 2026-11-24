# Comic Scanner

A personal iPhone app for comic collectors: point the camera at a comic, and it identifies the exact edition and shows what it's realistically worth from **actual sold sales**, by condition.

**Scan → identify → price, without going through extra screens.** The camera stays live. When a cover is held steady in the frame it's captured automatically (or tap the shutter), barcodes and CGC/PSA slab QR codes are read the moment they're seen, and a results card slides up from the bottom. Point at the next comic and it does it again.

## Features

**Scanning**
- Full-screen camera with a scanning frame, auto-capture when a cover is steady, manual shutter, flash and camera switch.
- Barcodes: the UPC plus the 5-digit add-on (issue number, cover, printing).
- CGC / PSA slab QR codes: reads the cert page for title, grade, label and signer.
- If the edition isn't certain, it shows the closest matches with their covers. Tap the right one; nothing is assumed.

**Identification**, best source first:
1. Barcodes and covers you've confirmed before: instant, and it learns as you go.
2. **VerseDB** (optional free token): matches a cover photo against its whole catalog, plus barcode lookup, variants, writer and cover artist, and key-issue notes.
3. eBay listings for the barcode, or for words read off the cover. Their photos are ranked by how much they **look like your copy** (using Apple's on-device image fingerprints).

**Pricing**
- From eBay **completed sales** only, never asking prices, for the same issue, cover and printing. Lots, reprints, other variants, signed copies, later printings and hidden Best Offer prices are left out.
- **Low / Mid / High**, using the number grade sellers put in the title: Low is under 5.0, Mid is 5.0–9.0, High is 9.2 and up. Slabbed sales are kept separate and shown by company and grade.
- Recent sales count more (half weight every 45 days), and prices far from the rest are dropped.
- **Confidence**: High (several recent sales), Medium (a few sales, a price guide, or slab sales), Low (estimate).
- With no sales of this issue, it gives an **Estimate**: from other grades of this book, from slab sales, or from other issues in the series. It's clearly labelled, or it shows **N/A** if there isn't enough to go on.
- Pick your copy's condition (Poor … Near Mint, or a CGC/CBCS/PSA grade) and that price is highlighted.

**Collection & history**
- Every scan is kept in History; tap the bookmark to save a comic to your Collection.
- Search, sort by title, publisher, value or scan date, see the total value and what you paid, export to CSV.
- The detail page has a large cover, full identification, prices by condition, slab prices, a price trend chart from real sales, every comp (counted and left out, with reasons), sources, and **Why is this comic valuable?** (VerseDB key-issue notes plus first appearances that sellers repeat in titles, labelled as such).
- You can correct anything by hand. Corrections are remembered for the next scan of that barcode or cover.

## Data sources

| Source | Used for | Needs |
|---|---|---|
| eBay sold listings | Prices (completed sales) and identification | Nothing |
| VerseDB | Cover-photo ID, barcode lookup, variants, credits, key issues | Free account token (personal use; 5 cover lookups a minute, 100 a day) |
| PriceCharting | Price-guide values (supporting) | Paid API token |
| GoCollect | — | Placeholder: API access must be requested and approved |
| CovrPrice | — | Placeholder: partner/paid access only |
| Key Collector, ComicBookRealm | — | Placeholder: no public API |

Tokens are added in Settings and stored in the iPhone Keychain. Nothing is hard-coded, and no backend is needed, since every service is called directly with your own token.

**Limits to know**
- eBay's terms restrict automated access. The app loads one public page at a time at a person's pace, for personal use. If eBay shows a "verify you're human" check, it's shown to you to complete.
- "AI estimate": there's no AI model in the app (that would need a paid API and a server). Estimates come from the rules above and are always labelled **Estimate · Low confidence**.
- Condition assessment from photos isn't built yet (marked in the app). It will be an estimate, never a CGC grade.

## Install

Every push to `main` builds an unsigned `ComicScanner.ipa` on the [Releases page](https://github.com/chucklefart34/Comic-app/releases/latest). Install it with **Sideloadly** or **AltStore** on a PC or Mac, using your Apple ID. On the iPhone, turn on Settings → Privacy & Security → Developer Mode. With a free Apple ID, re-sign every 7 days.

To build yourself: Xcode 16+, open `ComicScanner.xcodeproj`, set your team and bundle ID, then run on an iPhone (the camera doesn't work in the Simulator).

## Code layout

```
ComicScanner/
  ComicScannerApp.swift            Tabs (Scan / Collection / Settings), settings keys
  Camera/CameraModel.swift         AVFoundation camera, auto-capture, barcodes/QR, add-on digits
  Identification/Identifier.swift  Barcode / cover / text identification, learning, look-alike ranking
  Identification/VerseDBClient.swift
  Pricing/SaleClassifier.swift     Same edition? raw or slab? which grade?
  Pricing/PricingEngine.swift      Low/Mid/High, recency weighting, outliers, estimates, confidence
  Pricing/PricingService.swift     Providers (eBay, PriceCharting, placeholders) and caching
  Services/                        eBay page reader (WebBot), cover fingerprints, slab certs
  Models/                          ComicSpec, ComicRecord, Condition, learned covers/barcodes
  Views/                           Scan screen + results card, collection, detail, edit, settings
```
