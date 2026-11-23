import SwiftUI
import VisionKit
import AVFoundation
import Vision

struct ScanView: View {
    @Environment(DealCart.self) private var cart
    @Environment(AppState.self) private var appState
    @State private var path = NavigationPath()
    @State private var showingSettings = false
    @State private var cameraState: CameraState = .checking
    @State private var pendingBarcode: ComicBarcode?
    @State private var textChips: [String] = []
    @State private var query = ""
    /// 5-digit numbers seen by text recognition recently — candidates for the barcode add-on.
    @State private var recentFiveDigits: [String: Date] = [:]

    enum CameraState { case checking, ready, denied, unsupported }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Scan")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.visible, for: .navigationBar)
                .comicDestinations()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showingSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if !cart.lines.isEmpty {
                            Button {
                                appState.tab = .deal
                            } label: {
                                Label("\(cart.kind.rawValue) · \(cart.lines.count) · \(formatCents(cart.headlineCents))",
                                      systemImage: "cart.fill")
                                    .labelStyle(.titleAndIcon)
                                    .font(.subheadline.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
                .sheet(isPresented: $showingSettings) { SettingsView() }
                .environment(\.popToRoot, PopToRoot { path = NavigationPath() })
                .sheet(item: $pendingBarcode) { barcode in
                    BarcodeConfirmSheet(barcode: barcode) { confirmed in
                        pendingBarcode = nil
                        path.append(Route.barcode(confirmed))
                    }
                }
                .task { await checkCamera() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch cameraState {
        case .checking:
            ProgressView()
        case .ready:
            ZStack(alignment: .bottom) {
                DataScannerRepresentable(
                    isActive: path.isEmpty && pendingBarcode == nil,
                    onText: handleText,
                    onCode: handleCode
                )
                .ignoresSafeArea(edges: .horizontal)
                overlay
            }
        case .denied:
            ContentUnavailableView {
                Label("Camera access needed", systemImage: "camera.fill")
            } description: {
                Text("Allow camera access to scan comic barcodes and covers. You can still look up comics from the Search tab.")
            } actions: {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        case .unsupported:
            ContentUnavailableView(
                "Scanning not supported",
                systemImage: "camera.metering.unknown",
                description: Text("Live scanning needs an iPhone with an A12 chip or newer (it won't run in the Simulator). Use the Search tab instead.")
            )
        }
    }

    private var overlay: some View {
        VStack(spacing: 10) {
            Text(textChips.isEmpty
                 ? "Point at the barcode, a slab's QR code, or the cover title"
                 : "Tap words from the cover to build a search")
                .font(.footnote.weight(.medium))

            if !textChips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button {
                            textChips.removeAll()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Clear words")

                        ForEach(textChips, id: \.self) { chip in
                            Button(chip) { addToQuery(chip) }
                                .buttonStyle(.bordered)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal)
                }
            }

            HStack(spacing: 8) {
                TextField("Title and issue #", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit(searchText)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
                }
                Button("Search", action: searchText)
                    .buttonStyle(.borderedProminent)
                    .disabled(query.trimmed.isEmpty)
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    // MARK: - Actions

    private func checkCamera() async {
        guard DataScannerViewController.isSupported else {
            cameraState = .unsupported
            return
        }
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        let authorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        cameraState = authorized && DataScannerViewController.isAvailable ? .ready : .denied
    }

    private func handleText(_ transcripts: [String]) {
        let now = Date()
        var chips = textChips
        for raw in transcripts {
            let text = raw.trimmed
            let compact = text.filter { !$0.isWhitespace }
            let allDigits = !compact.isEmpty && compact.allSatisfy(\.isNumber)
            if allDigits && compact.count == 5 {
                recentFiveDigits[compact] = now
                continue
            }
            let useful = allDigits ? compact.count <= 4 : (2...40).contains(text.count)
            if useful && !chips.contains(text) {
                chips.append(text)
            }
        }
        if chips.count > 12 { chips.removeFirst(chips.count - 12) }
        if chips != textChips { textChips = chips }
        recentFiveDigits = recentFiveDigits.filter { now.timeIntervalSince($0.value) < 4 }
    }

    private func handleCode(_ payload: String, isProductBarcode: Bool) {
        guard pendingBarcode == nil, path.isEmpty else { return }

        // Slab labels: CGC / PSA QR codes and cert barcodes.
        if !isProductBarcode, let cert = SlabCert(payload: payload) {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            path.append(Route.cert(cert))
            return
        }

        guard isProductBarcode, var barcode = ComicBarcode(payload: payload) else { return }
        if !barcode.hasAddOn {
            // The digits printed under the main barcode come in groups of five too — skip those.
            let candidates = recentFiveDigits
                .filter { !barcode.base.contains($0.key) }
                .sorted { $0.value > $1.value }
            if let addOn = candidates.first?.key { barcode.addOn = addOn }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        pendingBarcode = barcode
    }

    private func addToQuery(_ chip: String) {
        let piece = chip.allSatisfy(\.isNumber) ? "#\(chip)" : chip
        query = query.isEmpty ? piece : "\(query) \(piece)"
    }

    private func searchText() {
        let text = query.trimmed
        guard !text.isEmpty else { return }
        path.append(Route.spec(ComicSpec(searchText: text)))
    }
}

// MARK: - Barcode confirmation

struct BarcodeConfirmSheet: View {
    @State private var barcode: ComicBarcode
    let onLookup: (ComicBarcode) -> Void
    @Environment(\.dismiss) private var dismiss

    init(barcode: ComicBarcode, onLookup: @escaping (ComicBarcode) -> Void) {
        _barcode = State(initialValue: barcode)
        self.onLookup = onLookup
    }

    private var addOnIsValid: Bool { barcode.addOn.isEmpty || barcode.hasAddOn }

    var body: some View {
        NavigationStack {
            Form {
                Section("Barcode") {
                    LabeledContent("UPC", value: barcode.formattedBase)
                        .monospacedDigit()
                }
                Section {
                    TextField("e.g. 00111", text: $barcode.addOn)
                        .keyboardType(.numberPad)
                        .font(.title3.monospacedDigit())
                        .onChange(of: barcode.addOn) { _, newValue in
                            let digits = String(newValue.filter(\.isNumber).prefix(5))
                            if digits != newValue { barcode.addOn = digits }
                        }
                    if let issue = barcode.issueNumber {
                        LabeledContent("Issue", value: "#\(issue)")
                        if let cover = barcode.coverVariant { LabeledContent("Cover", value: "\(cover)") }
                        if let printing = barcode.printing { LabeledContent("Printing", value: "\(printing)") }
                    }
                } header: {
                    Text("5-digit add-on")
                } footer: {
                    Text("The small 5-digit code to the right of the main barcode: issue number, cover variant, then printing. Check it matches your comic, or leave blank for older books that don't have one.")
                }
            }
            .navigationTitle("Comic barcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Rescan") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Look Up") { onLookup(barcode) }
                        .disabled(!addOnIsValid)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - VisionKit live scanner

struct DataScannerRepresentable: UIViewControllerRepresentable {
    var isActive: Bool
    var onText: ([String]) -> Void
    /// Payload, and whether it came from a retail (UPC/EAN) barcode rather than a QR/label code.
    var onCode: (String, Bool) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [
                .barcode(symbologies: [.ean13, .upce, .ean8, .qr, .code128, .code39, .dataMatrix]),
                .text(),
            ],
            qualityLevel: .accurate,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.parent = self
        if isActive, !scanner.isScanning {
            try? scanner.startScanning()
        } else if !isActive, scanner.isScanning {
            scanner.stopScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var parent: DataScannerRepresentable

        init(parent: DataScannerRepresentable) {
            self.parent = parent
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            process(allItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            process(allItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                parent.onCode(payload, Self.isProduct(barcode.observation.symbology))
            }
        }

        private func process(_ items: [RecognizedItem]) {
            var texts: [String] = []
            var codes: [(String, Bool)] = []
            for item in items {
                switch item {
                case .text(let text):
                    texts.append(text.transcript)
                case .barcode(let barcode):
                    if let payload = barcode.payloadStringValue {
                        codes.append((payload, Self.isProduct(barcode.observation.symbology)))
                    }
                @unknown default:
                    break
                }
            }
            // Text first, so an add-on code seen in the same frame can be paired with the barcode.
            parent.onText(texts)
            for (payload, isProduct) in codes { parent.onCode(payload, isProduct) }
        }

        static func isProduct(_ symbology: VNBarcodeSymbology) -> Bool {
            [.ean13, .upce, .ean8].contains(symbology)
        }
    }
}
