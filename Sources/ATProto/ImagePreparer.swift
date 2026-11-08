import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PreparedImage: Codable, Equatable, Sendable {
    let data: Data
    let mimeType: String
    let width: Int
    let height: Int
}

enum ImagePreparerError: LocalizedError {
    case unreadable
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .unreadable: return tr("Diese Datei lässt sich nicht als Bild lesen.", "This file cannot be read as a picture.")
        case .tooLarge: return tr("Das Bild lässt sich nicht klein genug speichern.", "This picture cannot be saved small enough.")
        }
    }
}

/// Bluesky rejects images near 1 MB, so pictures are scaled and re-encoded as JPEG before upload.
/// Re-encoding also drops metadata such as the GPS position a photo may contain.
enum ImagePreparer {
    static let maxBytes = 950_000
    private static let pixelSizes = [2000, 1500, 1000, 700]
    private static let qualities: [CGFloat] = [0.85, 0.7, 0.55, 0.4]

    static func prepare(_ source: Data) throws -> PreparedImage {
        guard let imageSource = CGImageSourceCreateWithData(source as CFData, nil),
              CGImageSourceGetCount(imageSource) > 0 else {
            throw ImagePreparerError.unreadable
        }
        for pixelSize in pixelSizes {
            guard let image = scaled(imageSource, maxPixels: pixelSize) else {
                throw ImagePreparerError.unreadable
            }
            for quality in qualities {
                if let data = jpeg(image, quality: quality), data.count <= maxBytes {
                    return PreparedImage(data: data, mimeType: "image/jpeg", width: image.width, height: image.height)
                }
            }
        }
        throw ImagePreparerError.tooLarge
    }

    private static func scaled(_ source: CGImageSource, maxPixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Bakes in the rotation, which would otherwise be lost along with the metadata.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return flattened(image)
    }

    /// JPEG has no transparency, and transparent areas would turn black without a background.
    private static func flattened(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    private static func jpeg(_ image: CGImage, quality: CGFloat) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
