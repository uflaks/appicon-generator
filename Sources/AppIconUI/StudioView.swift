import SwiftUI

/// The main window: compose on the left, candidates in the middle, the selected one on the right.
public struct StudioView: View {
    @Bindable private var studio: Studio
    @State private var showsInspector = true
    @State private var isImporting = false
    @State private var showsRanking = false

    public init(studio: Studio) {
        self.studio = studio
    }

    public var body: some View {
        NavigationSplitView {
            ComposePanel(studio: studio)
                .navigationSplitViewColumnWidth(min: 280, ideal: 300, max: 380)
        } detail: {
            CandidateGrid(studio: studio)
                .inspector(isPresented: $showsInspector) {
                    InspectorPanel(studio: studio)
                        .inspectorColumnWidth(min: 300, ideal: 340, max: 440)
                }
        }
        .navigationTitle("App Icon Generator")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsRanking = true
                } label: {
                    Label("Model Ranking", systemImage: "trophy")
                }
                .help("Compare the models by your own picks, public scores and age")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isImporting = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .help("Import existing images to refine or export")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the inspector")
            }
        }
        .sheet(isPresented: $showsRanking) {
            RankingView(standings: studio.standings)
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            if case .success(let files) = result { studio.importArtwork(from: files) }
        }
        .alert(
            studio.problem?.title ?? "",
            isPresented: Binding(get: { studio.problem != nil }, set: { if !$0 { studio.problem = nil } }),
            presenting: studio.problem
        ) { problem in
            if problem.pointsToSettings {
                SettingsLink { Text("Open Settings…") }
            }
            Button("OK", role: .cancel) {}
        } message: { problem in
            Text(problem.message)
        }
    }
}
