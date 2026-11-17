import AppIconCore
import ArgumentParser
import Foundation

@main
struct AppIcon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "appicon",
        abstract: "Generate app icon artwork with image models and export it for Xcode.",
        subcommands: [Generate.self, Edit.self, Export.self, Models.self]
    )
}

enum ProviderChoice: String, ExpressibleByArgument, CaseIterable {
    case hf
    case openai
    case codex

    func make() throws -> any ImageProvider {
        switch self {
        case .hf: HuggingFaceProvider(token: try Credentials.huggingFaceToken())
        case .openai: OpenAIProvider(apiKey: try Credentials.openAIKey())
        case .codex: CodexProvider(executable: try Credentials.codexExecutable())
        }
    }

    /// The provider without credentials, good only for reading its model lists.
    var catalogue: any ImageProvider {
        switch self {
        case .hf: HuggingFaceProvider(token: "")
        case .openai: OpenAIProvider(apiKey: "")
        case .codex: CodexProvider(executable: URL(fileURLWithPath: "/usr/bin/false"))
        }
    }
}

/// How a command picks its backend and model: `--best`, `--best-open`, or an explicit
/// `--provider` and `--model`.
struct ModelSelection: ParsableArguments {
    @Flag(help: "Use the best model there is: GPT Image through the OpenAI API if OPENAI_API_KEY is set, otherwise through Codex and your ChatGPT subscription.")
    var best = false

    @Flag(name: .customLong("best-open"), help: "Use the best open model, through Hugging Face.")
    var bestOpen = false

    @Option(help: "Backend: \(ProviderChoice.allCases.map(\.rawValue).joined(separator: ", ")). Defaults to hf.")
    var provider: ProviderChoice?

    @Option(help: "Model id. Defaults to the provider's first model; see `appicon models`.")
    var model: String?

    func validate() throws {
        if best && bestOpen {
            throw ValidationError("Choose either --best or --best-open, not both.")
        }
        if (best || bestOpen) && (provider != nil || model != nil) {
            throw ValidationError("--best and --best-open pick the provider and model themselves; leave out --provider and --model.")
        }
    }

    /// The backend to call and the model to ask it for.
    func resolve(editing: Bool) throws -> (backend: any ImageProvider, model: ImageModel) {
        func models(_ provider: any ImageProvider) -> [ImageModel] {
            editing ? provider.editModels : provider.models
        }
        func top(_ choice: ProviderChoice, because reason: String) throws -> (any ImageProvider, ImageModel) {
            let backend = try choice.make()
            guard let model = models(backend).topRated else {
                throw ValidationError("\(backend.name) does not offer image editing here.")
            }
            let route = model.name == backend.name ? model.name : "\(model.name) through \(backend.name)"
            print("Using \(route) (\(reason)).")
            return (backend, model)
        }

        if bestOpen {
            return try top(.hf, because: "the best open model")
        }
        if best {
            if (try? Credentials.openAIKey()) != nil {
                return try top(.openai, because: "the best model, with your OpenAI API key")
            }
            if (try? Credentials.codexExecutable()) != nil {
                return try top(.codex, because: "the best model; no OPENAI_API_KEY, so GPT Image through your ChatGPT subscription")
            }
            throw ValidationError(
                "--best needs GPT Image: set OPENAI_API_KEY, or install the codex command-line tool and run `codex login`. Use --best-open for the best open model.")
        }

        let backend = try (provider ?? .hf).make()
        let offered = models(backend)
        if let model {
            // An id that is not in the list is passed through, so new models can be tried.
            return (backend, offered.first { $0.id == model }
                ?? ImageModel(id: model, name: model, supportsTransparency: true))
        }
        guard let first = offered.first else {
            throw ValidationError("\(backend.name) does not offer image editing here.")
        }
        return (backend, first)
    }
}

/// Writes generated images as numbered PNG files and prints where they went.
func save(_ images: [GeneratedImage], model: String, in out: String) throws {
    let directory = URL(fileURLWithPath: out)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stamp = Int(Date().timeIntervalSince1970)
    let label = model.split(separator: "/").filter { $0 != "edit" }.suffix(2).joined(separator: "-")
    for (index, image) in images.enumerated() {
        let file = directory.appending(path: "\(stamp)-\(label)-\(index + 1).png")
        try image.png.write(to: file)
        print(file.path)
    }
}

func seconds(since start: ContinuousClock.Instant) -> String {
    (ContinuousClock.now - start).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))
}

extension IconStyle: ExpressibleByArgument {}

