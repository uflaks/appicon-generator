import Foundation
import Testing

@testable import AppIconCore

@Suite struct HuggingFaceProviderTests {
    /// Scripts the fal queue: submit, one "in progress" poll, completion, result, image download.
    private func queueTransport(polls: Int = 1) -> StubTransport {
        let remaining = Counter(polls)
        return StubTransport { request in
            let url = request.url!.absoluteString
            if request.httpMethod == "POST" {
                return (200, json([
                    "status": "IN_QUEUE",
                    "response_url": "https://queue.fal.run/fal-ai/flux/requests/abc",
                ]))
            }
            if url.contains("/status") {
                return (200, json(["status": remaining.take() ? "IN_PROGRESS" : "COMPLETED"]))
            }
            if url.hasPrefix("https://router.huggingface.co") {
                return (200, json(["images": [["url": "https://cdn.example/a.jpg"], ["url": "https://cdn.example/b.jpg"]]]))
            }
            return (200, testImage(type: .jpeg))
        }
    }

    @Test func runsTheQueueFlowAndReturnsPNGs() async throws {
        let transport = queueTransport()
        let provider = HuggingFaceProvider(token: "hf_test", transport: transport, pollInterval: .zero)

        let images = try await provider.generate(
            GenerationRequest(prompt: "a sun", model: "fal-ai/flux/krea", count: 2, seed: 7))

        #expect(images.count == 2)
        #expect(images.allSatisfy { $0.png.starts(with: [0x89, 0x50, 0x4E, 0x47]) })
        #expect(transport.requests.map { $0.url!.absoluteString } == [
            "https://router.huggingface.co/fal-ai/fal-ai/flux/krea?_subdomain=queue",
            "https://router.huggingface.co/fal-ai/fal-ai/flux/requests/abc/status?_subdomain=queue",
            "https://router.huggingface.co/fal-ai/fal-ai/flux/requests/abc/status?_subdomain=queue",
            "https://router.huggingface.co/fal-ai/fal-ai/flux/requests/abc?_subdomain=queue",
            "https://cdn.example/a.jpg",
            "https://cdn.example/b.jpg",
        ])

        let submitted = body(of: transport.requests[0])
        #expect(submitted["prompt"] as? String == "a sun")
        #expect(submitted["num_images"] as? Int == 2)
        #expect(submitted["seed"] as? Int == 7)
        #expect(submitted["output_format"] as? String == "png")
        #expect(submitted["image_size"] as? [String: Int] == ["width": 1024, "height": 1024])
    }

    @Test func sendsTheTokenToHuggingFaceButNotToTheImageHost() async throws {
        let transport = queueTransport()
        let provider = HuggingFaceProvider(token: "hf_test", transport: transport, pollInterval: .zero)
        _ = try await provider.generate(GenerationRequest(prompt: "a sun", model: "fal-ai/flux/krea"))

        for request in transport.requests {
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            if request.url!.host == "router.huggingface.co" {
                #expect(authorization == "Bearer hf_test")
            } else {
                #expect(authorization == nil)
            }
        }
    }

    @Test func editSendsTheArtworkInlineAndReturnsPNGs() async throws {
        let transport = queueTransport()
        let provider = HuggingFaceProvider(token: "hf_test", transport: transport, pollInterval: .zero)
        let artwork = testImage()

        let images = try await provider.edit(EditRequest(
            image: artwork, prompt: "make the sky orange", model: "fal-ai/flux-2/klein/9b/edit", count: 2, seed: 3))

        #expect(images.count == 2)
        #expect(images.allSatisfy { $0.png.starts(with: [0x89, 0x50, 0x4E, 0x47]) })
        #expect(transport.requests[0].url?.absoluteString
            == "https://router.huggingface.co/fal-ai/fal-ai/flux-2/klein/9b/edit?_subdomain=queue")

        let submitted = body(of: transport.requests[0])
        let dataURL = "data:image/png;base64," + artwork.base64EncodedString()
        #expect(submitted["prompt"] as? String == "make the sky orange")
        // Kontext reads `image_url`, the FLUX.2 endpoints read `image_urls`.
        #expect(submitted["image_url"] as? String == dataURL)
        #expect(submitted["image_urls"] as? [String] == [dataURL])
        #expect(submitted["num_images"] as? Int == 2)
        #expect(submitted["seed"] as? Int == 3)
        #expect(submitted["output_format"] as? String == "png")
        #expect(submitted["image_size"] == nil)
    }

    @Test func editConvertsOtherFormatsToPNGBeforeSending() async throws {
        let transport = queueTransport()
        let provider = HuggingFaceProvider(token: "hf_test", transport: transport, pollInterval: .zero)

        _ = try await provider.edit(EditRequest(
            image: testImage(type: .jpeg), prompt: "make the sky orange", model: "fal-ai/flux-kontext/dev"))

        let sent = try #require(body(of: transport.requests[0])["image_url"] as? String)
        let payload = try #require(Data(base64Encoded: String(sent.dropFirst("data:image/png;base64,".count))))
        #expect(payload.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func editRejectsUnreadableArtworkWithoutCallingTheNetwork() async {
        let transport = queueTransport()
        let provider = HuggingFaceProvider(token: "hf_test", transport: transport)

        await #expect(throws: ImageError.unreadable) {
            try await provider.edit(EditRequest(
                image: Data("not an image".utf8), prompt: "x", model: "fal-ai/flux-kontext/dev"))
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func offersTheKleinAndKontextEditingModels() {
        let ids = HuggingFaceProvider(token: "").editModels.map(\.id)
        #expect(ids == [
            "fal-ai/flux-2/klein/9b/edit",
            "fal-ai/flux-2/klein/4b/distilled/edit",
            "fal-ai/flux-kontext/dev",
        ])
    }

    @Test func reportsTheProvidersErrorMessage() async {
        let transport = StubTransport { _ in (402, json(["error": "Purchase pre-paid credits"])) }
        let provider = HuggingFaceProvider(token: "hf_test", transport: transport)

        await #expect(throws: ProviderError.http(status: 402, message: "Purchase pre-paid credits")) {
            try await provider.generate(GenerationRequest(prompt: "a sun", model: "fal-ai/flux/krea"))
        }
    }

    @Test func givesUpWhenTheQueueNeverCompletes() async {
        let transport = queueTransport(polls: .max)
        let provider = HuggingFaceProvider(
            token: "hf_test", transport: transport, pollInterval: .milliseconds(1), timeout: .milliseconds(20))

        await #expect(throws: ProviderError.timedOut) {
            try await provider.generate(GenerationRequest(prompt: "a sun", model: "fal-ai/flux/krea"))
        }
    }

    @Test func refusesTransparencyWithoutCallingTheNetwork() async {
        let transport = queueTransport()
        let provider = HuggingFaceProvider(token: "hf_test", transport: transport)

        await #expect(throws: ProviderError.self) {
            try await provider.generate(
                GenerationRequest(prompt: "a sun", model: "fal-ai/flux/krea", transparentBackground: true))
        }
        #expect(transport.requests.isEmpty)
    }
}

