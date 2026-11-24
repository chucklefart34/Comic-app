import SwiftData
import SwiftUI

/// The main screen: full-screen camera, scanning frame, and the results card that slides up from the bottom.
struct ScanScreen: View {
    @Environment(WebBot.self) private var bot
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var camera = CameraModel()
    @State private var session = ScanSession()
    @State private var showingSearch = false
    @State private var showingDetail = false
    @State private var showingCorrection = false
    @AppStorage(Prefs.autoCaptureKey) private var autoCapture = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch camera.status {
            case .running, .idle:
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
                ScanFrameOverlay(inView: camera.coverInView, progress: camera.lockProgress,
                                 hint: hint, compact: session.phase != .idle)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            case .denied:
                permissionView
            case .unavailable:
                ContentUnavailableView("Camera unavailable", systemImage: "camera.metering.unknown",
                                       description: Text("This device's camera can't be used. You can still search by title."))
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                if session.phase == .idle || session.phase == .result || (session.phase == .confirm && session.collectingMore) {
                    shutterRow
                        .padding(.bottom, session.phase == .idle ? 28 : 8)
                }
                card
            }
        }
        .preferredColorScheme(.dark)
        .task {
            camera.onEvent = { event in
                session.handle(event, context: modelContext, bot: bot)
            }
            camera.setAutoCapture(autoCapture)
            await camera.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await camera.start() } } else { camera.stop() }
        }
        .onChange(of: showingSearch || showingDetail || showingCorrection || bot.showingWebView) { _, covered in
            camera.setPaused(covered)
        }
        .onChange(of: session.phase == .confirm && !session.collectingMore) { _, waiting in
            camera.setPaused(waiting)
        }
        .onChange(of: session.collectingMore) { _, collecting in
            if collecting { camera.setPaused(false) }
        }
        .sheet(isPresented: $showingSearch) {
            ManualSearchView { candidate in
                showingSearch = false
                session.show(manualResult: candidate, context: modelContext, bot: bot)
            }
        }
        .sheet(isPresented: $showingDetail) {
            if let record = session.record {
                NavigationStack { ComicDetailView(record: record) }
            }
        }
        .sheet(isPresented: $showingCorrection) {
            CorrectionSheet(identification: session.identification, record: session.record) { candidate in
                showingCorrection = false
                session.choose(candidate, context: modelContext, bot: bot)
            } onSearch: {
                showingCorrection = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showingSearch = true }
            } onEdited: { record in
                showingCorrection = false
                Task { await session.price(record, bot: bot) }
            }
        }
    }

    private var hint: String {
        if camera.coverInView && camera.lockProgress > 0 { return "Hold steady…" }
        if !autoCapture { return "Tap the shutter to scan the cover" }
        return "Point at a cover or barcode"
    }

    // MARK: Bars

    private var topBar: some View {
        HStack(spacing: 12) {
            if camera.hasTorch {
                circleButton(camera.torchOn ? "bolt.fill" : "bolt.slash.fill", active: camera.torchOn) { camera.toggleTorch() }
                    .accessibilityLabel(camera.torchOn ? "Flash off" : "Flash on")
            }
            Button {
                autoCapture.toggle()
                camera.setAutoCapture(autoCapture)
            } label: {
                Text(autoCapture ? "AUTO" : "MANUAL")
                    .font(.caption.weight(.heavy))
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .foregroundStyle(autoCapture ? .white : Theme.secondary)
                    .background(autoCapture ? Theme.accent : Color.black.opacity(0.45), in: Capsule())
            }
            .accessibilityLabel(autoCapture ? "Automatic capture on" : "Automatic capture off")
            Spacer()
            if !NetworkMonitor.shared.isOnline {
                Label("Offline", systemImage: "wifi.slash")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(Color.black.opacity(0.55), in: Capsule())
            }
            circleButton("magnifyingglass", active: false) { showingSearch = true }
                .accessibilityLabel("Type a title")
            circleButton("arrow.triangle.2.circlepath.camera", active: false) { camera.switchCamera() }
                .accessibilityLabel("Switch camera")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func circleButton(_ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 40, height: 40)
                .foregroundStyle(active ? Theme.accent : .white)
                .background(Color.black.opacity(0.45), in: Circle())
        }
    }

    private var shutterRow: some View {
        HStack {
            Spacer()
            Button {
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                if !session.collectingMore { session.dismiss() }
                camera.captureNow()
            } label: {
                ZStack {
                    Circle().strokeBorder(.white, lineWidth: 4).frame(width: 72, height: 72)
                    Circle().fill(Theme.accent).frame(width: 58, height: 58)
                }
            }
            .accessibilityLabel("Scan cover now")
            Spacer()
        }
    }

    // MARK: Card

    @ViewBuilder
    private var card: some View {
        switch session.phase {
        case .idle:
            EmptyView()
        case .identifying:
            IdentifyingCard(photo: session.photo, status: session.statusText, botStatus: bot.status) {
                session.dismiss()
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        case .confirm:
            if let identification = session.identification {
                CandidatesCard(identification: identification, photos: session.evidencePhotos,
                               collecting: session.collectingMore, adding: session.addingEvidence,
                               status: session.statusText) {
                    session.startCollectingMore()
                } onStopAdding: {
                    session.stopCollectingMore()
                } onPick: { candidate in
                    session.choose(candidate, context: modelContext, bot: bot)
                } onSearch: {
                    showingSearch = true
                } onCancel: {
                    session.dismiss()
                    camera.waitForNextComic()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        case .result:
            if let record = session.record {
                ResultCard(record: record, valuation: session.valuation, loading: session.loadingPrice,
                           error: session.priceError, session: session) {
                    showingDetail = true
                } onCorrect: {
                    showingCorrection = true
                } onClose: {
                    session.dismiss()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        case .message:
            MessageCard(text: session.message, onSearch: { showingSearch = true }) {
                session.dismiss()
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var permissionView: some View {
        ContentUnavailableView {
            Label("Camera access needed", systemImage: "camera.fill")
        } description: {
            Text("Allow camera access to scan comic covers and barcodes. You can still look comics up by title.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            Button("Type a title") { showingSearch = true }
        }
    }
}

// MARK: - Scanning frame

struct ScanFrameOverlay: View {
    let inView: Bool
    let progress: Double
    let hint: String
    let compact: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width * 0.72, 320)
            let height = width / 0.66
            let rect = CGRect(x: (geometry.size.width - width) / 2,
                              y: max(110, (geometry.size.height - height) / 2 - (compact ? 120 : 40)),
                              width: width, height: height)
            ZStack {
                // Dim everything outside the frame.
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geometry.size))
                    path.addRoundedRect(in: rect, cornerSize: CGSize(width: 18, height: 18))
                }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))

                FrameCorners()
                    .stroke(inView ? Theme.accent : .white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .animation(.easeOut(duration: 0.2), value: inView)

                if progress > 0 {
                    RoundedRectangle(cornerRadius: 18)
                        .trim(from: 0, to: progress)
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .animation(.linear(duration: 0.18), value: progress)
                }

                if !compact {
                    Text(hint)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.black.opacity(0.55), in: Capsule())
                        .position(x: rect.midX, y: rect.maxY + 30)
                }
            }
        }
    }
}

struct FrameCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let length = min(rect.width, rect.height) * 0.14
        var path = Path()
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
            (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
        ]
        for (point, dx, dy) in corners {
            path.move(to: CGPoint(x: point.x, y: point.y + dy * length))
            path.addLine(to: point)
            path.addLine(to: CGPoint(x: point.x + dx * length, y: point.y))
        }
        return path
    }
}
