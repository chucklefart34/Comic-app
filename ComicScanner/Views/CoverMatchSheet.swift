import SwiftUI

struct CoverMatchResult: Identifiable {
    let id = UUID()
    let matches: [CoverMatch]
    let cover: CGImage
}

/// The covers that look most like the photo. Tap the right one to price it.
struct CoverMatchSheet: View {
    let result: CoverMatchResult
    let onPick: (CoverMatch) -> Void
    let onBarcodeInstead: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(decorative: result.cover, scale: 1)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 70, height: 105)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Text("Your photo. Tap the matching book below.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Best matches") {
                    ForEach(result.matches) { match in
                        Button {
                            onPick(match)
                        } label: {
                            HStack(spacing: 12) {
                                LearnedCoverImage(print: match.print)
                                    .frame(width: 56, height: 84)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(match.print.title)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(match.print.details)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    Text(match.closeness)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(match.distance < 0.45 ? .green : .orange)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                Section {
                    Button("None of these — scan the barcode instead", action: onBarcodeInstead)
                } footer: {
                    Text("The app only knows covers you've confirmed before. Every barcode scan + cover tap teaches it a new one.")
                }
            }
            .navigationTitle("Is it one of these?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onBarcodeInstead)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// A learned cover's picture: the saved thumbnail, or the original photo URL.
struct LearnedCoverImage: View {
    let print: CoverPrint

    var body: some View {
        if let data = print.thumbnail, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            CoverThumb(url: print.imageURL, width: 56, height: 84)
        }
    }
}
