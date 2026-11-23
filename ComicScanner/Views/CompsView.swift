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

    var outlook: [GradeOutlook] = []
    var loadingGraded = false

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
        outlook = Self.gradingOutlook(for: spec, listings: listings)
    }

    /// Graded sales already in the pool for the same book, grade by grade (raw books only).
    static func gradingOutlook(for spec: ComicSpec, listings: [SoldListing]) -> [GradeOutlook] {
        guard !spec.graded else { return [] }
        return [9.8, 9.6, 9.4, 9.2, 9.0, 8.5, 8.0].compactMap { grade in
            var slab = spec
            slab.graded = true
            slab.company = .cgc
            slab.grade = grade
            slab.label = spec.signed ? .signatureSeries : .universal
            guard let stats = CompMatcher.evaluate(listings, spec: slab, options: Prefs.compOptions).stats else { return nil }
            return GradeOutlook(grade: grade, stats: stats)
        }
    }

    /// Fetches CGC sales of this book so the grading check has something to compare.
    func loadGraded(spec: ComicSpec, bot: WebBot) async {
        loadingGraded = true
        defer { loadingGraded = false }
        do {
            let graded = try await EbaySoldSearch.soldListings(query: spec.broadQuery + " cgc", bot: bot, comicsOnly: Prefs.searchComicsOnly)
            listings = merge(listings, graded)
            recompute(spec: spec)
        } catch {
            if !error.isCancellation { note = error.localizedDescription }
        }
    }
}

/// Sold eBay prices for one exact book: median, range, and every sale with why it was counted or not.
struct CompsView: View {
    let spec: ComicSpec
    var item: CollectionItem? = nil

    @Environment(WebBot.self) private var bot
    @Environment(DealCart.self) private var cart
    @Environment(\.modelContext) private var modelContext
    @Environment(\.popToRoot) private var popToRoot
    @State private var model = CompsModel()
    @State private var saved = false
    @State private var addedToDeal = false
    @State private var gradingChecked = false
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
                if let item { ItemDetailsSection(item: item) }
                gradingSection
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
            if let item {
                if item.status != .sold {
                    Button {
                        cart.addOutgoing(item)
                        addedToDeal = true
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    } label: {
                        Label(addedToDeal ? "In the deal" : "Sell or trade this book · \(formatCents(item.sellPriceCents ?? 0))",
                              systemImage: addedToDeal ? "checkmark.circle.fill" : "cart.badge.plus")
                            .font(.headline)
                    }
                    .disabled(addedToDeal)
                }
                Button {
                    save()
                } label: {
                    Label(saved ? "Value updated" : "Update market value", systemImage: saved ? "checkmark.circle.fill" : "arrow.clockwise.circle")
                }
                .disabled(saved || model.stats == nil)
            } else {
                Button {
                    addToDeal()
                } label: {
                    Label(addedToDeal ? "Added to deal" : dealButtonTitle,
                          systemImage: addedToDeal ? "checkmark.circle.fill" : "cart.badge.plus")
                        .font(.headline)
                }
                .disabled(addedToDeal)
                Button {
                    save()
                } label: {
                    Label(saved ? "Added to inventory" : "Add to my inventory",
                          systemImage: saved ? "checkmark.circle.fill" : "plus.circle")
                }
                .disabled(saved)
            }
        } footer: {
            if item == nil, !cart.lines.isEmpty {
                Text("Open deal: \(cart.kind.rawValue.lowercased()), \(cart.lines.count) book\(cart.lines.count == 1 ? "" : "s").")
            }
        }
    }

    private var dealButtonTitle: String {
        let verb = cart.kind == .buy ? "Buy" : "Trade in"
        let offer = cart.offer(for: model.stats?.averageCents)
        return model.stats == nil ? "\(verb) — set price in deal" : "\(verb) · offer \(formatCents(offer))"
    }

    private func addToDeal() {
        cart.addIncoming(spec: spec, marketCents: model.stats?.averageCents, imageURL: coverForSaving)
        addedToDeal = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if Prefs.returnToScanner { popToRoot() }
    }

    private var coverForSaving: String? {
        spec.coverImageURL.isEmpty ? model.included.first?.listing.largeImageURL?.absoluteString : spec.coverImageURL
    }

    @ViewBuilder
    private var gradingSection: some View {
        if !spec.graded, let raw = model.stats {
            Section {
                if model.outlook.isEmpty {
                    if model.loadingGraded {
                        HStack(spacing: 10) { ProgressView(); Text("Checking CGC sales…") }
                    } else if gradingChecked {
                        Text("No CGC sales of this book found yet.").foregroundStyle(.secondary)
                    } else {
                        Button {
                            gradingChecked = true
                            Task { await model.loadGraded(spec: spec, bot: bot) }
                        } label: {
                            Label("Check graded prices", systemImage: "rosette")
                        }
                    }
                } else {
                    ForEach(model.outlook) { row in
                        let gain = row.stats.averageCents - Prefs.gradingFeeCents - raw.averageCents
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("CGC \(String(format: "%.1f", row.grade))").font(.subheadline.weight(.semibold))
                                Text("\(row.stats.count) sale\(row.stats.count == 1 ? "" : "s") · avg \(formatCents(row.stats.averageCents))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(gain >= 0 ? "+" : "−")\(formatCents(abs(gain)))")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(gain > 0 ? .green : .red)
                        }
                    }
                }
            } header: {
                Text("Worth grading?")
            } footer: {
                Text("Gain vs. selling raw (\(formatCents(raw.averageCents))) after a \(formatCents(Prefs.gradingFeeCents)) grading cost. Only counts if your copy would actually get that grade.")
            }
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
            let newItem = CollectionItem(spec: spec, stats: model.stats, imageURL: coverForSaving)
            newItem.status = .collection
            modelContext.insert(newItem)
        }
        saved = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

