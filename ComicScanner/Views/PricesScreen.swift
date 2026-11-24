import Charts
import SwiftData
import SwiftUI

/// The Prices tab: look up any comic, or reopen one you've priced before.
struct PricesScreen: View {
    @Query(sort: \PriceSnapshot.updatedAt, order: .reverse) private var snapshots: [PriceSnapshot]
    @State private var search = ""
    @State private var title = ""
    @State private var issue = ""
    @State private var publisher = ""
    @State private var variant = ""

    /// Latest snapshot per edition.
    private var editions: [PriceSnapshot] {
        var seen = Set<String>()
        let latest = snapshots.filter { seen.insert($0.editionKey).inserted }
        let text = search.trimmed.lowercased()
        guard !text.isEmpty else { return latest }
        return latest.filter { snapshot in
            let spec = snapshot.spec
            return "\(spec.title) \(spec.issue) #\(spec.issue) \(spec.publisher) \(spec.variant) \(spec.exclusive)".lowercased().contains(text)
        }
    }

    private var lookupSpec: ComicSpec {
        var spec = ComicSpec(searchText: title)
        if !issue.trimmed.isEmpty { spec.issue = issue.trimmed }
        spec.publisher = publisher.trimmed
        spec.variant = variant.trimmed
        return spec
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Title (e.g. Amazing Spider-Man)", text: $title).autocorrectionDisabled()
                    TextField("Issue #", text: $issue).keyboardType(.numbersAndPunctuation)
                    TextField("Publisher (optional)", text: $publisher)
                    TextField("Variant (optional, e.g. Cover B, Virgin 1:25)", text: $variant).autocorrectionDisabled()
                    NavigationLink {
                        PricingDashboardView(spec: lookupSpec)
                    } label: {
                        Label("Look up sold prices", systemImage: "magnifyingglass")
                            .font(.headline)
                            .foregroundStyle(Theme.accent)
                    }
                    .disabled(title.trimmed.isEmpty)
                } header: {
                    Text("Look up a comic")
                }
                .listRowBackground(Theme.card)

                Section {
                    ForEach(editions) { snapshot in
                        NavigationLink {
                            PricingDashboardView(spec: snapshot.spec)
                        } label: {
                            EditionRow(snapshot: snapshot)
                        }
                    }
                } header: {
                    Text("Priced before (\(editions.count))")
                }
                .listRowBackground(Theme.card)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .searchable(text: $search, prompt: "Search by title, issue, publisher, variant")
            .navigationTitle("Prices")
        }
        .preferredColorScheme(.dark)
    }
}

struct EditionRow: View {
    let snapshot: PriceSnapshot

    var body: some View {
        let spec = snapshot.spec
        HStack(spacing: 12) {
            CoverArt(url: spec.coverImageURL.nilIfEmpty).frame(width: 40, height: 60)
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.displayTitle).font(.headline)
                Text(spec.editionLine).font(.caption).foregroundStyle(Theme.accent).lineLimit(1)
                Text("\(snapshot.saleCount) sales · \(snapshot.updatedAt.relativeText)").font(.caption2).foregroundStyle(Theme.tertiary)
            }
            Spacer()
            Text(snapshot.marketCents.map(formatCents) ?? "N/A").font(.headline.monospacedDigit())
        }
    }
}

/// Full pricing for one edition: every copy group, time windows, charts, grade tables, company comparison,
/// highest and recent sales (with approve/reject), and current asking prices kept apart from sales.
struct PricingDashboardView: View {
    let spec: ComicSpec
    var record: ComicRecord?

