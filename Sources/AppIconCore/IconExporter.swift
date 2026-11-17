import CoreGraphics
import Foundation

public enum ExportError: Error, LocalizedError {
    case iconutilFailed(String)

    public var errorDescription: String? {
        switch self {
        case .iconutilFailed(let output): "iconutil could not build the .icns file: \(output)"
        }
    }
}

/// Turns one piece of square artwork into the icon files Xcode and macOS expect.
///
/// Artwork that is not square is centre-cropped. Transparent areas are filled with white,
/// because iOS icons may not contain alpha and a macOS tile needs a solid face.
public struct IconExporter: Sendable {
    public enum Platform: String, Sendable, CaseIterable {
        /// One opaque full-bleed 1024 px image; the system applies the corner mask.
        case iOS
        /// All ten sizes, drawn as the rounded tile with a drop shadow that macOS icons carry.
        case macOS
    }

    public init() {}

    /// Writes `AppIcon.appiconset` into `directory`, replacing an existing one, and returns its URL.
    @discardableResult
    public func writeAppIconSet(
        from artwork: Data,
        platforms: Set<Platform> = Set(Platform.allCases),
        in directory: URL
    ) throws -> URL {
        let source = try ImageCodec.decode(artwork)
        let files = FileManager.default
        let iconSet = directory.appending(path: "AppIcon.appiconset")
        if files.fileExists(atPath: iconSet.path) { try files.removeItem(at: iconSet) }
        try files.createDirectory(at: iconSet, withIntermediateDirectories: true)

        var entries: [Contents.Entry] = []
        if platforms.contains(.iOS) {
            let filename = "ios-1024.png"
            try render(source, pixels: 1024, shape: .fullBleed).write(to: iconSet.appending(path: filename))
            entries.append(.init(filename: filename, idiom: "universal", platform: "ios", scale: nil, size: "1024x1024"))
        }
        if platforms.contains(.macOS) {
            for slot in MacSlot.all {
                let filename = "mac-\(slot.points)\(slot.scale == 2 ? "@2x" : "").png"
                try render(source, pixels: slot.pixels, shape: .macTile).write(to: iconSet.appending(path: filename))
                entries.append(.init(
                    filename: filename, idiom: "mac", platform: nil,
                    scale: "\(slot.scale)x", size: "\(slot.points)x\(slot.points)"))
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Contents(images: entries, info: .init(author: "xcode", version: 1)))
            .write(to: iconSet.appending(path: "Contents.json"))
        return iconSet
    }

    /// Writes a macOS `.icns` file, replacing an existing one.
    public func writeICNS(from artwork: Data, to file: URL) throws {
        let source = try ImageCodec.decode(artwork)
        let files = FileManager.default
        let workspace = files.temporaryDirectory.appending(path: UUID().uuidString)
        let iconset = workspace.appending(path: "icon.iconset")
        try files.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: workspace) }

        for slot in MacSlot.all {
            let name = "icon_\(slot.points)x\(slot.points)\(slot.scale == 2 ? "@2x" : "").png"
            try render(source, pixels: slot.pixels, shape: .macTile).write(to: iconset.appending(path: name))
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["--convert", "icns", "--output", file.path, iconset.path]
        process.standardError = output
        process.standardOutput = output
        try process.run()
        let message = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExportError.iconutilFailed(String(data: message, encoding: .utf8) ?? "")
        }
    }

    // MARK: - Rendering

    private enum Shape {
        case fullBleed
        case macTile
    }

    /// The sizes macOS asks for, in points at 1x and 2x.
    private struct MacSlot {
        let points: Int
        let scale: Int
        var pixels: Int { points * scale }

        static let all = [16, 32, 128, 256, 512].flatMap { points in
            [MacSlot(points: points, scale: 1), MacSlot(points: points, scale: 2)]
        }
    }

    private func render(_ source: CGImage, pixels: Int, shape: Shape) throws -> Data {
        let opaque = shape == .fullBleed
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: alpha.rawValue) else {
            throw ImageError.encodingFailed
        }
        context.interpolationQuality = .high
        let side = CGFloat(pixels)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

        switch shape {
        case .fullBleed:
            let canvas = CGRect(x: 0, y: 0, width: side, height: side)
            context.setFillColor(white)
            context.fill(canvas)
            context.draw(source, in: Self.aspectFill(source, in: canvas))

        case .macTile:
            // Apple's macOS icon grid, defined on a 1024 px canvas: an 824 px tile with a
            // 185.4 px corner radius and a soft shadow below it.
            let unit = side / 1024
            let tile = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
            let outline = CGPath(
                roundedRect: tile, cornerWidth: 185.4 * unit, cornerHeight: 185.4 * unit, transform: nil)
            context.setShadow(
                offset: CGSize(width: 0, height: -12 * unit), blur: 28 * unit,
                color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.5))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.addPath(outline)
            context.clip()
            context.setFillColor(white)
            context.fill(tile)
            context.draw(source, in: Self.aspectFill(source, in: tile))
            context.endTransparencyLayer()
        }

        guard let image = context.makeImage() else { throw ImageError.encodingFailed }
        return try ImageCodec.encodePNG(image)
    }

    /// The rectangle that makes `image` cover `bounds` completely, centred, keeping its proportions.
    private static func aspectFill(_ image: CGImage, in bounds: CGRect) -> CGRect {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = max(bounds.width / width, bounds.height / height)
        let size = CGSize(width: width * scale, height: height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
            width: size.width, height: size.height)
    }

    // MARK: - Contents.json

    private struct Contents: Encodable {
        struct Entry: Encodable {
            let filename: String
            let idiom: String
            let platform: String?
            let scale: String?
            let size: String
        }
        struct Info: Encodable {
            let author: String
            let version: Int
        }
        let images: [Entry]
        let info: Info
    }
}
