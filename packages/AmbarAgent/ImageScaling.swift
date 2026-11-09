import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Clipboard images, made small enough to hand to a model (owner's decision: images go to
/// the agent too, under a size cap). ImageIO, so nothing outside the system is involved.
enum ImageScaling {
    /// Longest side sent: what vision models resize to anyway.
    static let maximumSide = 1568
    /// Bytes sent at most, before base64.
    static let maximumBytes = 1_500_000

    struct Scaled: Equatable {
        var data: Data
        var mimeType: String
        var width: Int
        var height: Int
    }

    /// A JPEG of the image no longer than `maximumSide` on its longest side and no larger
    /// than `maximumBytes`, stepping the size and quality down until it fits; nil when the
    /// data is not an image or will not fit at all.
    static func scaled(_ data: Data) -> Scaled? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        for (side, quality) in [(maximumSide, 0.85), (1200, 0.75), (900, 0.65), (640, 0.6)] {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if output.length <= maximumBytes {
                return Scaled(data: output as Data, mimeType: "image/jpeg", width: image.width, height: image.height)
            }
        }
        return nil
    }
}
