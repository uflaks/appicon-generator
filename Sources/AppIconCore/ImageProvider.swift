import CoreGraphics
import Foundation

/// The month a model was released.
public struct ReleaseDate: Sendable, Hashable, Comparable {
    public let year: Int
    public let month: Int

    public init(_ year: Int, _ month: Int) {
        self.year = year
        self.month = month
    }

    public static func < (lhs: ReleaseDate, rhs: ReleaseDate) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }

    /// For example "Jun 2026".
    public var label: String {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(months[max(1, min(12, month)) - 1]) \(year)"
    }
}

/// Where the public scores on ``ImageModel/arenaScore`` come from. They are a hand-copied
/// snapshot and judge general image quality, not icons.
public enum ArenaSnapshot {
    public static let source = "Artificial Analysis text-to-image arena"
    public static let date = "17 November 2026"
}

/// A model an ``ImageProvider`` can generate with.
public struct ImageModel: Sendable, Hashable, Identifiable {
    /// The identifier the provider's API expects.
    public let id: String
    public let name: String
    /// Whether the model can return an image with a real alpha channel.
    public let supportsTransparency: Bool
    public let released: ReleaseDate?
    /// Elo score in the public arena named by ``ArenaSnapshot``, if the model is listed there.
    public let arenaScore: Int?
    /// True for models that newer ones on offer have clearly overtaken.
    public let isOlder: Bool
    public let license: ModelLicense?

    public init(
        id: String, name: String, supportsTransparency: Bool,
        released: ReleaseDate? = nil, arenaScore: Int? = nil, isOlder: Bool = false,
        license: ModelLicense? = nil
    ) {
        self.license = license
        self.id = id
        self.name = name
        self.supportsTransparency = supportsTransparency
        self.released = released
        self.arenaScore = arenaScore
        self.isOlder = isOlder
    }
}

extension Collection where Element == ImageModel {
    /// The model with the highest public score. When none is rated, the first one, which is
    /// the provider's own default.
    public var topRated: ImageModel? {
        filter { $0.arenaScore != nil }.max { ($0.arenaScore ?? 0) < ($1.arenaScore ?? 0) } ?? first
    }
}

/// A request for square 1024×1024 icon artwork.
public struct GenerationRequest: Sendable {
    public var prompt: String
    public var model: String
    /// How many candidates to generate in one call.
    public var count: Int
    /// Honoured by providers that support seeding; ignored by the rest.
    public var seed: UInt64?
    /// Ask for an alpha channel. Only valid for models with ``ImageModel/supportsTransparency``.
    public var transparentBackground: Bool

    public init(
        prompt: String,
        model: String,
        count: Int = 1,
        seed: UInt64? = nil,
        transparentBackground: Bool = false
    ) {
        self.prompt = prompt
        self.model = model
        self.count = count
        self.seed = seed
        self.transparentBackground = transparentBackground
    }
}

/// A request to change existing artwork according to an instruction.
public struct EditRequest: Sendable {
    /// The artwork to change, in any readable image format.
    public var image: Data
    /// What to change, in plain words.
    public var prompt: String
    public var model: String
    /// How many variations to produce in one call.
    public var count: Int
    /// Honoured by providers that support seeding; ignored by the rest.
    public var seed: UInt64?

    public init(image: Data, prompt: String, model: String, count: Int = 1, seed: UInt64? = nil) {
        self.image = image
        self.prompt = prompt
        self.model = model
        self.count = count
        self.seed = seed
    }
}

public struct GeneratedImage: Sendable {
    /// PNG-encoded image data, whatever format the provider returned.
    public let png: Data

    public init(png: Data) {
        self.png = png
    }

    /// Wraps existing artwork in any readable format, converting it to PNG if needed.
    public init(imageData: Data) throws {
        self.png = try ImageCodec.png(from: imageData)
    }

    /// The decoded image, for display.
    public func makeCGImage() throws -> CGImage {
        try ImageCodec.decode(png)
    }
}

/// A backend that turns a prompt into icon artwork, and may also edit existing artwork.
public protocol ImageProvider: Sendable {
    var name: String { get }
    /// The models that generate from text, best default first.
    var models: [ImageModel] { get }
    /// The models that edit an existing image, best default first. Empty if editing is not offered.
    var editModels: [ImageModel] { get }
    func generate(_ request: GenerationRequest) async throws -> [GeneratedImage]
    func edit(_ request: EditRequest) async throws -> [GeneratedImage]
}

extension ImageProvider {
    public var editModels: [ImageModel] { [] }

    public func edit(_ request: EditRequest) async throws -> [GeneratedImage] {
        throw ProviderError.unsupported("\(name) does not offer image editing here.")
    }
}

public enum ProviderError: Error, LocalizedError, Equatable {
    case http(status: Int, message: String)
    case malformedResponse(String)
    case unsupported(String)
    /// The backend could not be used or did not deliver; the text says why.
    case unavailable(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .http(let status, let message): "HTTP \(status): \(message)"
        case .malformedResponse(let detail): "Unexpected response from the provider: \(detail)"
        case .unsupported(let detail), .unavailable(let detail): detail
        case .timedOut: "The provider did not finish in time."
        }
    }
}
