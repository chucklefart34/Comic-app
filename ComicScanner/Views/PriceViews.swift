import SwiftUI

/// The three condition price cards: Low / Mid / High.
struct PriceBandsView: View {
    let valuation: Valuation?
    var highlight: PriceBand?
    var loading = false

    var body: some View {
        HStack(spacing: 8) {
            ForEach(PriceBand.allCases) { band in
                BandCard(band: band, value: valuation?.band(band), highlighted: band == highlight, loading: loading && valuation == nil)
            }
        }
    }
}

struct BandCard: View {
    let band: PriceBand
    let value: BandValue?
    let highlighted: Bool
    let loading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(band.rawValue.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(highlighted ? Theme.accent : Theme.secondary)
            Group {
                if loading {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.cardRaised).frame(height: 24)
                        .shimmering()
                } else if let cents = value?.cents {
                    Text(formatCents(cents))
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                } else {
                    Text("N/A").font(.title3.weight(.bold)).foregroundStyle(Theme.tertiary)
                }
            }
            Text(band.gradeRange)
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
            if let value, value.cents != nil {
                Text(value.basis == .sales ? "Sold · \(value.count)" : "Estimate")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(value.basis == .sales ? Theme.good : Theme.caution)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(highlighted ? Theme.accent.opacity(0.16) : Theme.cardRaised, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(highlighted ? Theme.accent : .clear, lineWidth: 1.5)
        }
        .animation(.snappy, value: highlighted)
    }
}

/// Poor … Near Mint / CGC Graded chips.
struct ConditionPicker: View {
    let selected: Condition?
    let spec: ComicSpec
    let onSelect: (Condition) -> Void
    let onGrade: (Double, GradingCompany) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Condition.allCases.filter { $0 != .graded }) { condition in
                    chip(condition.rawValue, active: selected == condition) { onSelect(condition) }
                }
                Menu {
                    ForEach(GradingCompany.allCases) { company in
                        Menu(company.rawValue) {
                            ForEach(standardGrades, id: \.self) { grade in
                                Button(gradeLabel(grade)) { onGrade(grade, company) }
                            }
                        }
                    }
                } label: {
                    chipLabel(selected == .graded ? "\(spec.company.rawValue) \(spec.gradeText)" : "CGC Graded", active: selected == .graded)
                }
            }
        }
    }

    private func chip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(title, active: active) }
            .buttonStyle(.plain)
    }

    private func chipLabel(_ title: String, active: Bool) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(active ? .white : Theme.secondary)
            .background(active ? Theme.accent : Theme.cardRaised, in: Capsule())
    }
}

/// The big headline price.
struct HeadlinePrice: View {
    let valuation: Valuation?
    let condition: Condition?
    let spec: ComicSpec
    var manualCents: Int?
    var loading: Bool
    var error: String?

    var body: some View {
        let value = valuation?.value(for: condition, spec: spec)
        VStack(alignment: .leading, spacing: 2) {
            Text(manualCents != nil ? "Your price" : (value?.label ?? "Estimated market value").uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let cents = manualCents ?? value?.cents {
                    Text(formatCents(cents))
                        .font(.system(size: 42, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if manualCents == nil, value?.basis == .estimate {
                        Text("ESTIMATE")
                            .font(.caption2.weight(.heavy))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Theme.caution.opacity(0.2), in: Capsule())
                            .foregroundStyle(Theme.caution)
                    }
                } else if loading {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text("Finding sold prices…").font(.headline).foregroundStyle(Theme.secondary)
                    }
                    .frame(height: 50)
                } else {
                    Text("N/A")
                        .font(.system(size: 42, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            if let error, valuation == nil {
                Text(error).font(.caption).foregroundStyle(Theme.caution)
            } else if let valuation {
                Text(summary(valuation))
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }

    private func summary(_ valuation: Valuation) -> String {
        var parts: [String] = []
        let counted = valuation.sales.filter(\.counted).count
        if counted > 0 { parts.append("\(counted) sold comps") }
        parts.append("updated \(valuation.updatedAt.relativeText)")
        if loading { parts.append("refreshing…") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Shimmer

struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geometry in
                    LinearGradient(colors: [.clear, .white.opacity(0.18), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geometry.size.width * 0.6)
                        .offset(x: phase * geometry.size.width * 1.6)
                }
                .clipped()
            }
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

extension View {
    func shimmering() -> some View { modifier(Shimmer()) }
}
