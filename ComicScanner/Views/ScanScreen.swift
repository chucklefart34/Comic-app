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
    /// The tray item a search is for (nil = add a new book).
    @State private var searchTarget: TrayItem?
    @State private var compsItem: TrayItem?
    @State private var fixItem: TrayItem?
    @State private var confirmingClear = false
    @AppStorage(Prefs.autoCaptureKey) private var autoCapture = true
    @State private var flash = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                switch camera.status {
                case .running, .idle:
                    CameraPreview(session: camera.session)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                            camera.captureNow()
                        }
                    ScanFrameOverlay(inView: camera.coverInView, progress: camera.lockProgress,
                                     hint: hint, highlight: session.collectingFor != nil || session.pendingID != nil)
                        .allowsHitTesting(false)
                    Color.white
                        .opacity(flash ? 0.35 : 0)
                        .allowsHitTesting(false)
                case .denied:
                    permissionView
                case .unavailable:
                    ContentUnavailableView("Camera unavailable", systemImage: "camera.metering.unknown",
                                           description: Text("This device's camera can't be used. You can still search by title."))
                }

                VStack(spacing: 0) {
                    topBar
                    if let toast = session.toast {
                        Text(toast)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(Theme.good.opacity(0.9), in: Capsule())
                            .padding(.top, 10)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Spacer()
                    controlRow
                        .padding(.bottom, 12)
                }
            }
            .clipped()

            if !session.items.isEmpty {
                ScanTray(session: session) { item in
                    compsItem = item
                } onFix: { item in
                    fixItem = item
                } onSearch: { item in
                    searchTarget = item
                    showingSearch = true
                } onAddAll: {
                    session.addAllToCollection(context: modelContext)
                }
                .transition(.move(edge: .bottom))
            }
        }
        .background(Color.black.ignoresSafeArea())
        .animation(.snappy, value: session.items.isEmpty)
        .preferredColorScheme(.dark)
        .task {
            camera.onEvent = { event in
                session.handle(event, context: modelContext, bot: bot)
            }
            session.onNeedNewComic = { camera.waitForNextComic() }
            camera.setAutoCapture(autoCapture)
            updateBarcodes()
            await camera.start()
        }
        .onChange(of: session.collectingFor) { _, _ in updateBarcodes() }
        .onChange(of: camera.captureCount) { _, _ in
            flash = true
            withAnimation(.easeOut(duration: 0.35)) { flash = false }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await camera.start() } } else { camera.stop() }
        }
        .onChange(of: showingSearch || compsItem != nil || fixItem != nil || bot.showingWebView) { _, covered in
            camera.setPaused(covered)
        }
        .sheet(isPresented: $showingSearch, onDismiss: { searchTarget = nil }) {
            ManualSearchView { candidate in
                showingSearch = false
                if let target = searchTarget, session.items.contains(where: { $0.id == target.id }) {
                    session.choose(candidate, for: target, context: modelContext, bot: bot)
                } else {
                    session.addSearched(candidate, context: modelContext, bot: bot)
                }
            }
        }
        .sheet(item: $compsItem) { item in
            if let record = item.record {
                NavigationStack { ComicDetailView(record: record) }
            }
        }
        .sheet(item: $fixItem) { item in
            CorrectionSheet(identification: item.identification, record: item.record) { candidate in
                fixItem = nil
                session.choose(candidate, for: item, context: modelContext, bot: bot)
            } onSearch: {
                fixItem = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    searchTarget = item
                    showingSearch = true
                }
            } onEdited: { _ in
                fixItem = nil
                item.needsCheck = false
                session.reprice(item, bot: bot, context: modelContext)
            }
        }
        .confirmationDialog("Clear all \(session.items.count) scans?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear tray", role: .destructive) { session.clear() }
        } message: {
            Text("They stay in your scan history; only the tray is emptied.")
        }
    }

    private var hint: String {
        if session.collectingFor != nil { return "Scan the barcode of that book" }
        if let pending = session.pending {
            return pending.firstWasBarcode ? "Now tap to scan the front cover"
                                           : "Now scan the barcode — or tap to scan the cover again"
        }
        if camera.coverInView && camera.lockProgress > 0 { return "Hold steady…" }
        return autoCapture ? "Hold a cover in the frame, or tap to scan" : "Fill the frame with the cover, then tap to scan"
    }

    // MARK: Bars

    private var topBar: some View {
        HStack(spacing: 12) {
            circleButton("xmark", active: false) {
                if !session.items.isEmpty { confirmingClear = true }
            }
            .opacity(session.items.isEmpty ? 0.4 : 1)
            .accessibilityLabel("Clear the tray")
            Spacer()
            HStack(spacing: 8) {
                Text("Scan").font(.title3.weight(.semibold))
                if !NetworkMonitor.shared.isOnline {
                    Image(systemName: "wifi.slash").font(.subheadline).foregroundStyle(Theme.caution)
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 48)
            .background(.ultraThinMaterial.opacity(0.9), in: Capsule())
            Spacer()
            circleButton("magnifyingglass", active: false) {
                searchTarget = nil
                showingSearch = true
            }
            .accessibilityLabel("Search by title")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var controlRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                modeChip("Auto", active: autoCapture) { setAuto(true) }
                modeChip("Tap", active: !autoCapture) { setAuto(false) }
            }
            .padding(4)
            .background(.ultraThinMaterial.opacity(0.9), in: Capsule())

            HStack(spacing: 4) {
                if camera.hasTorch {
                    iconChip(camera.torchOn ? "flashlight.on.fill" : "flashlight.off.fill", active: camera.torchOn) { camera.toggleTorch() }
                        .accessibilityLabel(camera.torchOn ? "Light off" : "Light on")
                }
                iconChip("arrow.triangle.2.circlepath.camera", active: false) { camera.switchCamera() }
                    .accessibilityLabel("Switch camera")
            }
            .padding(4)
            .background(.ultraThinMaterial.opacity(0.9), in: Capsule())
        }
    }

    private func setAuto(_ on: Bool) {
        autoCapture = on
        camera.setAutoCapture(on)
        updateBarcodes()
    }

    /// Barcodes are read on sight in Auto mode, or while fixing a match; in Tap mode only a tap captures.
    private func updateBarcodes() {
        camera.setBarcodesLive(autoCapture || session.collectingFor != nil)
    }

    private func modeChip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .frame(height: 38)
                .foregroundStyle(active ? .white : Theme.secondary)
                .background(active ? Color.white.opacity(0.18) : .clear, in: Capsule())
        }
    }

    private func iconChip(_ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 42, height: 38)
                .foregroundStyle(active ? Theme.caution : .white)
        }
    }

    private func circleButton(_ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 48, height: 48)
                .foregroundStyle(active ? Theme.accent : .white)
                .background(.ultraThinMaterial.opacity(0.9), in: Circle())
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
            Button("Search by title") { showingSearch = true }
        }
    }
}

