import CoreGraphics
import Foundation
import Testing

@testable import AppIconCore

@Suite struct IconPromptTests {
    @Test(arguments: IconStyle.allCases)
    func neverAsksForAnAppIcon(style: IconStyle) {
        let text = IconPrompt(subject: "a sun behind a cloud", style: style).text.lowercased()
        #expect(!text.contains("app icon"))
        #expect(!text.contains("icon"))
        #expect(text.contains("no rounded square"))
    }

    @Test func describesTheSubjectStyleAndBackground() {
        let text = IconPrompt(subject: "A paper plane. ", style: .flat, background: .color("deep blue")).text
        #expect(text.hasPrefix("A paper plane, a single centered subject"))
        #expect(text.contains("Flat vector illustration"))
        #expect(text.contains("Deep blue background, extending edge to edge."))
    }

    @Test func asksForTransparencyInWords() {
        let text = IconPrompt(subject: "a fox", background: .transparent).text
        #expect(text.contains("transparent background"))
        #expect(!text.contains("edge to edge"))
    }
}

@Suite struct IconEditPromptTests {
    @Test func followsTheInstructionWithWhatToKeep() {
        let text = IconEditPrompt(instruction: " Make the sky orange. ").text
        #expect(text.hasPrefix("Make the sky orange. Keep everything else exactly the same"))
        #expect(text.contains("no rounded square"))
        #expect(!text.lowercased().contains("icon"))
    }
}

@Suite struct IconExporterTests {
    private struct Contents: Decodable {
        struct Entry: Decodable {
            let filename: String
            let idiom: String
            let platform: String?
            let scale: String?
            let size: String
        }
        let images: [Entry]
    }

    @Test func writesAnIconSetXcodeCanRead() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let iconSet = try IconExporter().writeAppIconSet(from: testImage(), in: directory)

        #expect(iconSet.lastPathComponent == "AppIcon.appiconset")
        let contents = try JSONDecoder().decode(
            Contents.self, from: Data(contentsOf: iconSet.appending(path: "Contents.json")))
        #expect(contents.images.count == 11)

        // Every listed file exists at the pixel size its entry declares.
        for entry in contents.images {
            let image = try ImageCodec.decode(Data(contentsOf: iconSet.appending(path: entry.filename)))
            let points = try #require(Int(entry.size.split(separator: "x")[0]))
            let scale = entry.scale.flatMap { Int($0.dropLast()) } ?? 1
            #expect(image.width == points * scale, "\(entry.filename)")
            #expect(image.height == points * scale, "\(entry.filename)")
        }

        let iOS = try #require(contents.images.first { $0.platform == "ios" })
        #expect(iOS.idiom == "universal")
        #expect(iOS.size == "1024x1024")
        #expect(contents.images.filter { $0.idiom == "mac" }.count == 10)
    }

    @Test func iOSIconIsOpaqueAndFullBleed() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let iconSet = try IconExporter().writeAppIconSet(
            from: testImage(transparent: true), platforms: [.iOS], in: directory)
        let image = try ImageCodec.decode(Data(contentsOf: iconSet.appending(path: "ios-1024.png")))

        // The App Store rejects icons with an alpha channel.
        #expect([.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo))
        // Transparent artwork is flattened onto white, right into the corner.
        #expect(pixel(image, x: 0, y: 0) == [255, 255, 255, 255])
    }

    @Test func macIconIsARoundedTileWithClearCorners() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let iconSet = try IconExporter().writeAppIconSet(from: testImage(), platforms: [.macOS], in: directory)
        let image = try ImageCodec.decode(Data(contentsOf: iconSet.appending(path: "mac-512@2x.png")))

        #expect(pixel(image, x: 0, y: 0)[3] == 0)  // canvas corner: outside the tile
        #expect(pixel(image, x: 110, y: 110)[3] < 128)  // inside the tile's bounding box, outside its rounded corner
        let centre = pixel(image, x: 512, y: 512)
        #expect(centre[0] > 240 && centre[1] < 20 && centre[3] == 255)  // the red artwork
        #expect(pixel(image, x: 512, y: 104)[3] == 255)  // just inside the tile's top edge
        #expect(pixel(image, x: 512, y: 90)[3] < 255)  // just outside it
    }

    @Test func cropsNonSquareArtworkInsteadOfStretching() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let iconSet = try IconExporter().writeAppIconSet(
            from: testImage(width: 128, height: 64), platforms: [.iOS], in: directory)
        let image = try ImageCodec.decode(Data(contentsOf: iconSet.appending(path: "ios-1024.png")))

        // Aspect fill leaves no white bars at the top or bottom.
        #expect(pixel(image, x: 512, y: 2)[1] < 20)
        #expect(pixel(image, x: 512, y: 1021)[1] < 20)
    }

    @Test func replacesAnExistingIconSet() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter = IconExporter()

        try exporter.writeAppIconSet(from: testImage(), in: directory)
        let iconSet = try exporter.writeAppIconSet(from: testImage(), platforms: [.iOS], in: directory)

        let files = try FileManager.default.contentsOfDirectory(atPath: iconSet.path).sorted()
        #expect(files == ["Contents.json", "ios-1024.png"])
    }

    @Test func writesAnICNSFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "AppIcon.icns")

        try IconExporter().writeICNS(from: testImage(), to: file)

        let data = try Data(contentsOf: file)
        #expect(data.starts(with: Array("icns".utf8)))
        #expect(data.count > 1000)
    }

    @Test func rejectsDataThatIsNotAnImage() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: ImageError.unreadable) {
            try IconExporter().writeAppIconSet(from: Data("not an image".utf8), in: directory)
        }
    }
}
