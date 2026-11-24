import AVFoundation
import CoreImage
import SwiftUI
import UIKit
import Vision

/// What the camera found.
enum CameraEvent {
    /// A retail barcode, with the 5-digit add-on if it could be read, and the frame it was seen in.
    case barcode(ComicBarcode, frame: CGImage?)
    /// A slab label QR code / cert barcode.
    case slab(SlabCert)
    /// A comic cover, straightened and cropped.
    case cover(CGImage, frame: CGImage)
}

/// Runs the camera: live preview, barcode/QR reading, and auto-capture when a cover holds still in frame.
@MainActor
@Observable
final class CameraModel {
    enum Status: Equatable { case idle, running, denied, unavailable }

    var status: Status = .idle
    var torchOn = false
    var usingFrontCamera = false
    var autoCapture = true
    /// A cover-shaped rectangle is in view.
    var coverInView = false
    /// 0…1 while the cover is held steady before auto-capture.
    var lockProgress: Double = 0
    var hasTorch = false
    /// Goes up by one on every capture, so the screen can flash and reset the frame.
    var captureCount = 0

    @ObservationIgnored var onEvent: ((CameraEvent) -> Void)?

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let processor = FrameProcessor()
    private var device: AVCaptureDevice?
    private var configured = false

    init() {
        processor.onUpdate = { [weak self] inView, progress in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.coverInView != inView { self.coverInView = inView }
                if abs(self.lockProgress - progress) > 0.01 { self.lockProgress = progress }
            }
        }
        processor.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                guard let self else { return }
                self.captureCount += 1
                self.coverInView = false
                self.lockProgress = 0
                self.onEvent?(event)
            }
        }
    }

    // MARK: Lifecycle

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { status = .denied; return }
        case .authorized:
            break
        default:
            status = .denied
            return
        }
        if !configured {
            guard configure(front: usingFrontCamera) else { status = .unavailable; return }
            configured = true
        }
        processor.autoCapture = autoCapture
        let session = session
        sessionQueue.async { if !session.isRunning { session.startRunning() } }
        status = .running
    }

    func stop() {
        let session = session
        sessionQueue.async { if session.isRunning { session.stopRunning() } }
        torchOn = false
    }

    /// Pause automatic captures (e.g. while a sheet is open). Barcodes are paused too.
    func setPaused(_ paused: Bool) {
        processor.paused = paused
    }

    func setAutoCapture(_ on: Bool) {
        autoCapture = on
        processor.autoCapture = on
    }

    /// Whether barcodes are read the moment they're seen. Off in Tap mode, so nothing is captured without a tap
    /// (a slab QR code seen just before a tap is still used).
    func setBarcodesLive(_ on: Bool) {
        processor.barcodesLive = on
    }

    /// Don't auto-capture again until the current comic leaves the frame.
    func waitForNextComic() {
        processor.requireNewComic()
    }

    // MARK: Controls

    func toggleTorch() {
        guard let device, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = torchOn ? .off : .on
            device.unlockForConfiguration()
            torchOn.toggle()
        } catch {}
    }

    func switchCamera() {
        usingFrontCamera.toggle()
        torchOn = false
        let front = usingFrontCamera
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        _ = addInput(front: front)
        session.commitConfiguration()
        applyRotation()
    }

    /// Manual shutter: uses the newest frame.
    func captureNow() {
        processor.captureNow()
    }

    // MARK: Setup

    private func configure(front: Bool) -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        guard addInput(front: front) else { return false }

        let video = AVCaptureVideoDataOutput()
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        video.alwaysDiscardsLateVideoFrames = true
        video.setSampleBufferDelegate(processor, queue: processor.queue)
        guard session.canAddOutput(video) else { return false }
        session.addOutput(video)

        let metadata = AVCaptureMetadataOutput()
        if session.canAddOutput(metadata) {
            session.addOutput(metadata)
            metadata.setMetadataObjectsDelegate(processor, queue: processor.queue)
            let wanted: [AVMetadataObject.ObjectType] = [.ean13, .upce, .ean8, .qr, .code128, .code39]
            metadata.metadataObjectTypes = wanted.filter { metadata.availableMetadataObjectTypes.contains($0) }
        }
        applyRotation()
        return true
    }

    @discardableResult
    private func addInput(front: Bool) -> Bool {
        let position: AVCaptureDevice.Position = front ? .front : .back
        let types: [AVCaptureDevice.DeviceType] = front
            ? [.builtInWideAngleCamera]
            : [.builtInDualWideCamera, .builtInTripleCamera, .builtInWideAngleCamera]
        guard let camera = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position).devices.first
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else { return false }
        session.addInput(input)
        device = camera
        hasTorch = camera.hasTorch

        if (try? camera.lockForConfiguration()) != nil {
            if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
            if camera.isAutoFocusRangeRestrictionSupported { camera.autoFocusRangeRestriction = .near }
            if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
            // Close-up comics: let multi-lens phones pick the macro-capable lens.
            if camera.deviceType != .builtInWideAngleCamera, camera.minAvailableVideoZoomFactor <= 1 {
                camera.videoZoomFactor = max(camera.minAvailableVideoZoomFactor, min(2, camera.maxAvailableVideoZoomFactor))
            }
            camera.unlockForConfiguration()
        }
        return true
    }

    private func applyRotation() {
        for output in session.outputs {
            guard let connection = output.connection(with: .video) else { continue }
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if usingFrontCamera, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }
    }
}

