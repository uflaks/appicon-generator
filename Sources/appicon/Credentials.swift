import AppIconCore
import ArgumentParser
import Foundation

/// Where the command-line tool finds API keys. The app will use the Keychain instead.
enum Credentials {
    /// `HF_TOKEN`, falling back to the login stored by the `hf` command-line tool.
    static func huggingFaceToken() throws -> String {
        if let token = ProcessInfo.processInfo.environment["HF_TOKEN"], !token.isEmpty { return token }
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/huggingface/token")
        if let token = try? String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return token
        }
        throw ValidationError("Set HF_TOKEN (with the Inference Providers permission) or run `hf auth login`.")
    }

    static func codexExecutable() throws -> URL {
        guard let executable = CodexProvider.locateExecutable() else {
            throw ValidationError("The codex command-line tool was not found. Install it and run `codex login`.")
        }
        return executable
    }

    static func openAIKey() throws -> String {
        if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty { return key }
        throw ValidationError("Set OPENAI_API_KEY.")
    }
}
