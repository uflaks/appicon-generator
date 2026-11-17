import AppIconCore
import SwiftUI

/// The left column: what to generate and with which model.
struct ComposePanel: View {
    @Bindable var studio: Studio

    var body: some View {
        Form {
            Section("Subject") {
                TextField(
                    "Subject", text: $studio.subject,
                    prompt: Text("A sun partly behind a soft white cloud"), axis: .vertical
                )
                .labelsHidden()
                .lineLimit(3...6)
            }

            Section("Look") {
                Picker("Style", selection: $studio.style) {
                    ForEach(IconStyle.allCases, id: \.self) { style in
                        Text(style.name).tag(style)
                    }
                }
                Picker("Background", selection: $studio.backgroundMode) {
                    Text("Automatic").tag(Studio.BackgroundMode.automatic)
                    Text("Colour").tag(Studio.BackgroundMode.color)
                    if studio.supportsTransparency {
                        Text("Transparent").tag(Studio.BackgroundMode.transparent)
                    }
                }
                if studio.backgroundMode == .color {
                    TextField("Colour", text: $studio.backgroundColor, prompt: Text("Deep blue gradient"))
                }
            }

            Section {
                Toggle("Compare models", isOn: $studio.isComparing)
                if studio.isComparing {
                    ForEach(ProviderKind.allCases) { provider in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(provider.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(studio.modelChoices.filter { $0.provider == provider }) { choice in
                                HStack {
                                    Toggle(choice.model.name, isOn: isCompared(choice))
                                        .toggleStyle(.checkbox)
                                        .help(choice.model.license.map { "\($0.name). \($0.summary)" } ?? "")
                                    Spacer()
                                    if let released = choice.model.released {
                                        Text(choice.model.isOlder ? "\(released.label) · older" : released.label)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Picker("Model", selection: $studio.modelChoice) {
                        ForEach(ProviderKind.allCases) { provider in
                            Section(provider.name) {
                                ForEach(studio.modelChoices.filter { $0.provider == provider }) { choice in
                                    Text(choice.label).tag(choice)
                                }
                            }
                        }
                    }
                }
                Stepper(
                    studio.isComparing ? "Candidates per model: \(studio.count)" : "Candidates: \(studio.count)",
                    value: $studio.count, in: 1...4)
            } footer: {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            generateBar
        }
    }

    private func isCompared(_ choice: ModelChoice) -> Binding<Bool> {
        Binding(
            get: { studio.comparedModels.contains(choice.id) },
            set: { isOn in
                if isOn {
                    studio.comparedModels.insert(choice.id)
                } else {
                    studio.comparedModels.remove(choice.id)
                }
            })
    }

    private var footnote: String {
        let models = studio.activeModels
        var notes: [String] = []
        if studio.isComparing {
            notes.append(
                models.isEmpty
                    ? "Tick at least one model."
                    : "Runs the same prompt on \(models.count == 1 ? "1 model" : "\(models.count) models") at once.")
        }
        if !studio.isComparing, let license = studio.modelChoice.model.license {
            notes.append("Licence: \(license.name). \(license.summary)")
        }
        if models.contains(where: { $0.provider == .codex }) {
            notes.append("Codex uses your ChatGPT subscription and takes about a minute per image.")
        }
        if !studio.supportsTransparency, !models.isEmpty {
            notes.append(
                studio.isComparing
                    ? "Transparent backgrounds need every ticked model to be an OpenAI model."
                    : "Transparent backgrounds need an OpenAI model.")
        }
        return notes.joined(separator: " ")
    }

    private var generateBar: some View {
        VStack(spacing: 8) {
            if case .generating = studio.activity {
                Button(role: .cancel) {
                    studio.cancel()
                } label: {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            } else {
                Button {
                    studio.startGenerating()
                } label: {
                    Text("Generate").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!studio.canGenerate)
                .help("Generate candidates (⌘↩)")
            }
        }
        .padding(16)
        .background(.bar)
    }
}
