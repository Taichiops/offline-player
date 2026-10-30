import SwiftUI

@main
struct OfflinePlayerApp: App {
    @State private var library: LibraryStore
    @State private var player: AudioPlayer
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let library = LibraryStore()
        let player = AudioPlayer()
        // Restores the last track and position, paused.
        player.setLibrary(library.tracks)
        _library = State(initialValue: library)
        _player = State(initialValue: player)
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(library)
                .environment(player)
                .onChange(of: library.tracks) { _, tracks in
                    player.setLibrary(tracks)
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                // Picks up files added through the Files app or Finder while the app was away.
                Task { await library.rescan() }
            case .background:
                player.saveState()
            default:
                break
            }
        }
    }
}
