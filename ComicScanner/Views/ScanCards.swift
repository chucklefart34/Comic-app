import SwiftData
import SwiftUI

/// Shared look for the bottom panels.
struct CardShell<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Theme.tertiary).frame(width: 38, height: 5).padding(.top, 8).padding(.bottom, 10)
            content
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.card.opacity(0.97), in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28))
        .shadow(color: .black.opacity(0.5), radius: 20, y: -4)
    }
}

struct IdentifyingCard: View {
    let photo: UIImage?
    let status: String
    let botStatus: String
    let onCancel: () -> Void

    var body: some View {
        CardShell {
            HStack(spacing: 14) {
                Group {
                    if let photo {
                        Image(uiImage: photo).resizable().scaledToFill()
                    } else {
                        Theme.cardRaised
                    }
                }
                .frame(width: 64, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shimmering()

                VStack(alignment: .leading, spacing: 6) {
                    Text(status).font(.headline)
                    HStack(spacing: 8) {
                        ProgressView().tint(Theme.accent)
                        Text(botStatus.isEmpty ? "Identifying the exact edition…" : botStatus)
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                    }
                    RoundedRectangle(cornerRadius: 4).fill(Theme.cardRaised).frame(width: 160, height: 12).shimmering()
                }
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark").font(.headline).foregroundStyle(Theme.secondary)
                }
            }
        }
    }
}

/// "Which one is it?" — shown when the edition isn't certain.
struct CandidatesCard: View {
    let identification: Identification
    let photos: [UIImage]
    let collecting: Bool
    let adding: Bool
    let status: String
    let onAddPhoto: () -> Void
    let onStopAdding: () -> Void
    let onPick: (Candidate) -> Void
    let onSearch: () -> Void
    let onCancel: () -> Void

