import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageTranscoder {
    static func jpegDataPreservingMetadata(from data: Data, quality: CGFloat = 0.9) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return transcodeJPEG(source: source, quality: quality)
    }

    static func jpegDataPreservingMetadata(fromFile url: URL, quality: CGFloat = 0.9) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return transcodeJPEG(source: source, quality: quality)
    }

    private static func transcodeJPEG(source: CGImageSource, quality: CGFloat) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output,
                                                                 UTType.jpeg.identifier as CFString,
                                                                 1,
                                                                 nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
