import SwiftUI
import SwiftData

/// Comic cons and shows you vend at. Deals made while a show is active are counted under it.
struct ShowsView: View {
    @Query(sort: \Show.date, order: .reverse) private var shows: [Show]
    @Query(sort: \Deal.date, order: .reverse) private var deals: [Deal]
    @Environment(\.modelContext) private var modelContext
    @AppStorage(Prefs.activeShowKey) private var activeShowID = ""

    @State private var creating = false
    @State private var newName = ""
    @State private var newDate = Date()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    let totals = DealTotals(deals: deals, expensesCents: shows.map(\.expenseCents).reduce(0, +))
                    TotalsRows(totals: totals)
                } header: {
                    Text("All deals")
                }

                Section {
                    ForEach(shows) { show in
                        NavigationLink {
                            ShowDetailView(show: show)
                        } label: {
                            ShowRow(show: show, deals: deals.filter { $0.showRef == show.ref }, active: show.ref.uuidString == activeShowID)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            if shows[index].ref.uuidString == activeShowID { activeShowID = "" }
                            modelContext.delete(shows[index])
                        }
                    }
                    Button {
                        newName = ""
                        newDate = .now
                        creating = true
                    } label: {
                        Label("New show", systemImage: "plus")
                    }
                } header: {
                    Text("Shows")
                } footer: {
                    Text("Make a show active and every buy, sale and trade gets counted under it, with your table and travel costs.")
                }
            }
            .navigationTitle("Shows")
            .alert("New show", isPresented: $creating) {
                TextField("Name (e.g. Indy Comic Con)", text: $newName)
                Button("Create and start") {
                    let show = Show(name: newName.trimmed.isEmpty ? "Show" : newName.trimmed, date: newDate)
                    modelContext.insert(show)
                    activeShowID = show.ref.uuidString
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deals you make from now on are counted under this show until you end it.")
            }
        }
    }
}

struct ShowRow: View {
    let show: Show
    let deals: [Deal]
    let active: Bool

    var body: some View {
        let totals = DealTotals(deals: deals, expensesCents: show.expenseCents)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(show.name).font(.headline)
                if active {
                    Text("ACTIVE")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.2), in: Capsule())
                        .foregroundStyle(.green)
                }
                Spacer()
                Text(show.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(totals.deals) deals · profit \(formatCents(totals.netProfitCents)) · cash \(formatCents(totals.netCashCents))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

struct TotalsRows: View {
    let totals: DealTotals

    var body: some View {
        LabeledContent("Deals", value: "\(totals.deals)")
        LabeledContent("Sales", value: "\(formatCents(totals.salesCents)) · \(totals.booksOut) books")
        LabeledContent("Bought / traded in", value: "\(formatCents(totals.boughtCents)) · \(totals.booksIn) books")
        if totals.expensesCents > 0 {
            LabeledContent("Expenses", value: formatCents(totals.expensesCents))
        }
        LabeledContent("Profit on books sold") {
            Text(formatCents(totals.netProfitCents))
                .foregroundStyle(totals.netProfitCents >= 0 ? .green : .red)
                .fontWeight(.semibold)
        }
        LabeledContent("Cash in hand change") {
            Text("\(totals.netCashCents >= 0 ? "+" : "−")\(formatCents(abs(totals.netCashCents)))")
                .foregroundStyle(totals.netCashCents >= 0 ? .green : .red)
        }
    }
}

struct ShowDetailView: View {
    @Bindable var show: Show
    @Query(sort: \Deal.date, order: .reverse) private var allDeals: [Deal]
    @AppStorage(Prefs.activeShowKey) private var activeShowID = ""

    @State private var expenseLabel = ""
    @State private var expenseCents: Int?

    private var deals: [Deal] { allDeals.filter { $0.showRef == show.ref } }
    private var isActive: Bool { show.ref.uuidString == activeShowID }

    var body: some View {
        List {
            Section {
                TextField("Name", text: $show.name)
                DatePicker("Date", selection: $show.date, displayedComponents: .date)
                Button {
                    activeShowID = isActive ? "" : show.ref.uuidString
                } label: {
                    Label(isActive ? "End show (stop counting deals)" : "Make active",
                          systemImage: isActive ? "stop.circle" : "play.circle")
                }
            }

            Section("Results") {
                TotalsRows(totals: DealTotals(deals: deals, expensesCents: show.expenseCents))
            }

            Section {
                ForEach(show.expenses) { expense in
                    LabeledContent(expense.label, value: formatCents(expense.cents))
                }
                .onDelete { offsets in
                    var list = show.expenses
                    list.remove(atOffsets: offsets)
                    show.expenses = list
                }
                HStack {
                    TextField("Table, travel, food…", text: $expenseLabel)
                    CentsField(title: "", cents: $expenseCents)
                        .frame(maxWidth: 120)
                    Button {
                        guard let cents = expenseCents, cents > 0 else { return }
                        show.expenses = show.expenses + [Expense(label: expenseLabel.trimmed.isEmpty ? "Expense" : expenseLabel.trimmed, cents: cents)]
                        expenseLabel = ""
                        expenseCents = nil
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                }
            } header: {
                Text("Expenses")
            } footer: {
                Text("Expenses come off the show's profit.")
            }

            Section("Deals (\(deals.count))") {
                ForEach(deals) { deal in
                    NavigationLink {
                        DealDetailView(deal: deal)
                    } label: {
                        DealRow(deal: deal)
                    }
                }
            }

            Section {
                TextField("Notes", text: $show.notes, axis: .vertical)
            }
        }
        .navigationTitle(show.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
