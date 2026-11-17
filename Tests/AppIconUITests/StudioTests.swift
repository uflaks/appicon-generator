import AppIconCore
import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import AppIconUI

/// A provider that records what it was asked and answers with solid-colour images.
private final class StubProvider: ImageProvider, @unchecked Sendable {
    let name = "Stub"
    let models: [ImageModel] = []
    private let lock = NSLock()
    private var recordedGenerations: [GenerationRequest] = []
    private var recordedEdits: [EditRequest] = []
    private let failure: (any Error)?
    private let failingModels: Set<String>

    /// - Parameters:
    ///   - failure: thrown by every request, or only by those for `failingModels` when that is not empty.
    init(failure: (any Error)? = nil, failingModels: Set<String> = []) {
        self.failure = failure
        self.failingModels = failingModels
    }

    private func failure(for model: String) -> (any Error)? {
        failingModels.isEmpty || failingModels.contains(model) ? failure : nil
    }

    var generations: [GenerationRequest] { lock.withLock { recordedGenerations } }
    var edits: [EditRequest] { lock.withLock { recordedEdits } }

    func generate(_ request: GenerationRequest) async throws -> [GeneratedImage] {
        lock.withLock { recordedGenerations.append(request) }
        if let failure = failure(for: request.model) { throw failure }
        return (0..<request.count).map { _ in GeneratedImage(png: testPNG()) }
    }

    func edit(_ request: EditRequest) async throws -> [GeneratedImage] {
        lock.withLock { recordedEdits.append(request) }
        if let failure = failure(for: request.model) { throw failure }
        return (0..<request.count).map { _ in GeneratedImage(png: testPNG()) }
    }
}

