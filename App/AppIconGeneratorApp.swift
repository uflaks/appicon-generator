import AppIconUI
import AppKit
import SwiftUI

@main
struct AppIconGeneratorApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("App Icon Generator", id: "studio") {
            StudioView(studio: delegate.studio)
                .frame(minWidth: 980, minHeight: 600)
        }
        .defaultSize(width: 1240, height: 780)

        Settings {
            SettingsView(store: delegate.store)
        }
    }
}

/// Owns the session so that images opened with the app (from Finder or the Dock) reach it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = KeychainStore()
    private(set) lazy var studio = Studio(store: store, session: .standard)

    func application(_ application: NSApplication, open urls: [URL]) {
        studio.importArtwork(from: urls.filter(\.isFileURL))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
