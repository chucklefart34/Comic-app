import SwiftUI
import SwiftData

@MainActor
@Observable
final class CompsModel {
    enum Status: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    var status: Status = .idle
    var listings: [SoldListing] = []
    var overrides: [String: Bool] = [:]
    var verdicts: [CompVerdict] = []
    var stats: PriceStats?

    var included: [CompVerdict] { verdicts.filter(\.included) }
    var excluded: [CompVerdict] { verdicts.filter { !$0.included } }

    /// True while a quick result is on screen and the exact search is still running.
    var refining = false
    var note: String?

    func load(spec: ComicSpec, bot: WebBot) async {
        note = nil

        // Head start: sales fetched while you were picking the cover.
        if spec.customQuery.trimmed.isEmpty,
           let prefetched = SoldCache.shared.results(for: spec),
           let pool = try? await prefetched.value, !pool.isEmpty {
            listings = pool
            recompute(spec: spec)
            status = .loaded
            refining = true
            defer { refining = false }
            do {
                let exact = try await EbaySoldSearch.soldListings(for: spec, bot: bot, comicsOnly: Prefs.searchComicsOnly)
                listings = merge(listings, exact)
                recompute(spec: spec)
            } catch {
                if !error.isCancellation { note = "Showing early results — couldn't finish the full search (\(error.localizedDescription))." }
            }
            return
        }

        status = .loading
        do {
            listings = try await EbaySoldSearch.soldListings(for: spec, bot: bot, comicsOnly: Prefs.searchComicsOnly)
            recompute(spec: spec)
            status = .loaded
        } catch {
            status = error.isCancellation ? .idle : .failed(error.localizedDescription)
        }
    }

    func toggle(_ verdict: CompVerdict, spec: ComicSpec) {
        overrides[verdict.id] = !verdict.included
        recompute(spec: spec)
    }

    func recompute(spec: ComicSpec) {
        let result = CompMatcher.evaluate(listings, spec: spec, options: Prefs.compOptions, overrides: overrides)
        verdicts = result.verdicts
        stats = result.stats
    }
}

/// Sold eBay prices for one exact book: median, range, and every sale with why it was counted or not.
struct CompsView: View {
    let spec: ComicSpec
    var item: CollectionItem? = nil