@Suite struct ModelFactsTests {
    @Test func theFluxOneModelsAreMarkedAsOlder() throws {
        let models = HuggingFaceProvider(token: "").models
        let older = models.filter(\.isOlder).map(\.name)
        #expect(older == ["FLUX.1 Krea dev", "FLUX.1 schnell", "FLUX.1 dev"])
        // Everything marked older really is older, and scores lower, than the default.
        let newest = try #require(models[0].released)
        let best = try #require(models[0].arenaScore)
        for model in models where model.isOlder {
            #expect(try #require(model.released) < newest)
            #expect(try #require(model.arenaScore) < best)
        }
    }

    @Test func theTopRatedModelIsTheOneWithTheHighestPublicScore() {
        #expect(HuggingFaceProvider(token: "").models.topRated?.name == "Krea 2 Turbo")
        #expect(OpenAIProvider(apiKey: "").models.topRated?.name == "GPT Image 2.5 Sunburst")
        // Editing models have no public scores, so the provider's default stands.
        #expect(HuggingFaceProvider(token: "").editModels.topRated?.name == "FLUX.2 klein 9B")
        #expect([ImageModel]().topRated == nil)
    }

    @Test func everyModelSaysWhatItsLicenceAllows() {
        let providers: [any ImageProvider] = [
            HuggingFaceProvider(token: ""), OpenAIProvider(apiKey: ""),
            CodexProvider(executable: URL(fileURLWithPath: "/usr/bin/false")),
        ]
        let models = providers.flatMap { $0.models + $0.editModels }
        #expect(models.allSatisfy { $0.license != nil })

        func use(_ id: String) -> ModelLicense.CommercialUse? { models.first { $0.id == id }?.license?.commercialUse }
        #expect(use("fal-ai/krea-2/turbo") == .conditional)
        #expect(use("fal-ai/z-image/turbo") == .unrestricted)
        #expect(use("fal-ai/qwen-image-2512") == .unrestricted)
        #expect(use("ideogram/v4") == .notAllowed)
        #expect(use("fal-ai/flux/dev") == .imagesOnly)
        #expect(use("fal-ai/flux/schnell") == .unrestricted)
        #expect(use("fal-ai/flux-2/klein/9b/edit") == .imagesOnly)
        #expect(use("fal-ai/flux-2/klein/4b/distilled/edit") == .unrestricted)
        #expect(use("gpt-image-2.5-flare") == .providerTerms)
        #expect(use("codex") == .providerTerms)
        #expect(ModelLicense.krea2Community.summary.contains("1 million US dollars"))
    }

