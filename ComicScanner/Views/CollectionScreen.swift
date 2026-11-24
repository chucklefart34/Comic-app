import SwiftData
import SwiftUI

/// Your saved comics and every scan, with search, sorting and total value.
struct CollectionScreen: View {
    @Query(sort: \ComicRecord.scannedAt, order: .reverse) private var records: [ComicRecord]
    @Environment(\.modelContext) private var modelContext
    @Environment(WebBot.self) private var bot

    @State private var mode: Mode = .collection
    @State private var sort: Sort = .date
    @State private var search = ""
    @State private var updating = false
    @State private var progress = ""

    enum Mode: String, CaseIterable, Identifiable {
        case collection = "Collection"
        case history = "Scan history"
        var id: String { rawValue }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case date = "Scan date"
        case title = "Title"
        case publisher = "Publisher"
        case value = "Value"
        var id: String { rawValue }
    }

    private var shown: [ComicRecord] {
        var list = mode == .collection ? records.filter(\.inCollection) : records
        let text = search.trimmed.lowercased()
        if !text.isEmpty {
            list = list.filter {
                "\($0.title) \($0.issue) \($0.publisher) \($0.editionLine)".lowercased().contains(text)
            }
        }
        switch sort {
        case .date: return list.sorted { $0.scannedAt > $1.scannedAt }
        case .title: return list.sorted { ($0.title, Int($0.issue) ?? 0) < ($1.title, Int($1.issue) ?? 0) }
        case .publisher: return list.sorted { ($0.publisher, $0.title) < ($1.publisher, $1.title) }
        case .value: return list.sorted { ($0.displayValueCents ?? -1) > ($1.displayValueCents ?? -1) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Show", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    summary
                        .listRowBackground(Theme.card)
                }

                Section {
                    ForEach(shown) { record in
                        NavigationLink {
                            ComicDetailView(record: record)
                        } label: {
                            RecordRow(record: record)
                        }
                        .listRowBackground(Theme.card)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { modelContext.delete(record) } label: { Label("Delete", systemImage: "trash") }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                record.inCollection.toggle()
                            } label: {
                                Label(record.inCollection ? "Remove" : "Save",
                                      systemImage: record.inCollection ? "bookmark.slash" : "bookmark")
                            }
                            .tint(Theme.accent)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView(
                        mode == .collection ? "No saved comics" : "No scans yet",
                        systemImage: "books.vertical",
                        description: Text(mode == .collection
                                          ? "Scan a comic and tap Save on the results card."
                                          : "Everything you scan shows up here.")
                    )
                }
            }
            .searchable(text: $search, prompt: "Title, publisher, variant")
            .navigationTitle(mode == .collection ? "Collection" : "History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort by", selection: $sort) {
                            ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Button {
                            Task { await updateAll() }
                        } label: { Label("Update all prices", systemImage: "arrow.clockwise") }
                            .disabled(updating || shown.isEmpty)
                        ShareLink(item: csv, preview: SharePreview("Comic collection.csv")) {
                            Label("Export CSV", systemImage: "square.and.arrow.up")
                        }
                        if mode == .history {
                            Button(role: .destructive) {
                                records.filter { !$0.inCollection }.forEach { modelContext.delete($0) }
                            } label: { Label("Clear unsaved history", systemImage: "trash") }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var summary: some View {
        let list = shown
        let total: Int = list.compactMap(\.displayValueCents).reduce(0, +)
        let paid: Int = list.compactMap(\.purchaseCents).reduce(0, +)
        let countText = "\(list.count) comic\(list.count == 1 ? "" : "s")"
        let gainText = (total >= paid ? "+" : "−") + formatCents(abs(total - paid))
        let gainColor: Color = total >= paid ? Theme.good : Theme.accent
        return VStack(alignment: .leading, spacing: 4) {
            Text("ESTIMATED VALUE").font(.caption2.weight(.bold)).foregroundStyle(Theme.secondary)
            Text(formatCents(total))
                .font(.system(size: 38, weight: .heavy, design: .rounded))
                .monospacedDigit()
            HStack(spacing: 12) {
                Text(countText)
                if paid > 0 {
                    Text("Paid " + formatCents(paid))
                    Text(gainText).foregroundStyle(gainColor)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.secondary)
            if updating {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.caption2).foregroundStyle(Theme.tertiary)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func updateAll() async {
        updating = true
        defer { updating = false }
        let list = shown
        for (index, record) in list.enumerated() {
            progress = "Updating \(index + 1) of \(list.count): \(record.displayTitle)"
            guard let valuation = try? await PricingService.valuation(for: record.spec, bot: bot, forceRefresh: true) else { continue }
            record.setValuation(valuation)
        }
    }

    private var csv: String {
        var rows = ["Title,Issue,Publisher,Year,Edition,Condition,Value,Confidence,Paid,Scanned"]
        for record in shown {
            let fields = [
                record.title, record.issue, record.publisher, record.year, record.editionLine,
                record.condition?.rawValue ?? "",
                record.displayValueCents.map { String(format: "%.2f", Double($0) / 100) } ?? "",
                record.confidence?.rawValue ?? "",
                record.purchaseCents.map { String(format: "%.2f", Double($0) / 100) } ?? "",
                record.scannedAt.formatted(date: .numeric, time: .omitted),
            ]
            rows.append(fields.map { field in
                field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" })
                    ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                    : field
            }.joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }
}

struct RecordRow: View {
    let record: ComicRecord

    var body: some View {
        HStack(spacing: 12) {
            CoverArt(url: record.imageURL, data: record.imageURL == nil ? record.thumbnail : nil)
                .frame(width: 46, height: 70)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.displayTitle).font(.headline).lineLimit(2)
                Text([record.publisher, record.year].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(Theme.secondary)
                Text(record.editionLine).font(.caption2).foregroundStyle(Theme.accent).lineLimit(1)
                Text(record.scannedAt.formatted(date: .abbreviated, time: .omitted) + (record.condition.map { " · \($0.rawValue)" } ?? ""))
                    .font(.caption2).foregroundStyle(Theme.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(record.displayValueCents.map(formatCents) ?? "—")
                    .font(.headline.monospacedDigit())
                if let confidence = record.confidence, confidence != .high {
                    Text(confidence == .low ? "Estimate" : "\(confidence.rawValue) conf.")
                        .font(.caption2).foregroundStyle(Theme.caution)
                }
                if record.inCollection {
                    Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(Theme.accent)
                }
            }
        }
    }
}
