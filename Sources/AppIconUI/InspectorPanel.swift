import AppIconCore
import AppKit
import SwiftUI

/// The right column: preview, refine and export the selected candidate.
struct InspectorPanel: View {
    @Bindable var studio: Studio
    @State private var previewShape = PreviewShape.iOS
    @State private var isChoosingFolder = false
    @State private var folderAwaitingConfirmation: URL?

    var body: some View {
        if let candidate = studio.selection {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Picker("Preview", selection: $previewShape) {
                            ForEach(PreviewShape.allCases) { shape in
                                Text(shape.rawValue).tag(shape)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        IconPreview(image: candidate.image, shape: previewShape)
                            .frame(maxWidth: 260)
                            .draggable(candidate)
                            .help("Drag to save this image as a PNG file")

                        Button {
                            studio.toggleFavourite(candidate)
                        } label: {
                            Label(
                                candidate.isFavourite ? "Favourite" : "Mark as Favourite",
                                systemImage: candidate.isFavourite ? "heart.fill" : "heart")
                        }
                        .help("Favourites count as wins for their model in the ranking")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }

                Section("Refine") {
                    TextField(
                        "Change", text: $studio.instruction,
                        prompt: Text("Make the sky a warm orange sunset"), axis: .vertical
                    )
                    .labelsHidden()
                    .lineLimit(2...5)
                    .onSubmit { studio.startRefining() }

                    Picker("Model", selection: $studio.editModel) {
                        ForEach(ProviderKind.allCases) { provider in
                            Section(provider.name) {
                                ForEach(studio.editModels.filter { $0.provider == provider }) { choice in
                                    Text(choice.label).tag(choice)
                                }
                            }
                        }
                    }
                    Stepper("Variations: \(studio.variations)", value: $studio.variations, in: 1...4)

                    if case .refining = studio.activity {
                        Button("Cancel", role: .cancel) { studio.cancel() }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    } else {
                        Button("Refine") { studio.startRefining() }
                            .disabled(!studio.canRefine)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }

                Section {
                    Toggle("iOS", isOn: $studio.exportsIOS)
                    Toggle("macOS", isOn: $studio.exportsMacOS)
                    Toggle("Separate .icns file", isOn: $studio.exportsICNS)
                    Button("Export…") { isChoosingFolder = true }
                        .disabled(!studio.canExport)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } header: {
                    Text("Export")
                } footer: {
                    Text("Writes AppIcon.appiconset into the folder you choose, such as your project's Assets.xcassets.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let license = studio.license(for: candidate) {
                    Section("Licence") {
                        LicenceBadge(license: license)
                        Text(license.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Link(license.name, destination: license.url)
                            .font(.callout)
                    }
                }

                if !candidate.prompt.isEmpty {
                    Section("Prompt") {
                        Text(candidate.prompt)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        LabeledContent("Model", value: candidate.caption)
                    }
                }
            }
            .formStyle(.grouped)
            .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
                guard case .success(let folder) = result else { return }
                if studio.wouldReplaceIconSet(in: folder) {
                    folderAwaitingConfirmation = folder
                } else {
                    export(to: folder)
                }
            }
            .fileDialogConfirmationLabel("Export")
            .confirmationDialog(
                "Replace the existing AppIcon.appiconset?",
                isPresented: Binding(
                    get: { folderAwaitingConfirmation != nil },
                    set: { if !$0 { folderAwaitingConfirmation = nil } }),
                presenting: folderAwaitingConfirmation
            ) { folder in
                Button("Replace", role: .destructive) { export(to: folder) }
                Button("Cancel", role: .cancel) {}
            } message: { folder in
                Text("“\(folder.lastPathComponent)” already contains an icon set. Its images will be deleted and replaced.")
            }
        } else {
            Text("Select an icon to preview, refine or export it.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func export(to folder: URL) {
        let written = studio.export(to: folder)
        if !written.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(written)
        }
    }
}

/// A coloured dot and a few words saying whether icons from a model may be used commercially.
struct LicenceBadge: View {
    let license: ModelLicense

    var body: some View {
        Label {
            Text(license.commercialUse.label)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch license.commercialUse {
        case .unrestricted, .imagesOnly: "checkmark.circle.fill"
        case .conditional, .providerTerms: "exclamationmark.circle.fill"
        case .notAllowed: "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch license.commercialUse {
        case .unrestricted, .imagesOnly: .green
        case .conditional, .providerTerms: .orange
        case .notAllowed: .red
        }
    }
}
