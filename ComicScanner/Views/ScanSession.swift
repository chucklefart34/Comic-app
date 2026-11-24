import SwiftData
import SwiftUI
import UIKit

/// The scan → identify → price flow behind the Scan screen.
@MainActor
@Observable
final class ScanSession {
    enum Phase: Equatable {
        case idle
        case identifying
        case confirm
        case result
        case message
    }

    var phase: Phase = .idle
    var statusText = ""
    var message = ""
    var identification: Identification?
    var photo: UIImage?
    /// Extra photos taken on the "Which one is it?" card (barcode, other angles).
    var evidencePhotos: [UIImage] = []
    var collectingMore = false
    var addingEvidence = false

    // Current result
    var record: ComicRecord?
    var valuation: Valuation?
    var loadingPrice = false
    var priceError: String?

    private var work: Task<Void, Never>?
    private var modelContext: ModelContext?

    var spec: ComicSpec? { record?.spec }

    // MARK: Camera events

    func handle(_ event: CameraEvent, context: ModelContext, bot: WebBot) {
        modelContext = context
        // On the "Which one is it?" card, the camera only counts when you've asked to add a photo.
        if phase == .confirm {
            if collectingMore && !addingEvidence { addEvidence(event, context: context, bot: bot) }
            return
        }
        if phase == .identifying { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        work?.cancel()

        switch event {
        case .barcode(let barcode, let frame):
            start(status: barcode.issueNumber.map { "Barcode found · issue #\($0)" } ?? "Barcode found",
                  photo: frame.map(CoverRecognizer.cropCover))
            work = Task {
                let result = await Identifier.identify(barcode: barcode, frame: frame, context: context, bot: bot)
                finishIdentifying(result, context: context, bot: bot)
            }
        case .cover(let cover, _):
            start(status: "Identifying cover…", photo: cover)
            work = Task {
                let result = await Identifier.identify(cover: cover, context: context, bot: bot)
                finishIdentifying(result, context: context, bot: bot)
            }
        case .slab(let cert):
            start(status: "Reading \(cert.company.rawValue) cert \(cert.number)…", photo: nil)
            work = Task {
                do {
                    let result = try await CertLookup.lookUp(cert, bot: bot)
                    guard !result.spec.isEmpty else {
                        show(message: "Couldn't read the cert page. Try scanning the cover instead.")
                        return
                    }
                    let candidate = Candidate(spec: result.spec, imageURL: result.spec.coverImageURL.nilIfEmpty, source: cert.company.rawValue)
                    present(candidate, from: nil, context: context, bot: bot, learn: false)
                } catch {
                    if !error.isCancellation { show(message: error.localizedDescription) }
                }
            }
        }
    }

    private func start(status: String, photo: CGImage?) {
        statusText = status
        self.photo = photo.map { UIImage(cgImage: $0) }
        evidencePhotos = self.photo.map { [$0] } ?? []
        collectingMore = false
        identification = nil
        phase = .identifying
    }

    // MARK: Extra photos

    func startCollectingMore() {
        collectingMore = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func stopCollectingMore() {
        collectingMore = false
    }

    private func addEvidence(_ event: CameraEvent, context: ModelContext, bot: WebBot) {
        guard let current = identification else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        addingEvidence = true
        work?.cancel()
        work = Task {
            let extra: Identification
            switch event {
            case .barcode(let barcode, let frame):
                statusText = barcode.issueNumber.map { "Barcode added · issue #\($0)" } ?? "Barcode added"
                if let frame { evidencePhotos.append(UIImage(cgImage: CoverRecognizer.cropCover(frame))) }
                extra = await Identifier.identify(barcode: barcode, frame: nil, context: context, bot: bot)
            case .cover(let cover, _):
                statusText = "Photo added"
                evidencePhotos.append(UIImage(cgImage: cover))
                extra = await Identifier.identify(cover: cover, context: context, bot: bot)
            case .slab:
                addingEvidence = false
                collectingMore = false
                handleSlab(event, context: context, bot: bot)
                return
            }
            guard !Task.isCancelled else { return }
            let combined = await Identifier.combine(current, extra)
            addingEvidence = false
            collectingMore = false
            finishIdentifying(combined, context: context, bot: bot)
        }
    }

    private func handleSlab(_ event: CameraEvent, context: ModelContext, bot: WebBot) {
        phase = .idle
        handle(event, context: context, bot: bot)
    }

    private func finishIdentifying(_ result: Identification, context: ModelContext, bot: WebBot) {
        guard !Task.isCancelled else { return }
        identification = result
        if result.confident, let best = result.best {
            present(best, from: result, context: context, bot: bot, learn: best.source != "Your scans" && best.source != "Your covers")
        } else if result.candidates.isEmpty {
            show(message: result.message ?? "Couldn't identify this comic. Try the barcode, or type the title.")
        } else {
            phase = .confirm
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            // Get prices for the likeliest match ready while you decide.
            if let best = result.best { SoldCache.shared.prefetch(for: best.spec, seed: [], bot: bot) }
        }
    }

    // MARK: Choosing

    /// You picked (or confirmed) a match.
    func choose(_ candidate: Candidate, context: ModelContext, bot: WebBot) {
        present(candidate, from: identification, context: context, bot: bot, learn: true)
    }

    func present(_ candidate: Candidate, from identification: Identification?, context: ModelContext, bot: WebBot, learn: Bool) {
        modelContext = context
        if learn { Identifier.remember(candidate, from: identification, context: context) }

        let thumbnail = identification?.photo.flatMap(CoverRecognizer.thumbnailJPEG)
        let record = ComicRecord(spec: candidate.spec, imageURL: candidate.imageURL ?? candidate.spec.coverImageURL.nilIfEmpty, thumbnail: thumbnail)
        context.insert(record)
        self.record = record
        valuation = PricingService.cached(candidate.spec) ?? SalesStore.latestValuation(for: candidate.spec, context: context)
        if let valuation { record.setValuation(valuation) }
        priceError = nil
        phase = .result
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        work?.cancel()
        work = Task {
            // Prices first (that's what you're waiting for); extra details load alongside.
            async let details: Void = fillDetails(record)
            await price(record, bot: bot)
            await details
        }
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

    func price(_ record: ComicRecord, bot: WebBot, force: Bool = false) async {
        loadingPrice = true
        defer { loadingPrice = false }
        do {
            let result = try await PricingService.valuation(for: record.spec, bot: bot, context: modelContext, forceRefresh: force)
            guard !Task.isCancelled else { return }
            record.setValuation(result)
            if self.record === record { valuation = result; priceError = nil }
        } catch {
            guard !error.isCancellation else { return }
            if self.record === record {
                priceError = NetworkMonitor.shared.isOnline ? error.localizedDescription : "Offline — showing saved prices if there are any."
            }
        }
    }

    // MARK: Card actions

    func setCondition(_ condition: Condition) {
        record?.condition = condition
    }

    func setGrade(_ grade: Double, company: GradingCompany) {
        guard let record else { return }
        var spec = record.spec
        spec.graded = true
        spec.grade = grade
        spec.company = company
        record.condition = .graded
        record.update(spec: spec)
    }

    func toggleSaved() {
        guard let record else { return }
        record.inCollection.toggle()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func show(message: String) {
        self.message = message
        phase = .message
    }

    func dismiss() {
        work?.cancel()
        phase = .idle
        identification = nil
        collectingMore = false
        addingEvidence = false
    }

    func show(manualResult candidate: Candidate, context: ModelContext, bot: WebBot) {
        present(candidate, from: identification, context: context, bot: bot, learn: true)
    }
}