// MARK: - Scanning frame

struct ScanFrameOverlay: View {
    let inView: Bool
    let progress: Double
    let hint: String
    var highlight = false

    var body: some View {
        GeometryReader { geometry in
            let topSpace: CGFloat = 76
            let bottomSpace: CGFloat = 70
            let available = max(120, geometry.size.height - topSpace - bottomSpace)
            let height = min(available, geometry.size.width * 0.84 / 0.66)
            let width = height * 0.66
            let rect = CGRect(x: (geometry.size.width - width) / 2, y: topSpace + (available - height) / 2,
                              width: width, height: height)
            let color = highlight ? Theme.caution : (inView ? Theme.good : Color.white.opacity(0.85))
            ZStack {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geometry.size))
                    path.addRoundedRect(in: rect, cornerSize: CGSize(width: 22, height: 22))
                }
                .fill(Color.black.opacity(0.35), style: FillStyle(eoFill: true))

                RoundedRectangle(cornerRadius: 22)
                    .stroke(color, lineWidth: 4)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .animation(.easeOut(duration: 0.2), value: inView)

                if progress > 0 {
                    RoundedRectangle(cornerRadius: 22)
                        .trim(from: 0, to: progress)
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .animation(.linear(duration: 0.18), value: progress)
                }

                Text(hint)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial.opacity(0.85), in: Capsule())
                    .frame(maxWidth: rect.width - 16)
                    .position(x: rect.midX, y: rect.midY)
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
