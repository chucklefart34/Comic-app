import Charts
import SwiftData
import SwiftUI

/// Everything about one scanned comic: identity, prices by condition, comps, trend, sources, key info.
struct ComicDetailView: View {
    @Bindable var record: ComicRecord
    @Environment(WebBot.self) private var bot
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var refreshing = false
    @State private var refreshError: String?
    @State private var showAllSales = false
    @State private var confirmingDelete = false

    var body: some View {
        let spec = record.spec
        let valuation = record.valuation
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(spec)

                section {
                    HeadlinePrice(valuation: valuation, condition: record.condition, spec: spec,
                                  manualCents: record.manualValueCents, loading: refreshing, error: refreshError)
                    PriceBandsView(valuation: valuation, highlight: record.condition?.band, loading: refreshing)
                    ConditionPicker(selected: record.condition, spec: spec) { condition in
                        record.condition = condition
                    } onGrade: { grade, company in
                        var updated = record.spec
                        updated.graded = true
                        updated.grade = grade
                        updated.company = company
                        record.condition = .graded
                        record.update(spec: updated)
                    }
                    if let valuation {
                        HStack {
                            ConfidenceBadge(confidence: valuation.confidence)
                            Text(valuation.confidence.explanation).font(.caption).foregroundStyle(Theme.secondary)
                        }
                        if let note = valuation.estimateNote {
                            Label(note, systemImage: "sparkles").font(.caption).foregroundStyle(Theme.caution)
                        }
                        Text("Updated \(valuation.updatedAt.relativeText)").font(.caption2).foregroundStyle(Theme.tertiary)
                    }
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label(refreshing ? "Checking sales…" : "Refresh prices", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                    }
                    .disabled(refreshing)
                    .tint(Theme.accent)
                }

                NavigationLink {
                    PricingDashboardView(spec: spec, record: record)
                } label: {
                    HStack {
                        Label("Full pricing: history, grades, CGC vs CBCS, asking prices", systemImage: "chart.line.uptrend.xyaxis")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if let flagged = valuation?.reviewCount, flagged > 0 {
                            Text("\(flagged) to check").font(.caption.weight(.bold)).foregroundStyle(Theme.caution)
                        }
                        Image(systemName: "chevron.right").foregroundStyle(Theme.tertiary)
                    }
                    .padding(14)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
                }
                .buttonStyle(.plain)

                if let valuation, let median = valuation.medianCents {
                    section(title: "\(valuation.headlineGroup ?? "Raw") sales summary") {
                        HStack {
                            summaryTile("Median", formatCents(median))
                            summaryTile("Average", valuation.averageCents.map(formatCents) ?? "—")
                            summaryTile("Low", valuation.lowCents.map(formatCents) ?? "—")
                            summaryTile("High", valuation.highCents.map(formatCents) ?? "—")
                        }
                        if let windows = valuation.windows {
                            HStack {
                                ForEach(windows) { window in
                                    summaryTile("\(window.days)d", window.medianCents.map(formatCents) ?? "—", detail: "\(window.count) sales")
                                }
                            }
                        }
                        if let trend = valuation.trendPercent {
                            Label(String(format: "Trend: %@%.0f%% (last 30 days vs the 90 before)", trend >= 0 ? "+" : "", trend),
                                  systemImage: trend >= 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(trend >= 0 ? Theme.good : Theme.accent)
                        }
                    }
                }

                if let valuation, !valuation.graded.filter({ $0.count > 0 }).isEmpty {
                    section(title: "Graded (slab) sales") {
                        ForEach(valuation.graded.filter { $0.count > 0 }) { slab in
                            HStack {
                                Text("\(slab.company.rawValue) \(gradeLabel(slab.grade))\(slab.slabLabel == .universal ? "" : " " + CopyGroup.shortLabel(slab.slabLabel))")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("\(slab.count) sale\(slab.count == 1 ? "" : "s")").font(.caption).foregroundStyle(Theme.tertiary)
                                Text(formatCents(slab.cents)).font(.subheadline.weight(.bold)).monospacedDigit()
                            }
                        }
                        Text("Slabbed prices are kept separate from raw prices.").font(.caption2).foregroundStyle(Theme.tertiary)
                    }
                }

                whyValuable(spec, valuation: valuation)

                if let valuation, valuation.sales.contains(where: { $0.counted && $0.listing.soldDate != nil }) {
                    section(title: "Price trend") { TrendChart(sales: valuation.sales.filter(\.counted)) }
                }

                if let valuation, !valuation.sales.isEmpty {
                    compsSection(valuation)
                }

                if let valuation {
                    section(title: "Sources") {
                        ForEach(valuation.sources) { source in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name).font(.subheadline.weight(.semibold))
                                Text(source.detail).font(.caption).foregroundStyle(Theme.secondary)
                            }
                        }
                        Text("Only completed sales are used — never asking prices.").font(.caption2).foregroundStyle(Theme.tertiary)
                        Link(destination: EbaySoldSearch.soldURL(query: spec.broadQuery, comicsOnly: Prefs.searchComicsOnly)) {
                            Label("See these sold listings on eBay", systemImage: "safari").font(.caption.weight(.semibold))
                        }
                    }
                }