/// Works on camera frames off the main thread: finds covers, reads barcodes and add-on digits.
final class FrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureMetadataOutputObjectsDelegate {
    let queue = DispatchQueue(label: "camera.frames", qos: .userInitiated)

    var onUpdate: ((Bool, Double) -> Void)?
    var onEvent: ((CameraEvent) -> Void)?

    // Settings changed from the main thread; read on `queue`.
    var paused = false
    var autoCapture = true
    var barcodesLive = true

    private let context = CIContext(options: [.cacheIntermediates: false])
    private var latestFrame: CGImage?
    private var lastAnalysis = Date.distantPast
    private var stableCount = 0
    private var lastRect: CGRect?
    private var waitingForNewComic = false
    private var missingCount = 0
    private var capturedRect: CGRect?
    private var lastBarcode: (payload: String, at: Date)?
    private var manualRequested = false
    /// In Tap mode: the last slab QR seen, used if you tap right after.
    private var recentSlab: (cert: SlabCert, at: Date)?

    private static let framesToLock = 3

    func requireNewComic() {
        queue.async {
            self.waitingForNewComic = true
            self.missingCount = 0
        }
    }

    func captureNow() {
        queue.async { self.manualRequested = true }
    }

    // MARK: Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard manualRequested || now.timeIntervalSince(lastAnalysis) >= 0.12 else { return }
        lastAnalysis = now
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let longest = max(image.extent.width, image.extent.height)
        let scale = min(1, 1600 / longest)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let frame = context.createCGImage(scaled, from: scaled.extent) else { return }
        latestFrame = frame

        if manualRequested {
            manualRequested = false
            if let slab = recentSlab, now.timeIntervalSince(slab.at) < 1.5 {
                recentSlab = nil
                requireNewComicNow()
                onUpdate?(false, 0)
                onEvent?(.slab(slab.cert))
                return
            }
            let cover = CoverRecognizer.cropCover(frame)
            requireNewComicNow()
            onUpdate?(false, 0)
            onEvent?(.cover(cover, frame: frame))
            return
        }