    @Environment(WebBot.self) private var bot
    @Environment(\.modelContext) private var modelContext
    @State private var model = CompsModel()
    @State private var saved = false
    @State private var showExcluded = false

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    if let cover = URL(string: spec.coverImageURL), !spec.coverImageURL.isEmpty {
                        AsyncImage(url: cover) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFit()
                            } else {
                                Color.secondary.opacity(0.15)
                            }
                        }
                        .frame(width: 80, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(spec.displayTitle).font(.headline)
                        Text(spec.detailLine).font(.subheadline).foregroundStyle(.secondary)
                        NavigationLink(value: Route.spec(spec)) {
                            Label("Edit details", systemImage: "slider.horizontal.3")
                                .font(.subheadline)
                        }
                        .padding(.top, 4)
                    }
                }
            } footer: {
                Text("Wrong cover, signed or graded? Tap Edit details.")
            }

            switch model.status {
            case .idle, .loading:
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading) {
                            Text("Checking eBay sold listings…")
                            if !bot.status.isEmpty {
                                Text(bot.status).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            case .failed(let message):
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Try again") { Task { await model.load(spec: spec, bot: bot) } }
                }
            case .loaded:
                summarySection
                saveSection
                compsSections
            }

            Section {
                Link(destination: EbaySoldSearch.soldURL(query: spec.ebayQuery, comicsOnly: Prefs.searchComicsOnly)) {
                    Label("Open this search on eBay", systemImage: "safari")
                }
            } footer: {
                Text("Searched for: \(spec.ebayQuery)")
                    .font(.caption.monospaced())
            }
        }
        .navigationTitle("Sold prices")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model.status == .idle { await model.load(spec: spec, bot: bot) }
        }
        .refreshable { await model.load(spec: spec, bot: bot) }
    }

    // MARK: Sections

    @ViewBuilder
    private var summarySection: some View {
        Section {
            if let stats = model.stats {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Average sold price").font(.subheadline).foregroundStyle(.secondary)
                        if model.refining {
                            ProgressView().controlSize(.mini)
                            Text("checking more sales…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(formatCents(stats.averageCents))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.default, value: stats.averageCents)
                    Text("from \(stats.count) sale\(stats.count == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                LabeledContent("Middle sale (median)", value: formatCents(stats.medianCents))
                if stats.count >= 4 {
                    LabeledContent("Most sell for", value: "\(formatCents(stats.lowerQuartileCents)) – \(formatCents(stats.upperQuartileCents))")
                }
                LabeledContent("Lowest / highest", value: "\(formatCents(stats.lowCents)) / \(formatCents(stats.highCents))")
                if let oldest = stats.oldest, let newest = stats.newest {
                    LabeledContent("Sold between", value: "\(oldest.formatted(.dateTime.month(.abbreviated).day())) – \(newest.formatted(.dateTime.month(.abbreviated).day().year()))")
                }
                if stats.count < 3 {
                    Label("Only \(stats.count) matching sale\(stats.count == 1 ? "" : "s") — treat this as a rough guide.", systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } else if model.refining {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("No exact matches yet — checking more sales…")
                }
            } else {
                Label("No matching sales found in eBay's recent sold listings.", systemImage: "magnifyingglass")
                Text("Check the \"Left out\" list below, or go back and loosen the details (e.g. remove the variant words).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let note = model.note { Text(note).foregroundStyle(.orange) }
                Text(Prefs.compOptions.includeShipping ? "Prices include shipping." : "Prices exclude shipping.")
            }
        }
    }

    private var saveSection: some View {
        Section {
            Button {
                save()
            } label: {
                Label(item == nil ? (saved ? "Added to collection" : "Add to collection") : (saved ? "Value updated" : "Update collection value"),
                      systemImage: saved ? "checkmark.circle.fill" : "plus.circle.fill")
            }
            .disabled(saved)
        }
    }

    @ViewBuilder
    private var compsSections: some View {
        if !model.included.isEmpty {
            Section {
                ForEach(model.included) { verdict in
                    CompRow(verdict: verdict) { model.toggle(verdict, spec: spec) }
                }
            } header: {
                Text("Counted (\(model.included.count))")
            } footer: {
                Text("Tap a sale to leave it out. Press and hold to open it on eBay.")
            }
        }
        if !model.excluded.isEmpty {
            Section {
                DisclosureGroup("Left out (\(model.excluded.count))", isExpanded: $showExcluded) {
                    ForEach(model.excluded) { verdict in
                        CompRow(verdict: verdict) { model.toggle(verdict, spec: spec) }
                    }
                }
            } footer: {
                Text("Other grades, covers, signed or graded copies, lots and reprints. Tap one to count it.")
            }
        }
    }

    private func save() {
        if let item {
            item.update(spec: spec)
            item.apply(model.stats)
        } else {
            let image = spec.coverImageURL.isEmpty ? model.included.first?.listing.imageURL?.absoluteString : spec.coverImageURL
            modelContext.insert(CollectionItem(spec: spec, stats: model.stats, imageURL: image))
        }
        saved = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

struct CompRow: View {
    let verdict: CompVerdict
    let onTap: () -> Void

    var body: some View {
        let listing = verdict.listing
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: listing.imageURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(listing.title)
                    .font(.subheadline)
                    .lineLimit(3)
                    .foregroundStyle(verdict.included ? .primary : .secondary)
                HStack(spacing: 6) {
                    if let date = listing.soldDate {
                        Text(date.formatted(.dateTime.month(.abbreviated).day().year()))
                    }
                    if listing.bestOffer { Text("· Best Offer") }
                    if verdict.overridden { Text("· changed by you") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let reason = verdict.reason {
                    Text(reason)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(formatCents(listing.priceCents))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                if let shipping = listing.shippingCents, shipping > 0 {
                    Text("+\(formatCents(shipping))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu {
            if let url = listing.url {
                Link(destination: url) { Label("Open on eBay", systemImage: "safari") }
            }
            Button(verdict.included ? "Leave out" : "Count this sale", action: onTap)
        }
    }
}
