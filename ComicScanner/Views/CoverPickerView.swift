import SwiftUI

@MainActor
@Observable
final class CoverPickerModel {
    var covers: [SoldListing] = []
    var loading = true
    var problem: String?
    /// Sold listings found by barcode — exact matches for this book, used as a head start on prices.
    private(set) var soldByBarcode: [SoldListing] = []
    private var started = false

    func load(_ barcode: ComicBarcode, bot: WebBot) async {
        guard !started else { return }
        started = true
        loading = true
        defer { loading = false }

        var codes: [String] = []
        if let full = barcode.fullUPC { codes.append(full) }
        codes.append(barcode.base)

        for code in codes {
            for sold in [false, true] {
                do {
                    let found = try await EbaySoldSearch.listingsForBarcode(code, sold: sold, bot: bot)
                    if sold { soldByBarcode = merge(soldByBarcode, found) }
                    add(found)
                } catch {
                    if error.isCancellation { started = false; return }
                    problem = error.localizedDescription
                }
            }
            if !covers.isEmpty { break }
        }

        if covers.isEmpty {
            if problem == nil { problem = "No eBay listings show this barcode. Enter the details instead." }
            return
        }
        problem = nil

        // Start fetching sold prices for the most likely title while you choose.
        let likely = spec(for: covers[0], barcode: barcode)
        var common = likely
        common.title = mostCommonSeries(barcode: barcode) ?? likely.title
        SoldCache.shared.prefetch(for: common, seed: soldByBarcode, bot: bot)
    }

    /// The details for the cover you tapped: title, issue, variant/exclusive wording, photo.
    func spec(for listing: SoldListing, barcode: ComicBarcode) -> ComicSpec {
        var spec = barcode.spec
        if spec.issue.isEmpty, let issue = EbaySoldSearch.issueGuess(from: listing.title) {
            spec.issue = issue
        }
        spec.title = mostCommonSeries(barcode: barcode) ?? EbaySoldSearch.seriesGuess(from: listing.title, issue: spec.issue)
        let guess = EbaySoldSearch.variantGuess(from: listing.title, series: spec.title)
        spec.variant = guess.variant
        spec.exclusive = guess.exclusive
        spec.coverImageURL = listing.largeImageURL?.absoluteString ?? ""
        spec.notes = ""
        return spec
    }

    /// The series title most listings agree on (sellers word titles differently).
    private func mostCommonSeries(barcode: ComicBarcode) -> String? {
        var counts: [String: (count: Int, title: String)] = [:]
        for listing in covers {
            let issue = barcode.issueNumber.map(String.init) ?? EbaySoldSearch.issueGuess(from: listing.title) ?? ""
            let series = EbaySoldSearch.seriesGuess(from: listing.title, issue: issue)
            guard series.count >= 3 else { continue }
            let key = series.lowercased()
            counts[key] = ((counts[key]?.count ?? 0) + 1, counts[key]?.title ?? series)
        }
        return counts.values.max { $0.count < $1.count }?.title
    }

    private func add(_ listings: [SoldListing]) {
        var seenImages = Set(covers.map(imageKey))
        for listing in listings where listing.imageURL != nil && covers.count < 36 {
            let key = imageKey(listing)
            guard !seenImages.contains(key), !covers.contains(where: { $0.id == listing.id }) else { continue }
            seenImages.insert(key)
            covers.append(listing)
        }
    }

    /// eBay image URLs differ only by size suffix for the same photo.
    private func imageKey(_ listing: SoldListing) -> String {
        replacing(#"s-l\d+\.\w+$"#, in: listing.imageURL?.absoluteString ?? listing.id, with: "")
    }
}

/// After a barcode scan: photos of listings with that barcode. Tap the cover that matches yours.
struct CoverPickerView: View {
    let barcode: ComicBarcode

    @Environment(WebBot.self) private var bot
    @State private var model = CoverPickerModel()

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(model.covers) { listing in
                        NavigationLink(value: Route.comps(model.spec(for: listing, barcode: barcode))) {
                            CoverTile(listing: listing)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if model.loading {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(bot.status.isEmpty ? "Finding covers…" : bot.status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                if let problem = model.problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                NavigationLink(value: Route.spec(barcode.spec)) {
                    Label(model.covers.isEmpty ? "Enter the details" : "None of these — enter the details",
                          systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.loading && model.covers.isEmpty)
            }
            .padding()
        }
        .navigationTitle("Pick your cover")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(barcode, bot: bot) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tap the cover that matches yours")
                .font(.headline)
            HStack(spacing: 8) {
                Text(barcode.formattedBase).monospacedDigit()
                if let issue = barcode.issueNumber { Text("· #\(issue)") }
                if let cover = barcode.coverVariant { Text("· cover \(cover)") }
                if let printing = barcode.printing, printing > 1 { Text("· \(ordinal(printing)) print") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct CoverTile: View {
    let listing: SoldListing

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: listing.largeImageURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    AsyncImage(url: listing.imageURL) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Color.secondary.opacity(0.15)
                    }
                default:
                    Color.secondary.opacity(0.15)
                        .overlay { ProgressView() }
                }
            }
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(listing.title)
                .font(.caption2)
                .lineLimit(3)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}
