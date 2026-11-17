import AppIconCore
import CoreGraphics
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// One piece of generated, refined or imported artwork.
public struct Candidate: Identifiable, Sendable {
    public let id: UUID
    public let png: Data
    public let image: CGImage
    /// The subject it was generated from, or the instruction it was refined with.
    public let title: String
    /// The full text that was sent to the model. Empty for imported artwork.
    public let prompt: String
    public let modelName: String
    /// The ``ModelChoice/id`` of the model that generated it, if one did.
    public let modelID: String?
    /// The candidate this one was refined from, if any.
    public let parentID: UUID?
    /// How long the request that produced it took, shared by every image of that request.
    public let duration: Duration?
    /// The press of Generate it came from; candidates of one comparison share it.
    public let runID: UUID?
    public let createdAt: Date
    /// Marked by the user as a keeper. In a comparison this is what counts as a win.
    public var isFavourite: Bool

    init(
        _ generated: GeneratedImage, title: String, prompt: String, modelName: String,
        modelID: String? = nil, parentID: UUID? = nil, duration: Duration? = nil, runID: UUID? = nil
    ) throws {
        self.id = UUID()
        self.png = generated.png
        self.image = try generated.makeCGImage()
        self.title = title
        self.prompt = prompt
        self.modelName = modelName
        self.modelID = modelID
        self.parentID = parentID
        self.duration = duration
        self.runID = runID
        self.createdAt = Date()
        self.isFavourite = false
    }

    /// The model and, when known, how long it took: "Krea 2 Turbo · 3.8s".
    public var caption: String {
        guard let duration else { return modelName }
        let time = duration.formatted(.units(allowed: [.seconds], width: .narrow, fractionalPart: .show(length: 1)))
        return "\(modelName) · \(time)"
    }
}

extension Candidate {
    /// What is written to disk about a candidate; its image is stored beside it as a PNG file.
    struct Record: Codable {
        let id: UUID
        let title: String
        let prompt: String
        let modelName: String
        let modelID: String?
        let parentID: UUID?
        let seconds: Double?
        let runID: UUID?
        let createdAt: Date
        let isFavourite: Bool
    }

    var record: Record {
        Record(
            id: id, title: title, prompt: prompt, modelName: modelName, modelID: modelID, parentID: parentID,
            seconds: duration.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 },
            runID: runID, createdAt: createdAt, isFavourite: isFavourite)
    }

    init(_ record: Record, png: Data) throws {
        self.id = record.id
        self.png = png
        self.image = try GeneratedImage(png: png).makeCGImage()
        self.title = record.title
        self.prompt = record.prompt
        self.modelName = record.modelName
        self.modelID = record.modelID
        self.parentID = record.parentID
        self.duration = record.seconds.map { .seconds($0) }
        self.runID = record.runID
        self.createdAt = record.createdAt
        self.isFavourite = record.isFavourite
    }
}

extension Candidate: Transferable {
    /// Lets a candidate be dragged out of the app as a PNG file.
    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.png }
            .suggestedFileName("Icon.png")
    }
}

/// A model together with the provider that serves it.
public struct ModelChoice: Hashable, Identifiable, Sendable {
    public let provider: ProviderKind
    public let model: ImageModel

    public var id: String { "\(provider.rawValue)/\(model.id)" }

    /// The name, with a marker on models that newer ones have overtaken.
    public var label: String {
        model.isOlder ? "\(model.name) (older)" : model.name
    }

    /// Every generation model, grouped by provider in display order.
    public static let all: [ModelChoice] =
        HuggingFaceProvider(token: "").models.map { ModelChoice(provider: .huggingFace, model: $0) }
        + OpenAIProvider(apiKey: "").models.map { ModelChoice(provider: .openAI, model: $0) }
        + codex.models.map { ModelChoice(provider: .codex, model: $0) }

    /// The models ticked for comparison until the user chooses otherwise: the quick open ones.
    static let comparedByDefault: [ModelChoice] = all.filter {
        ["fal-ai/krea-2/turbo", "fal-ai/z-image/turbo", "fal-ai/qwen-image-2512", "ideogram/v4"].contains($0.model.id)
    }

    /// Every editing model, grouped by provider in display order.
    public static let allEditing: [ModelChoice] =
        HuggingFaceProvider(token: "").editModels.map { ModelChoice(provider: .huggingFace, model: $0) }
        + OpenAIProvider(apiKey: "").editModels.map { ModelChoice(provider: .openAI, model: $0) }
        + codex.editModels.map { ModelChoice(provider: .codex, model: $0) }

    /// Only used to read the model lists, so the path does not matter.
    private static let codex = CodexProvider(executable: URL(fileURLWithPath: "/usr/bin/false"))
}
