import SwiftData
import SwiftUI

/// The tray under the camera: running total, "Add N" to save them all, and one swipeable card per scanned book.
struct ScanTray: View {
    let session: ScanSession
    let onComps: (TrayItem) -> Void
    let onFix: (TrayItem) -> Void
    let onSearch: (TrayItem?) -> Void
    let onAddAll: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            TabView(selection: selection) {
                ForEach(session.items) { item in
                    TrayCard(item: item, session: session,
                             onComps: { onComps(item) }, onFix: { onFix(item) }, onSearch: { onSearch(item) })
                        .padding(.horizontal, 16)
                        .tag(Optional(item.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 214)
            pageDots
                .padding(.bottom, 6)
        }
        .background(Theme.card.opacity(0.98))
    }

    private var selection: Binding<UUID?> {
        Binding { session.selected?.id } set: { session.selectedID = $0 }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Total")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                HStack(spacing: 8) {
                    Text(formatCents(session.totalCents))
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: session.totalCents)
                    if session.anyWorking { ProgressView().controlSize(.small).tint(Theme.secondary) }
                }
            }
            Spacer()
            Button(action: onAddAll) {
                HStack(spacing: 6) {
                    Text("Add \(session.addableCount)")
                    Image(systemName: "chevron.right").font(.subheadline.weight(.bold))
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .frame(height: 44)
                .background(session.addableCount > 0 ? Theme.accent : Theme.cardRaised, in: Capsule())
            }
            .disabled(session.addableCount == 0)
            .accessibilityLabel("Add \(session.addableCount) to Collection")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var pageDots: some View {
        if session.items.count > 1 {
            HStack(spacing: 7) {
                ForEach(session.items.prefix(12)) { item in
                    Circle()
                        .fill(item.id == session.selected?.id ? Color.white : Theme.tertiary)
                        .frame(width: 7, height: 7)
                }
                if session.items.count > 12 {
                    Text("+\(session.items.count - 12)").font(.caption2).foregroundStyle(Theme.tertiary)
                }
            }
            .frame(height: 14)
        } else {
            Color.clear.frame(height: 14)
        }
    }
}

/// One book in the tray.
struct TrayCard: View {
    @Environment(WebBot.self) private var bot
    @Environment(\.modelContext) private var modelContext
    let item: TrayItem
    let session: ScanSession
    let onComps: () -> Void
    let onFix: () -> Void
    let onSearch: () -> Void
    @State private var choosingCondition = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                cover
                    .frame(width: 92, height: 138)
                    .onTapGesture { if item.record != nil { choosingCondition = true } }
                    .confirmationDialog("Condition", isPresented: $choosingCondition, titleVisibility: .visible) {
                        ForEach(PriceBand.allCases) { band in
                            Button("\(band.rawValue) · \(band.gradeRange)") { setCondition(band.condition) }
                        }
                        Button("Details & comps") { onComps() }
                    }
                VStack(alignment: .leading, spacing: 4) {
                    titleRow
                    if let spec = item.record?.spec {
                        Text(subtitle(spec))
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                        if !spec.detailLine.isEmpty {
                            Text(spec.detailLine)
                                .font(.caption)
                                .foregroundStyle(Theme.accent)
                                .lineLimit(1)
                        }
                    }
                    if item.record != nil && !item.isWorking && !item.addingPhoto {
                        Button { session.startAddingPhoto(to: item) } label: {
                            Label(item.needsCheck ? "Not sure — scan barcode" : "Wrong? Scan barcode",
                                  systemImage: "barcode.viewfinder")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(item.needsCheck ? Theme.caution : Theme.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                    priceArea
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(Color.white.opacity(0.08))
            controls
        }
        .padding(.top, 14)
    }

    // MARK: Parts

    @ViewBuilder
    private var cover: some View {
        if let record = item.record, record.imageURL != nil {
            CoverArt(url: record.imageURL, cornerRadius: 8)
        } else if let photo = item.photo {
            Image(uiImage: photo).resizable().scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            CoverArt(cornerRadius: 8)
        }
    }

    private var titleRow: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if item.record != nil {
                Button(action: onFix) {
                    Image(systemName: "pencil").font(.title3)
                }
                .accessibilityLabel("Fix the match or edit details")
            }
            Button { session.remove(item) } label: {
                Image(systemName: "xmark").font(.title3)
            }
            .accessibilityLabel("Remove from tray")
        }
        .foregroundStyle(.white)
    }

    private var title: String {
        guard let spec = item.record?.spec else {
            if case .notFound = item.state { return "Not identified" }
            return item.status
        }
        let name = spec.title.isEmpty ? "Unknown comic" : spec.title
        return spec.issue.isEmpty ? name : "\(name) #\(spec.issue)"
    }

