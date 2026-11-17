import AppIconCore
import Foundation
import Observation

/// The state of one working session: what to generate, the candidates so far, and
/// the refine and export steps applied to the selected one.
@MainActor @Observable
public final class Studio {
    public enum BackgroundMode: String, CaseIterable, Identifiable, Sendable {
        case automatic
        case color
        case transparent

        public var id: Self { self }
    }

    public enum Activity: Equatable, Sendable {
        case idle
        /// Still waiting for this many new candidates.
        case generating(Int)
        /// Waiting for this many variations of the selected candidate.
        case refining(Int)
    }

    /// Something that went wrong, worded for the person using the app.
    public struct Problem: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public let title: String
        public let message: String
        /// True when the fix is to enter or correct an API key.
        public let pointsToSettings: Bool
    }

    // MARK: Compose

    public var subject = ""
    public var style = IconStyle.gradient
    public var backgroundMode = BackgroundMode.automatic
    /// The colour in plain words, used when ``backgroundMode`` is `.color`.
    public var backgroundColor = ""
    /// The model used when not comparing.
    public var modelChoice: ModelChoice {
        didSet { dropUnsupportedTransparency() }
    }
    /// When on, ``generate()`` runs every model in ``comparedModels`` with the same prompt.
    public var isComparing = false {
        didSet { dropUnsupportedTransparency() }
    }
    public var comparedModels: Set<ModelChoice.ID> {
        didSet { dropUnsupportedTransparency() }
    }
    /// How many candidates to generate, per model when comparing.
    public var count = 2

    // MARK: Refine

    public var instruction = ""
    public var editModel: ModelChoice
    public var variations = 1

    // MARK: Export

    public var exportsIOS = true
    public var exportsMacOS = true
    public var exportsICNS = false

    // MARK: Results

    /// Newest first.
    public private(set) var candidates: [Candidate] = []
    /// Every comparison run so far, the raw material of ``standings``.
    public private(set) var contests: [Contest] = []
    public var selectionID: Candidate.ID?
    public private(set) var activity = Activity.idle
    public var problem: Problem?

    public let modelChoices: [ModelChoice]
    public let editModels: [ModelChoice]

    private let makeProvider: @Sendable (ProviderKind) throws -> any ImageProvider
    private let session: SessionStore?
    private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - session: where candidates and comparison results are kept between launches;
    ///     nil keeps everything in memory only.
    ///   - makeProvider: builds the backend for a provider, throwing if its key is missing.
    public init(
        session: SessionStore? = nil,
        makeProvider: @escaping @Sendable (ProviderKind) throws -> any ImageProvider
    ) {
        self.makeProvider = makeProvider
        self.session = session
        self.modelChoices = ModelChoice.all
        self.editModels = ModelChoice.allEditing
        self.modelChoice = ModelChoice.all[0]
        self.editModel = ModelChoice.allEditing[0]
        self.comparedModels = Set(ModelChoice.comparedByDefault.map(\.id))
        if let saved = session?.load() {
            self.candidates = saved.candidates
            self.contests = saved.contests
            self.selectionID = saved.candidates.first?.id
        }
    }

    /// A studio that reads API keys from `store` and keeps its session in `session`.
    public convenience init(store: any CredentialStore, session: SessionStore?) {
        self.init(session: session) { try liveProvider($0, store: store) }
    }

    /// Every generation model, best first: by the user's own picks in comparisons, then by
    /// public score, then by release date.
    public var standings: [ModelStanding] {
        ModelStanding.ranking(of: modelChoices, from: contests)
    }

    public var selection: Candidate? {
        candidates.first { $0.id == selectionID }
    }

    /// The licence of the model that made a candidate; nil for imported artwork.
    public func license(for candidate: Candidate) -> ModelLicense? {
        (modelChoices + editModels).first { $0.id == candidate.modelID }?.model.license
    }

    public var isBusy: Bool { activity != .idle }

    /// The models ``generate()`` will run, in display order.
    public var activeModels: [ModelChoice] {
        isComparing ? modelChoices.filter { comparedModels.contains($0.id) } : [modelChoice]
    }

    /// Transparent backgrounds are only on offer when every model about to run can produce one.
    public var supportsTransparency: Bool {
        let models = activeModels
        return !models.isEmpty && models.allSatisfy(\.model.supportsTransparency)
    }

    public var canGenerate: Bool {
        !isBusy && !activeModels.isEmpty && !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var canRefine: Bool {
        !isBusy && selection != nil && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var canExport: Bool {
        selection != nil && (exportsIOS || exportsMacOS || exportsICNS)
    }

    /// The text that ``generate()`` will send for the current settings.
    public var prompt: String {
        IconPrompt(subject: subject, style: style, background: background).text
    }

    private var background: IconBackground {
        switch backgroundMode {
        case .automatic: return .automatic
        case .transparent: return .transparent
        case .color:
            let color = backgroundColor.trimmingCharacters(in: .whitespacesAndNewlines)
            return color.isEmpty ? .automatic : .color(color)
        }
    }

    private func dropUnsupportedTransparency() {
        if backgroundMode == .transparent, !supportsTransparency {
            backgroundMode = .automatic
        }
    }

    // MARK: - Actions

    public func startGenerating() {
        task = Task { await generate() }
    }

    public func startRefining() {
        task = Task { await refine() }
    }

    public func cancel() {
        task?.cancel()
    }

    /// Generates ``count`` candidates with each active model, all at once, adding results as
    /// they arrive. The first result to arrive is selected.
    public func generate() async {
        guard canGenerate else { return }
        let choices = activeModels
        let prompt = prompt
        let title = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = count
        let transparent = background == .transparent
        let makeProvider = makeProvider

        struct Outcome: Sendable {
            let choice: ModelChoice
            let result: Result<[GeneratedImage], any Error>
            let duration: Duration
        }

        var remaining = choices.count * count
        activity = .generating(remaining)
        defer { activity = .idle }
        var failures: [(ModelChoice, any Error)] = []
        var hasSelected = false
        let runID = UUID()
        var delivered: [String] = []

        await withTaskGroup(of: Outcome.self) { group in
            for choice in choices {
                group.addTask {
                    let started = ContinuousClock.now
                    let result: Result<[GeneratedImage], any Error>
                    do {
                        let provider = try makeProvider(choice.provider)
                        result = .success(try await provider.generate(GenerationRequest(
                            prompt: prompt, model: choice.model.id, count: count, transparentBackground: transparent)))
                    } catch {
                        result = .failure(error)
                    }
                    return Outcome(choice: choice, result: result, duration: ContinuousClock.now - started)
                }
            }
            for await outcome in group {
                remaining -= count
                activity = .generating(remaining)
                do {
                    let new = try outcome.result.get().map {
                        try Candidate(
                            $0, title: title, prompt: prompt, modelName: outcome.choice.model.name,
                            modelID: outcome.choice.id, duration: outcome.duration, runID: runID)
                    }
                    candidates.insert(contentsOf: new, at: 0)
                    delivered.append(outcome.choice.id)
                    // It becomes a comparison as soon as a second model has delivered.
                    if delivered.count == 2 {
                        contests.append(Contest(id: runID, date: Date(), models: delivered))
                    } else if let index = contests.firstIndex(where: { $0.id == runID }) {
                        contests[index].models = delivered
                    }
                    persist()
                    if !hasSelected, let first = new.first {
                        selectionID = first.id
                        hasSelected = true
                    }
                } catch {
                    failures.append((outcome.choice, error))
                }
            }
        }

        failures.removeAll { Self.isCancellation($0.1) }
        guard !failures.isEmpty else { return }
        if choices.count == 1 {
            report(failures[0].1, title: "The icons could not be generated")
        } else {
            let order = Dictionary(uniqueKeysWithValues: choices.enumerated().map { ($1.id, $0) })
            failures.sort { order[$0.0.id, default: 0] < order[$1.0.id, default: 0] }
            problem = Problem(
                title: failures.count == choices.count
                    ? "None of the models could generate"
                    : "\(failures.count) of \(choices.count) models could not generate",
                message: failures.map { "\($0.0.model.name): \($0.1.localizedDescription)" }.joined(separator: "\n"),
                pointsToSettings: failures.contains { Self.pointsToSettings($0.1) })
        }
    }

    /// Produces ``variations`` edited versions of the selected candidate and selects the first.
    public func refine() async {
        guard canRefine, let source = selection else { return }
        let choice = editModel
        let title = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = IconEditPrompt(instruction: title).text
        let request = EditRequest(image: source.png, prompt: prompt, model: choice.model.id, count: variations)

        activity = .refining(variations)
        defer { activity = .idle }
        do {
            // The editing provider is independent of whichever one made the source.
            let provider = try makeProvider(choice.provider)
            let started = ContinuousClock.now
            let images = try await provider.edit(request)
            let duration = ContinuousClock.now - started
            let new = try images.map {
                try Candidate(
                    $0, title: title, prompt: prompt, modelName: choice.model.name,
                    modelID: choice.id, parentID: source.id, duration: duration)
            }
            add(new)
            instruction = ""
        } catch {
            report(error, title: "The icon could not be refined")
        }
    }

    /// Adds existing image files as candidates, so they can be refined and exported.
    public func importArtwork(from files: [URL]) {
        var imported: [Candidate] = []
        for file in files {
            do {
                let image = try GeneratedImage(imageData: try Data(contentsOf: file))
                imported.append(try Candidate(
                    image, title: file.deletingPathExtension().lastPathComponent, prompt: "", modelName: "Imported"))
            } catch {
                report(error, title: "“\(file.lastPathComponent)” could not be imported")
            }
        }
        add(imported)
    }

    /// Removes a candidate. A pick it earned in a comparison stays on the record.
    public func remove(_ candidate: Candidate) {
        candidates.removeAll { $0.id == candidate.id }
        if selectionID == candidate.id { selectionID = candidates.first?.id }
        session?.removeImage(of: candidate.id)
        persist()
    }

    /// Marks or unmarks a candidate as a keeper. If it came from a comparison, that is a
    /// pick for its model there.
    public func toggleFavourite(_ candidate: Candidate) {
        guard let index = candidates.firstIndex(where: { $0.id == candidate.id }) else { return }
        candidates[index].isFavourite.toggle()
        let isFavourite = candidates[index].isFavourite
        if let model = candidate.modelID,
           let contest = contests.firstIndex(where: { $0.id == candidate.runID && $0.models.contains(model) }) {
            let picks = contests[contest].picks[model, default: 0] + (isFavourite ? 1 : -1)
            contests[contest].picks[model] = picks > 0 ? picks : nil
        }
        persist()
    }

    /// Whether exporting into `directory` would replace an icon set that is already there.
    public func wouldReplaceIconSet(in directory: URL) -> Bool {
        (exportsIOS || exportsMacOS)
            && FileManager.default.fileExists(atPath: directory.appending(path: "AppIcon.appiconset").path)
    }

    /// Writes the selected candidate into `directory` and returns the files and folders created.
    @discardableResult
    public func export(to directory: URL) -> [URL] {
        guard let candidate = selection else { return [] }
        // Exporting an icon is the clearest sign that it was the one worth keeping.
        if !candidate.isFavourite { toggleFavourite(candidate) }
        let exporter = IconExporter()
        var written: [URL] = []
        do {
            var platforms: Set<IconExporter.Platform> = []
            if exportsIOS { platforms.insert(.iOS) }
            if exportsMacOS { platforms.insert(.macOS) }
            if !platforms.isEmpty {
                written.append(try exporter.writeAppIconSet(from: candidate.png, platforms: platforms, in: directory))
            }
            if exportsICNS {
                let file = directory.appending(path: "AppIcon.icns")
                try exporter.writeICNS(from: candidate.png, to: file)
                written.append(file)
            }
        } catch {
            report(error, title: "The icon could not be exported")
        }
        return written
    }

    // MARK: - Helpers

    private func add(_ new: [Candidate]) {
        candidates.insert(contentsOf: new, at: 0)
        selectionID = new.first?.id ?? selectionID
        persist()
    }

    private func persist() {
        guard let session else { return }
        do {
            try session.save(candidates: candidates, contests: contests)
        } catch {
            report(error, title: "Your icons could not be saved for next time")
        }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private static func pointsToSettings(_ error: any Error) -> Bool {
        if error is CredentialError { return true }
        if case ProviderError.http(let status, _) = error { return status == 401 || status == 403 }
        return false
    }

    private func report(_ error: any Error, title: String) {
        if Self.isCancellation(error) { return }
        problem = Problem(
            title: title, message: error.localizedDescription, pointsToSettings: Self.pointsToSettings(error))
    }
}
