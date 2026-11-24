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
