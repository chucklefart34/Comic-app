import Foundation
import SwiftData

enum DealKind: String, Codable, CaseIterable, Identifiable {
    case buy = "Buy"
    case sell = "Sell"
    case trade = "Trade"

    var id: String { rawValue }

    var takesIn: Bool { self != .sell }
    var givesOut: Bool { self != .buy }
}

/// One comic in a deal. Incoming = you receive it (buying, trade-in). Outgoing = you hand it over.
struct DealLine: Codable, Hashable, Identifiable {
    enum Direction: String, Codable {
        case incoming, outgoing
    }

    var id = UUID()
    var spec: ComicSpec
    var direction: Direction
    var imageURL: String?
    /// Average sold price when it was added.
    var marketCents: Int?
    /// What you pay / credit (incoming) or what you charge (outgoing).
    var priceCents: Int
    /// True once you've typed a price, so changing the offer % leaves it alone.
    var priceEdited = false
    /// Outgoing only: what you paid for it, for profit.
    var costCents: Int?
    /// The inventory book this line created (incoming) or sold (outgoing).
    var itemRef: UUID?

    var profitCents: Int? {
        guard direction == .outgoing, let costCents else { return nil }
        return priceCents - costCents
    }
}

/// A finished buy, sale or trade.
@Model
final class Deal {
    var kindRaw: String
    var date: Date
    var linesData: Data
    var showRef: UUID?
    /// Money the customer paid you (sales, trades where they add cash).
    var cashInCents: Int
    /// Money you paid the customer (buys, trades where you add cash).
    var cashOutCents: Int
    var voided: Bool
    var note: String

    init(kind: DealKind, lines: [DealLine], showRef: UUID?, cashInCents: Int, cashOutCents: Int, note: String = "") {
        self.kindRaw = kind.rawValue
        self.date = .now
        self.linesData = (try? JSONEncoder().encode(lines)) ?? Data()
        self.showRef = showRef
        self.cashInCents = cashInCents
        self.cashOutCents = cashOutCents
        self.voided = false
        self.note = note
    }

    var kind: DealKind { DealKind(rawValue: kindRaw) ?? .buy }

    var lines: [DealLine] {
        (try? JSONDecoder().decode([DealLine].self, from: linesData)) ?? []
    }

    var incoming: [DealLine] { lines.filter { $0.direction == .incoming } }
    var outgoing: [DealLine] { lines.filter { $0.direction == .outgoing } }

    var salesCents: Int { outgoing.map(\.priceCents).reduce(0, +) }
    var boughtCents: Int { incoming.map(\.priceCents).reduce(0, +) }
    var profitCents: Int { outgoing.compactMap(\.profitCents).reduce(0, +) }

    var summary: String {
        switch kind {
        case .buy: return "Bought \(incoming.count) for \(formatCents(cashOutCents))"
        case .sell: return "Sold \(outgoing.count) for \(formatCents(cashInCents))"
        case .trade:
            var text = "Traded \(outgoing.count) out, \(incoming.count) in"
            if cashInCents > 0 { text += " · +\(formatCents(cashInCents))" }
            if cashOutCents > 0 { text += " · −\(formatCents(cashOutCents))" }
            return text
        }
    }
}

struct Expense: Codable, Hashable, Identifiable {
    var id = UUID()
    var label: String
    var cents: Int
}

/// A comic con or show you vend at. Deals made while it's active are grouped under it.
@Model
final class Show {
    var ref: UUID
    var name: String
    var date: Date
    var expensesData: Data
    var notes: String

    init(name: String, date: Date = .now) {
        self.ref = UUID()
        self.name = name
        self.date = date
        self.expensesData = (try? JSONEncoder().encode([Expense]())) ?? Data()
        self.notes = ""
    }

    var expenses: [Expense] {
        get { (try? JSONDecoder().decode([Expense].self, from: expensesData)) ?? [] }
        set { expensesData = (try? JSONEncoder().encode(newValue)) ?? expensesData }
    }

    var expenseCents: Int { expenses.map(\.cents).reduce(0, +) }
}

/// Totals for a set of deals (one show, or everything).
struct DealTotals {
    var deals = 0
    var salesCents = 0
    var boughtCents = 0
    var profitCents = 0
    var cashInCents = 0
    var cashOutCents = 0
    var expensesCents = 0
    var booksIn = 0
    var booksOut = 0

    init(deals: [Deal], expensesCents: Int = 0) {
        for deal in deals where !deal.voided {
            self.deals += 1
            salesCents += deal.salesCents
            boughtCents += deal.boughtCents
            profitCents += deal.profitCents
            cashInCents += deal.cashInCents
            cashOutCents += deal.cashOutCents
            booksIn += deal.incoming.count
            booksOut += deal.outgoing.count
        }
        self.expensesCents = expensesCents
    }

    var netProfitCents: Int { profitCents - expensesCents }
    var netCashCents: Int { cashInCents - cashOutCents - expensesCents }
}
