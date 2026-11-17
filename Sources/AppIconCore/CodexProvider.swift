import Foundation

/// Image generation through the Codex command-line tool, which uses the ChatGPT
/// subscription it is signed in with instead of an API key.
///
/// Each request is one `codex exec` agent run that is told to generate the images with
/// its built-in tool and save them into a scratch folder. That makes it slower than an
/// API call, and Codex chooses the image model and its settings itself.
public struct CodexProvider: ImageProvider {
    public let name = "Codex"
    public let models = [ImageModel(id: "codex", name: "Codex", supportsTransparency: false, license: .openAI)]
    public var editModels: [ImageModel] { models }

    private let executable: URL
    private let home: URL
    private let runner: any CommandRunner

    /// - Parameters:
    ///   - executable: the `codex` binary; see ``locateExecutable()``.
    ///   - home: Codex's data folder, where it keeps the images it generates.
    public init(
        executable: URL,
        home: URL = CodexProvider.defaultHome,
        runner: any CommandRunner = ProcessRunner()
    ) {
        self.executable = executable
        self.home = home
        self.runner = runner
    }

    public static var defaultHome: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
    }

    /// Finds the `codex` binary in the usual install locations. Apps launched from Finder
    /// do not inherit the shell's `PATH`, so this does not rely on it alone.
    public static func locateExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let folders =
            ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin"]
            + path.split(separator: ":").map(String.init)
        return folders
            .map { URL(fileURLWithPath: $0).appending(path: "codex") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func generate(_ request: GenerationRequest) async throws -> [GeneratedImage] {
        guard !request.transparentBackground else {
            throw ProviderError.unsupported("Codex cannot be asked for a transparent background.")
        }
        let task = """
            Use your built-in image generation tool to create exactly \(Self.images(request.count)) from the \
            description below\(request.count > 1 ? ", each a different interpretation of it" : "").
            \(Self.saving(request.count))

            Description: \(request.prompt)
            """
        return try await run(task, count: request.count, source: nil)
    }

    public func edit(_ request: EditRequest) async throws -> [GeneratedImage] {
        let task = """
            Use your built-in image generation tool to edit the attached image, which is also saved as \
            source.png in the current directory. Create exactly \(Self.images(request.count)) by applying the \
            change below\(request.count > 1 ? ", each a different take on it" : "").
            \(Self.saving(request.count))

            Change: \(request.prompt)
            """
        return try await run(task, count: request.count, source: try ImageCodec.png(from: request.image))
    }

    // MARK: - Running Codex

    private static func images(_ count: Int) -> String {
        count == 1 ? "one square image" : "\(count) square images"
    }

    private static func saving(_ count: Int) -> String {
        let names = count == 1 ? "it as icon-1.png" : "them as icon-1.png to icon-\(count).png"
        return "Save \(names) in the current directory as 1024x1024 pixel PNG files. "
            + "Do not write code that draws the image yourself, and do nothing else."
    }

    private func run(_ task: String, count: Int, source: Data?) async throws -> [GeneratedImage] {
        let files = FileManager.default
        let workspace = files.temporaryDirectory.appending(path: "appicon-codex-\(UUID().uuidString)")
        try files.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: workspace) }

        // The prompt goes first: `--image` takes a list and would swallow anything after it.
        // The user's Codex config is ignored so that a model or tool server chosen for coding
        // cannot break image requests; the sign-in is still used.
        var arguments = [
            "exec", task, "--ignore-user-config", "--skip-git-repo-check", "--ephemeral", "--json",
            "--sandbox", "workspace-write", "--cd", workspace.path,
        ]
        if let source {
            let file = workspace.appending(path: "source.png")
            try source.write(to: file)
            arguments += ["--image", file.path]
        }

        var environment = ProcessInfo.processInfo.environment
        let toolPath = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        environment["PATH"] = (toolPath + [environment["PATH"] ?? ""]).joined(separator: ":")

        let result = try await runner.run(executable, arguments: arguments, environment: environment, directory: workspace)
        let events = Events(result.output)
        // Codex keeps its own copy of everything it generates; this run's copy is not needed afterwards.
        let archive = events.threadID.map { home.appending(path: "generated_images").appending(path: $0) }
        defer { if let archive { try? files.removeItem(at: archive) } }

        guard result.status == 0 else {
            let detail = events.failure ?? String(decoding: result.errorOutput.suffix(400), as: UTF8.self)
            throw ProviderError.unavailable("Codex stopped with an error. \(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // Prefer what Codex saved where it was told to; fall back to its own archive of the run.
        var saved = pngFiles(in: workspace).filter { $0.lastPathComponent.hasPrefix("icon-") }
        if saved.isEmpty, let archive { saved = pngFiles(in: archive) }
        guard !saved.isEmpty else {
            throw ProviderError.unavailable(
                "Codex finished without producing an image. \(events.lastMessage ?? "")"
                    .trimmingCharacters(in: .whitespaces))
        }
        return try saved.prefix(count).map {
            GeneratedImage(png: try ImageCodec.squarePNG(from: try Data(contentsOf: $0), side: 1024))
        }
    }

    private func pngFiles(in folder: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// The parts of Codex's JSON-lines event stream that matter here.
    private struct Events {
        var threadID: String?
        var lastMessage: String?
        var failure: String?

        init(_ output: Data) {
            struct Event: Decodable {
                struct Item: Decodable {
                    let type: String?
                    let text: String?
                }
                struct Failure: Decodable { let message: String? }
                let type: String
                let thread_id: String?
                let item: Item?
                let message: String?
                let error: Failure?
            }
            let decoder = JSONDecoder()
            for line in output.split(separator: UInt8(ascii: "\n")) {
                guard let event = try? decoder.decode(Event.self, from: line) else { continue }
                if let id = event.thread_id { threadID = id }
                if event.item?.type == "agent_message", let text = event.item?.text { lastMessage = text }
                if event.type == "error" || event.type == "turn.failed" {
                    failure = event.error?.message ?? event.message ?? failure
                }
            }
        }
    }
}