    @Environment(WebBot.self) private var bot
    @Environment(\.modelContext) private var modelContext
    @State private var valuation: Valuation?
    @State private var loading = false
    @State private var error: String?
    @State private var group: CopyGroup?
    @State private var windowDays = 90
    @State private var asking: [AskingRecord] = []
    @State private var loadingAsking = false
    @State private var history: [PriceSnapshot] = []
    @State private var showExcluded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let valuation {
                    groupPicker(valuation)
                    windowPicker
                    let groupSales = sales(in: valuation)
                    statsCard(groupSales, valuation: valuation)
                    chartCard(groupSales)
                    gradesCard(valuation)
                    companyComparison(valuation)
                    salesCard(groupSales, valuation: valuation)
                    askingCard
                    excludedCard(valuation)
                    sourcesCard(valuation)
                } else if loading {
                    HStack(spacing: 10) {
                        ProgressView().tint(Theme.accent)
                        Text(bot.status.isEmpty ? "Finding sold listings…" : bot.status).foregroundStyle(Theme.secondary)
                    }
                    .padding()
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.caution).padding()
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("Pricing")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await load(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(loading)
            }
        }
        .task { await load(force: false) }
        .preferredColorScheme(.dark)
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            CoverArt(url: record?.imageURL ?? spec.coverImageURL.nilIfEmpty, data: record?.thumbnail).frame(width: 72, height: 108)
            VStack(alignment: .leading, spacing: 4) {
                Text(spec.displayTitle).font(.title3.weight(.bold))
                if !spec.publicationLine.isEmpty { Text(spec.publicationLine).font(.subheadline).foregroundStyle(Theme.secondary) }
                Text(spec.editionLine).font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                if let valuation {
                    HStack(spacing: 6) {
                        ConfidenceBadge(confidence: valuation.confidence)
                        if Date().timeIntervalSince(valuation.updatedAt) > PricingService.staleAfter {
                            Text("STALE").font(.caption2.weight(.heavy)).foregroundStyle(Theme.caution)
                        }
                    }
                    Text("Updated \(valuation.updatedAt.relativeText)\(loading ? " · refreshing…" : "")")
                        .font(.caption2).foregroundStyle(Theme.tertiary)
                }
            }
        }
    }

    private func groupPicker(_ valuation: Valuation) -> some View {
        let available = availableGroups(valuation)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(available, id: \.self) { option in
                    let count = valuation.sales.filter { $0.counted && $0.group == option }.count
                    Button {
                        group = option
                    } label: {
                        Text("\(option.label) · \(count)")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .foregroundStyle(selectedGroup == option ? .white : Theme.secondary)
                            .background(selectedGroup == option ? Theme.accent : Theme.cardRaised, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var windowPicker: some View {
        Picker("Period", selection: $windowDays) {
            ForEach(PricingEngine.windowDays, id: \.self) { days in Text("\(days)d").tag(days) }
        }
        .pickerStyle(.segmented)
    }

    private func statsCard(_ groupSales: [ClassifiedSale], valuation: Valuation) -> some View {
        let now = Date()
        let stats = PricingEngine.stats(for: groupSales, days: windowDays, options: Prefs.compOptions, now: now)
        let trend = PricingEngine.trend(groupSales, options: Prefs.compOptions, now: now)
        let last30 = PricingEngine.stats(for: groupSales, days: 30, options: Prefs.compOptions, now: now).count
        return card(title: "\(selectedGroup.label) · last \(windowDays) days") {
            VStack(alignment: .leading, spacing: 2) {
                Text("MEDIAN SOLD").font(.caption2.weight(.bold)).foregroundStyle(Theme.secondary)
                Text(stats.medianCents.map(formatCents) ?? "N/A")
                    .font(.system(size: 40, weight: .heavy, design: .rounded)).monospacedDigit()
                    .foregroundStyle(stats.medianCents == nil ? Theme.tertiary : .white)
            }
            HStack(spacing: 8) {
                statTile("Average", stats.averageCents.map(formatCents) ?? "—")
                statTile("Low", stats.lowCents.map(formatCents) ?? "—")
                statTile("High", stats.highCents.map(formatCents) ?? "—")
                statTile("Sales", "\(stats.count)")
            }
            HStack {
                Label("\(last30) sales in the last 30 days", systemImage: "chart.bar.fill").font(.caption)
                Spacer()
                if let trend {
                    Label(String(format: "%@%.0f%%", trend >= 0 ? "+" : "", trend), systemImage: trend >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(trend >= 0 ? Theme.good : Theme.accent)
                }
            }
            .foregroundStyle(Theme.secondary)
            if stats.count == 0 {
                Text(windowDays > 90
                     ? "eBay shows about 90 days of sales. Longer periods fill in as the app saves sales from each lookup."
                     : "No sales of this copy type in this period.")
                    .font(.caption2).foregroundStyle(Theme.tertiary)
            } else if stats.count < 3 {
                Text("Few sales — treat as a rough guide.").font(.caption2).foregroundStyle(Theme.caution)
            }
            Text("Median of actual completed sales\(Prefs.compOptions.includeShipping ? ", including shipping" : ""). Never asking prices.")
                .font(.caption2).foregroundStyle(Theme.tertiary)
        }
    }

    private func chartCard(_ groupSales: [ClassifiedSale]) -> some View {
        let cutoff = Date().addingTimeInterval(-Double(windowDays) * 86_400)
        let points = groupSales.compactMap { sale -> (Date, Double)? in
            guard let date = sale.listing.soldDate, date >= cutoff else { return nil }
            return (date, Double(sale.listing.totalCents(includeShipping: Prefs.compOptions.includeShipping)) / 100)
        }
        let saved = history.filter { $0.day >= cutoff }.compactMap { snapshot -> (Date, Double)? in
            guard let cents = snapshot.marketCents else { return nil }
            return (snapshot.day, Double(cents) / 100)
        }
        return card(title: "Price history") {
            if points.isEmpty && saved.count < 2 {
                Text("No dated sales in this period.").font(.caption).foregroundStyle(Theme.tertiary)
            } else {
                Chart {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                        PointMark(x: .value("Date", point.0), y: .value("Price", point.1))
                            .foregroundStyle(by: .value("Series", "Sold price"))
                            .symbolSize(36)
                    }
                    if saved.count >= 2 {
                        ForEach(Array(saved.enumerated()), id: \.offset) { _, point in
                            LineMark(x: .value("Date", point.0), y: .value("Price", point.1))
                                .foregroundStyle(by: .value("Series", "Your saved valuation"))
                        }
                    }
                }
                .chartForegroundStyleScale(["Sold price": Theme.accent, "Your saved valuation": Theme.good])
                .chartYAxis { AxisMarks(format: .currency(code: "USD").precision(.fractionLength(0))) }
                .chartLegend(position: .bottom)
                .frame(height: 200)
            }
        }
    }

    @ViewBuilder
    private func gradesCard(_ valuation: Valuation) -> some View {
        switch selectedGroup {
        case .slab(let company, let label):
            let rows = valuation.graded(company: company, label: label)
            card(title: "\(company.rawValue) \(CopyGroup.shortLabel(label)) by grade") {
                if rows.isEmpty {
                    Text("No graded sales with a readable grade.").font(.caption).foregroundStyle(Theme.tertiary)
                }
                ForEach(rows) { row in
                    HStack {
                        Text(gradeLabel(row.grade)).font(.subheadline.weight(.semibold).monospacedDigit()).frame(width: 44, alignment: .leading)
                        Text(row.count > 0 ? "\(row.count) sale\(row.count == 1 ? "" : "s")" : "price guide")
                            .font(.caption).foregroundStyle(Theme.tertiary)
                        Spacer()
                        Text(formatCents(row.cents)).font(.subheadline.weight(.bold).monospacedDigit())
                    }
                }
            }
        default:
            card(title: "\(selectedGroup.label) by condition") {
                PriceBandsView(valuation: valuation, highlight: record?.condition?.band)
                Text("Grades are what sellers stated in their titles. Low under 5.0, Mid 5.0–9.0, High 9.2+.")
                    .font(.caption2).foregroundStyle(Theme.tertiary)
            }
        }
    }

    @ViewBuilder
    private func companyComparison(_ valuation: Valuation) -> some View {
        let universal = valuation.graded.filter { $0.slabLabel == .universal && $0.count > 0 }
        let companies = GradingCompany.allCases.filter { company in universal.contains { $0.company == company } }
        let grades = Array(Set(universal.map(\.grade))).sorted(by: >)
        if companies.count >= 1 && !grades.isEmpty {
            card(title: "Compare grading companies (Universal)") {
                HStack {
                    Text("Grade").frame(width: 50, alignment: .leading)
                    ForEach(companies) { Text($0.rawValue).frame(maxWidth: .infinity, alignment: .trailing) }
                }
                .font(.caption.weight(.bold)).foregroundStyle(Theme.secondary)
                ForEach(grades, id: \.self) { grade in
                    HStack {
                        Text(gradeLabel(grade)).frame(width: 50, alignment: .leading).monospacedDigit()
                        ForEach(companies) { company in
                            let match = universal.first { $0.company == company && abs($0.grade - grade) < 0.05 }
                            Text(match.map { formatCents($0.cents) } ?? "—")
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .foregroundStyle(match == nil ? Theme.tertiary : .white)
                                .monospacedDigit()
                        }
                    }
                    .font(.subheadline)
                }
                Text("Median sold price per grade. Signature Series, Qualified and Restored are listed separately in their own groups.")
                    .font(.caption2).foregroundStyle(Theme.tertiary)
            }
        }
    }

    private func salesCard(_ groupSales: [ClassifiedSale], valuation: Valuation) -> some View {
        let cutoff = Date().addingTimeInterval(-Double(windowDays) * 86_400)
        let inWindow = groupSales.filter { ($0.listing.soldDate ?? .distantPast) >= cutoff }
        let highest = inWindow.sorted { $0.listing.priceCents > $1.listing.priceCents }.prefix(3)
        let flagged = groupSales.filter(\.needsReview).count
        return card(title: "Sold listings (\(inWindow.count))") {
            if !highest.isEmpty {
                Text("HIGHEST RECENT").font(.caption2.weight(.bold)).foregroundStyle(Theme.secondary)
                ForEach(Array(highest)) { sale in ReviewableSaleRow(sale: sale, onReview: review) }
                Divider().overlay(Theme.cardRaised)
            }
            if flagged > 0 {
                Label("\(flagged) match\(flagged == 1 ? "" : "es") to check — press and hold a sale to approve or reject it.",
                      systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(Theme.caution)
            }
            Text("MOST RECENT").font(.caption2.weight(.bold)).foregroundStyle(Theme.secondary)
            ForEach(inWindow.prefix(25)) { sale in ReviewableSaleRow(sale: sale, onReview: review) }
            if inWindow.isEmpty {
                Text("No sales in this period.").font(.caption).foregroundStyle(Theme.tertiary)
            }
        }
    }

    private var askingCard: some View {
        card(title: "Current asking prices — not sales") {
            if asking.isEmpty {
                Text("Listings still for sale. Shown only for comparison; they never count toward the value.")
                    .font(.caption).foregroundStyle(Theme.tertiary)
            } else {
                let prices = asking.map(\.priceCents).sorted()
                HStack(spacing: 8) {
                    statTile("Lowest ask", formatCents(prices[0]))
                    statTile("Median ask", formatCents(CompMatcher.percentile(prices, 0.5)))
                    statTile("Listings", "\(prices.count)")
                }
                ForEach(asking.prefix(5)) { item in
                    HStack {
                        Text(item.title).font(.caption).lineLimit(1)
                        Spacer()
                        Text(formatCents(item.priceCents)).font(.caption.weight(.semibold)).monospacedDigit()
                    }
                    .contextMenu {
                        if let url = item.url.flatMap({ URL(string: $0) }) { Link("Open on eBay", destination: url) }
                    }
                }
                Text("Checked \(asking[0].seenAt.relativeText)").font(.caption2).foregroundStyle(Theme.tertiary)
            }
            Button {
                Task { await loadAsking() }
            } label: {
                Label(loadingAsking ? "Checking listings…" : "Check current listings", systemImage: "tag")
                    .font(.subheadline.weight(.semibold))
            }
            .disabled(loadingAsking)
        }
    }

    @ViewBuilder
    private func excludedCard(_ valuation: Valuation) -> some View {
        let excluded = valuation.sales.filter { !$0.counted }
        if !excluded.isEmpty {
            card(title: "Not counted (\(excluded.count))") {
                DisclosureGroup(isExpanded: $showExcluded) {
                    ForEach(excluded.prefix(80)) { sale in ReviewableSaleRow(sale: sale, onReview: review) }
                } label: {
                    Text("Other editions, covers, printings, lots, reprints and price outliers. Press and hold to count one.")
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
                .tint(Theme.secondary)
            }
        }
    }

    private func sourcesCard(_ valuation: Valuation) -> some View {
        card(title: "Sources") {
            ForEach(valuation.sources) { source in
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name).font(.subheadline.weight(.semibold))
                    Text(source.detail).font(.caption).foregroundStyle(Theme.secondary)
                }
            }
            Link(destination: EbaySoldSearch.soldURL(query: spec.broadQuery, comicsOnly: Prefs.searchComicsOnly)) {
                Label("See these sold listings on eBay", systemImage: "safari").font(.caption.weight(.semibold))
            }
        }
    }

    // MARK: Helpers

    private var selectedGroup: CopyGroup { group ?? CopyGroup.of(spec) }

    private func availableGroups(_ valuation: Valuation) -> [CopyGroup] {
        var groups = [CopyGroup.of(spec)]
        let counts = Dictionary(grouping: valuation.sales.filter(\.counted)) { $0.group }.mapValues(\.count)
        for (group, _) in counts.sorted(by: { $0.value > $1.value }) where !groups.contains(group) {
            groups.append(group)
        }
        return groups
    }

    private func sales(in valuation: Valuation) -> [ClassifiedSale] {
        valuation.sales.filter { $0.counted && $0.group == selectedGroup }
    }

    private func statTile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(Theme.tertiary)
            Text(value).font(.subheadline.weight(.bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 10))
    }

    private func card<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.bold)).foregroundStyle(Theme.secondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private func load(force: Bool) async {
        history = SalesStore.history(for: spec, context: modelContext)
        asking = SalesStore.asking(for: spec, context: modelContext)
        if valuation == nil {
            valuation = PricingService.cached(spec) ?? record?.valuation ?? SalesStore.latestValuation(for: spec, context: modelContext)
        }
        let stale = valuation.map { Date().timeIntervalSince($0.updatedAt) > PricingService.staleAfter } ?? true
        guard force || stale || valuation == nil else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let fresh = try await PricingService.valuation(for: spec, bot: bot, context: modelContext, forceRefresh: force)
            valuation = fresh
            record?.setValuation(fresh)
            history = SalesStore.history(for: spec, context: modelContext)
        } catch {
            if !error.isCancellation { self.error = error.localizedDescription }
        }
    }

    private func loadAsking() async {
        loadingAsking = true
        defer { loadingAsking = false }
        guard let listings = try? await EbaySoldSearch.listingsForBarcode(spec.broadQuery, sold: false, bot: bot) else { return }
        let sameEdition = SaleClassifier.classify(listings, spec: spec, options: CompOptions(includeShipping: true, includeBestOffer: true))
            .filter { $0.counted && $0.group == selectedGroup }
            .map(\.listing)
        SalesStore.saveAsking(sameEdition, for: spec, context: modelContext)
        asking = SalesStore.asking(for: spec, context: modelContext)
    }

    /// Approve / reject a match, then recalculate from the sales already loaded (no new lookup needed).
    private func review(_ sale: ClassifiedSale, _ decision: Bool?) {
        SalesStore.setReview(decision, listing: sale.listing, spec: spec, context: modelContext)
        guard let current = valuation else { return }
        var updated = PricingEngine.valuation(spec: spec, listings: current.sales.map(\.listing), sources: current.sources,
                                              options: Prefs.compOptions,
                                              reviews: SalesStore.reviews(for: spec, context: modelContext))
        updated.updatedAt = current.updatedAt
        valuation = updated
        PricingService.remember(updated, for: spec)
        record?.setValuation(updated)
        SalesStore.snapshot(updated, spec: spec, context: modelContext)
    }
}