                identity(spec)
                yourCopy

                section(title: "Condition check") {
                    Label("Coming later: photograph the front and back for an estimated condition. It will be an estimate, not a CGC grade.",
                          systemImage: "camera.viewfinder")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                }

                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label("Delete", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .padding(.vertical, 8)
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle(spec.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    EditComicView(record: record) { Task { await refresh() } }
                } label: { Text("Edit") }
            }
        }
        .confirmationDialog("Delete this comic?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                modelContext.delete(record)
                dismiss()
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Sections

    private func header(_ spec: ComicSpec) -> some View {
        HStack(alignment: .top, spacing: 16) {
            CoverArt(url: record.imageURL, data: record.imageURL == nil ? record.thumbnail : nil, cornerRadius: 10)
                .frame(width: 140, height: 212)
                .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
            VStack(alignment: .leading, spacing: 6) {
                Text(spec.title).font(.title2.weight(.bold))
                if !spec.issue.isEmpty { Text("#\(spec.issue)").font(.title3.weight(.semibold)).foregroundStyle(Theme.secondary) }
                Text(spec.publicationLine).font(.subheadline).foregroundStyle(Theme.secondary)
                Text(spec.detailLine).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                Button {
                    record.inCollection.toggle()
                } label: {
                    Label(record.inCollection ? "In collection" : "Save to collection",
                          systemImage: record.inCollection ? "bookmark.fill" : "bookmark")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(record.inCollection ? Theme.cardRaised : Theme.accent)
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func whyValuable(_ spec: ComicSpec, valuation: Valuation?) -> some View {
        let mentions = valuation.map { ListingMentions.keyPhrases(in: $0.sales.map(\.listing.title)) } ?? []
        if !spec.keyNotes.isEmpty || !mentions.isEmpty || (spec.variantCount ?? 0) > 1 || spec.printing > 1 || !spec.variant.isEmpty {
            section(title: "Why is this comic valuable?") {
                ForEach(spec.keyNotes, id: \.self) { note in
                    Label(note, systemImage: "star.fill").font(.subheadline)
                }
                if !spec.keyNotes.isEmpty {
                    Text("Source: VerseDB").font(.caption2).foregroundStyle(Theme.tertiary)
                }
                ForEach(mentions, id: \.phrase) { mention in
                    Label("\(mention.phrase) — mentioned in \(mention.count) sold listings", systemImage: "tag")
                        .font(.subheadline)
                }
                if !mentions.isEmpty {
                    Text("From sellers' listing titles; not independently verified.").font(.caption2).foregroundStyle(Theme.tertiary)
                }
                if let count = spec.variantCount, count > 1 {
                    Label("\(count) covers exist for this issue — make sure yours is the \(spec.variant.isEmpty ? "regular cover" : spec.variant).",
                          systemImage: "square.on.square")
                        .font(.subheadline)
                }
                if !spec.variant.isEmpty {
                    Label("Variant: \(spec.variant). Variants can sell for much more (or less) than the regular cover.", systemImage: "sparkles")
                        .font(.subheadline)
                }
                if spec.printing > 1 {
                    Label("\(ordinal(spec.printing)) printing — later printings usually sell for less than the 1st.", systemImage: "printer")
                        .font(.subheadline)
                }
            }
        }
    }

    private func compsSection(_ valuation: Valuation) -> some View {
        let counted = valuation.sales.filter(\.counted)
        let excluded = valuation.sales.filter { !$0.counted }
        return section(title: "Recent sold comps (\(counted.count))") {
            ForEach(counted.prefix(showAllSales ? 200 : 8)) { sale in SaleRow(sale: sale) }
            if counted.count > 8 {
                Button(showAllSales ? "Show fewer" : "Show all \(counted.count)") { showAllSales.toggle() }
                    .font(.subheadline).tint(Theme.accent)
            }
            if !excluded.isEmpty {
                DisclosureGroup("Left out (\(excluded.count))") {
                    ForEach(excluded.prefix(60)) { sale in SaleRow(sale: sale) }
                }
                .font(.subheadline)
                .tint(Theme.secondary)
            }
        }
    }

    private func identity(_ spec: ComicSpec) -> some View {
        section(title: "Identification") {
            row("Series", spec.title)
            row("Issue", spec.issue)
            row("Publisher", spec.publisher)
            row("Published", spec.releaseDate.isEmpty ? spec.year : spec.releaseDate)
            row("Volume", spec.volume)
            row("Cover", spec.variant.isEmpty ? "Regular" : spec.variant)
            row("Exclusive", spec.exclusive)
            row("Printing", spec.printing > 1 ? ordinal(spec.printing) : "1st")
            row("Writer", spec.writer)
            row("Cover artist", spec.coverArtist)
            row("UPC", spec.upc)
            row("ISBN", spec.isbn)
            if spec.graded {
                row("Slab", "\(spec.company.rawValue) \(spec.gradeText) · \(spec.label.rawValue)")
                row("Cert", spec.certNumber)
            }
            if spec.signed { row("Signed by", spec.signer.isEmpty ? "Yes" : spec.signer) }
        }
    }

    private var yourCopy: some View {
        section(title: "Your copy") {
            CentsField(title: "You paid", cents: $record.purchaseCents)
            DatePicker("Bought on", selection: Binding(get: { record.purchaseDate ?? record.scannedAt },
                                                      set: { record.purchaseDate = $0 }),
                       displayedComponents: .date)
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
            if let profit = record.profitCents {
                HStack {
                    Text("Profit / loss").font(.subheadline).foregroundStyle(Theme.secondary)
                    Spacer()
                    Text("\(profit >= 0 ? "+" : "−")\(formatCents(abs(profit)))\(record.profitPercent.map { String(format: " (%@%.0f%%)", $0 >= 0 ? "+" : "", $0) } ?? "")")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(profit >= 0 ? Theme.good : Theme.accent)
                }
            }
            CentsField(title: "Your price (overrides market)", cents: $record.manualValueCents)
            row("Scanned", record.scannedAt.formatted(date: .abbreviated, time: .shortened))
            TextField("Notes", text: $record.notes, axis: .vertical)
                .font(.subheadline)
        }
    }

    private func summaryTile(_ title: String, _ value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(Theme.tertiary)
            Text(value).font(.subheadline.weight(.bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            if let detail { Text(detail).font(.caption2).foregroundStyle(Theme.tertiary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        if !value.trimmed.isEmpty {
            HStack(alignment: .top) {
                Text(label).font(.subheadline).foregroundStyle(Theme.secondary)
                Spacer()
                Text(value).font(.subheadline.weight(.medium)).multilineTextAlignment(.trailing)
            }
        }
    }

    private func section<Content: View>(title: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title.uppercased()).font(.caption.weight(.bold)).foregroundStyle(Theme.secondary)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private func refresh() async {
        refreshing = true
        refreshError = nil
        defer { refreshing = false }
        do {
            let valuation = try await PricingService.valuation(for: record.spec, bot: bot, context: modelContext, forceRefresh: true)
            record.setValuation(valuation)
        } catch {
            if !error.isCancellation { refreshError = error.localizedDescription }
        }
    }
}

struct SaleRow: View {
    let sale: ClassifiedSale

    var body: some View {
        let listing = sale.listing
        HStack(alignment: .top, spacing: 10) {
            CoverArt(url: listing.imageURL?.absoluteString, cornerRadius: 4).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(listing.title).font(.caption).lineLimit(2)
                HStack(spacing: 6) {
                    Text(sale.kindLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(sale.kind.isGraded ? Theme.caution : Theme.good)
                    if let date = listing.soldDate {
                        Text(date.formatted(.dateTime.month(.abbreviated).day().year())).font(.caption2).foregroundStyle(Theme.tertiary)
                    }
                }
                if let reason = sale.excludedReason {
                    Text(reason).font(.caption2.weight(.medium)).foregroundStyle(Theme.accent)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatCents(listing.priceCents)).font(.subheadline.weight(.semibold)).monospacedDigit()
                if let shipping = listing.shippingCents, shipping > 0 {
                    Text("+\(formatCents(shipping))").font(.caption2).foregroundStyle(Theme.tertiary)
                }
            }
        }
        .contextMenu {
            if let url = listing.url { Link(destination: url) { Label("Open on eBay", systemImage: "safari") } }
        }
    }
}

/// Sold prices over time (real sales only).
struct TrendChart: View {
    let sales: [ClassifiedSale]

    private struct Point: Identifiable {
        let id: String
        let date: Date
        let dollars: Double
        let group: String
    }

    var body: some View {
        let points = sales.compactMap { sale -> Point? in
            guard let date = sale.listing.soldDate else { return nil }
            let group: String
            switch sale.kind {
            case .graded: group = "Slabbed"
            case .raw(let grade?): group = "Raw · \(PriceBand.of(grade: grade).rawValue)"
            case .raw(nil): group = "Raw · no grade"
            }
            return Point(id: sale.id, date: date, dollars: Double(sale.listing.priceCents) / 100, group: group)
        }
        Chart(points) { point in
            PointMark(x: .value("Sold", point.date), y: .value("Price", point.dollars))
                .foregroundStyle(by: .value("Copy", point.group))
                .symbolSize(40)
        }
        .chartYAxis { AxisMarks(format: .currency(code: "USD").precision(.fractionLength(0))) }
        .chartLegend(position: .bottom)
        .frame(height: 180)
    }
}

/// Key phrases sellers repeat in titles ("1st appearance of Venom").
enum ListingMentions {
    struct Mention { let phrase: String; let count: Int }

    static func keyPhrases(in titles: [String]) -> [Mention] {
        var counts: [String: (String, Int)] = [:]
        for title in titles {
            guard let phrase = firstMatch(#"\b((?:1st|first)\s+(?:full\s+|cameo\s+)?(?:app(?:earance)?\.?|appearance)(?:\s+of)?\s+[A-Za-z][A-Za-z\-' ]{2,30}?)(?=\s*(?:[,|/()\-]|cgc|cbcs|\d|$|key|nm|vf|fn|vg))"#, in: title)
                    ?? firstMatch(#"\b(origin of\s+[A-Za-z][A-Za-z\-' ]{2,25}|death of\s+[A-Za-z][A-Za-z\-' ]{2,25})"#, in: title) else { continue }
            let clean = phrase.trimmed
            let key = clean.lowercased()
            counts[key] = (counts[key]?.0 ?? clean, (counts[key]?.1 ?? 0) + 1)
        }
        return counts.values.filter { $0.1 >= 2 }
            .sorted { $0.1 > $1.1 }
            .prefix(3)
            .map { Mention(phrase: $0.0, count: $0.1) }
    }
}

/// A dollar amount field backed by optional cents.
struct CentsField: View {
    let title: String
    @Binding var cents: Int?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text(title).font(.subheadline).foregroundStyle(Theme.secondary)
            Spacer()
            Text("$").foregroundStyle(Theme.tertiary)
            TextField("—", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 100)
                .focused($focused)
        }
        .onAppear { text = cents.map { String(format: "%.2f", Double($0) / 100) } ?? "" }
        .onChange(of: focused) { _, isFocused in
            guard !isFocused else { return }
            let cleaned = text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "").trimmed
            if cleaned.isEmpty {
                cents = nil
            } else if let value = Double(cleaned) {
                cents = Int((value * 100).rounded())
            }
        }
        .toolbar {
            if focused {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = false }
                }
            }
        }
    }
}
