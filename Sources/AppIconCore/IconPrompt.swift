import Foundation

/// A visual style preset for icon artwork.
public enum IconStyle: String, CaseIterable, Sendable {
    case flat
    case gradient
    case glossy
    case clay
    case glass
    case line
    case pixel
    case illustrated

    public var name: String {
        switch self {
        case .flat: "Flat"
        case .gradient: "Gradient"
        case .glossy: "Glossy 3D"
        case .clay: "Clay"
        case .glass: "Glass"
        case .line: "Line"
        case .pixel: "Pixel art"
        case .illustrated: "Illustrated"
        }
    }

    var descriptor: String {
        switch self {
        case .flat:
            "Flat vector illustration, bold simple shapes, solid colours, crisp clean edges"
        case .gradient:
            "Flat vector illustration with smooth subtle gradients, bold simple shapes, crisp clean edges"
        case .glossy:
            "Glossy 3D render, smooth rounded forms, soft studio lighting, gentle highlights"
        case .clay:
            "Soft matte clay 3D render, rounded chunky forms, pastel colours, soft shadows"
        case .glass:
            "Translucent frosted glass material, layered depth, soft refraction and glow"
        case .line:
            "Minimal line art, uniform thick strokes, a single accent colour, generous negative space"
        case .pixel:
            "Pixel art, large visible pixels, limited colour palette, hard edges"
        case .illustrated:
            "Detailed digital illustration, rich colours, painterly shading, clear silhouette"
        }
    }
}

public enum IconBackground: Sendable, Equatable {
    /// Let the model pick a simple background that suits the subject.
    case automatic
    /// A colour or gradient in plain words, such as "deep blue" or "orange to pink gradient".
    case color(String)
    /// No background. Needs a model with ``ImageModel/supportsTransparency``.
    case transparent
}

/// Builds the text sent to an editing model to refine existing icon artwork.
///
/// Editing models change more than they are asked to unless told what to keep, so the
/// instruction is followed by an explicit list of what must stay the same.
public struct IconEditPrompt: Sendable {
    public var instruction: String

    public init(instruction: String) {
        self.instruction = instruction
    }

    public var text: String {
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
        return [
            "\(instruction).",
            "Keep everything else exactly the same: the subject, the art style, the composition and the edge-to-edge background.",
            "No text, no letters, no frame, no rounded square, no border.",
        ].joined(separator: " ")
    }
}

/// Builds the text sent to an image model for a square, full-bleed piece of icon artwork.
///
/// The wording deliberately never says "app icon": image models respond to that by
/// drawing a rounded tile inset on a backdrop, which is unusable as source artwork.
public struct IconPrompt: Sendable {
    public var subject: String
    public var style: IconStyle
    public var background: IconBackground

    public init(subject: String, style: IconStyle = .gradient, background: IconBackground = .automatic) {
        self.subject = subject
        self.style = style
        self.background = background
    }

    public var text: String {
        let subject = subject.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
        let backdrop =
            switch background {
            case .automatic:
                "Simple background in a complementary colour, extending edge to edge."
            case .color(let description):
                "\(description.prefix(1).uppercased() + description.dropFirst()) background, extending edge to edge."
            case .transparent:
                "Isolated on a fully transparent background with nothing behind the subject."
            }
        return [
            "\(subject), a single centered subject, large, filling most of the frame.",
            "\(style.descriptor).",
            backdrop,
            "No text, no letters, no frame, no rounded square, no border.",
        ].joined(separator: " ")
    }
}