struct GradeOutlook: Identifiable, Hashable {
    let grade: Double
    let stats: PriceStats
    var id: Double { grade }
}

/// Your copy: keep or sell, what you paid, asking price, which box it's in.
struct ItemDetailsSection: View {
    @Bindable var item: CollectionItem

    var body: some View {
        Section("Your copy") {
            Picker("Status", selection: Binding(get: { item.status }, set: { item.status = $0 })) {
                ForEach(ItemStatus.allCases) { Text($0.rawValue).tag($0) }
            }
            CentsField(title: "You paid", cents: $item.costCents)
            CentsField(title: "Asking price", cents: $item.askingCents, placeholder: item.valueCents.map { DealLineRow.dollars($0) } ?? "")
            TextField("Box or binder", text: Binding(get: { item.boxName }, set: { item.boxName = $0 }))
            if item.status == .sold, let sold = item.soldCents {
                LabeledContent("Sold for", value: formatCents(sold))
                if let cost = item.costCents {
                    LabeledContent("Profit", value: formatCents(sold - cost))
                }
            } else if let value = item.valueCents, let cost = item.costCents {
                LabeledContent("Gain vs. market", value: "\(value >= cost ? "+" : "−")\(formatCents(abs(value - cost)))")
            }
        }
    }
}

/// A dollar amount field backed by optional cents.
struct CentsField: View {
    let title: String
    @Binding var cents: Int?
    var placeholder = ""
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 2) {
                Text("$").foregroundStyle(.secondary)
                TextField(placeholder.isEmpty ? "0" : placeholder, text: $text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 110)
                    .focused($focused)
            }
        }
        .onAppear { text = cents.map(DealLineRow.dollars) ?? "" }
        .onChange(of: focused) { _, isFocused in
            guard !isFocused else { return }
            let cleaned = text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "").trimmed
            if cleaned.isEmpty {
                cents = nil
            } else if let value = Double(cleaned) {
                cents = Int((value * 100).rounded())
            } else {
                text = cents.map(DealLineRow.dollars) ?? ""
            }
        }
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
