import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: Data
    public let errorOutput: Data

    public init(status: Int32, output: Data, errorOutput: Data) {
        self.status = status
        self.output = output
        self.errorOutput = errorOutput
    }
}

/// The subprocess seam: providers that drive a command-line tool talk to this, tests substitute a stub.
public protocol CommandRunner: Sendable {
    func run(
        _ executable: URL, arguments: [String], environment: [String: String], directory: URL
    ) async throws -> CommandResult
}

/// Runs a real subprocess, ending it if the calling task is cancelled.
public struct ProcessRunner: CommandRunner {
    public init() {}

    public func run(
        _ executable: URL, arguments: [String], environment: [String: String], directory: URL
    ) async throws -> CommandResult {
        // Output goes to files rather than pipes, so a chatty tool can never fill a pipe and stall.
        let files = FileManager.default
        let scratch = files.temporaryDirectory.appending(path: "appicon-run-\(UUID().uuidString)")
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: scratch) }
        let outputFile = scratch.appending(path: "stdout")
        let errorFile = scratch.appending(path: "stderr")
        files.createFile(atPath: outputFile.path, contents: nil)
        files.createFile(atPath: errorFile.path, contents: nil)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = try FileHandle(forWritingTo: outputFile)
        process.standardError = try FileHandle(forWritingTo: errorFile)

        let running = RunningProcess(process)
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            running.terminate()
        }
        try Task.checkCancellation()
        return CommandResult(
            status: status, output: try Data(contentsOf: outputFile), errorOutput: try Data(contentsOf: errorFile))
    }

    /// Lets the cancellation handler reach the process from another thread.
    private final class RunningProcess: @unchecked Sendable {
        private let process: Process

        init(_ process: Process) {
            self.process = process
        }

        func terminate() {
            if process.isRunning { process.terminate() }
        }
    }
}
