import Foundation
import SwiftData

/// The deal you're building right now. Saved on the phone as you go, so nothing is lost if the app closes mid-deal.
@MainActor
@Observable
final class DealCart {
    var kind: DealKind = .buy {
        didSet {
            if kind != oldValue { repriceIncoming() }
            save()
        }
    }
    var lines: [DealLine] = [] {
        didSet { save() }
    }
    var note = ""

    private static let storageKey = "openDeal"

    init() {
        load()
    }

    // MARK: Lines that count in the current mode

    var incoming: [DealLine] { kind.takesIn ? lines.filter { $0.direction == .incoming } : [] }
    var outgoing: [DealLine] { kind.givesOut ? lines.filter { $0.direction == .outgoing } : [] }

    /// Lines that don't belong to the current mode (e.g. books you were buying, after switching to Sell).
    var hiddenCount: Int { lines.count - incoming.count - outgoing.count }

    // MARK: Totals

    var marketInCents: Int { incoming.compactMap(\.marketCents).reduce(0, +) }
    var offerInCents: Int { incoming.map(\.priceCents).reduce(0, +) }
    var marketOutCents: Int { outgoing.compactMap(\.marketCents).reduce(0, +) }
    var totalOutCents: Int { outgoing.map(\.priceCents).reduce(0, +) }
    var profitOutCents: Int { outgoing.compactMap(\.profitCents).reduce(0, +) }

    /// Positive: the customer pays you. Negative: you pay the customer.
    var balanceCents: Int { totalOutCents - offerInCents }

    /// The number shown on the scanner's deal button.
    var headlineCents: Int {
        switch kind {
        case .buy: return offerInCents
        case .sell: return totalOutCents
        case .trade: return abs(balanceCents)
        }
    }

    var offerPercent: Int { kind == .trade ? Prefs.tradePercent : Prefs.buyPercent }

    /// What you'd offer for a book worth `marketCents` at the current buy / trade-credit percentage.
    func offer(for marketCents: Int?) -> Int {
        guard let marketCents else { return 0 }
        let raw = Double(marketCents) * Double(offerPercent) / 100
        if Prefs.roundOffers {
            return Int((raw / 100).rounded(.down)) * 100
        }
        return Int(raw.rounded())
    }

    // MARK: Editing

    func addIncoming(spec: ComicSpec, marketCents: Int?, imageURL: String?) {
        if kind == .sell { kind = .trade }
        lines.append(DealLine(
            spec: spec,
            direction: .incoming,
            imageURL: imageURL,
            marketCents: marketCents,
            priceCents: offer(for: marketCents)
        ))
    }

    func addOutgoing(_ item: CollectionItem) {
        let ref = item.stableRef
        guard !lines.contains(where: { $0.itemRef == ref }) else { return }
        if kind == .buy { kind = .trade }
        lines.append(DealLine(
            spec: item.spec,
            direction: .outgoing,
            imageURL: item.imageURL,
            marketCents: item.valueCents,
            priceCents: item.sellPriceCents ?? 0,
            costCents: item.costCents,
            itemRef: ref
        ))
    }

    func setPrice(_ cents: Int, for lineID: UUID) {
        guard let index = lines.firstIndex(where: { $0.id == lineID }) else { return }
        lines[index].priceCents = max(0, cents)
        lines[index].priceEdited = true
    }

    /// Sets every line in a direction to a percentage of market.
    func setAll(percent: Int, direction: DealLine.Direction) {
        for index in lines.indices where lines[index].direction == direction {
            guard let market = lines[index].marketCents else { continue }
            lines[index].priceCents = Int((Double(market) * Double(percent) / 100).rounded())
            lines[index].priceEdited = true
        }
    }

    func remove(_ lineID: UUID) {
        lines.removeAll { $0.id == lineID }
    }

    func repriceIncoming() {
        for index in lines.indices where lines[index].direction == .incoming && !lines[index].priceEdited {
            lines[index].priceCents = offer(for: lines[index].marketCents)
        }
    }

    func clear() {
        lines = []
        note = ""
        kind = .buy
    }

    // MARK: Completing

    /// Moves the books in and out of inventory, records the deal, and empties the cart.
    @discardableResult
    func complete(in context: ModelContext) -> Deal {
        let inventory = (try? context.fetch(FetchDescriptor<CollectionItem>())) ?? []
        var recorded: [DealLine] = []

        for var line in incoming + outgoing {
            switch line.direction {
            case .incoming:
                let item = CollectionItem(spec: line.spec, stats: nil, imageURL: line.imageURL)
                item.valueCents = line.marketCents
                item.pricedAt = line.marketCents == nil ? nil : .now
                item.costCents = line.priceCents
                item.status = Prefs.buysGoForSale ? .forSale : .collection
                context.insert(item)
                line.itemRef = item.stableRef
            case .outgoing:
                if let ref = line.itemRef, let item = inventory.first(where: { $0.ref == ref }) {
                    item.status = .sold
                    item.soldCents = line.priceCents
                    item.soldAt = .now
                    line.costCents = item.costCents
                }
            }
            recorded.append(line)
        }

        var cashIn = 0
        var cashOut = 0
        switch kind {
        case .buy: cashOut = offerInCents
        case .sell: cashIn = totalOutCents
        case .trade:
            if balanceCents > 0 { cashIn = balanceCents } else { cashOut = -balanceCents }
        }

        let deal = Deal(kind: kind, lines: recorded, showRef: Prefs.activeShowRef,
                        cashInCents: cashIn, cashOutCents: cashOut, note: note)
        context.insert(deal)
        try? context.save()
        clear()
        return deal
    }

    /// Undoes a finished deal: bought books come back out of inventory, sold books go back on sale.
    static func void(_ deal: Deal, in context: ModelContext) {
        guard !deal.voided else { return }
        let inventory = (try? context.fetch(FetchDescriptor<CollectionItem>())) ?? []
        for line in deal.lines {
            guard let ref = line.itemRef, let item = inventory.first(where: { $0.ref == ref }) else { continue }
            switch line.direction {
            case .incoming:
                context.delete(item)
            case .outgoing:
                item.status = .forSale
                item.soldCents = nil
                item.soldAt = nil
            }
        }
        deal.voided = true
        try? context.save()
    }

    // MARK: Saving the open deal

    private struct Stored: Codable {
        var kind: DealKind
        var lines: [DealLine]
    }

    private var loading = false

    private func save() {
        guard !loading, let data = try? JSONEncoder().encode(Stored(kind: kind, lines: lines)) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        loading = true
        kind = stored.kind
        lines = stored.lines
        loading = false
    }
}
