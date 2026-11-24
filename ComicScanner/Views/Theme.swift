import SwiftUI

enum Theme {
    static let background = Color(red: 0.06, green: 0.06, blue: 0.07)
    static let card = Color(red: 0.12, green: 0.12, blue: 0.13)
    static let cardRaised = Color(red: 0.17, green: 0.17, blue: 0.19)
    static let accent = Color(red: 0.90, green: 0.17, blue: 0.20)
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.38)
    static let good = Color(red: 0.30, green: 0.80, blue: 0.45)
    static let caution = Color(red: 1.0, green: 0.72, blue: 0.25)
}

func formatCents(_ cents: Int) -> String {
    let dollars = Double(cents) / 100
    return dollars >= 1000
        ? dollars.formatted(.currency(code: "USD").precision(.fractionLength(0)))
        : dollars.formatted(.currency(code: "USD"))
}

func formatRange(_ low: Int?, _ high: Int?) -> String? {
    guard let low, let high, high > low else { return nil }
    return "\(formatCents(low)) – \(formatCents(high))"
}

struct ConfidenceBadge: View {
    let confidence: Confidence

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(confidence == .none ? "No data" : "\(confidence.rawValue) confidence")
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(color)
        .background(color.opacity(0.15), in: Capsule())
    }

    private var color: Color {
        switch confidence {
        case .high: return Theme.good
        case .medium: return Theme.caution
        case .low: return Theme.accent
        case .none: return Theme.tertiary
        }
    }

    private var icon: String {
        switch confidence {
        case .high: return "checkmark.seal.fill"
        case .medium: return "circle.lefthalf.filled"
        case .low: return "sparkles"
        case .none: return "questionmark.circle"
        }
    }
}

/// A comic cover from a URL or local image data.
struct CoverArt: View {
    var url: String?
    var data: Data?
    var cornerRadius: CGFloat = 6

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let url, let link = URL(string: url) {
                AsyncImage(url: link) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Theme.cardRaised)
            .overlay { Image(systemName: "book.closed.fill").foregroundStyle(Theme.tertiary) }
    }
}

extension Date {
    var relativeText: String {
        formatted(.relative(presentation: .named))
    }
}
