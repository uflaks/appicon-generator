import Foundation

/// Open image models through Hugging Face Inference Providers, routed to fal and billed
/// to the Hugging Face account that owns the token.
///
/// Follows the queue flow of the official `huggingface.js` fal provider: submit,
/// poll the status URL, fetch the result, then download each image URL.
public struct HuggingFaceProvider: ImageProvider {
    public let name = "Hugging Face"

    /// FLUX.2 is missing on purpose: on Hugging Face it only edits, it does not generate from text.
    public let models = [
        ImageModel(
            id: "fal-ai/krea-2/turbo", name: "Krea 2 Turbo", supportsTransparency: false,
            released: ReleaseDate(2026, 6), arenaScore: 1020, license: .krea2Community),
        ImageModel(
            id: "fal-ai/z-image/turbo", name: "Z-Image Turbo", supportsTransparency: false,
            released: ReleaseDate(2025, 11), arenaScore: 937, license: .apache2),
        ImageModel(
            id: "fal-ai/qwen-image-2512", name: "Qwen-Image 2512", supportsTransparency: false,
            released: ReleaseDate(2025, 12), license: .apache2),
        ImageModel(
            id: "ideogram/v4", name: "Ideogram 4", supportsTransparency: false,
            released: ReleaseDate(2026, 5), arenaScore: 1003, license: .ideogramNonCommercial),
        ImageModel(
            id: "fal-ai/flux/krea", name: "FLUX.1 Krea dev", supportsTransparency: false,
            released: ReleaseDate(2025, 7), arenaScore: 870, isOlder: true, license: .flux1DevNonCommercial),
        ImageModel(
            id: "fal-ai/flux/schnell", name: "FLUX.1 schnell", supportsTransparency: false,
            released: ReleaseDate(2024, 8), arenaScore: 743, isOlder: true, license: .apache2),
        ImageModel(
            id: "fal-ai/flux/dev", name: "FLUX.1 dev", supportsTransparency: false,
            released: ReleaseDate(2024, 8), arenaScore: 816, isOlder: true, license: .flux1DevNonCommercial),
        ImageModel(
            id: "fal-ai/z-image/base", name: "Z-Image (slow)", supportsTransparency: false,
            released: ReleaseDate(2026, 1), arenaScore: 894, license: .apache2),
    ]

    public let editModels = [
        ImageModel(
            id: "fal-ai/flux-2/klein/9b/edit", name: "FLUX.2 klein 9B", supportsTransparency: false,
            released: ReleaseDate(2026, 1), license: .fluxNonCommercial),
        ImageModel(
            id: "fal-ai/flux-2/klein/4b/distilled/edit", name: "FLUX.2 klein 4B", supportsTransparency: false,
            released: ReleaseDate(2026, 1), license: .apache2),
        ImageModel(
            id: "fal-ai/flux-kontext/dev", name: "FLUX.1 Kontext dev", supportsTransparency: false,
            released: ReleaseDate(2025, 5), isOlder: true, license: .flux1DevNonCommercial),
    ]

    private let client: APIClient
    private let downloads: APIClient
    private let pollInterval: Duration
    private let timeout: Duration

    private static let base = "https://router.huggingface.co/fal-ai"
    private static let query = "?_subdomain=queue"

    /// - Parameter token: a Hugging Face token with the Inference Providers permission.
    public init(
        token: String,
        transport: any HTTPTransport = URLSession.shared,
        pollInterval: Duration = .milliseconds(500),
        timeout: Duration = .seconds(180)
    ) {
        self.client = APIClient(transport: transport, bearer: token)
        // Image URLs point at the provider's CDN, which must not receive the token.
        self.downloads = APIClient(transport: transport, bearer: nil)
        self.pollInterval = pollInterval
        self.timeout = timeout
    }

    public func generate(_ request: GenerationRequest) async throws -> [GeneratedImage] {
        guard !request.transparentBackground else {
            throw ProviderError.unsupported("These models cannot produce a transparent background.")
        }
        return try await run(
            model: request.model,
            body: Generation(
                prompt: request.prompt,
                image_size: .init(width: 1024, height: 1024),
                num_images: request.count,
                output_format: "png",
                seed: request.seed
            ))
    }

    public func edit(_ request: EditRequest) async throws -> [GeneratedImage] {
        let source = "data:image/png;base64," + (try ImageCodec.png(from: request.image)).base64EncodedString()
        return try await run(
            model: request.model,
            body: Edit(
                prompt: request.prompt,
                image_url: source,
                image_urls: [source],
                num_images: request.count,
                output_format: "png",
                seed: request.seed
            ))
    }

    /// Submits a job to the queue, waits for it and downloads the resulting images.
    private func run(model: String, body: some Encodable) async throws -> [GeneratedImage] {
        let queued: Queued = try await client.post(try Self.url("/\(model)"), body: body)
        // The provider may answer under a different model path than the one requested.
        let path = queued.response_url.path

        let deadline = ContinuousClock.now + timeout
        var status = queued.status
        while status != "COMPLETED" {
            guard ContinuousClock.now < deadline else { throw ProviderError.timedOut }
            try await Task.sleep(for: pollInterval)
            let poll: Status = try await client.get(try Self.url("\(path)/status"))
            status = poll.status
        }

        let result: Result = try await client.get(try Self.url(path))
        guard !result.images.isEmpty else {
            throw ProviderError.malformedResponse("the result contained no images")
        }

        var images: [GeneratedImage] = []
        for image in result.images {
            let data = try await downloads.data(for: URLRequest(url: image.url))
            images.append(GeneratedImage(png: try ImageCodec.png(from: data)))
        }
        return images
    }

    private static func url(_ path: String) throws -> URL {
        guard let url = URL(string: base + path + query) else {
            throw ProviderError.malformedResponse("invalid path \(path)")
        }
        return url
    }

    private struct Generation: Encodable {
        struct Size: Encodable {
            let width: Int
            let height: Int
        }
        let prompt: String
        let image_size: Size
        let num_images: Int
        let output_format: String
        let seed: UInt64?
    }

    /// The source image travels inline as a data URL. Kontext reads `image_url` and the
    /// FLUX.2 endpoints read `image_urls`, so both are sent, as the official client does.
    /// No size is sent: the result keeps the source image's dimensions.
    private struct Edit: Encodable {
        let prompt: String
        let image_url: String
        let image_urls: [String]
        let num_images: Int
        let output_format: String
        let seed: UInt64?
    }

    private struct Queued: Decodable {
        let status: String?
        let response_url: URL
    }

    private struct Status: Decodable {
        let status: String
    }

    private struct Result: Decodable {
        struct Image: Decodable { let url: URL }
        let images: [Image]
    }
}
