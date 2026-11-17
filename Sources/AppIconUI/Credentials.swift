import AppIconCore
import Foundation
import Security

public enum ProviderKind: String, CaseIterable, Identifiable, Sendable {
    case huggingFace
    case openAI
    /// The Codex command-line tool, which needs no key: it uses its own ChatGPT sign-in.
    case codex

    public var id: Self { self }

    public var name: String {
        switch self {
        case .huggingFace: "Hugging Face"
        case .openAI: "OpenAI"
        case .codex: "Codex (ChatGPT subscription)"
        }
    }

    /// The name without the explanation, for tight spaces.
    public var shortName: String {
        self == .codex ? "Codex" : name
    }
}

/// Where API keys are kept.
public protocol CredentialStore: Sendable {
    func secret(for provider: ProviderKind) -> String?
    /// Stores the secret, or removes it when `secret` is nil or empty.
    func setSecret(_ secret: String?, for provider: ProviderKind) throws
}

public enum CredentialError: Error, LocalizedError, Equatable {
    case missing(ProviderKind)
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .missing(.huggingFace): "Add a Hugging Face token in Settings."
        case .missing(.openAI): "Add an OpenAI API key in Settings."
        case .missing(.codex): CodexStatus.notInstalledMessage
        case .keychain(let status):
            "The Keychain refused the request (\(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"))."
        }
    }
}

/// Keeps API keys in the user's login Keychain.
public struct KeychainStore: CredentialStore {
    private let service: String

    public init(service: String = "local.appicon-generator") {
        self.service = service
    }

    private func query(for provider: ProviderKind) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: provider.rawValue,
        ]
    }

    public func secret(for provider: ProviderKind) -> String? {
        var query = query(for: provider)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ secret: String?, for provider: ProviderKind) throws {
        let query = query(for: provider)
        guard let secret, !secret.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialError.keychain(status)
            }
            return
        }
        let value = [kSecValueData: Data(secret.utf8)]
        var status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(value) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
    }
}

/// The login the `hf` command-line tool leaves behind, used when no token has been saved.
public enum HuggingFaceLogin {
    public static func token() -> String? {
        if let token = ProcessInfo.processInfo.environment["HF_TOKEN"], !token.isEmpty { return token }
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/huggingface/token")
        guard let token = try? String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return nil }
        return token
    }
}

/// Builds a provider from stored credentials, or throws ``CredentialError/missing(_:)``.
func liveProvider(_ kind: ProviderKind, store: any CredentialStore) throws -> any ImageProvider {
    let saved = store.secret(for: kind).flatMap { $0.isEmpty ? nil : $0 }
    switch kind {
    case .huggingFace:
        guard let token = saved ?? HuggingFaceLogin.token() else { throw CredentialError.missing(kind) }
        return HuggingFaceProvider(token: token)
    case .openAI:
        guard let key = saved else { throw CredentialError.missing(kind) }
        return OpenAIProvider(apiKey: key)
    case .codex:
        guard let executable = CodexProvider.locateExecutable() else {
            throw ProviderError.unavailable(CodexStatus.notInstalledMessage)
        }
        return CodexProvider(executable: executable)
    }
}

public enum CodexStatus {
    static let notInstalledMessage =
        "The Codex command-line tool was not found. Install it and sign in with your ChatGPT account by running “codex login”."

    /// Where the Codex tool is installed, if it is.
    public static var executable: URL? { CodexProvider.locateExecutable() }
}
