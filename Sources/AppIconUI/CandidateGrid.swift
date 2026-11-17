import SwiftUI

/// The middle column: every candidate of the session, newest first.
struct CandidateGrid: View {
    @Bindable var studio: Studio

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 24)]

    var body: some View {
        Group {
            if studio.candidates.isEmpty && !studio.isBusy {
                ContentUnavailableView(
                    "No Icons Yet",
                    systemImage: "app.dashed",
                    description: Text("Describe a subject and choose Generate, or drop an image here.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(0..<pendingCount, id: \.self) { _ in
                            PendingTile()
                        }
                        ForEach(studio.candidates) { candidate in
                            CandidateTile(
                                candidate: candidate,
                                isSelected: candidate.id == studio.selectionID,
                                isRefinement: candidate.parentID != nil
                            )
                            .onTapGesture { studio.selectionID = candidate.id }
                            .draggable(candidate)
                            .contextMenu {
                                Button(candidate.isFavourite ? "Remove Favourite" : "Mark as Favourite") {
                                    studio.toggleFavourite(candidate)
                                }
                                Divider()
                                Button("Delete", role: .destructive) { studio.remove(candidate) }
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .dropDestination(for: URL.self) { files, _ in
            let before = studio.candidates.count
            studio.importArtwork(from: files.filter(\.isFileURL))
            return studio.candidates.count > before
        }
    }

    private var pendingCount: Int {
        switch studio.activity {
        case .idle: 0
        case .generating(let count), .refining(let count): count
        }
    }
}

private struct CandidateTile: View {
    let candidate: Candidate
    let isSelected: Bool
    let isRefinement: Bool

    private var symbol: String {
        if isRefinement { return "wand.and.sparkles" }
        return candidate.prompt.isEmpty ? "square.and.arrow.down" : "sparkles"
    }

    var body: some View {
        VStack(spacing: 8) {
            IconPreview(image: candidate.image)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                .padding(6)
                .overlay {
                    if isSelected {
                        IconMask().strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if candidate.isFavourite {
                        Image(systemName: "heart.fill")
                            .font(.body)
                            .foregroundStyle(.white, .red)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.red)
                            .padding(6)
                            .background(.regularMaterial, in: Circle())
                            .accessibilityLabel("Favourite")
                    }
                }
            VStack(spacing: 2) {
                Text(candidate.title)
                    .font(.callout)
                    .lineLimit(1)
                Label(candidate.caption, systemImage: symbol)
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Stands in for a candidate that is still being made.
private struct PendingTile: View {
    var body: some View {
        VStack(spacing: 8) {
            IconMask()
                .fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)
                .overlay { ProgressView() }
                .padding(6)
            VStack(spacing: 2) {
                Text("Working…").font(.callout)
                Text(" ").font(.caption)
            }
            .foregroundStyle(.secondary)
        }
    }
}
