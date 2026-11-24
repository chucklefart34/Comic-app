import SwiftData
import SwiftUI
import UIKit

/// One scanned book in the tray at the bottom of the Scan screen. It identifies and prices itself
/// in the background, so you can keep scanning.
@MainActor
@Observable
final class TrayItem: Identifiable {
    enum State: Equatable {
        /// First photo taken; waiting for the barcode (or a second cover photo).
        case waitingSecond
        case identifying
        case pricing
        case done
        case notFound(String)
    }

    let id = UUID()
    var state: State = .identifying
    var status = "Identifying…"
    var photo: UIImage?
    var identification: Identification?
    var record: ComicRecord?
    var quantity = 1
    /// The match wasn't certain: shown with a "Check match" flag.
    var needsCheck = false
    var priceError: String?
    /// Scanning a barcode or another photo to help identify this book.
    var addingPhoto = false
    fileprivate var task: Task<Void, Never>?
    /// What the first photo found, worked out while you take the second.
    fileprivate var firstLook: Task<Identification, Never>?
    var firstWasBarcode = false

    init(photo: UIImage?) {
        self.photo = photo
    }

    var isWorking: Bool { state == .identifying || state == .pricing }

    /// Value of one copy for the chosen condition.
    var unitCents: Int? { record?.displayValueCents }
    var totalCents: Int { (unitCents ?? 0) * quantity }
}

/// The scan → identify → price flow behind the Scan screen. Every scan becomes a tray item right away.
@MainActor
@Observable
final class ScanSession {
    var items: [TrayItem] = []
    var selectedID: UUID?
    /// When set, the next camera event is an extra photo for this item instead of a new book.
    var collectingFor: UUID?
    /// The book waiting for its second photo (barcode, or the cover again).
    var pendingID: UUID?
    /// Asks the camera not to auto-capture the same thing again until it changes.
    var onNeedNewComic: (() -> Void)?
    /// A short message shown over the camera ("Added 3 to Collection").
    var toast: String?

    private var toastTask: Task<Void, Never>?

    var pending: TrayItem? { items.first { $0.id == pendingID } }

    var selected: TrayItem? { items.first { $0.id == selectedID } ?? items.first }
    var totalCents: Int { items.reduce(0) { $0 + $1.totalCents } }
    var addableCount: Int { items.filter { $0.record != nil }.reduce(0) { $0 + $1.quantity } }
    var anyWorking: Bool { items.contains { $0.isWorking } }

    // MARK: Camera events

