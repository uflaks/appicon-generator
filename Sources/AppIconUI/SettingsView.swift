import SwiftUI

/// The Settings window: API keys, kept in the Keychain.
public struct SettingsView: View {
    private let store: any CredentialStore

    public init(store: any CredentialStore) {
        self.store = store
    }

    public var body: some View {
        Form {
            KeySection(
                provider: .huggingFace,
                label: "Token",
                note: "Needs the “Inference Providers” permission. Used for the FLUX models.",
                fallbackNote: HuggingFaceLogin.token() == nil
                    ? nil : "No token saved, so the login from the hf command-line tool is used.",
                store: store
            )
            KeySection(
                provider: .openAI,
                label: "API key",
                note: "Used for the GPT Image models.",
                fallbackNote: nil,
                store: store
            )
            Section {
                if let executable = CodexStatus.executable {
                    LabeledContent("Command-line tool", value: executable.path)
                } else {
                    LabeledContent("Command-line tool", value: "Not found")
                }
            } header: {
                Text("Codex")
            } footer: {
                Text("Generates with your ChatGPT subscription instead of an API key. Sign in by running “codex login” in Terminal. Each request is slower and counts against your Codex usage limits.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct KeySection: View {
    let provider: ProviderKind
    let label: String
    let note: String
    let fallbackNote: String?
    let store: any CredentialStore

    @State private var value = ""
    @State private var saved = ""
    @State private var failure: String?

    var body: some View {
        Section {
            SecureField(label, text: $value)
                .onSubmit(save)
            HStack {
                if let failure {
                    Text(failure).foregroundStyle(.red)
                } else if saved.isEmpty, let fallbackNote {
                    Text(fallbackNote).foregroundStyle(.secondary)
                } else if !saved.isEmpty, value == saved {
                    Label("Saved in your Keychain", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save", action: save)
                    .disabled(value == saved)
            }
            .font(.callout)
        } header: {
            Text(provider.name)
        } footer: {
            Text(note)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            saved = store.secret(for: provider) ?? ""
            value = saved
        }
    }

    private func save() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try store.setSecret(trimmed, for: provider)
            value = trimmed
            saved = trimmed
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}
