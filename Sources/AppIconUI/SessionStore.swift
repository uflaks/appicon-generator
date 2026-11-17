import Foundation

/// Keeps candidates and comparison results on disk between launches: one PNG per
/// candidate in `images/`, and an index of everything else in `session.json`.
public struct SessionStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/AppIconGenerator`.
    public static var standard: SessionStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SessionStore(directory: support.appending(path: "AppIconGenerator"))
    }

    private struct Index: Codable {
        var candidates: [Candidate.Record] = []
        var contests: [Contest] = []
    }

    private var indexFile: URL { directory.appending(path: "session.json") }

    private func imageFile(_ id: UUID) -> URL {
        directory.appending(path: "images").appending(path: "\(id.uuidString).png")
    }

    /// Reads what was saved. Candidates whose image is missing or unreadable are left out.
    func load() -> (candidates: [Candidate], contests: [Contest]) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: indexFile),
              let index = try? decoder.decode(Index.self, from: data) else { return ([], []) }
        let candidates = index.candidates.compactMap { record in
            (try? Data(contentsOf: imageFile(record.id))).flatMap { try? Candidate(record, png: $0) }
        }
        return (candidates, index.contests)
    }

    /// Writes the index, and the image of any candidate that does not have one on disk yet.
    func save(candidates: [Candidate], contests: [Contest]) throws {
        let files = FileManager.default
        try files.createDirectory(at: directory.appending(path: "images"), withIntermediateDirectories: true)
        for candidate in candidates where !files.fileExists(atPath: imageFile(candidate.id).path) {
            try candidate.png.write(to: imageFile(candidate.id), options: .atomic)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Index(candidates: candidates.map(\.record), contests: contests))
            .write(to: indexFile, options: .atomic)
    }

    func removeImage(of id: UUID) {
        try? FileManager.default.removeItem(at: imageFile(id))
    }
}