    var body: some View {
        CardShell {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Which one is it?").font(.title3.weight(.bold))
                        Text("Tap the matching cover — or add a photo of the barcode for a sharper match.")
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Button(action: onCancel) {
                        Image(systemName: "xmark").font(.headline).foregroundStyle(Theme.secondary)
                    }
                }

                addPhotoRow

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(identification.candidates) { candidate in
                            Button { onPick(candidate) } label: { CandidateTile(candidate: candidate) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .opacity(adding ? 0.4 : 1)
                .disabled(adding)

                Button(action: onSearch) {
                    Label("Not here — type the title", systemImage: "magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Your photos so far, plus the button to add another (barcode, back cover, another angle).
    private var addPhotoRow: some View {
        HStack(spacing: 8) {
            ForEach(Array(photos.enumerated()), id: \.offset) { _, photo in
                Image(uiImage: photo).resizable().scaledToFill()
                    .frame(width: 40, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.accent, lineWidth: 1.5))
            }
            if adding {
                HStack(spacing: 8) {
                    ProgressView().tint(Theme.accent)
                    Text(status).font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 12))
            } else if collecting {
                HStack(spacing: 8) {
                    Image(systemName: "barcode.viewfinder").foregroundStyle(Theme.accent)
                    Text("Point at the barcode, or tap the shutter for another photo")
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button("Done", action: onStopAdding).font(.caption.weight(.bold))
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Theme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent, lineWidth: 1))
            } else {
                Button(action: onAddPhoto) {
                    Label("Add photo (barcode or cover)", systemImage: "camera.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(.white)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct CandidateTile: View {
    let candidate: Candidate

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CoverArt(url: candidate.imageURL, cornerRadius: 8)
                .frame(width: 92, height: 138)
            Text(candidate.spec.displayTitle)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
            Text(candidate.spec.editionLine)
                .font(.caption2)
                .foregroundStyle(Theme.secondary)
                .lineLimit(2)
            HStack(spacing: 4) {
                Text(candidate.source)
                if let look = candidate.lookLabel { Text("· \(look)") }
            }
            .font(.caption2)
            .foregroundStyle(candidate.distance.map { $0 < 0.4 } == true ? Theme.good : Theme.tertiary)
        }
        .frame(width: 92, alignment: .leading)
    }
}

/// The DeckTrader-style results panel: cover, identity, big price, three condition prices, condition chips.
struct ResultCard: View {
    @Bindable var record: ComicRecord
    let valuation: Valuation?
    let loading: Bool
    let error: String?
    let session: ScanSession
    let onDetails: () -> Void
    let onCorrect: () -> Void
    let onClose: () -> Void

    @State private var collapsed = false

    var body: some View {
        let spec = record.spec
        CardShell {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    CoverArt(url: record.imageURL, data: record.imageURL == nil ? record.thumbnail : nil)
                        .frame(width: 64, height: 96)
                        .onTapGesture(perform: onDetails)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(spec.title.isEmpty ? "Unknown comic" : spec.title)
                            .font(.headline)
                            .lineLimit(2)
                        Text([spec.issue.isEmpty ? nil : "#\(spec.issue)", spec.publicationLine.nilIfEmpty]
                                .compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.secondary)
                        Text(spec.detailLine)
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                            .lineLimit(2)
                        if let valuation { ConfidenceBadge(confidence: valuation.confidence).padding(.top, 2) }
                    }
                    Spacer(minLength: 0)
                    VStack(spacing: 14) {
                        Button(action: onClose) {
                            Image(systemName: "xmark").font(.headline).foregroundStyle(Theme.secondary)
                        }
                        Button {
                            session.toggleSaved()
                        } label: {
                            Image(systemName: record.inCollection ? "bookmark.fill" : "bookmark")
                                .font(.title3)
                                .foregroundStyle(record.inCollection ? Theme.accent : .white)
                        }
                        .accessibilityLabel(record.inCollection ? "Saved to collection" : "Save to collection")
                    }
                }

                HeadlinePrice(valuation: valuation, condition: record.condition, spec: spec,
                              manualCents: record.manualValueCents, loading: loading, error: error)

                if !collapsed {
                    PriceBandsView(valuation: valuation, highlight: record.condition?.band ?? (record.condition == .graded ? PriceBand.of(grade: spec.grade) : nil),
                                   loading: loading)
                    ConditionPicker(selected: record.condition, spec: spec) { condition in
                        session.setCondition(condition)
                    } onGrade: { grade, company in
                        session.setGrade(grade, company: company)
                    }
                    if let note = valuation?.estimateNote {
                        Label(note, systemImage: "sparkles")
                            .font(.caption)
                            .foregroundStyle(Theme.caution)
                    }
                    HStack(spacing: 10) {
                        actionButton(record.inCollection ? "Saved" : "Save", icon: record.inCollection ? "checkmark" : "plus", primary: !record.inCollection) {
                            session.toggleSaved()
                        }
                        actionButton("Details", icon: "doc.text.magnifyingglass", primary: false, action: onDetails)
                        actionButton("Not right?", icon: "arrow.uturn.left", primary: false, action: onCorrect)
                    }
                }
            }
        }
        .gesture(DragGesture(minimumDistance: 20).onEnded { value in
            withAnimation(.snappy) {
                if value.translation.height > 40 { collapsed = true }
                if value.translation.height < -40 { collapsed = false }
            }
        })
    }

    private func actionButton(_ title: String, icon: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .foregroundStyle(.white)
                .background(primary ? Theme.accent : Theme.cardRaised, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

struct MessageCard: View {
    let text: String
    let onSearch: () -> Void
    let onClose: () -> Void

    var body: some View {
        CardShell {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Label(text, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Theme.caution)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.headline).foregroundStyle(Theme.secondary)
                    }
                }
                Button(action: onSearch) {
                    Label("Type the title instead", systemImage: "magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Manual identification

/// Type a title; pick from VerseDB (if set up) and eBay listing matches.
struct ManualSearchView: View {
    let onPick: (Candidate) -> Void
    @Environment(WebBot.self) private var bot
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Candidate] = []
    @State private var searching = false
    @State private var searched = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("e.g. Amazing Spider-Man #300", text: $query)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { Task { await search() } }
                    if !query.trimmed.isEmpty {
                        Button {
                            onPick(Candidate(spec: ComicSpec(searchText: query), imageURL: nil, source: "Typed"))
                        } label: {
                            Label("Use \"\(query.trimmed)\" as typed", systemImage: "text.cursor")
                        }
                    }
                } footer: {
                    Text("Include the issue number after a #.")
                }

                if searching {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(bot.status.isEmpty ? "Searching…" : bot.status).foregroundStyle(Theme.secondary)
                    }
                }
                if !results.isEmpty {
                    Section("Matches") {
                        ForEach(results) { candidate in
                            Button { onPick(candidate) } label: {
                                HStack(spacing: 12) {
                                    CoverArt(url: candidate.imageURL).frame(width: 46, height: 70)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.spec.displayTitle).font(.headline).foregroundStyle(.white)
                                        Text(candidate.spec.editionLine).font(.caption).foregroundStyle(Theme.secondary)
                                        Text(candidate.source).font(.caption2).foregroundStyle(Theme.tertiary)
                                    }
                                }
                            }
                        }
                    }
                } else if searched && !searching {
                    Text("No matches. Check the spelling, or use the title as typed.").foregroundStyle(Theme.secondary)
                }
            }
            .navigationTitle("Find a comic")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Search") { Task { await search() } }.disabled(query.trimmed.isEmpty || searching)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func search() async {
        guard !query.trimmed.isEmpty else { return }
        searching = true
        results = await Identifier.search(query.trimmed, bot: bot)
        searching = false
        searched = true
    }
}

/// "Not right?" — other matches, a new search, or edit the details by hand.
struct CorrectionSheet: View {
    let identification: Identification?
    let record: ComicRecord?
    let onPick: (Candidate) -> Void
    let onSearch: () -> Void
    let onEdited: (ComicRecord) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let others = identification?.candidates, others.count > 1 {
                    Section("Other matches") {
                        ForEach(others) { candidate in
                            Button { onPick(candidate) } label: {
                                HStack(spacing: 12) {
                                    CoverArt(url: candidate.imageURL).frame(width: 46, height: 70)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.spec.displayTitle).font(.headline).foregroundStyle(.white)
                                        Text(candidate.spec.editionLine).font(.caption).foregroundStyle(Theme.secondary)
                                        HStack(spacing: 4) {
                                            Text(candidate.source)
                                            if let look = candidate.lookLabel { Text("· \(look)") }
                                        }
                                        .font(.caption2).foregroundStyle(Theme.tertiary)
                                    }
                                }
                            }
                        }
                    }
                }
                Section {
                    Button(action: onSearch) { Label("Search by title", systemImage: "magnifyingglass") }
                    if let record {
                        NavigationLink {
                            EditComicView(record: record) { onEdited(record) }
                        } label: {
                            Label("Edit the details (variant, printing, signature…)", systemImage: "slider.horizontal.3")
                        }
                    }
                } footer: {
                    Text("Your correction is remembered, so the same barcode or cover is identified correctly next time.")
                }
            }
            .navigationTitle("Not right?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}
