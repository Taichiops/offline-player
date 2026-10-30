import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AudioPlayer.self) private var player
    @State private var showingImporter = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Library")
                .toolbar { toolbar }
                .safeAreaInset(edge: .bottom) { NowPlayingBar() }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task { await library.importFiles(urls) }
            case .failure(let error):
                library.importFailures.append(error.localizedDescription)
            }
        }
        .alert("Some files couldn't be imported", isPresented: showingFailures) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.importFailures.joined(separator: "\n"))
        }
    }

    @ViewBuilder
    private var content: some View {
        if library.tracks.isEmpty {
            ContentUnavailableView {
                Label("No Music Yet", systemImage: "music.note.list")
            } description: {
                Text("Tap + to import audio files from the Files app. They are copied into the app, so they play offline.\n\nYou can also copy files into Files › On My iPad › Offline Player.")
            } actions: {
                Button("Import Music") { showingImporter = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            let currentID = player.currentTrack?.id
            List {
                ForEach(library.tracks) { track in
                    Button {
                        player.play(trackID: track.id)
                    } label: {
                        TrackRow(track: track, isCurrent: track.id == currentID)
                    }
                }
                .onDelete { library.delete(at: $0) }
                .onMove { library.move(from: $0, to: $1) }
            }
            .listStyle(.plain)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !library.tracks.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if library.isImporting {
                ProgressView()
            } else {
                Button {
                    showingImporter = true
                } label: {
                    Label("Import", systemImage: "plus")
                }
            }
        }
    }

    private var showingFailures: Binding<Bool> {
        Binding(
            get: { !library.importFailures.isEmpty },
            set: { if !$0 { library.importFailures = [] } }
        )
    }
}

private struct TrackRow: View {
    let track: Track
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(Color.accentColor)
                .opacity(isCurrent ? 1 : 0)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                if let artist = track.artist {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let duration = track.duration {
                Text(duration.clockString)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