struct Generate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Generate icon candidates from a subject description.")

    @Argument(help: "What the icon shows, for example \"a sun partly behind a cloud\".")
    var subject: String

    @OptionGroup var selection: ModelSelection

    @Option(help: "Style preset: \(IconStyle.allCases.map(\.rawValue).joined(separator: ", ")).")
    var style: IconStyle = .gradient

    @Option(help: "Background: \"auto\", \"transparent\" (OpenAI API only), or a colour in words.")
    var background = "auto"

    @Option(help: "How many candidates to generate.")
    var count = 1

    @Option(help: "Seed for reproducible results, where the provider supports it.")
    var seed: UInt64?

    @Option(help: "Directory to write the PNG files into.")
    var out = "out"

    @Flag(help: "Send the subject text to the model as the whole prompt, without the style preset.")
    var rawPrompt = false

    func run() async throws {
        let (backend, model) = try selection.resolve(editing: false)
        let modelID = model.id
        let backdrop: IconBackground =
            switch background {
            case "auto": .automatic
            case "transparent": .transparent
            default: .color(background)
            }
        let prompt = rawPrompt ? subject : IconPrompt(subject: subject, style: style, background: backdrop).text
        print("Prompt: \(prompt)")

        let started = ContinuousClock.now
        let images = try await backend.generate(GenerationRequest(
            prompt: prompt, model: modelID, count: count, seed: seed,
            transparentBackground: backdrop == .transparent))
        print("\(backend.name) \(modelID): \(images.count) image(s) in \(seconds(since: started))")
        try save(images, model: modelID, in: out)
    }
}

struct Edit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Refine existing artwork with an editing model, for example a generated candidate.")

    @Argument(help: "The artwork to change.")
    var image: String

    @Argument(help: "What to change, for example \"make the cloud smaller and the sky orange\".")
    var instruction: String

    @OptionGroup var selection: ModelSelection

    @Option(help: "How many variations to produce.")
    var count = 1

    @Option(help: "Seed for reproducible results, where the provider supports it.")
    var seed: UInt64?

    @Option(help: "Directory to write the PNG files into.")
    var out = "out"

    @Flag(help: "Send the instruction to the model as the whole prompt, without the keep-the-rest wording.")
    var rawPrompt = false

    func run() async throws {
        let (backend, model) = try selection.resolve(editing: true)
        let modelID = model.id
        let artwork = try Data(contentsOf: URL(fileURLWithPath: image))
        let prompt = rawPrompt ? instruction : IconEditPrompt(instruction: instruction).text
        print("Prompt: \(prompt)")

        let started = ContinuousClock.now
        let images = try await backend.edit(EditRequest(
            image: artwork, prompt: prompt, model: modelID, count: count, seed: seed))
        print("\(backend.name) \(modelID): \(images.count) image(s) in \(seconds(since: started))")
        try save(images, model: modelID, in: out)
    }
}

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Export an image as AppIcon.appiconset, and optionally a .icns file.")

    @Argument(help: "The artwork to export, ideally 1024×1024.")
    var image: String

    @Option(help: "Directory to write into.")
    var out = "out"

    @Flag(name: .customLong("ios"), help: "Include only iOS in the icon set (combine with --macos for both).")
    var iOS = false

    @Flag(name: .customLong("macos"), help: "Include only macOS in the icon set (combine with --ios for both).")
    var macOS = false

    @Flag(help: "Also write AppIcon.icns.")
    var icns = false

    func run() throws {
        let artwork = try Data(contentsOf: URL(fileURLWithPath: image))
        let directory = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var platforms: Set<IconExporter.Platform> = []
        if iOS { platforms.insert(.iOS) }
        if macOS { platforms.insert(.macOS) }
        if platforms.isEmpty { platforms = Set(IconExporter.Platform.allCases) }

        let exporter = IconExporter()
        print(try exporter.writeAppIconSet(from: artwork, platforms: platforms, in: directory).path)
        if icns {
            let file = directory.appending(path: "AppIcon.icns")
            try exporter.writeICNS(from: artwork, to: file)
            print(file.path)
        }
    }
}

struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the models each provider offers, with what their licences say about commercial use.")

    func run() {
        func line(_ model: ImageModel) -> String {
            var notes = [model.name]
            if model.supportsTransparency { notes.append("transparency") }
            if model.isOlder { notes.append("older") }
            if let license = model.license { notes.append(license.commercialUse.label.lowercased()) }
            return "  \(model.id)  (\(notes.joined(separator: ", ")))"
        }
        for choice in ProviderChoice.allCases {
            let provider = choice.catalogue
            print("\(choice.rawValue) generate:")
            provider.models.forEach { print(line($0)) }
            if !provider.editModels.isEmpty {
                print("\(choice.rawValue) edit:")
                provider.editModels.forEach { print(line($0)) }
            }
        }
        print("\nLicence notes describe each model's own licence; see the app's Model Ranking for details.")
    }
}