    func handle(_ event: CameraEvent, context: ModelContext, bot: WebBot) {
        if let id = collectingFor, let item = items.first(where: { $0.id == id }) {
            addPhoto(event, to: item, context: context, bot: bot)
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        // Second photo for the book that's waiting: combine both and price it.
        if let item = pending, !isSlab(event) {
            secondPhoto(event, for: item, context: context, bot: bot)
            return
        }

        let item: TrayItem
        switch event {
        case .barcode(let barcode, _):
            item = TrayItem(photo: nil)
            item.firstWasBarcode = true
            item.status = barcode.issueNumber.map { "Barcode · issue #\($0)" } ?? "Barcode read"
            add(item)
            item.task = Task {
                let result = await Identifier.identify(barcode: barcode, frame: nil, context: context, bot: bot)
                await finish(item, with: result, context: context, bot: bot)
            }
        case .cover(let cover, _):
            item = TrayItem(photo: UIImage(cgImage: cover))
            item.status = "Cover captured"
            add(item)
            item.task = Task {
                let result = await Identifier.identify(cover: cover, context: context, bot: bot)
                await finish(item, with: result, context: context, bot: bot)
            }
        case .slab(let cert):
            item = TrayItem(photo: nil)
            item.status = "Reading \(cert.company.rawValue) cert \(cert.number)…"
            add(item)
            item.task = Task {
                do {
                    let result = try await CertLookup.lookUp(cert, bot: bot)
                    guard !result.spec.isEmpty else {
                        item.state = .notFound("Couldn't read the cert page. Scan the cover instead.")
                        return
                    }
                    let candidate = Candidate(spec: result.spec, imageURL: result.spec.coverImageURL.nilIfEmpty, source: cert.company.rawValue)
                    await use(candidate, for: item, learn: false, context: context, bot: bot)
                } catch {
                    if !error.isCancellation { item.state = .notFound(error.localizedDescription) }
                }
            }
        }
    }

    private func isSlab(_ event: CameraEvent) -> Bool {
        if case .slab = event { return true }
        return false
    }

    /// Starts identifying from the first photo right away, and waits for the second.
    private func startWaiting(_ item: TrayItem, identify: @escaping @MainActor () async -> Identification) {
        item.state = .waitingSecond
        item.firstLook = Task { await identify() }
        pendingID = item.id
    }

    private func secondPhoto(_ event: CameraEvent, for item: TrayItem, context: ModelContext, bot: WebBot) {
        pendingID = nil
        item.state = .identifying
        let first = item.firstLook
        item.task = Task {
            let second: Identification
            switch event {
            case .barcode(let barcode, _):
                item.status = barcode.issueNumber.map { "Barcode · issue #\($0)" } ?? "Barcode read"
                second = await Identifier.identify(barcode: barcode, frame: nil, context: context, bot: bot)
            case .cover(let cover, _):
                if item.photo == nil { item.photo = UIImage(cgImage: cover) }
                item.status = item.firstWasBarcode ? "Cover captured" : "Second cover photo"
                second = await Identifier.identify(cover: cover, context: context, bot: bot)
            case .slab:
                return
            }
            guard !Task.isCancelled else { return }
            item.status = "Matching both photos…"
            let result: Identification
            if let firstResult = await first?.value {
                result = await Identifier.combine(firstResult, second)
            } else {
                result = second
            }
            await finish(item, with: result, context: context, bot: bot)
        }
    }

    /// Use only the first photo (no barcode and you don't want a second shot).
    func skipSecondPhoto(_ item: TrayItem, context: ModelContext, bot: WebBot) {
        if pendingID == item.id { pendingID = nil }
        item.state = .identifying
        let first = item.firstLook
        item.task = Task {
            guard let result = await first?.value else { return }
            await finish(item, with: result, context: context, bot: bot)
        }
    }

    private func add(_ item: TrayItem) {
        withAnimation(.snappy) {
            items.insert(item, at: 0)
            selectedID = item.id
        }
    }

    private func finish(_ item: TrayItem, with result: Identification, context: ModelContext, bot: WebBot) async {
        guard !Task.isCancelled, items.contains(where: { $0.id == item.id }) else { return }
        item.identification = result
        guard let best = result.best else {
            item.state = .notFound(result.message ?? "Couldn't identify this one. Try the barcode, or search by title.")
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        // Not certain: use the closest match for now and flag it, rather than stopping you.
        item.needsCheck = !result.confident
        let learn = result.confident && best.source != "Your scans" && best.source != "Your covers"
        await use(best, for: item, learn: learn, context: context, bot: bot)
    }

    /// Puts a match on the item and prices it.
    private func use(_ candidate: Candidate, for item: TrayItem, learn: Bool, context: ModelContext, bot: WebBot) async {
        if learn { Identifier.remember(candidate, from: item.identification, context: context) }

        let thumbnail = item.photo?.cgImage.flatMap(CoverRecognizer.thumbnailJPEG)
        let previousCondition = item.record?.condition
        let record = ComicRecord(spec: candidate.spec, imageURL: candidate.imageURL ?? candidate.spec.coverImageURL.nilIfEmpty, thumbnail: thumbnail)
        context.insert(record)
        if let old = item.record, !old.inCollection { context.delete(old) }
        item.record = record
        if let previousCondition { record.condition = previousCondition }
        if let saved = PricingService.cached(candidate.spec) ?? SalesStore.latestValuation(for: candidate.spec, context: context) {
            record.setValuation(saved)
        }
        if !item.needsCheck { UINotificationFeedbackGenerator().notificationOccurred(.success) }

        async let details: Void = fillDetails(record)
        await price(item, bot: bot, context: context)
        await details
    }

    func price(_ item: TrayItem, bot: WebBot, context: ModelContext, force: Bool = false) async {
        guard let record = item.record else { return }
        item.state = .pricing
        item.status = "Finding sold prices…"
        item.priceError = nil
        do {
            let result = try await PricingService.valuation(for: record.spec, bot: bot, context: context, forceRefresh: force)
            guard item.record === record else { return }
            record.setValuation(result)
            if !result.hasAnyPrice { item.priceError = "No sales found" }
        } catch {
            guard !error.isCancellation, item.record === record else { return }
            item.priceError = NetworkMonitor.shared.isOnline ? "Couldn't load prices" : "Offline"
        }
        if item.record === record { item.state = .done }
    }

    /// Adds credits/key info from VerseDB when the match came from somewhere else.
    private func fillDetails(_ record: ComicRecord) async {
        var spec = record.spec
        guard let verseDB = VerseDBClient.shared, let id = spec.verseDBIssueID, spec.writer.isEmpty && spec.keyNotes.isEmpty,
              let detail = try? await verseDB.issue(id: id) else { return }
        spec.writer = detail.writer
        spec.coverArtist = detail.coverArtist
        spec.keyNotes = detail.keyNotes
        if spec.publisher.isEmpty { spec.publisher = detail.publisher }
        if spec.year.isEmpty { spec.year = detail.year }
        if spec.isbn.isEmpty { spec.isbn = detail.isbn }
        if spec.upc.isEmpty { spec.upc = detail.upc }
        spec.variantCount = detail.variantCount
        record.update(spec: spec)
    }

    // MARK: Fixing a match

    /// You picked the right match from the list (or a search).
    func choose(_ candidate: Candidate, for item: TrayItem, context: ModelContext, bot: WebBot) {
        item.needsCheck = false
        item.state = .identifying
        item.status = "Updating…"
        item.task?.cancel()
        item.task = Task { await use(candidate, for: item, learn: true, context: context, bot: bot) }
    }

    /// A typed search when nothing was scanned (or for a new book).
    func addSearched(_ candidate: Candidate, context: ModelContext, bot: WebBot) {
        let item = TrayItem(photo: nil)
        add(item)
        item.task = Task { await use(candidate, for: item, learn: false, context: context, bot: bot) }
    }

    func reprice(_ item: TrayItem, bot: WebBot, context: ModelContext) {
        item.task?.cancel()
        item.task = Task { await price(item, bot: bot, context: context, force: true) }
    }

    // MARK: Extra photos

    func startAddingPhoto(to item: TrayItem) {
        collectingFor = item.id
        item.addingPhoto = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func stopAddingPhoto() {
        items.first { $0.id == collectingFor }?.addingPhoto = false
        collectingFor = nil
    }

    private func addPhoto(_ event: CameraEvent, to item: TrayItem, context: ModelContext, bot: WebBot) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        stopAddingPhoto()
        guard let current = item.identification else { return }
        item.task?.cancel()
        item.state = .identifying
        item.task = Task {
            let extra: Identification
            switch event {
            case .barcode(let barcode, _):
                item.status = barcode.issueNumber.map { "Barcode added · issue #\($0)" } ?? "Barcode added"
                extra = await Identifier.identify(barcode: barcode, frame: nil, context: context, bot: bot)
            case .cover(let cover, _):
                item.status = "Photo added"
                extra = await Identifier.identify(cover: cover, context: context, bot: bot)
            case .slab(let cert):
                item.status = "Reading \(cert.company.rawValue) cert…"
                guard let result = try? await CertLookup.lookUp(cert, bot: bot), !result.spec.isEmpty else {
                    item.state = item.record == nil ? .notFound("Couldn't read the cert page.") : .done
                    return
                }
                item.needsCheck = false
                await use(Candidate(spec: result.spec, imageURL: result.spec.coverImageURL.nilIfEmpty, source: cert.company.rawValue),
                          for: item, learn: false, context: context, bot: bot)
                return
            }
            guard !Task.isCancelled else { return }
            let combined = await Identifier.combine(current, extra)
            await finish(item, with: combined, context: context, bot: bot)
        }
    }

    // MARK: Tray actions

    func remove(_ item: TrayItem) {
        item.task?.cancel()
        item.firstLook?.cancel()
        if collectingFor == item.id { collectingFor = nil }
        if pendingID == item.id { pendingID = nil }
        withAnimation(.snappy) {
            let index = items.firstIndex { $0.id == item.id }
            items.removeAll { $0.id == item.id }
            if selectedID == item.id, let index {
                selectedID = items.indices.contains(index) ? items[index].id : items.last?.id
            }
        }
    }

    func clear() {
        items.forEach { $0.task?.cancel(); $0.firstLook?.cancel() }
        withAnimation(.snappy) { items.removeAll() }
        collectingFor = nil
        pendingID = nil
        selectedID = nil
    }

    /// Saves every identified book in the tray to your Collection (one entry per copy) and empties the tray.
    func addAllToCollection(context: ModelContext) {
        var added = 0
        for item in items {
            guard let record = item.record else { continue }
            record.inCollection = true
            added += 1
            for _ in 1..<max(1, item.quantity) {
                let copy = ComicRecord(spec: record.spec, imageURL: record.imageURL, thumbnail: record.thumbnail)
                copy.condition = record.condition
                copy.valuationData = record.valuationData
                copy.valueCents = record.valueCents
                copy.confidenceRaw = record.confidenceRaw
                copy.pricedAt = record.pricedAt
                copy.inCollection = true
                context.insert(copy)
                added += 1
            }
        }
        let leftover = items.filter { $0.record == nil }
        withAnimation(.snappy) {
            items = leftover
            selectedID = leftover.first?.id
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        show(toast: added == 1 ? "Added 1 comic to Collection" : "Added \(added) comics to Collection")
    }

    func show(toast text: String) {
        toastTask?.cancel()
        withAnimation { toast = text }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { toast = nil }
        }
    }
}
