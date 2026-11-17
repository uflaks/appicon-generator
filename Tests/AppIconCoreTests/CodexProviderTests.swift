import Foundation
import Testing

@testable import AppIconCore

/// Plays the part of the `codex` tool: records how it was called and leaves files behind.
private final class StubRunner: CommandRunner, @unchecked Sendable {
    struct Call {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let directory: URL
        /// The files that were in the working directory when the tool started.
        let filesAtStart: [String: Data]
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let behave: @Sendable (URL) throws -> CommandResult

    init(behave: @escaping @Sendable (URL) throws -> CommandResult) {
        self.behave = behave
    }

    var calls: [Call] { lock.withLock { recorded } }

    func run(
        _ executable: URL, arguments: [String], environment: [String: String], directory: URL
    ) async throws -> CommandResult {
        var present: [String: Data] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
            present[name] = try? Data(contentsOf: directory.appending(path: name))
        }
        lock.withLock {
            recorded.append(Call(
                executable: executable, arguments: arguments, environment: environment,
                directory: directory, filesAtStart: present))
        }
        return try behave(directory)
    }
}

private func events(thread: String = "thread-1", message: String = "Saved.") -> Data {
    Data("""
        {"type":"thread.started","thread_id":"\(thread)"}
        {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"\(message)"}}
        {"type":"turn.completed","usage":{"input_tokens":1}}

        """.utf8)
}

@Suite struct CodexProviderTests {
    private let executable = URL(fileURLWithPath: "/opt/tools/bin/codex")

    private func provider(_ runner: StubRunner, home: URL? = nil) -> CodexProvider {
        CodexProvider(
            executable: executable,
            home: home ?? FileManager.default.temporaryDirectory.appending(path: "codex-home-\(UUID().uuidString)"),
            runner: runner)
    }

    @Test func generatesByRunningCodexAndCollectingTheSavedFiles() async throws {
        let runner = StubRunner { directory in
            try testImage(width: 1254, height: 1254).write(to: directory.appending(path: "icon-1.png"))
            try testImage(width: 1024, height: 1024).write(to: directory.appending(path: "icon-2.png"))
            try testImage().write(to: directory.appending(path: "unrelated.png"))
            return CommandResult(status: 0, output: events(), errorOutput: Data())
        }

        let images = try await provider(runner).generate(
            GenerationRequest(prompt: "a paper plane, flat style", model: "codex", count: 2))

        // Every result is a 1024 px square PNG, whatever size Codex saved.
        #expect(images.count == 2)
        for image in images {
            let decoded = try image.makeCGImage()
            #expect(decoded.width == 1024 && decoded.height == 1024)
        }

        let call = try #require(runner.calls.first)
        #expect(call.executable == executable)
        #expect(call.arguments.first == "exec")
        let task = call.arguments[1]
        #expect(task.contains("built-in image generation tool"))
        #expect(task.contains("exactly 2 square images"))
        #expect(task.contains("icon-1.png to icon-2.png"))
        #expect(task.contains("Description: a paper plane, flat style"))
        #expect(call.arguments.contains("--json"))
        #expect(call.arguments.contains("--ephemeral"))
        #expect(call.arguments.contains("--ignore-user-config"))
        #expect(call.arguments.contains("--skip-git-repo-check"))
        #expect(!call.arguments.contains("--image"))
        let cd = try #require(call.arguments.firstIndex(of: "--cd"))
        #expect(call.arguments[cd + 1] == call.directory.path)
        #expect(call.environment["PATH"]?.hasPrefix("/opt/tools/bin:") == true)
        // The scratch folder is gone afterwards.
        #expect(!FileManager.default.fileExists(atPath: call.directory.path))
    }

    @Test func editAttachesTheArtworkAndLeavesItInTheWorkingFolder() async throws {
        let runner = StubRunner { directory in
            try testImage(width: 1024, height: 1024).write(to: directory.appending(path: "icon-1.png"))
            return CommandResult(status: 0, output: events(), errorOutput: Data())
        }
        let artwork = testImage()

        let images = try await provider(runner).edit(
            EditRequest(image: artwork, prompt: "make the sky orange", model: "codex"))

        #expect(images.count == 1)
        let call = try #require(runner.calls.first)
        #expect(call.filesAtStart["source.png"] == artwork)
        #expect(call.arguments[1].contains("edit the attached image"))
        #expect(call.arguments[1].contains("exactly one square image"))
        #expect(call.arguments[1].contains("Change: make the sky orange"))
        // `--image` takes a list, so it must come last or it would swallow the prompt.
        #expect(Array(call.arguments.suffix(2)) == ["--image", call.directory.appending(path: "source.png").path])
    }

    @Test func fallsBackToCodexsOwnArchiveAndClearsIt() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "codex-home-\(UUID().uuidString)")
        let archive = home.appending(path: "generated_images/thread-9")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try testImage(width: 1254, height: 1254).write(to: archive.appending(path: "exec-abc.png"))
        // Codex generated the image but never copied it into the working folder.
        let runner = StubRunner { _ in
            CommandResult(status: 0, output: events(thread: "thread-9"), errorOutput: Data())
        }

        let images = try await provider(runner, home: home).generate(
            GenerationRequest(prompt: "a fox", model: "codex"))

        #expect(images.count == 1)
        #expect(try images[0].makeCGImage().width == 1024)
        #expect(!FileManager.default.fileExists(atPath: archive.path))
    }

    @Test func reportsCodexsOwnErrorWhenItFails() async {
        let runner = StubRunner { _ in
            CommandResult(
                status: 1,
                output: Data(#"{"type":"error","message":"You've hit your usage limit."}"#.utf8),
                errorOutput: Data("noise".utf8))
        }

        await #expect(throws: ProviderError.unavailable("Codex stopped with an error. You've hit your usage limit.")) {
            try await provider(runner).generate(GenerationRequest(prompt: "a fox", model: "codex"))
        }
    }

    @Test func saysSoWhenCodexProducesNoImage() async {
        let runner = StubRunner { _ in
            CommandResult(status: 0, output: events(message: "I can't generate images here."), errorOutput: Data())
        }

        await #expect(
            throws: ProviderError.unavailable("Codex finished without producing an image. I can't generate images here.")
        ) {
            try await provider(runner).generate(GenerationRequest(prompt: "a fox", model: "codex"))
        }
    }

    @Test func refusesTransparencyWithoutRunningCodex() async {
        let runner = StubRunner { _ in CommandResult(status: 0, output: Data(), errorOutput: Data()) }

        await #expect(throws: ProviderError.self) {
            try await provider(runner).generate(
                GenerationRequest(prompt: "a fox", model: "codex", transparentBackground: true))
        }
        #expect(runner.calls.isEmpty)
    }
}

@Suite struct ProcessRunnerTests {
    @Test func capturesOutputAndExitStatus() async throws {
        let result = try await ProcessRunner().run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo out; echo err >&2; pwd; exit 3"],
            environment: [:], directory: URL(fileURLWithPath: "/usr"))

        #expect(result.status == 3)
        #expect(String(decoding: result.output, as: UTF8.self) == "out\n/usr\n")
        #expect(String(decoding: result.errorOutput, as: UTF8.self) == "err\n")
    }

    @Test func endsTheProcessWhenCancelled() async throws {
        let started = ContinuousClock.now
        let task = Task {
            try await ProcessRunner().run(
                URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:],
                directory: URL(fileURLWithPath: "/"))
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(10))
    }
}
