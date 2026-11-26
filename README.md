# Comic Scanner

A personal iPhone app for comic collectors: point the camera at a comic, and it identifies the exact edition and shows what it's realistically worth from **actual sold sales**, by condition.

**Scan → identify → price, without going through extra screens.** The camera stays live. When a cover is held steady in the frame it's captured automatically (or tap the screen), barcodes and CGC/PSA slab QR codes are read the moment they're seen, and the book drops into a tray under the camera. Move straight to the next one while the first is still pricing.

## Features

**Scanning**
- Camera with a scanning frame, Auto (captures when a cover is steady) or Tap mode, light and camera switch.
- **Scan tray**: every book you scan becomes a card with its cover, price, condition, quantity and Comps. Each one identifies and prices itself in the background, so you never wait between books. Swipe between cards, see the running **Total**, and **Add N** saves them all to your Collection (one entry per copy).
- Barcodes: the UPC plus the 5-digit add-on (issue number, cover, printing). One scan per book; if the match is wrong, tap **Wrong? Scan barcode** on its card and scan the barcode to fix it.
- CGC / PSA slab QR codes: reads the cert page for title, grade, label and signer.
- If the edition isn't certain, the closest match is used and the card is flagged **Check match**: tap it (or the pencil) to pick the right cover, search, or scan the barcode as an extra photo.

