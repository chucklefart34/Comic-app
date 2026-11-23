import SwiftUI
import SwiftData

/// Inventory: everything you own (and what you've sold), grouped by box, with value, cost and gain.
struct CollectionView: View {
    @Query(sort: \CollectionItem.addedAt, order: .reverse) private var items: [CollectionItem]
    @Environment(\.modelContext) private var modelContext
    @Environment(WebBot.self) private var bot

    @State private var path = NavigationPath()
    @State private var filter: Filter = .owned
    @State private var search = ""
    @State private var groupByBox = true
    @State private var refreshing = false
    @State private var progress = ""
    @State private var refreshError: String?
    @State private var showingSettings = false

    enum Filter: String, CaseIterable, Identifiable {
        case owned = "All owned"
        case keeping = "Keeping"
        case forSale = "For sale"
        case sold = "Sold"
        var id: String { rawValue }
    }

    private var shown: [CollectionItem] {
        let byStatus: [CollectionItem]
        switch filter {
        case .owned: byStatus = items.filter { $0.status != .sold }
        case .keeping: byStatus = items.filter { $0.status == .collection }
        case .forSale: byStatus = items.filter { $0.status == .forSale }
        case .sold: byStatus = items.filter { $0.status == .sold }
        }
        let text = search.trimmed.lowercased()
        guard !text.isEmpty else { return byStatus }
        return byStatus.filter {
            $0.title.lowercased().contains(text) || $0.details.lowercased().contains(text) || $0.boxName.lowercased().contains(text)
        }
    }

    struct BoxGroup: Identifiable {
        let name: String
        let items: [CollectionItem]
        var id: String { name }
    }

    private var boxes: [BoxGroup] {
        let grouped = Dictionary(grouping: shown) { $0.boxName }
        return grouped.keys.sorted { a, b in
            if a.isEmpty { return false }
            if b.isEmpty { return true }
            return a.localizedStandardCompare(b) == .orderedAscending
        }.map { BoxGroup(name: $0, items: grouped[$0] ?? []) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    summary
                }

                if groupByBox && filter != .sold {
                    ForEach(boxes) { box in
                        Section {
                            rows(box.items)
                        } header: {
                            HStack {
                                Text(box.name.isEmpty ? "No box" : box.name)
                                Spacer()
                                Text("\(box.items.count) · \(formatCents(box.items.compactMap(\.valueCents).reduce(0, +)))")
                            }
                        }
                    }
                } else {
                    Section {
                        rows(shown)
                    }
                }
            }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView(
                        "No comics yet",
                        systemImage: "books.vertical",
                        description: Text("Scan a comic and tap Add to my inventory, or buy books in the Deal tab.")
                    )
                }
            }
            .searchable(text: $search, prompt: "Title, variant, box")
            .navigationTitle("Inventory")
            .navigationDestination(for: CollectionItem.self) { item in
                CompsView(spec: item.spec, item: item)
            }
            .comicDestinations()
            .environment(\.popToRoot, PopToRoot { path = NavigationPath() })
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Task { await refreshAll() }
                        } label: {
                            Label("Update all market values", systemImage: "arrow.clockwise")
                        }
                        .disabled(items.isEmpty || refreshing)
                        Toggle("Group by box", isOn: $groupByBox)
                        ShareLink(item: csv, preview: SharePreview("Comic inventory.csv")) {
                            Label("Export CSV", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
        }
    }

    @ViewBuilder
    private var summary: some View {
        let list = shown
        let value = list.compactMap(\.valueCents).reduce(0, +)
        let cost = list.compactMap(\.costCents).reduce(0, +)
        if filter == .sold {
            let sold = list.compactMap(\.soldCents).reduce(0, +)
            let soldCost = list.filter { $0.soldCents != nil }.compactMap(\.costCents).reduce(0, +)
            LabeledContent("Sold", value: "\(list.count) books · \(formatCents(sold))")
            LabeledContent("Profit", value: formatCents(sold - soldCost))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Market value").font(.subheadline).foregroundStyle(.secondary)
                Text(formatCents(value)).font(.largeTitle.bold()).monospacedDigit()
                Text("\(list.count) book\(list.count == 1 ? "" : "s")").font(.subheadline).foregroundStyle(.secondary)
            }
            if cost > 0 {
                LabeledContent("You paid", value: formatCents(cost))
                LabeledContent("Gain", value: "\(value >= cost ? "+" : "−")\(formatCents(abs(value - cost)))")
            }
        }
        if refreshing {
            HStack(spacing: 8) {
                ProgressView()
                Text(progress).font(.footnote).foregroundStyle(.secondary)
            }
        }
        if let refreshError {
            Text(refreshError).font(.footnote).foregroundStyle(.red)
        }
    }

    private func rows(_ list: [CollectionItem]) -> some View {
        ForEach(list) { item in
            NavigationLink(value: item) {
                CollectionRow(item: item)
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    modelContext.delete(item)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .swipeActions(edge: .leading) {
                if item.status == .collection {
                    Button {
                        item.status = .forSale
                    } label: {
                        Label("For sale", systemImage: "tag")
                    }
                    .tint(.orange)
                } else if item.status == .forSale {
                    Button {
                        item.status = .collection
                    } label: {
                        Label("Keep", systemImage: "heart")
                    }
                    .tint(.pink)
                }
            }
        }
    }

    /// Re-checks eBay for every unsold book, one at a time.
    private func refreshAll() async {
        guard !refreshing else { return }
        refreshing = true
        refreshError = nil
        defer { refreshing = false }

        let books = items.filter { $0.status != .sold }
        for (index, item) in books.enumerated() {
            progress = "Updating \(index + 1) of \(books.count): \(item.title)"
            let spec = item.spec
            do {
                let listings = try await EbaySoldSearch.soldListings(for: spec, bot: bot, comicsOnly: Prefs.searchComicsOnly)
                let result = CompMatcher.evaluate(listings, spec: spec, options: Prefs.compOptions)
                item.apply(result.stats)
            } catch {
                if !error.isCancellation { refreshError = error.localizedDescription }
                break
            }
        }
    }

    private var csv: String {
        var rows = ["Title,Details,Status,Box,Market value,You paid,Asking,Sold for,Sales counted,Priced,Added"]
        for item in items {
            let fields = [
                item.title,
                item.details,
                item.status.rawValue,
                item.boxName,
                dollars(item.valueCents),
                dollars(item.costCents),
                dollars(item.askingCents),
                dollars(item.soldCents),
                String(item.compCount),
                item.pricedAt?.formatted(date: .numeric, time: .omitted) ?? "",
                item.addedAt.formatted(date: .numeric, time: .omitted),
            ]
            rows.append(fields.map(csvEscape).joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    private func dollars(_ cents: Int?) -> String {
        cents.map { String(format: "%.2f", Double($0) / 100) } ?? ""
    }

    private func csvEscape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

struct CollectionRow: View {
    let item: CollectionItem

    var body: some View {
        HStack(spacing: 12) {
            CoverThumb(url: item.imageURL, width: 44, height: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(item.details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if item.status == .forSale {
                    Text("For sale\(item.askingCents.map { " · \(formatCents($0))" } ?? "")")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if item.status == .sold {
                    Text(item.soldCents.map(formatCents) ?? "—").monospacedDigit()
                    Text("sold").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(item.valueCents.map(formatCents) ?? "—").monospacedDigit()
                    if let cost = item.costCents {
                        Text("paid \(formatCents(cost))").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text(item.compCount == 0 ? "no sales" : "\(item.compCount) sales")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
