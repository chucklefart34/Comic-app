import Foundation
import SwiftData
import UIKit
import Vision
import CoreImage

struct CoverMatch: Identifiable {
    let print: CoverPrint
    /// Lower is closer.
    let distance: Float
    var id: UUID { print.ref }

    /// Rough label for how close the match is.
    var closeness: String {
        switch distance {
        case ..<0.45: return "Very close"
        case ..<0.7: return "Close"
        default: return "Possible"
        }
    }
}

enum CoverRecognizerError: LocalizedError {
    case noImage
    case noFingerprint

    var errorDescription: String? {
        switch self {
        case .noImage: return "Couldn't read the photo."
        case .noFingerprint: return "Couldn't analyse the cover. Try again with the whole cover in view."
        }
    }
}

/// Learns covers you confirm and recognises them later from a camera photo, all on the phone.
@MainActor
enum CoverRecognizer {
    private static var cache: [UUID: VNFeaturePrintObservation] = [:]
    /// Most photos kept per book.
    private static let photosPerBook = 6

    // MARK: Learning

    /// Downloads a cover photo (e.g. the eBay listing you tapped) and remembers it for this book.
    static func learn(spec: ComicSpec, imageURL: String, context: ModelContext) async {
        guard !spec.isEmpty, let url = URL(string: imageURL) else { return }
        let existing = (try? context.fetch(FetchDescriptor<CoverPrint>())) ?? []

        // Same photo already learned: if you've since corrected the details, follow the correction.
        if let known = existing.first(where: { $0.imageURL == imageURL }) {
            if known.bookKey != CoverPrint.key(for: spec) { known.update(spec: spec) }
            return
        }
        guard existing.filter({ $0.bookKey == CoverPrint.key(for: spec) }).count < photosPerBook else { return }

        guard let download = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: download.0),
              let cgImage = normalized(image) else { return }
        await learn(spec: spec, image: cgImage, imageURL: imageURL, source: "eBay photo", context: context)
    }

    /// Remembers a photo for this book (e.g. the camera shot you just matched).
    static func learn(spec: ComicSpec, image: CGImage, imageURL: String?, source: String, context: ModelContext) async {
        guard !spec.isEmpty else { return }
        let existing = (try? context.fetch(FetchDescriptor<CoverPrint>())) ?? []
        guard existing.filter({ $0.bookKey == CoverPrint.key(for: spec) }).count < photosPerBook else { return }

        let result = await Task.detached(priority: .utility) { () -> (Data, Data?)? in
            guard let observation = try? makePrint(from: image),
                  let archived = try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true) else { return nil }
            return (archived, thumbnailJPEG(image))
        }.value
        guard let result else { return }

        let print = CoverPrint(spec: spec, imageURL: imageURL, thumbnail: result.1, printData: result.0, source: source)
        context.insert(print)
        try? context.save()
    }

    // MARK: Recognising

    /// Finds the learned covers that look most like an already-cropped cover photo.
    static func matches(forCover cover: CGImage, context: ModelContext, limit: Int = 6) async throws -> [CoverMatch] {
        let prints = (try? context.fetch(FetchDescriptor<CoverPrint>())) ?? []
        guard !prints.isEmpty else { return [] }
        guard let target = await fingerprint(cover) else { throw CoverRecognizerError.noFingerprint }

        var bestPerBook: [String: CoverMatch] = [:]
        for print in prints {
            guard let observation = observation(for: print) else { continue }
            var distance: Float = 0
            do {
                try target.computeDistance(&distance, to: observation)
            } catch {
                continue  // made by a different version of the analyser
            }
            if let current = bestPerBook[print.bookKey], current.distance <= distance { continue }
            bestPerBook[print.bookKey] = CoverMatch(print: print, distance: distance)
        }
        let ranked = bestPerBook.values.sorted { $0.distance < $1.distance }
        return Array(ranked.prefix(limit))
    }

    /// Fingerprint of an image, computed off the main thread.
    static func fingerprint(_ image: CGImage) async -> VNFeaturePrintObservation? {
        let archived = await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let observation = try? makePrint(from: image) else { return nil }
            return try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
        }.value
        return archived.flatMap(unarchive)
    }

    /// Visual distance between two fingerprints (lower = more alike), or nil if they can't be compared.
    static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float? {
        var distance: Float = 0
        do {
            try a.computeDistance(&distance, to: b)
            return distance
        } catch {
            return nil
        }
    }

    static func learnedCount(context: ModelContext) -> Int {
        (try? context.fetchCount(FetchDescriptor<CoverPrint>())) ?? 0
    }

    private static func observation(for print: CoverPrint) -> VNFeaturePrintObservation? {
        if let cached = cache[print.ref] { return cached }
        guard let observation = unarchive(print.printData) else { return nil }
        cache[print.ref] = observation
        return observation
    }

    private static func unarchive(_ data: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }

    // MARK: Image work (runs off the main thread)

    nonisolated static func makePrint(from image: CGImage) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else { throw CoverRecognizerError.noFingerprint }
        return observation
    }

    /// Finds the comic in the photo and straightens it; falls back to the middle of the frame.
    nonisolated static func cropCover(_ image: CGImage) -> CGImage {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.45
        request.maximumAspectRatio = 0.9
        request.minimumSize = 0.25
        request.minimumConfidence = 0.5
        request.maximumObservations = 4
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])

        func area(_ r: VNRectangleObservation) -> CGFloat { r.boundingBox.width * r.boundingBox.height }
        guard let rectangle = request.results?.max(by: { area($0) < area($1) }) else {
            return centerCrop(image)
        }

        let input = CIImage(cgImage: image)
        let width = input.extent.width
        let height = input.extent.height
        func point(_ p: CGPoint) -> CIVector { CIVector(x: p.x * width, y: p.y * height) }

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return centerCrop(image) }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(point(rectangle.topLeft), forKey: "inputTopLeft")
        filter.setValue(point(rectangle.topRight), forKey: "inputTopRight")
        filter.setValue(point(rectangle.bottomLeft), forKey: "inputBottomLeft")
        filter.setValue(point(rectangle.bottomRight), forKey: "inputBottomRight")
        guard let output = filter.outputImage,
              let cropped = CIContext().createCGImage(output, from: output.extent) else { return centerCrop(image) }
        return cropped
    }

    nonisolated static func centerCrop(_ image: CGImage) -> CGImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let cropHeight = min(height * 0.85, width * 0.85 / 0.65)
        let cropWidth = cropHeight * 0.65
        let rect = CGRect(x: (width - cropWidth) / 2, y: (height - cropHeight) / 2, width: cropWidth, height: cropHeight)
        return image.cropping(to: rect.integral) ?? image
    }

    nonisolated static func thumbnailJPEG(_ image: CGImage) -> Data? {
        let maxSide: CGFloat = 320
        let scale = min(1, maxSide / CGFloat(max(image.width, image.height)))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: 0.7)
    }

    /// Bakes the photo's rotation into the pixels and keeps it a sensible size.
    nonisolated static func normalized(_ image: UIImage, maxSide: CGFloat = 1600) -> CGImage? {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxSide / longest)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.cgImage
    }
}
