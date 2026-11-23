import SwiftUI
import SwiftData

/// Point of sale: build a buy, sale or trade, show the customer the offer, then complete it.
struct DealView: View {
    @Environment(DealCart.self) private var cart
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Show.date, order: .reverse) private var shows: [Show]

    @State private var showingInventoryPicker = false
    @State private var showingCustomerView = false
    @State private var confirmingComplete = false
    @State private var confirmingClear = false
    @State private var pendingKind: DealKind?
    @State private var completedMessage: String?
    @State private var bulkPercent = 60

    private var activeShow: Show? {
        guard let ref = Prefs.activeShowRef else { return nil }
        return shows.first { $0.ref == ref }
    }

    var body: some View {
        @Bindable var cart = cart

        NavigationStack {
            List {
                Section {
                    Picker("Deal type", selection: kindBinding) {
                        ForEach(DealKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if let show = activeShow {
                        Label("At \(show.name)", systemImage: "tent")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(modeHint)
                }

                if let completedMessage {
                    Section {
                        Label(completedMessage, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                if cart.kind.takesIn {
                    incomingSection
                }
                if cart.kind.givesOut {
                    outgoingSection
                }

                if !cart.lines.isEmpty {
                    totalsSection
                    Section {
                        TextField("Note (customer name, payment…)", text: $cart.note, axis: .vertical)
                    }
                    Section {
                        Button {
                            showingCustomerView = true
                        } label: {
                            Label("Show customer", systemImage: "person.crop.rectangle")
                        }
                        Button {
                            confirmingComplete = true
                        } label: {
                            Label("Complete \(cart.kind.rawValue.lowercased())", systemImage: "checkmark.seal.fill")
                                .font(.headline)
                        }
                        .disabled(cart.incoming.isEmpty && cart.outgoing.isEmpty)
                        Button("Clear deal", role: .destructive) { confirmingClear = true }
                    }
                }

                Section {
                    NavigationLink {
                        DealHistoryView()
                    } label: {
                        Label("Past deals", systemImage: "clock.arrow.circlepath")
                    }
                }
            }
            .navigationTitle("Deal")
            .sheet(isPresented: $showingInventoryPicker) {
                InventoryPicker()
            }
            .fullScreenCover(isPresented: $showingCustomerView) {
                CustomerView()
            }
            .confirmationDialog(completeTitle, isPresented: $confirmingComplete, titleVisibility: .visible) {
                Button("Complete") { complete() }
            } message: {
                Text(completeMessage)
            }
            .confirmationDialog("Clear this deal?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear", role: .destructive) { cart.clear() }
            }
            .confirmationDialog("Switch deal type?", isPresented: Binding(get: { pendingKind != nil }, set: { if !$0 { pendingKind = nil } }), titleVisibility: .visible) {
                Button("Switch to \(pendingKind?.rawValue ?? "")") {
                    if let pendingKind { cart.kind = pendingKind }
                    pendingKind = nil
                }
            } message: {
                Text("Some books in this deal don't apply to \(pendingKind?.rawValue ?? "that") and will be set aside (not deleted).")
            }
            .onAppear { bulkPercent = cart.offerPercent }
        }
    }

    // MARK: Sections

    private var incomingSection: some View {
        Section {
            ForEach(cart.incoming) { line in
                DealLineRow(line: line)
            }
            .onDelete { offsets in
                let ids = offsets.map { cart.incoming[$0].id }
                ids.forEach(cart.remove)
            }
            Button {
                appState.tab = .scan
            } label: {
                Label(cart.incoming.isEmpty ? "Scan comics to \(cart.kind == .buy ? "buy" : "take in")" : "Scan more",
                      systemImage: "barcode.viewfinder")
            }
        } header: {
            Text(cart.kind == .buy ? "Buying (\(cart.incoming.count))" : "Taking in (\(cart.incoming.count))")
        } footer: {
            if !cart.incoming.isEmpty {
                HStack {
                    Text("Offer % of market:")
                    Stepper("\(bulkPercent)%", value: $bulkPercent, in: 0...150, step: 5)
                        .fixedSize()
                    Button("Apply") { cart.setAll(percent: bulkPercent, direction: .incoming) }
                }
            }
        }
    }

    private var outgoingSection: some View {
        Section {
            ForEach(cart.outgoing) { line in
                DealLineRow(line: line)
            }
            .onDelete { offsets in
                let ids = offsets.map { cart.outgoing[$0].id }
                ids.forEach(cart.remove)
            }
            Button {
                showingInventoryPicker = true
            } label: {
                Label("Add from inventory", systemImage: "plus.rectangle.on.rectangle")
            }
        } header: {
            Text(cart.kind == .sell ? "Selling (\(cart.outgoing.count))" : "Trading out (\(cart.outgoing.count))")
        }
    }

    private var totalsSection: some View {
        Section("Totals") {
            switch cart.kind {
            case .buy:
                LabeledContent("Market value", value: formatCents(cart.marketInCents))
                LabeledContent("Your offer", value: formatCents(cart.offerInCents))
                    .font(.title3.bold())
                if cart.marketInCents > 0 {
                    LabeledContent("Offer is", value: "\(Int((Double(cart.offerInCents) / Double(cart.marketInCents) * 100).rounded()))% of market")
                }
            case .sell:
                LabeledContent("Market value", value: formatCents(cart.marketOutCents))
                LabeledContent("Customer pays", value: formatCents(cart.totalOutCents))
                    .font(.title3.bold())
                LabeledContent("Your profit", value: formatCents(cart.profitOutCents))
            case .trade:
                LabeledContent("Trade-in credit", value: formatCents(cart.offerInCents))
                LabeledContent("Trade-out value", value: formatCents(cart.totalOutCents))
                if cart.balanceCents >= 0 {
                    LabeledContent("Customer pays you", value: formatCents(cart.balanceCents))
                        .font(.title3.bold())
                } else {
                    LabeledContent("You pay customer", value: formatCents(-cart.balanceCents))
                        .font(.title3.bold())
                }
            }
            if cart.hiddenCount > 0 {
                Text("\(cart.hiddenCount) book\(cart.hiddenCount == 1 ? "" : "s") set aside — switch the deal type to see them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Helpers

    private var kindBinding: Binding<DealKind> {
        Binding(
            get: { cart.kind },
            set: { newKind in
                let wouldHide = cart.lines.contains { line in
                    (line.direction == .incoming && !newKind.takesIn) || (line.direction == .outgoing && !newKind.givesOut)
                }
                if wouldHide { pendingKind = newKind } else { cart.kind = newKind }
                bulkPercent = newKind == .trade ? Prefs.tradePercent : Prefs.buyPercent
            }
        )
    }

    private var modeHint: String {
        switch cart.kind {
        case .buy: return "Scan the customer's books. Offers start at \(Prefs.buyPercent)% of the average sold price; tap a price to change it."
        case .sell: return "Add books from your inventory. Prices start at your asking price (or market value)."
        case .trade: return "Scan what they bring (credited at \(Prefs.tradePercent)% of market) and add what they're taking from your inventory."
        }
    }

    private var completeTitle: String {
        switch cart.kind {
        case .buy: return "Pay \(formatCents(cart.offerInCents)) for \(cart.incoming.count) book\(cart.incoming.count == 1 ? "" : "s")?"
        case .sell: return "Sell \(cart.outgoing.count) book\(cart.outgoing.count == 1 ? "" : "s") for \(formatCents(cart.totalOutCents))?"
        case .trade:
            return cart.balanceCents >= 0
                ? "Complete trade — customer pays \(formatCents(cart.balanceCents))?"
                : "Complete trade — you pay \(formatCents(-cart.balanceCents))?"
        }
    }

    private var completeMessage: String {
        var parts: [String] = []
        if !cart.incoming.isEmpty { parts.append("Books coming in are added to your inventory with what you paid as their cost.") }
        if !cart.outgoing.isEmpty { parts.append("Books going out are marked sold.") }
        parts.append("You can void it later from Past deals.")
        return parts.joined(separator: " ")
    }

    private func complete() {
        let deal = cart.complete(in: modelContext)
        completedMessage = "\(deal.kind.rawValue) recorded: \(deal.summary)"
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

/// One book in the open deal, with an editable price.
struct DealLineRow: View {
    let line: DealLine
    @Environment(DealCart.self) private var cart
    @State private var priceText = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverThumb(url: line.imageURL, width: 44, height: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.spec.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(line.spec.detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(line.marketCents.map { "Market \(formatCents($0))" } ?? "No market price")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let profit = line.profitCents {
                    Text("Profit \(formatCents(profit))")
                        .font(.caption)
                        .foregroundStyle(profit >= 0 ? .green : .red)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                Text("$").foregroundStyle(.secondary)
                TextField("0", text: $priceText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                    .focused($focused)
                    .font(.body.monospacedDigit().weight(.semibold))
                    .onSubmit(commit)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
        .onAppear { priceText = Self.dollars(line.priceCents) }
        .onChange(of: line.priceCents) { _, cents in
            if !focused { priceText = Self.dollars(cents) }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
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

    private func commit() {
        guard let value = Double(priceText.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")) else {
            priceText = Self.dollars(line.priceCents)
            return
        }
        let cents = Int((value * 100).rounded())
        if cents != line.priceCents { cart.setPrice(cents, for: line.id) }
    }

    static func dollars(_ cents: Int) -> String {
        cents % 100 == 0 ? String(cents / 100) : String(format: "%.2f", Double(cents) / 100)
    }
}

struct CoverThumb: View {
    let url: String?
    var width: CGFloat = 44
    var height: CGFloat = 64

    var body: some View {
        AsyncImage(url: url.flatMap { URL(string: $0) }) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .overlay { Image(systemName: "book.closed").foregroundStyle(.secondary) }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// Pick books from your inventory to sell or trade out.
struct InventoryPicker: View {
    @Environment(DealCart.self) private var cart
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \CollectionItem.title) private var items: [CollectionItem]
    @State private var search = ""

    private var available: [CollectionItem] {
        let unsold = items.filter { $0.status != .sold }
        let text = search.trimmed.lowercased()
        guard !text.isEmpty else { return unsold }
        return unsold.filter {
            $0.title.lowercased().contains(text) || $0.details.lowercased().contains(text) || $0.boxName.lowercased().contains(text)
        }
    }

    var body: some View {
        NavigationStack {
            List(available) { item in
                let inDeal = cart.lines.contains { $0.itemRef != nil && $0.itemRef == item.ref }
                Button {
                    cart.addOutgoing(item)
                } label: {
                    HStack(spacing: 12) {
                        CoverThumb(url: item.imageURL, width: 36, height: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            Text(item.details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if !item.boxName.isEmpty {
                                Text(item.boxName).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(item.sellPriceCents.map(formatCents) ?? "—").monospacedDigit().foregroundStyle(.primary)
                        Image(systemName: inDeal ? "checkmark.circle.fill" : "plus.circle")
                            .foregroundStyle(inDeal ? Color.green : Color.accentColor)
                    }
                }
                .disabled(inDeal)
            }
            .overlay {
                if available.isEmpty {
                    ContentUnavailableView("Nothing to add", systemImage: "books.vertical",
                                           description: Text("Books you keep or have for sale show up here."))
                }
            }
            .searchable(text: $search, prompt: "Title, variant, box")
            .navigationTitle("Add from inventory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Big, simple screen to turn toward the customer.
struct CustomerView: View {
    @Environment(DealCart.self) private var cart
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 8) {
                        Text(headline)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text(formatCents(amount))
                            .font(.system(size: 60, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .minimumScaleFactor(0.5)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                if !cart.incoming.isEmpty {
                    Section(cart.kind == .buy ? "We're buying" : "You're trading in") {
                        ForEach(cart.incoming) { line in
                            customerRow(line)
                        }
                    }
                }
                if !cart.outgoing.isEmpty {
                    Section(cart.kind == .sell ? "You're buying" : "You're getting") {
                        ForEach(cart.outgoing) { line in
                            customerRow(line)
                        }
                    }
                }
            }
            .navigationTitle("Your deal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func customerRow(_ line: DealLine) -> some View {
        HStack(spacing: 12) {
            CoverThumb(url: line.imageURL, width: 40, height: 58)
            VStack(alignment: .leading) {
                Text(line.spec.displayTitle).font(.headline)
                Text(line.spec.detailLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(formatCents(line.priceCents))
                .font(.headline.monospacedDigit())
        }
    }

    private var headline: String {
        switch cart.kind {
        case .buy: return "Our offer"
        case .sell: return "Your total"
        case .trade: return cart.balanceCents >= 0 ? "You pay the difference" : "We pay you"
        }
    }

    private var amount: Int {
        switch cart.kind {
        case .buy: return cart.offerInCents
        case .sell: return cart.totalOutCents
        case .trade: return abs(cart.balanceCents)
        }
    }
}

/// Finished deals, newest first. Tap one to see it or void it.
struct DealHistoryView: View {
    @Query(sort: \Deal.date, order: .reverse) private var deals: [Deal]
    @Query private var shows: [Show]

    var body: some View {
        List {
            ForEach(deals) { deal in
                NavigationLink {
                    DealDetailView(deal: deal)
                } label: {
                    DealRow(deal: deal, showName: shows.first { $0.ref == deal.showRef }?.name)
                }
            }
        }
        .overlay {
            if deals.isEmpty {
                ContentUnavailableView("No deals yet", systemImage: "arrow.left.arrow.right",
                                       description: Text("Completed buys, sales and trades show up here."))
            }
        }
        .navigationTitle("Past deals")
    }
}

struct DealRow: View {
    let deal: Deal
    var showName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(deal.kind.rawValue).font(.headline)
                if deal.voided {
                    Text("VOID").font(.caption.bold()).foregroundStyle(.red)
                }
                Spacer()
                Text(deal.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(deal.summary)
                .font(.subheadline)
                .strikethrough(deal.voided)
            if let showName {
                Label(showName, systemImage: "tent").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct DealDetailView: View {
    let deal: Deal
    @Environment(\.modelContext) private var modelContext
    @State private var confirmingVoid = false

    var body: some View {
        List {
            Section {
                LabeledContent("Type", value: deal.kind.rawValue)
                LabeledContent("Date", value: deal.date.formatted(date: .abbreviated, time: .shortened))
                if deal.cashInCents > 0 { LabeledContent("Customer paid", value: formatCents(deal.cashInCents)) }
                if deal.cashOutCents > 0 { LabeledContent("You paid", value: formatCents(deal.cashOutCents)) }
                if !deal.outgoing.isEmpty { LabeledContent("Profit", value: formatCents(deal.profitCents)) }
                if !deal.note.isEmpty { Text(deal.note).font(.callout) }
                if deal.voided { Label("Voided", systemImage: "xmark.octagon").foregroundStyle(.red) }
            }
            if !deal.incoming.isEmpty {
                Section("Came in") {
                    ForEach(deal.incoming) { line in lineRow(line) }
                }
            }
            if !deal.outgoing.isEmpty {
                Section("Went out") {
                    ForEach(deal.outgoing) { line in lineRow(line) }
                }
            }
            if !deal.voided {
                Section {
                    Button("Void this deal", role: .destructive) { confirmingVoid = true }
                } footer: {
                    Text("Voiding takes bought books back out of inventory and puts sold books back on sale.")
                }
            }
        }
        .navigationTitle(deal.kind.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Void this deal?", isPresented: $confirmingVoid, titleVisibility: .visible) {
            Button("Void deal", role: .destructive) { DealCart.void(deal, in: modelContext) }
        }
    }

    private func lineRow(_ line: DealLine) -> some View {
        HStack(spacing: 12) {
            CoverThumb(url: line.imageURL, width: 36, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.spec.displayTitle).font(.subheadline.weight(.semibold))
                Text(line.spec.detailLine).font(.caption).foregroundStyle(.secondary)
                if let market = line.marketCents {
                    Text("Market \(formatCents(market))").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(formatCents(line.priceCents)).monospacedDigit()
                if let profit = line.profitCents {
                    Text("\(profit >= 0 ? "+" : "")\(formatCents(profit))")
                        .font(.caption)
                        .foregroundStyle(profit >= 0 ? .green : .red)
                }
            }
        }
    }
}