        analyse(frame)
    }

    private func analyse(_ frame: CGImage) {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.5
        request.maximumAspectRatio = 0.85
        request.minimumSize = 0.3
        request.minimumConfidence = 0.6
        request.maximumObservations = 3
        try? VNImageRequestHandler(cgImage: frame, options: [:]).perform([request])

        let rectangle = request.results?.max { area($0.boundingBox) < area($1.boundingBox) }
        let box = rectangle?.boundingBox
        let bigEnough = box.map { area($0) >= 0.18 } ?? false

        if waitingForNewComic {
            // Re-arm once the comic leaves, or a clearly different one appears.
            if !bigEnough {
                missingCount += 1
            } else if let box, let capturedRect, iou(box, capturedRect) < 0.4 {
                missingCount += 1
            } else {
                missingCount = 0
            }
            if missingCount >= 3 {
                waitingForNewComic = false
                capturedRect = nil
            }
            stableCount = 0
            onUpdate?(false, 0)
            return
        }

        guard bigEnough, let box, let rectangle else {
            stableCount = 0
            lastRect = nil
            onUpdate?(false, 0)
            return
        }

        if let lastRect, iou(box, lastRect) > 0.85 {
            stableCount += 1
        } else {
            stableCount = 1
        }
        lastRect = box

        let canFire = autoCapture && !paused
        onUpdate?(true, canFire ? min(1, Double(stableCount) / Double(Self.framesToLock)) : 0)

        if canFire, stableCount >= Self.framesToLock {
            let cover = crop(frame, to: rectangle)
            capturedRect = box
            requireNewComicNow()
            onEvent?(.cover(cover, frame: frame))
        }
    }

    private func requireNewComicNow() {
        waitingForNewComic = true
        missingCount = 0
        stableCount = 0
    }

    private func crop(_ frame: CGImage, to rectangle: VNRectangleObservation) -> CGImage {
        let input = CIImage(cgImage: frame)
        let width = input.extent.width
        let height = input.extent.height
        func point(_ p: CGPoint) -> CIVector { CIVector(x: p.x * width, y: p.y * height) }
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return frame }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(point(rectangle.topLeft), forKey: "inputTopLeft")
        filter.setValue(point(rectangle.topRight), forKey: "inputTopRight")
        filter.setValue(point(rectangle.bottomLeft), forKey: "inputBottomLeft")
        filter.setValue(point(rectangle.bottomRight), forKey: "inputBottomRight")
        guard let output = filter.outputImage,
              let cropped = context.createCGImage(output, from: output.extent) else { return frame }
        return cropped
    }

    // MARK: Barcodes

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !paused else { return }
        for object in metadataObjects {
            guard let code = object as? AVMetadataMachineReadableCodeObject, let payload = code.stringValue else { continue }
            if let last = lastBarcode, last.payload == payload, Date().timeIntervalSince(last.at) < 4 { continue }
            if waitingForNewComic, lastBarcode?.payload == payload { continue }
            lastBarcode = (payload, Date())

            let isProduct = [.ean13, .upce, .ean8].contains(code.type)
            if !barcodesLive {
                // Tap mode: nothing fires by itself. Remember a slab QR so a tap can use it.
                if !isProduct, let cert = SlabCert(payload: payload) { recentSlab = (cert, Date()) }
                lastBarcode = nil
                continue
            }
            if !isProduct, let cert = SlabCert(payload: payload) {
                requireNewComicNow()
                onEvent?(.slab(cert))
                return
            }
            guard isProduct, var barcode = ComicBarcode(payload: payload) else { continue }
            let frame = latestFrame
            if !barcode.hasAddOn, let frame, let addOn = Self.readAddOn(in: frame, excluding: barcode.base) {
                barcode.addOn = addOn
            }
            requireNewComicNow()
            onEvent?(.barcode(barcode, frame: frame))
            return
        }
    }

    /// The 5 small digits printed beside a comic's barcode (issue, cover, printing).
    static func readAddOn(in frame: CGImage, excluding base: String) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: frame, options: [:]).perform([request])
        for observation in request.results ?? [] {
            for candidate in observation.topCandidates(2) {
                let digits = candidate.string.filter { !$0.isWhitespace }
                guard digits.count == 5, digits.allSatisfy(\.isNumber), !base.contains(digits) else { continue }
                return digits
            }
        }
        return nil
    }

    private func area(_ r: CGRect) -> CGFloat { r.width * r.height }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let inter = area(intersection)
        return inter / (area(a) + area(b) - inter)
    }
}

/// Camera preview layer.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