/// A sale with approve/reject on press-and-hold.
struct ReviewableSaleRow: View {
    let sale: ClassifiedSale
    let onReview: (ClassifiedSale, Bool?) -> Void

    var body: some View {
        SaleRow(sale: sale)
            .overlay(alignment: .topTrailing) {
                if sale.needsReview {
                    Text("CHECK").font(.caption2.weight(.heavy)).foregroundStyle(Theme.caution).padding(.top, 18)
                } else if sale.review == true {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.good).font(.caption).padding(.top, 18)
                }
            }
            .contextMenu {
                if let url = sale.listing.url { Link(destination: url) { Label("Open on eBay", systemImage: "safari") } }
                Button { onReview(sale, true) } label: { Label("Approve — this is the same book", systemImage: "checkmark.circle") }
                Button(role: .destructive) { onReview(sale, false) } label: { Label("Reject — not this book", systemImage: "xmark.circle") }
                if sale.review != nil {
                    Button { onReview(sale, nil) } label: { Label("Reset to automatic", systemImage: "arrow.uturn.backward") }
                }
            }
    }
}

/// Every price lookup: what was searched, how many sales came back, new vs duplicate, failures.
struct ImportLogView: View {
    @Query(sort: \ImportLog.date, order: .reverse) private var logs: [ImportLog]

    var body: some View {
        List(logs) { log in
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(log.title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(log.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(Theme.tertiary)
                }
                if let error = log.error {
                    Text("Failed: \(error)").font(.caption).foregroundStyle(Theme.accent)
                } else {
                    Text("\(log.listingsRead) listings read · \(log.newSales) new sales · \(log.duplicates) already saved · via \(log.method)")
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
                Text(log.query).font(.caption2.monospaced()).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            .listRowBackground(Theme.card)
        }
        .overlay { if logs.isEmpty { ContentUnavailableView("No lookups yet", systemImage: "list.bullet.rectangle") } }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Pricing log")
        .preferredColorScheme(.dark)
    }
}
