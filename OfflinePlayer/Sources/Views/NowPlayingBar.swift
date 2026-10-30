import SwiftUI

@MainActor
struct NowPlayingBar: View {
    @Environment(AudioPlayer.self) private var player
    /// Slider position while the user drags it; nil otherwise.
    @State private var scrubPosition: Double?

    var body: some View {
        if let track = player.currentTrack {
            VStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.headline)
                        .lineLimit(1)
                    if let artist = track.artist {
                        Text(artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)

                scrubber
                controls
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private var scrubber: some View {
        let upperBound = max(player.duration, 1)
        let position = min(scrubPosition ?? player.currentTime, upperBound)
        return HStack(spacing: 8) {
            Text(position.clockString)
            Slider(
                value: Binding(get: { position }, set: { scrubPosition = $0 }),
                in: 0...upperBound,
                onEditingChanged: { editing in
                    if !editing, let scrubPosition {
                        player.seek(to: scrubPosition)
                        self.scrubPosition = nil
                    }
                }
            )
            .accessibilityLabel("Position")
            .accessibilityValue("\(position.clockString) of \(player.duration.clockString)")
            Text(player.duration.clockString)
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }

    private var controls: some View {
        HStack {
            Button {
                player.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
            }
            .foregroundStyle(player.isShuffled ? Color.accentColor : Color.secondary)
            .accessibilityLabel("Shuffle")
            .accessibilityValue(player.isShuffled ? "On" : "Off")

            Spacer()

            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
            }
            .accessibilityLabel("Previous")

            Spacer()

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.largeTitle)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Spacer()

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
            }
            .accessibilityLabel("Next")

            Spacer()

            Button {
                player.repeatAll.toggle()
            } label: {
                Image(systemName: "repeat")
            }
            .foregroundStyle(player.repeatAll ? Color.accentColor : Color.secondary)
            .accessibilityLabel("Repeat All")
            .accessibilityValue(player.repeatAll ? "On" : "Off")
        }
        .font(.title2)
        .buttonStyle(.borderless)
        .frame(maxWidth: 420)
    }
}