private func testPNG() -> Data {
    let context = CGContext(
        data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(srgbRed: 0, green: 0.5, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// Remembers which providers the studio asked for.
private final class Requests: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ProviderKind] = []
    var kinds: [ProviderKind] { lock.withLock { recorded } }
    func record(_ kind: ProviderKind) { lock.withLock { recorded.append(kind) } }
}

@MainActor @Suite struct StudioTests {
    private func studio(_ provider: StubProvider, requests: Requests = Requests()) -> Studio {
        Studio { kind in
            requests.record(kind)
            return provider
        }
    }

    @Test func generatingAddsCandidatesAndSelectsTheFirst() async {
        let provider = StubProvider()
        let studio = studio(provider)
        studio.subject = "  a paper plane "
        studio.style = .flat
        studio.count = 3

        await studio.generate()

        #expect(studio.candidates.count == 3)
        #expect(studio.selectionID == studio.candidates.first?.id)
        #expect(studio.candidates.allSatisfy { $0.title == "a paper plane" && $0.parentID == nil })
        #expect(studio.activity == .idle)
        #expect(studio.problem == nil)

        let request = provider.generations[0]
        #expect(request.model == "fal-ai/krea-2/turbo")
        #expect(request.count == 3)
        #expect(studio.candidates.allSatisfy { $0.duration != nil && $0.caption.hasPrefix("Krea 2 Turbo · ") })
        #expect(request.prompt == studio.prompt)
        #expect(request.prompt.contains("Flat vector illustration"))
        #expect(!request.transparentBackground)
    }

    @Test func doesNothingWithoutASubject() async {
        let provider = StubProvider()
        let studio = studio(provider)
        studio.subject = "   "

        #expect(!studio.canGenerate)
        await studio.generate()
        #expect(provider.generations.isEmpty)
    }

    @Test func usesTheProviderOfTheChosenModel() async throws {
        let requests = Requests()
        let studio = studio(StubProvider(), requests: requests)
        studio.subject = "a fox"
        studio.modelChoice = try #require(studio.modelChoices.first { $0.provider == .openAI })

        await studio.generate()

        #expect(requests.kinds == [.openAI])
    }

    @Test func transparencyIsOnlyKeptForModelsThatSupportIt() async throws {
        let provider = StubProvider()
        let studio = studio(provider)
        let openAI = try #require(studio.modelChoices.first { $0.provider == .openAI })
        let flux = try #require(studio.modelChoices.first { $0.provider == .huggingFace })
        studio.subject = "a fox"

        studio.modelChoice = openAI
        studio.backgroundMode = .transparent
        await studio.generate()
        #expect(provider.generations[0].transparentBackground)
        #expect(provider.generations[0].prompt.contains("transparent background"))

        studio.modelChoice = flux
        #expect(studio.backgroundMode == .automatic)
    }

    @Test func aColourBackgroundWithoutAColourFallsBackToAutomatic() {
        let studio = studio(StubProvider())
        studio.subject = "a fox"
        studio.backgroundMode = .color

        studio.backgroundColor = "  "
        #expect(studio.prompt.contains("complementary colour"))

        studio.backgroundColor = "deep green"
        #expect(studio.prompt.contains("Deep green background"))
    }

    @Test func refiningCanUseAnOpenAIModel() async throws {
        let provider = StubProvider()
        let requests = Requests()
        let studio = studio(provider, requests: requests)
        studio.importArtwork(from: [])
        studio.subject = "a fox"
        await studio.generate()

        studio.editModel = try #require(studio.editModels.first { $0.provider == .openAI })
        studio.instruction = "make it blue"
        await studio.refine()

        #expect(requests.kinds == [.huggingFace, .openAI])
        #expect(provider.edits[0].model == "gpt-image-2.5-flare")
        #expect(studio.candidates[0].modelName == "GPT Image 2.5 Flare")
    }

    @Test func comparingRunsTheSamePromptOnEveryTickedModel() async throws {
        let provider = StubProvider()
        let requests = Requests()
        let studio = studio(provider, requests: requests)
        let openAI = try #require(studio.modelChoices.first { $0.provider == .openAI })
        studio.subject = "a fox"
        studio.count = 2
        studio.isComparing = true
        studio.comparedModels = ["huggingFace/fal-ai/krea-2/turbo", "huggingFace/ideogram/v4", openAI.id]

        #expect(studio.activeModels.map(\.model.name) == ["Krea 2 Turbo", "Ideogram 4", openAI.model.name])
        await studio.generate()

        #expect(Set(provider.generations.map(\.model)) == ["fal-ai/krea-2/turbo", "ideogram/v4", openAI.model.id])
        #expect(Set(provider.generations.map(\.prompt)) == [studio.prompt])
        #expect(provider.generations.allSatisfy { $0.count == 2 })
        #expect(Set(requests.kinds) == [.huggingFace, .openAI])
        // Two candidates per model, each labelled with the model that made it.
        #expect(studio.candidates.count == 6)
        #expect(Dictionary(grouping: studio.candidates, by: \.modelName).mapValues(\.count)
            == ["Krea 2 Turbo": 2, "Ideogram 4": 2, openAI.model.name: 2])
        #expect(studio.selection != nil)
        #expect(studio.activity == .idle)
        #expect(studio.problem == nil)
    }

    @Test func comparingKeepsWhatWorkedAndNamesWhatFailed() async {
        let provider = StubProvider(
            failure: ProviderError.http(status: 500, message: "Overloaded"),
            failingModels: ["ideogram/v4", "fal-ai/z-image/turbo"])
        let studio = studio(provider)
        studio.subject = "a fox"
        studio.count = 1
        studio.isComparing = true
        studio.comparedModels = [
            "huggingFace/fal-ai/krea-2/turbo", "huggingFace/fal-ai/z-image/turbo", "huggingFace/ideogram/v4",
        ]

        await studio.generate()

        #expect(studio.candidates.map(\.modelName) == ["Krea 2 Turbo"])
        #expect(studio.problem?.title == "2 of 3 models could not generate")
        #expect(studio.problem?.message == "Z-Image Turbo: HTTP 500: Overloaded\nIdeogram 4: HTTP 500: Overloaded")
    }

    @Test func comparingNeedsAtLeastOneModel() {
        let studio = studio(StubProvider())
        studio.subject = "a fox"
        studio.isComparing = true
        #expect(studio.canGenerate)
        #expect(studio.activeModels.map(\.model.name) == ["Krea 2 Turbo", "Z-Image Turbo", "Qwen-Image 2512", "Ideogram 4"])

        studio.comparedModels = []
        #expect(!studio.canGenerate)
    }

    @Test func transparencyWhenComparingNeedsEveryModelToSupportIt() throws {
        let studio = studio(StubProvider())
        let openAI = studio.modelChoices.filter { $0.provider == .openAI }
        studio.isComparing = true
        studio.comparedModels = Set(openAI.map(\.id))
        #expect(studio.supportsTransparency)
        studio.backgroundMode = .transparent

        studio.comparedModels.insert("huggingFace/fal-ai/krea-2/turbo")

        #expect(!studio.supportsTransparency)
        #expect(studio.backgroundMode == .automatic)
    }

    // MARK: Ranking

    private func comparing(_ models: [String], in studio: Studio) async {
        studio.subject = "a fox"
        studio.count = 1
        studio.isComparing = true
        studio.comparedModels = Set(models)
        await studio.generate()
    }

    private let krea = "huggingFace/fal-ai/krea-2/turbo"
    private let zImage = "huggingFace/fal-ai/z-image/turbo"
    private let ideogram = "huggingFace/ideogram/v4"

    private func standing(_ id: String, in studio: Studio) -> ModelStanding? {
        studio.standings.first { $0.id == id }
    }

    @Test func aFavouriteInAComparisonIsAWinForItsModel() async throws {
        let studio = studio(StubProvider())
        await comparing([krea, zImage, ideogram], in: studio)
        #expect(studio.contests.count == 1)
        #expect(Set(studio.contests[0].models) == [krea, zImage, ideogram])
        // Nothing is counted until a pick has been made.
        #expect(standing(krea, in: studio)?.contests == 0)

        let pick = try #require(studio.candidates.first { $0.modelID == zImage })
        studio.toggleFavourite(pick)

        #expect(studio.candidates.first { $0.id == pick.id }?.isFavourite == true)
        #expect(standing(zImage, in: studio).map { [$0.wins, $0.contests] } == [1, 1])
        #expect(standing(krea, in: studio).map { [$0.wins, $0.contests] } == [0, 1])
        // The winner now ranks above Krea, which has the higher public score but lost here.
        let order = studio.standings.map(\.id)
        #expect(try #require(order.firstIndex(of: zImage)) < #require(order.firstIndex(of: krea)))
        // One lost comparison does not drop a current model below the older ones nobody compared.
        #expect(try #require(order.firstIndex(of: krea)) < #require(order.firstIndex(of: "huggingFace/fal-ai/flux/dev")))
        // And one comparison is not enough to overtake the top of the public ranking.
        #expect(studio.standings.first?.choice.model.name == "GPT Image 2.5 Sunburst")
        // Models that did not take part are untouched.
        #expect(standing("huggingFace/fal-ai/flux/dev", in: studio)?.contests == 0)

        studio.toggleFavourite(pick)
        #expect(standing(zImage, in: studio)?.contests == 0)
        #expect(studio.contests[0].picks.isEmpty)
    }

    @Test func withoutPicksTheRankingFollowsPublicScoresAndPutsOlderModelsBelowNewerOnes() {
        let studio = studio(StubProvider())
        let names = studio.standings.map(\.choice.model.name)

        #expect(names.first == "GPT Image 2.5 Sunburst")
        let krea2 = try! #require(names.firstIndex(of: "Krea 2 Turbo"))
        for older in ["FLUX.1 Krea dev", "FLUX.1 dev", "FLUX.1 schnell"] {
            #expect(krea2 < (names.firstIndex(of: older) ?? -1))
        }
        // A model without a public score is not treated as the worst: it stays above the older ones.
        let qwen = try! #require(names.firstIndex(of: "Qwen-Image 2512"))
        #expect(qwen < (names.firstIndex(of: "FLUX.1 Krea dev") ?? -1))
        #expect(Array(names.suffix(3)) == ["FLUX.1 Krea dev", "FLUX.1 dev", "FLUX.1 schnell"])
        #expect(studio.modelChoices.first { $0.model.name == "FLUX.1 dev" }?.label == "FLUX.1 dev (older)")
    }

    @Test func aSingleModelRunIsNotAComparison() async throws {
        let studio = studio(StubProvider())
        studio.subject = "a fox"
        await studio.generate()

        studio.toggleFavourite(try #require(studio.selection))

        #expect(studio.contests.isEmpty)
        #expect(studio.selection?.isFavourite == true)
        #expect(studio.standings.allSatisfy { $0.contests == 0 })
    }

    @Test func aComparisonWhereOnlyOneModelDeliveredIsNotCounted() async throws {
        let provider = StubProvider(failure: ProviderError.timedOut, failingModels: ["ideogram/v4"])
        let studio = studio(provider)
        await comparing([krea, ideogram], in: studio)

        studio.toggleFavourite(try #require(studio.candidates.first))

        #expect(studio.contests.isEmpty)
        #expect(studio.standings.allSatisfy { $0.contests == 0 })
    }

    @Test func exportingCountsAsAPick() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "studio-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let studio = studio(StubProvider())
        await comparing([krea, zImage], in: studio)
        studio.selectionID = try #require(studio.candidates.first { $0.modelID == krea }).id

        studio.export(to: directory)

        #expect(studio.selection?.isFavourite == true)
        #expect(standing(krea, in: studio).map { [$0.wins, $0.contests] } == [1, 1])
    }

    @Test func aLongGoodRecordOutranksOneLuckyWin() {
        let choices = ModelChoice.all.filter { [krea, zImage].contains($0.id) }
        var contests: [Contest] = []
        // Krea: 7 wins of 10. Z-Image: 1 win of 1, in a comparison against a third model.
        for index in 0..<10 {
            contests.append(Contest(
                id: UUID(), date: Date(), models: [krea, ideogram], picks: index < 7 ? [krea: 1] : [ideogram: 1]))
        }
        contests.append(Contest(id: UUID(), date: Date(), models: [zImage, ideogram], picks: [zImage: 2]))

        let ranking = ModelStanding.ranking(of: choices, from: contests)

        #expect(ranking.map(\.id) == [krea, zImage])
        #expect(ranking.map(\.wins) == [7, 1])
    }

    @Test func aCandidateKnowsTheLicenceOfTheModelThatMadeIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "studio-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let studio = studio(StubProvider())
        await comparing([krea, ideogram], in: studio)
        let fromKrea = try #require(studio.candidates.first { $0.modelID == krea })
        let fromIdeogram = try #require(studio.candidates.first { $0.modelID == ideogram })

        #expect(studio.license(for: fromKrea) == .krea2Community)
        #expect(studio.license(for: fromIdeogram)?.commercialUse == .notAllowed)

        // A refinement carries the licence of the editing model, not of its source.
        studio.selectionID = fromKrea.id
        studio.instruction = "make it blue"
        await studio.refine()
        #expect(studio.license(for: try #require(studio.selection)) == .fluxNonCommercial)

        // Imported artwork has no model, so no licence is claimed for it.
        let file = directory.appending(path: "mine.png")
        try testPNG().write(to: file)
        studio.importArtwork(from: [file])
        #expect(studio.license(for: try #require(studio.selection)) == nil)
    }

    // MARK: Saving

    @Test func theSessionSurvivesARelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "session-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionStore(directory: directory)
        let provider = StubProvider()
        let first = Studio(session: session) { _ in provider }
        await comparing([krea, zImage], in: first)
        let pick = try #require(first.candidates.first { $0.modelID == zImage })
        first.toggleFavourite(pick)
        let removed = try #require(first.candidates.first { $0.modelID == krea })
        first.remove(removed)

        let second = Studio(session: session) { _ in provider }

        #expect(second.candidates.map(\.id) == [pick.id])
        let restored = try #require(second.candidates.first)
        #expect(restored.png == pick.png)
        #expect(restored.isFavourite)
        #expect(restored.title == "a fox")
        #expect(restored.prompt == pick.prompt)
        #expect(restored.modelID == zImage)
        #expect(restored.caption == pick.caption)
        #expect(second.selectionID == pick.id)
        // The deleted candidate's image is gone, but the comparison result is kept.
        let images = try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "images").path)
        #expect(images == ["\(pick.id.uuidString).png"])
        // Dates are stored to the second, so compare everything else.
        #expect(second.contests.map(\.id) == first.contests.map(\.id))
        #expect(second.contests.map(\.models) == first.contests.map(\.models))
        #expect(second.contests.map(\.picks) == first.contests.map(\.picks))
        #expect(standing(zImage, in: second).map { [$0.wins, $0.contests] } == [1, 1])
    }

    @Test func startsEmptyWhenNothingWasSaved() {
        let session = SessionStore(
            directory: FileManager.default.temporaryDirectory.appending(path: "session-tests-\(UUID().uuidString)"))
        let studio = Studio(session: session) { _ in StubProvider() }

        #expect(studio.candidates.isEmpty)
        #expect(studio.contests.isEmpty)
        #expect(studio.problem == nil)
    }

    @Test func codexIsUsedWhenItsModelIsChosen() async throws {
        let requests = Requests()
        let provider = StubProvider()
        let studio = studio(provider, requests: requests)
        studio.subject = "a fox"
        studio.modelChoice = try #require(studio.modelChoices.first { $0.provider == .codex })

        await studio.generate()

        #expect(requests.kinds == [.codex])
        #expect(provider.generations[0].model == "codex")
        #expect(studio.candidates[0].modelName == "Codex")
    }

    @Test func offersEditingModelsFromEveryProvider() {
        let studio = studio(StubProvider())
        #expect(studio.editModel.model.id == "fal-ai/flux-2/klein/9b/edit")
        #expect(Set(studio.editModels.map(\.provider)) == [.huggingFace, .openAI, .codex])
        #expect(Set(studio.modelChoices.map(\.provider)) == [.huggingFace, .openAI, .codex])
    }

    @Test func refiningEditsTheSelectionThroughHuggingFace() async throws {
        let provider = StubProvider()
        let requests = Requests()
        let studio = studio(provider, requests: requests)
        studio.subject = "a fox"
        studio.modelChoice = try #require(studio.modelChoices.first { $0.provider == .openAI })
        studio.count = 1
        await studio.generate()
        let source = try #require(studio.selection)

        studio.instruction = "make it blue"
        studio.variations = 2
        await studio.refine()

        #expect(requests.kinds == [.openAI, .huggingFace])
        #expect(studio.candidates.count == 3)
        let refined = Array(studio.candidates.prefix(2))
        #expect(refined.allSatisfy { $0.parentID == source.id && $0.title == "make it blue" })
        #expect(studio.selectionID == refined[0].id)
        #expect(studio.instruction.isEmpty)

        let edit = provider.edits[0]
        #expect(edit.image == source.png)
        #expect(edit.model == "fal-ai/flux-2/klein/9b/edit")
        #expect(edit.count == 2)
        #expect(edit.prompt.hasPrefix("make it blue. Keep everything else exactly the same"))
    }

    @Test func cannotRefineWithoutASelectionOrInstruction() async {
        let studio = studio(StubProvider())
        studio.instruction = "make it blue"
        #expect(!studio.canRefine)

        studio.subject = "a fox"
        await studio.generate()
        studio.instruction = " "
        #expect(!studio.canRefine)
    }

    @Test func aMissingKeyPointsToSettings() async {
        let studio = Studio { kind in throw CredentialError.missing(kind) }
        studio.subject = "a fox"

        await studio.generate()

        let problem = studio.problem
        #expect(problem?.title == "The icons could not be generated")
        #expect(problem?.message == "Add a Hugging Face token in Settings.")
        #expect(problem?.pointsToSettings == true)
        #expect(studio.candidates.isEmpty)
        #expect(studio.activity == .idle)
    }

    @Test func aProviderErrorIsReportedInItsOwnWords() async {
        let studio = studio(StubProvider(failure: ProviderError.http(status: 402, message: "Purchase credits")))
        studio.subject = "a fox"

        await studio.generate()

        #expect(studio.problem?.message == "HTTP 402: Purchase credits")
        #expect(studio.problem?.pointsToSettings == false)
    }

    @Test func aRejectedKeyPointsToSettings() async {
        let studio = studio(StubProvider(failure: ProviderError.http(status: 401, message: "Incorrect API key")))
        studio.subject = "a fox"

        await studio.generate()

        #expect(studio.problem?.pointsToSettings == true)
    }

    @Test func cancellingIsNotReportedAsAProblem() async {
        let studio = studio(StubProvider(failure: CancellationError()))
        studio.subject = "a fox"

        await studio.generate()

        #expect(studio.problem == nil)
        #expect(studio.activity == .idle)
    }

    @Test func importsImageFilesAsCandidatesAndReportsUnreadableOnes() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "studio-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let artwork = directory.appending(path: "My Icon.png")
        let notes = directory.appending(path: "notes.txt")
        try testPNG().write(to: artwork)
        try Data("not an image".utf8).write(to: notes)
        let studio = studio(StubProvider())

        studio.importArtwork(from: [artwork, notes])

        #expect(studio.candidates.map(\.title) == ["My Icon"])
        #expect(studio.selectionID == studio.candidates[0].id)
        #expect(studio.candidates[0].prompt.isEmpty)
        #expect(studio.problem?.title == "“notes.txt” could not be imported")
    }

    @Test func removingTheSelectionSelectsAnotherCandidate() async throws {
        let studio = studio(StubProvider())
        studio.subject = "a fox"
        studio.count = 2
        await studio.generate()
        let first = try #require(studio.selection)

        studio.remove(first)

        #expect(studio.candidates.count == 1)
        #expect(studio.selectionID == studio.candidates[0].id)
    }

    @Test func exportsTheSelectionAndWarnsBeforeReplacing() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "studio-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let studio = studio(StubProvider())
        studio.subject = "a fox"
        await studio.generate()
        studio.exportsICNS = true

        #expect(!studio.wouldReplaceIconSet(in: directory))
        let written = studio.export(to: directory)

        #expect(written.map(\.lastPathComponent) == ["AppIcon.appiconset", "AppIcon.icns"])
        #expect(written.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(studio.wouldReplaceIconSet(in: directory))
        #expect(studio.problem == nil)

        // Exporting only the .icns file never touches an existing icon set.
        studio.exportsIOS = false
        studio.exportsMacOS = false
        #expect(!studio.wouldReplaceIconSet(in: directory))
    }
}