    @Test func releaseDatesReadAsMonthAndYearAndSortByTime() {
        #expect(ReleaseDate(2026, 6).label == "Jun 2026")
        #expect(ReleaseDate(2024, 8) < ReleaseDate(2025, 7))
        #expect(ReleaseDate(2025, 11) < ReleaseDate(2025, 12))
    }
}

@Suite struct OpenAIProviderTests {
    @Test func requestsATransparentPNGAndDecodesIt() async throws {
        let transport = StubTransport { _ in
            (200, json(["data": [["b64_json": testImage().base64EncodedString()]]]))
        }
        let provider = OpenAIProvider(apiKey: "sk-test", transport: transport)

        let images = try await provider.generate(GenerationRequest(
            prompt: "a sun", model: "gpt-image-2.5-flare", count: 1, transparentBackground: true))

        #expect(images.count == 1)
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/images/generations")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let submitted = body(of: request)
        #expect(submitted["model"] as? String == "gpt-image-2.5-flare")
        #expect(submitted["background"] as? String == "transparent")
        #expect(submitted["output_format"] as? String == "png")
        #expect(submitted["size"] as? String == "1024x1024")
        #expect(submitted["n"] as? Int == 1)
    }

    @Test func asksForAnOpaqueBackgroundByDefault() async throws {
        let transport = StubTransport { _ in
            (200, json(["data": [["b64_json": testImage().base64EncodedString()]]]))
        }
        let provider = OpenAIProvider(apiKey: "sk-test", transport: transport)
        _ = try await provider.generate(GenerationRequest(prompt: "a sun", model: "gpt-image-2"))

        #expect(body(of: transport.requests[0])["background"] as? String == "opaque")
    }

    @Test func editUploadsTheArtworkAsAMultipartForm() async throws {
        let transport = StubTransport { _ in
            (200, json(["data": [["b64_json": testImage().base64EncodedString()]]]))
        }
        let provider = OpenAIProvider(apiKey: "sk-test", transport: transport)
        let artwork = testImage()

        let images = try await provider.edit(EditRequest(
            image: artwork, prompt: "make the sky orange", model: "gpt-image-2.5-flare", count: 2))

        #expect(images.count == 1)
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/images/edits")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")

        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        let sent = try #require(request.httpBody)
        let text = String(decoding: sent, as: UTF8.self)
        for (name, value) in [
            ("model", "gpt-image-2.5-flare"), ("prompt", "make the sky orange"), ("n", "2"),
            ("size", "1024x1024"), ("output_format", "png"),
        ] {
            #expect(text.contains("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"))
        }
        let fileHeader = Data(
            "Content-Disposition: form-data; name=\"image\"; filename=\"artwork.png\"\r\nContent-Type: image/png\r\n\r\n"
                .utf8)
        #expect(sent.range(of: fileHeader + artwork) != nil)
        #expect(sent.suffix(boundary.utf8.count + 6) == Data("--\(boundary)--\r\n".utf8))
    }

    @Test func offersItsModelsForEditingToo() {
        let provider = OpenAIProvider(apiKey: "")
        #expect(provider.editModels == provider.models)
    }

    @Test func aProviderWithoutEditingSaysSo() async {
        struct GenerateOnly: ImageProvider {
            let name = "Generate Only"
            let models: [ImageModel] = []
            func generate(_ request: GenerationRequest) async throws -> [GeneratedImage] { [] }
        }
        let provider = GenerateOnly()

        #expect(provider.editModels.isEmpty)
        await #expect(throws: ProviderError.unsupported("Generate Only does not offer image editing here.")) {
            try await provider.edit(EditRequest(image: testImage(), prompt: "x", model: "any"))
        }
    }

    @Test func reportsNestedErrorMessages() async {
        let transport = StubTransport { _ in (401, json(["error": ["message": "Incorrect API key"]])) }
        let provider = OpenAIProvider(apiKey: "sk-test", transport: transport)

        await #expect(throws: ProviderError.http(status: 401, message: "Incorrect API key")) {
            try await provider.generate(GenerationRequest(prompt: "a sun", model: "gpt-image-2"))
        }
    }
}

/// Counts down how many "in progress" answers a stub still owes.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int

    init(_ value: Int) { remaining = value }

    /// True while there are answers left to give.
    func take() -> Bool {
        lock.withLock {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
    }
}