**Identification**, best source first:
1. Barcodes and covers you've confirmed before: instant, and it learns as you go.
2. **VerseDB** (optional free token): matches a cover photo against its whole catalog, plus barcode lookup, variants, writer and cover artist, and key-issue notes.
3. eBay listings for the barcode, or for words read off the cover. Their photos are ranked by how much they **look like your copy** (using Apple's on-device image fingerprints).

**Pricing**
- From eBay **completed sales** only. Asking prices are saved separately and never counted as sales.
- Copies are never mixed: raw, raw signed, and each slab company + label (Universal, Signature Series, Qualified, Restored) + exact grade are separate price groups. A CGC 9.8 is priced only from CGC 9.8 Universal sales — not 9.6, not CBCS, not raw, not signed.
- Different editions are left out with the reason shown: lots, reprints/facsimiles, other issues, other variants or exclusives, other printings, newsstand vs direct, other signers, hidden Best Offer prices.
- **Median is the main value**, with average, lowest, highest and number of sales, for the last **30 / 90 / 180 / 365 days**, plus a trend (last 30 days vs the months before).
- **Low / Mid / High** for raw copies, from the number grade in the title: Low is under 5.0, Mid is 5.0–9.0, High is 9.2 and up.
- Recent sales count more (half weight every 45 days); outliers are dropped per group and grade.
- Each sale gets a **match confidence**. Doubtful ones are flagged "to check" and you can approve or reject any sale; your choice is remembered.
- **Confidence**: High (several recent, clear sales), Medium, Low (estimate). With no sales it gives a clearly labelled **Estimate**, or **N/A**.

**Prices tab (dashboard)**
- Every priced edition, its value history, sales by group and window, a chart, grade and company comparison, highest and most recent sales, asking prices, left-out sales with reasons, and a pricing log of every lookup (listings read, new sales, duplicates, errors).

**Stored on the phone (SwiftData)**
- `SaleRecord` — each sold listing, keyed by edition + eBay item number, so re-reading a page never adds duplicates. Sales build up over time, so history goes beyond what eBay shows.
- `AskingRecord` — active listings, kept apart from sales.
- `PriceSnapshot` — one value per edition per day, for price history.
- `ImportLog` — each lookup and what it found.
- Auto-update re-prices your collection in the background (daily, weekly or monthly; Settings).

**Collection & history**
- Every scan is kept in History; tap the bookmark to save a comic to your Collection.
- Search, sort by title, publisher, value or scan date, see the total value, what you paid, and **profit / loss** (with purchase date), export to CSV.
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
- eBay sometimes answers with an error page depending on how a page is requested, so the app tries a few ways (direct download or in-app browser, iPhone or desktop) and remembers the one that works. Settings → Test eBay pricing shows every attempt.
- eBay's terms restrict automated access. The app loads one public page at a time at a person's pace, for personal use. If eBay shows a "verify you're human" check, it's shown to you to complete.
- "AI estimate": there's no AI model in the app (that would need a paid API and a server). Estimates come from the rules above and are always labelled **Estimate · Low confidence**.
- Condition assessment from photos isn't built yet (marked in the app). It will be an estimate, never a CGC grade.

## Offline comic catalog (Marvel, DC & Image)

Every Marvel, DC and Image issue, variant and barcode lives on the phone, with links to their cover scans, so most
books are identified without VerseDB or any request limit:

- **Barcodes** are matched against the catalog instantly — exact issue, cover and printing.
- **Covers**: the series and issue number printed on the cover are looked up in the catalog, and your photo is
  compared with the catalog's cover scans for that issue (variants included) and with eBay photos. VerseDB is
  only asked about books the catalog doesn't know.

The **Build comic catalog** workflow (`.github/workflows/catalog.yml`, `scripts/catalog.py`) builds it from the
comics.org API with your free account, every day, inside comics.org's limit for registered accounts
(25 requests a minute, 2,000 a day — the job uses 1,800):

- once a week: new and upcoming issues, with barcodes, variants and cover links, from the on-sale list;
- first ~3 days: every Marvel, DC & Image series with all its issues and variants (adding a publisher later
  goes through the series list again; Dark Horse, IDW and BOOM! Studios ids are also known);
- next ~10 days: a cover link for every regular issue;
- after that: barcodes and variant covers for older issues, newest first, a batch each day.

(comics.org's website — and so its full data download — sits behind a Cloudflare check that GitHub's servers
can't pass, so the catalog is built from the API instead.) It's published to the `catalog` release; the app
checks once a day and downloads it when it has changed (Settings → Comic catalog → Update now). Only cover
*links* are stored — the phone loads a cover picture only when a scan needs it.

Setup (once): make a free account at comics.org, then in this repo go to Settings → Secrets and variables →
Actions and add `GCD_EMAIL` and `GCD_PASSWORD`. Then run the workflow from the Actions tab (it then runs daily by itself).

Catalog data from the [Grand Comics Database™](https://www.comics.org), licensed
[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).

## Internal pricing API

Everything runs on the phone, so there's no server. `Pricing/PricingAPI.swift` gives the same operations as a pricing API would:

| Endpoint | Function |
|---|---|
| `GET /comics/search` | `PricingAPI.search(_:context:)` |
| `GET /comics/:id` | `PricingAPI.comic(editionKey:context:)` |
| `GET /comics/:id/prices` | `PricingAPI.prices(for:bot:context:)` |
| `GET /comics/:id/sales` | `PricingAPI.sales(for:context:)` |
| `GET /comics/:id/trends` | `PricingAPI.trends(for:context:)` |
| `GET /comics/:id/grades` | `PricingAPI.grades(for:context:)` |
| `GET /collection/value` | `PricingAPI.collectionValue(context:)` |
| `GET /collection/performance` | `PricingAPI.collectionPerformance(context:)` |
| `GET /pricing/status` | `PricingAPI.pricingStatus(context:)` |

## Tests

`ComicScannerTests/` runs on an iPhone simulator in GitHub Actions before every release; a failing test blocks the IPA. It uses sample sales only (no network) and covers barcode/cert/search identification, variant, printing and newsstand matching, grade and slab-label parsing (including the ASM #300 CGC 9.8 vs 9.6 / CBCS 9.8 / raw / 2nd printing / signed case), listing parsing, duplicate detection, outliers, medians, time windows and trends, price history, the pricing API, combining photos, and collection profit/loss.

## Install

Every push to `main` builds an unsigned `ComicScanner.ipa` on the [Releases page](https://github.com/chucklefart34/Comic-app/releases/latest). Install it with **Sideloadly** or **AltStore** on a PC or Mac, using your Apple ID. On the iPhone, turn on Settings → Privacy & Security → Developer Mode. With a free Apple ID, re-sign every 7 days.

To build yourself: Xcode 16+, open `ComicScanner.xcodeproj`, set your team and bundle ID, then run on an iPhone (the camera doesn't work in the Simulator).

## Code layout

```
ComicScanner/
  ComicScannerApp.swift            Tabs (Scan / Collection / Prices / Settings), settings, auto-update
  Camera/CameraModel.swift         AVFoundation camera, auto-capture, barcodes/QR, add-on digits
  Identification/Identifier.swift  Barcode / cover / text identification, learning, look-alike ranking
  Identification/VerseDBClient.swift
  Pricing/SaleClassifier.swift     Same edition? raw or slab? which grade?
  Pricing/PricingEngine.swift      Low/Mid/High, recency weighting, outliers, estimates, confidence
  Pricing/PricingService.swift     Providers (eBay, PriceCharting, placeholders) and caching
  Pricing/SalesStore.swift         Saved sales, reviews, asking prices, snapshots, import log
  Pricing/PricingAPI.swift         Endpoint-style functions (see above)
  Services/                        eBay page reader (WebBot), cover fingerprints, slab certs
  Models/                          ComicSpec, ComicRecord, Condition, learned covers/barcodes
  Views/                           Scan, collection, prices dashboard, detail, edit, settings
ComicScannerTests/                 Unit tests with sample data
```
