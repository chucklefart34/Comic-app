import SwiftUI
import SwiftData

struct CollectionView: View {
    @Query(sort: \CollectionItem.addedAt, order: .reverse) private var items: [CollectionItem]
    @Environment(\.modelContext) private var modelContext
    @Environment(WebBot.self) private var bot

    @State private var refreshing = false
    @State private var progress = ""
    @State private var refreshError: String?

    private var totalCents: Int { items.compactMap(\.valueCents).reduce(0, +) }

    var body: some View {
        NavigationStack {
            List {
                if !items.isEmpty {
                    Section {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Collection value")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text(formatCents(totalCents))
                                    .font(.largeTitle.bold())
                                    .monospacedDigit()
                            }
                            Spacer()
                            Text(items.count == 1 ? "1 book" : "\(items.count) books")
                                .foregroundStyle(.secondary)
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

                    Section {
                        ForEach(items) { item in
                            NavigationLink(value: item) {
                                CollectionRow(item: item)
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { modelContext.delete(items[index]) }
                        }
                    }
                }
            }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView(
                        "No comics yet",
                        systemImage: "books.vertical",
                        description: Text("Scan or look up a comic, check its sold prices, then tap Add to collection.")
                    )
                }
            }
            .navigationTitle("Collection")
            .navigationDestination(for: CollectionItem.self) { item in
                CompsView(spec: item.spec, item: item)
            }
            .comicDestinations()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !items.isEmpty {
                        ShareLink(item: csv, preview: SharePreview("Comic collection.csv")) {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await refreshAll() }
                    } label: {
                        Label("Update all values", systemImage: "arrow.clockwise")
                    }
                    .disabled(items.isEmpty || refreshing)
                }
            }
        }
    }

    /// Re-checks eBay for every book, one at a time.
    private func refreshAll() async {
        guard !refreshing else { return }
        refreshing = true
        refreshError = nil
        defer { refreshing = false }

        let books = Array(items)
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
        var rows = ["Title,Details,Value (USD),Typical low,Typical high,Sales counted,Priced,Added"]
        for item in items {
            let fields = [
                item.title,
                item.details,
                dollars(item.valueCents),
                dollars(item.lowCents),
                dollars(item.highCents),
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
            AsyncImage(url: item.imageURL.flatMap { URL(string: $0) }) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                        .overlay { Image(systemName: "book.closed").foregroundStyle(.secondary) }
                }
            }
            .frame(width: 44, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(item.details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.valueCents.map(formatCents) ?? "—")
                    .monospacedDigit()
                Text(item.compCount == 0 ? "no sales" : "\(item.compCount) sales")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