    private func subtitle(_ spec: ComicSpec) -> String {
        [spec.publisher.nilIfEmpty, spec.year.nilIfEmpty].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var priceArea: some View {
        switch item.state {
        case .waitingSecond:
            VStack(alignment: .leading, spacing: 6) {
                Label(item.firstWasBarcode ? "Now the cover" : "Now the barcode",
                      systemImage: item.firstWasBarcode ? "book.closed.fill" : "barcode.viewfinder")
                    .font(.headline)
                    .foregroundStyle(Theme.caution)
                Text(item.firstWasBarcode ? "Tap the screen to scan the front cover." : "No barcode? Tap to scan the cover again.")
                    .font(.caption).foregroundStyle(Theme.secondary).lineLimit(2)
                smallButton("Use one photo", icon: "forward.fill") {
                    session.skipSecondPhoto(item, context: modelContext, bot: bot)
                }
            }
        case .identifying:
            HStack(spacing: 8) {
                ProgressView().tint(Theme.accent)
                Text(item.record == nil ? "Identifying…" : item.status)
                    .font(.subheadline).foregroundStyle(Theme.secondary)
            }
            .frame(height: 44, alignment: .leading)
        case .notFound(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.caption).foregroundStyle(Theme.secondary).lineLimit(2)
                HStack(spacing: 8) {
                    smallButton("Search", icon: "magnifyingglass", action: onSearch)
                    smallButton("Add photo", icon: "camera.fill") { session.startAddingPhoto(to: item) }
                }
            }
        case .pricing, .done:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let cents = item.unitCents {
                    Text(formatCents(cents))
                        .font(.system(size: 36, weight: .bold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                } else if item.state == .pricing {
                    Text("Pricing…").font(.title3.weight(.semibold)).foregroundStyle(Theme.secondary)
                } else {
                    Text("N/A").font(.system(size: 36, weight: .bold)).foregroundStyle(Theme.tertiary)
                }
                if item.state == .pricing {
                    ProgressView().controlSize(.small).tint(Theme.secondary)
                } else if let note = priceNote {
                    Text(note).font(.caption).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
            }
            .animation(.snappy, value: item.unitCents)
        }
    }

    private var priceNote: String? {
        if let error = item.priceError, item.unitCents == nil { return error }
        guard let valuation = item.record?.valuation else { return nil }
        if valuation.marketBasis == .estimate { return "estimate" }
        let count = valuation.rawSaleCount + valuation.graded.reduce(0) { $0 + $1.count }
        return count > 0 ? "\(count) sale\(count == 1 ? "" : "s")" : nil
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                conditionMenu
                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 24)
                quantityStepper
            }
            .frame(height: 44)
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14)))
            .disabled(item.record == nil)
            .opacity(item.record == nil ? 0.4 : 1)

            Spacer()

            if item.addingPhoto {
                Button { session.stopAddingPhoto() } label: {
                    Label("Scan barcode…", systemImage: "barcode.viewfinder")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).frame(height: 44)
                        .foregroundStyle(Theme.caution)
                        .overlay(Capsule().strokeBorder(Theme.caution))
                }
            } else {
                Button(action: onComps) {
                    Label("Comps", systemImage: "chart.line.uptrend.xyaxis")
                        .font(.headline)
                        .padding(.horizontal, 18).frame(height: 44)
                        .foregroundStyle(.white)
                        .overlay(Capsule().strokeBorder(LinearGradient(colors: [Theme.accent, .orange, .purple],
                                                                       startPoint: .leading, endPoint: .trailing), lineWidth: 2))
                }
                .disabled(item.record == nil)
                .opacity(item.record == nil ? 0.4 : 1)
            }
        }
        .padding(.bottom, 4)
    }

    private var conditionMenu: some View {
        Menu {
            ForEach(PriceBand.allCases) { band in
                Button("\(band.rawValue) (\(band.gradeRange))") { setCondition(band.condition) }
            }
            Menu("Graded slab") {
                ForEach(GradingCompany.allCases) { company in
                    Menu(company.rawValue) {
                        ForEach(standardGrades.reversed(), id: \.self) { grade in
                            Button(gradeLabel(grade)) { setGrade(grade, company: company) }
                        }
                    }
                }
            }
            Divider()
            Button {
                session.startAddingPhoto(to: item)
            } label: {
                Label("Add barcode or photo", systemImage: "camera.fill")
            }
        } label: {
            HStack(spacing: 6) {
                Text(conditionLabel).font(.headline)
                Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(Theme.secondary)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 44)
        }
    }

    private var conditionLabel: String {
        guard let record = item.record, let condition = record.condition else { return "Mid" }
        if condition == .graded { return "\(record.spec.company.rawValue) \(record.spec.gradeText)" }
        return condition.band?.rawValue ?? "Mid"
    }

    private var quantityStepper: some View {
        HStack(spacing: 0) {
            if item.quantity > 1 {
                Button { item.quantity -= 1 } label: {
                    Image(systemName: "minus").frame(width: 36, height: 44)
                }
            }
            Text("\(item.quantity)")
                .font(.headline)
                .monospacedDigit()
                .frame(minWidth: 26)
            Button { item.quantity += 1 } label: {
                Image(systemName: "plus").frame(width: 40, height: 44)
            }
        }
        .font(.headline)
        .foregroundStyle(.white)
        .padding(.leading, 8)
    }

    private func setCondition(_ condition: Condition?) {
        guard let record = item.record else { return }
        if record.spec.graded, condition != nil {
            var spec = record.spec
            spec.graded = false
            record.update(spec: spec)
        }
        record.condition = condition
        record.refreshValue()
    }

    private func setGrade(_ grade: Double, company: GradingCompany) {
        guard let record = item.record else { return }
        var spec = record.spec
        spec.graded = true
        spec.grade = grade
        spec.company = company
        record.update(spec: spec)
        record.condition = .graded
    }

    private func smallButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12).frame(height: 32)
                .foregroundStyle(.white)
                .background(Theme.cardRaised, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
