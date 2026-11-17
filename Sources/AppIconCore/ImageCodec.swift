import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageError: Error, LocalizedError, Equatable {
    case unreadable
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .unreadable: "The data is not a readable image."
        case .encodingFailed: "The image could not be encoded as PNG."
        }
    }
}

enum ImageCodec {
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]

    static func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageError.unreadable
        }
        return image
    }

    static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else {
            throw ImageError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageError.encodingFailed }
        return data as Data
    }

    /// Returns a PNG that is exactly `side` pixels square, centre-cropping and scaling as needed.
    /// Data that already is such a PNG is returned untouched.
    static func squarePNG(from data: Data, side: Int) throws -> Data {
        let image = try decode(data)
        if image.width == side, image.height == side { return try png(from: data) }
        let hasAlpha = ![.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: (hasAlpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue) else {
            throw ImageError.encodingFailed
        }
        context.interpolationQuality = .high
        let scale = max(CGFloat(side) / CGFloat(image.width), CGFloat(side) / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.draw(image, in: CGRect(
            x: (CGFloat(side) - size.width) / 2, y: (CGFloat(side) - size.height) / 2,
            width: size.width, height: size.height))
        guard let scaled = context.makeImage() else { throw ImageError.encodingFailed }
        return try encodePNG(scaled)
    }

    /// Returns PNG data for any readable image, leaving data that is already PNG untouched.
    static func png(from data: Data) throws -> Data {
        if data.starts(with: pngSignature) {
            _ = try decode(data)
            return data
        }
        return try encodePNG(try decode(data))
    }
}
