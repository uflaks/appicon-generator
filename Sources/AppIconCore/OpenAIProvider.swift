import Foundation

/// OpenAI's GPT Image models, for generating and editing. These can return a real alpha
/// channel, which FLUX cannot. Seeds are not supported by the API and are ignored.
public struct OpenAIProvider: ImageProvider {
    public let name = "OpenAI"

    public let models = [
        ImageModel(
            id: "gpt-image-2.5-flare", name: "GPT Image 2.5 Flare", supportsTransparency: true,
            released: ReleaseDate(2026, 9), arenaScore: 1210, license: .openAI),
        ImageModel(
            id: "gpt-image-2.5-sunburst", name: "GPT Image 2.5 Sunburst", supportsTransparency: true,
            released: ReleaseDate(2026, 9), arenaScore: 1229, license: .openAI),
        ImageModel(
            id: "gpt-image-2", name: "GPT Image 2", supportsTransparency: true,
            released: ReleaseDate(2026, 4), arenaScore: 1192, license: .openAI),
    ]

    /// The same models edit as well as generate.
    public var editModels: [ImageModel] { models }

    private let client: APIClient
    private static let endpoint = URL(string: "https://api.openai.com/v1/images/generations")!
    private static let editEndpoint = URL(string: "https://api.openai.com/v1/images/edits")!

    public init(apiKey: String, transport: any HTTPTransport = URLSession.shared) {
        self.client = APIClient(transport: transport, bearer: apiKey)
    }

    public func generate(_ request: GenerationRequest) async throws -> [GeneratedImage] {
        let response: Response = try await client.post(
            Self.endpoint,
            body: Body(
                model: request.model,
                prompt: request.prompt,
                n: request.count,
                size: "1024x1024",
                background: request.transparentBackground ? "transparent" : "opaque",
                output_format: "png"
            )
        )
        return try images(in: response)
    }

    /// Edits through the multipart `images/edits` endpoint. No background is requested, so
    /// the model decides whether the result is opaque or transparent.
    public func edit(_ request: EditRequest) async throws -> [GeneratedImage] {
        var form = MultipartForm()
        form.field("model", request.model)
        form.field("prompt", request.prompt)
        form.field("n", String(request.count))
        form.field("size", "1024x1024")
        form.field("output_format", "png")
        form.file("image", filename: "artwork.png", type: "image/png", data: try ImageCodec.png(from: request.image))
        let response: Response = try await client.post(Self.editEndpoint, form: form)
        return try images(in: response)
    }

    private func images(in response: Response) throws -> [GeneratedImage] {
        guard !response.data.isEmpty else {
            throw ProviderError.malformedResponse("the response contained no images")
        }
        return try response.data.map { item in
            guard let data = Data(base64Encoded: item.b64_json) else {
                throw ProviderError.malformedResponse("image data was not valid base64")
            }
            return GeneratedImage(png: try ImageCodec.png(from: data))
        }
    }

    private struct Body: Encodable {
        let model: String
        let prompt: String
        let n: Int
        let size: String
        let background: String
        let output_format: String
    }

    private struct Response: Decodable {
        struct Item: Decodable { let b64_json: String }
        let data: [Item]
    }
}
