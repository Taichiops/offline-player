import AVFoundation
import MediaPlayer
import Observation
import OSLog

/// Plays the library one track after another, keeps going in the background,
/// and drives the lock screen / Control Center controls.
@MainActor
@Observable
final class AudioPlayer {
    private(set) var tracks: [Track] = []
    /// Track IDs in playback order: the library order, or a shuffled copy when shuffle is on.
    /// Empty while nothing is loaded.
    private(set) var order: [Track.ID] = []
    /// Position of the current track in `order`.
    private(set) var currentIndex = 0
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isShuffled: Bool
    var repeatAll: Bool {
        didSet {
            defaults.set(repeatAll, forKey: Keys.repeatAll)
            refreshUpcoming()
        }
    }

    var currentTrack: Track? {
        guard order.indices.contains(currentIndex) else { return nil }
        return track(withID: order[currentIndex])
    }

    @ObservationIgnored private let queue = AVQueuePlayer()
    /// The queue item that plays `currentTrack`.
    @ObservationIgnored private weak var currentItem: QueueItem?
    /// Position to jump to once the current item is ready (used when restoring).
    @ObservationIgnored private var pendingSeek: Double?
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var hasRestored = false
    @ObservationIgnored private var lastSaveDate = Date.distantPast
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let logger = Logger(subsystem: "OfflinePlayer", category: "Player")

    private enum Keys {
        static let trackID = "lastTrackID"
        static let position = "lastPosition"
        static let repeatAll = "repeatAll"
        static let shuffle = "shuffle"
    }

    init() {
        isShuffled = UserDefaults.standard.bool(forKey: Keys.shuffle)
        repeatAll = UserDefaults.standard.object(forKey: Keys.repeatAll) as? Bool ?? true
        queue.actionAtItemEnd = .advance
        configureAudioSession()
        observeNotifications()
        observeTime()
        configureRemoteCommands()
    }

    // MARK: - Library

    /// Called with the library's tracks at launch and whenever the library changes.
    /// The first call restores the last track and position, paused.
    func setLibrary(_ newTracks: [Track]) {
        tracks = newTracks
        if !hasRestored {
            hasRestored = true
            restoreState()
        } else if !order.isEmpty {
            reconcileOrder()
        }
    }

    private func reconcileOrder() {
        let ids = Set(tracks.map(\.id))
        let oldOrder = order
        let oldCurrentID = oldOrder[currentIndex]

        if isShuffled {
            let known = Set(oldOrder)
            order = oldOrder.filter(ids.contains) + tracks.map(\.id).filter { !known.contains($0) }.shuffled()
        } else {
            order = tracks.map(\.id)
        }
        guard !order.isEmpty else {
            stop()
            return
        }

        if let index = order.firstIndex(of: oldCurrentID) {
            currentIndex = index
            refreshUpcoming()
            updateNowPlaying()
            return
        }

        // The current track was deleted: move on to the next one that still exists.
        let following = oldOrder[(currentIndex + 1)...] + oldOrder[..<currentIndex]
        let nextID = following.first(where: ids.contains)
        currentIndex = nextID.flatMap { order.firstIndex(of: $0) } ?? 0
        loadCurrent(autoplay: isPlaying)
    }

    private func makeOrder(startingWith id: Track.ID) -> [Track.ID] {
        let ids = tracks.map(\.id)
        guard isShuffled else { return ids }
        return [id] + ids.filter { $0 != id }.shuffled()
    }

    private func track(withID id: Track.ID) -> Track? {
        tracks.first { $0.id == id }
    }

    // MARK: - Controls

    func play(trackID: Track.ID) {
        guard track(withID: trackID) != nil else { return }
        order = makeOrder(startingWith: trackID)
        currentIndex = order.firstIndex(of: trackID) ?? 0
        loadCurrent(autoplay: true)
    }

    func play() {
        guard currentTrack != nil else {
            if let first = tracks.first { play(trackID: first.id) }
            return
        }
        activateAudioSession()
        queue.play()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        queue.pause()
        isPlaying = false
        saveState()
        updateNowPlaying()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func next() {
        guard !order.isEmpty else { return }
        currentIndex = (currentIndex + 1) % order.count
        loadCurrent(autoplay: isPlaying)
    }

    /// After 3 seconds, restarts the current track instead (the usual music-app behavior).
    func previous() {
        guard !order.isEmpty else { return }
        if currentTime > 3 || (currentIndex == 0 && !repeatAll) {
            seek(to: 0)
            return
        }
        currentIndex = (currentIndex - 1 + order.count) % order.count
        loadCurrent(autoplay: isPlaying)
    }

    func seek(to seconds: Double) {
        guard let currentItem else { return }
        let target = max(0, seconds)
        currentTime = target
        if currentItem.status == .readyToPlay {
            isSeeking = true
            let time = CMTime(seconds: target, preferredTimescale: 600)
            queue.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.isSeeking = false
                    self.updateNowPlaying()
                }
            }
        } else {
            pendingSeek = target
        }
        updateNowPlaying()
    }

    /// Shuffles the play order. The library order is left unchanged.
    func toggleShuffle() {
        isShuffled.toggle()
        defaults.set(isShuffled, forKey: Keys.shuffle)
        guard let currentID = currentTrack?.id else { return }
        order = makeOrder(startingWith: currentID)
        currentIndex = order.firstIndex(of: currentID) ?? 0
        refreshUpcoming()
    }

    // MARK: - Queue

    /// Replaces the queue with the current track (optionally at a position) plus the one after it.
    private func loadCurrent(at position: Double = 0, autoplay: Bool) {
        guard let track = currentTrack else {
            stop()
            return
        }
        queue.removeAllItems()
        let item = makeItem(for: track)
        queue.insert(item, after: nil)
        currentItem = item
        pendingSeek = position > 0 ? position : nil
        currentTime = position
        duration = track.duration ?? 0
        refreshUpcoming()
        if autoplay {
            play()
        } else {
            pause()
        }
    }

    private func stop() {
        queue.pause()
        queue.removeAllItems()
        currentItem = nil
        order = []
        currentIndex = 0
        isPlaying = false
        currentTime = 0
        duration = 0
        pendingSeek = nil
        saveState()
        updateNowPlaying()
    }

    private var upcomingTrackID: Track.ID? {
        guard !order.isEmpty else { return nil }
        if currentIndex + 1 < order.count { return order[currentIndex + 1] }
        return repeatAll ? order[0] : nil
    }

    /// Keeps exactly one item queued after the current one, so AVQueuePlayer moves on by itself,
    /// also while the screen is locked. With repeat-all on, the first track follows the last.
    private func refreshUpcoming() {
        guard let currentItem else { return }
        let items = queue.items()
        guard let position = items.firstIndex(where: { $0 === currentItem }) else { return }
        let expectedID = upcomingTrackID
        var hasExpected = false
        for (offset, item) in items[(position + 1)...].enumerated() {
            if offset == 0, let queued = item as? QueueItem, queued.trackID == expectedID {
                hasExpected = true
            } else {
                queue.remove(item)
            }
        }
        if !hasExpected, let expectedID, let track = track(withID: expectedID) {
            queue.insert(makeItem(for: track), after: currentItem)
        }
    }

    private func makeItem(for track: Track) -> QueueItem {
        let item = QueueItem(track: track)
        let itemID = ObjectIdentifier(item)
        item.statusObservation = item.observe(\.status) { [weak self] observed, _ in
            guard let self else { return }
            let status = observed.status
            Task { @MainActor in self.itemStatusChanged(itemID, to: status) }
        }
        return item
    }

    private func itemDidPlayToEnd(_ itemID: ObjectIdentifier) {
        guard let currentItem, ObjectIdentifier(currentItem) == itemID else { return }

        if currentIndex + 1 < order.count {
            currentIndex += 1
        } else if repeatAll {
            currentIndex = 0
        } else {
            // End of the list with repeat off: go back to the first track and stop there.
            currentIndex = 0
            loadCurrent(autoplay: false)
            return
        }

        // AVQueuePlayer has moved on to the item refreshUpcoming() queued. Adopt it if it is the right track.
        guard let upcoming = queue.items().first(where: { $0 !== currentItem }) as? QueueItem,
              upcoming.trackID == order[currentIndex] else {
            loadCurrent(autoplay: true)
            return
        }
        if upcoming.status == .failed {
            self.currentItem = upcoming
            skipFailedItem()
            return
        }
        self.currentItem = upcoming
        consecutiveFailures = 0
        pendingSeek = nil
        currentTime = 0
        duration = currentTrack?.duration ?? 0
        readDuration(from: upcoming)
        refreshUpcoming()
        updateNowPlaying()
        saveState()
    }

    private func itemStatusChanged(_ itemID: ObjectIdentifier, to status: AVPlayerItem.Status) {
        guard let currentItem, ObjectIdentifier(currentItem) == itemID else { return }
        switch status {
        case .readyToPlay:
            consecutiveFailures = 0
            readDuration(from: currentItem)
            if let pendingSeek {
                self.pendingSeek = nil
                seek(to: pendingSeek)
            }
            updateNowPlaying()
        case .failed:
            skipFailedItem()
        default:
            break
        }
    }

    /// Moves past a file that can't be played. Gives up after every track has failed once in a row.
    private func skipFailedItem() {
        logger.error("Skipping unplayable track: \(self.currentTrack?.fileName ?? "?", privacy: .public)")
        consecutiveFailures += 1
        guard consecutiveFailures < order.count else {
            consecutiveFailures = 0
            pause()
            return
        }
        currentIndex = (currentIndex + 1) % order.count
        loadCurrent(autoplay: isPlaying)
    }

    private func readDuration(from item: AVPlayerItem) {
        let seconds = item.duration.seconds
        if seconds.isFinite, seconds > 0, seconds != duration {
            duration = seconds
            updateNowPlaying()
        }
    }

    // MARK: - Time and saved state

    private func observeTime() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = queue.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            MainActor.assumeIsolated { self?.tick(seconds) }
        }
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, !isSeeking, pendingSeek == nil else { return }
        currentTime = seconds
        if let currentItem { readDuration(from: currentItem) }
        if isPlaying, Date().timeIntervalSince(lastSaveDate) >= 5 {
            saveState()
        }
    }

    /// Saves the current track and position. Also called when the app goes to the background.
    func saveState() {
        lastSaveDate = Date()
        if let track = currentTrack {
            defaults.set(track.id.uuidString, forKey: Keys.trackID)
            defaults.set(pendingSeek ?? currentTime, forKey: Keys.position)
        } else {
            defaults.removeObject(forKey: Keys.trackID)
            defaults.removeObject(forKey: Keys.position)
        }
    }

    private func restoreState() {
        guard let savedID = defaults.string(forKey: Keys.trackID).flatMap(UUID.init(uuidString:)),
              track(withID: savedID) != nil else { return }
        order = makeOrder(startingWith: savedID)
        currentIndex = order.firstIndex(of: savedID) ?? 0
        loadCurrent(at: defaults.double(forKey: Keys.position), autoplay: false)
    }

    // MARK: - Audio session

    private func configureAudioSession() {
        do {
            // .playback keeps audio going when the screen locks (together with the "audio" background mode).
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        } catch {
            logger.error("Audio session category failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Activated on play rather than at launch, so opening the app doesn't stop other apps' audio.
    private func activateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            logger.error("Audio session activation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func observeNotifications() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
                guard let item = note.object as? AVPlayerItem else { return }
                let itemID = ObjectIdentifier(item)
                MainActor.assumeIsolated { self?.itemDidPlayToEnd(itemID) }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
                guard let item = note.object as? AVPlayerItem else { return }
                let itemID = ObjectIdentifier(item)
                MainActor.assumeIsolated { self?.itemStatusChanged(itemID, to: .failed) }
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
                let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
                MainActor.assumeIsolated { self?.handleInterruption(type: type, options: options) }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
                let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                MainActor.assumeIsolated { self?.handleRouteChange(reason: reason) }
            },
        ]
    }

    /// Pauses for calls and Siri. Resumes afterwards only if the system says so.
    private func handleInterruption(type rawType: UInt?, options rawOptions: UInt?) {
        guard let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            resumeAfterInterruption = isPlaying
            if isPlaying { pause() }
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions ?? 0)
            if resumeAfterInterruption && options.contains(.shouldResume) {
                play()
            }
            resumeAfterInterruption = false
        @unknown default:
            break
        }
    }

    /// Pauses when headphones are unplugged or Bluetooth disconnects.
    private func handleRouteChange(reason rawReason: UInt?) {
        guard let rawReason,
              AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable,
              isPlaying else { return }
        pause()
    }

    // MARK: - Lock screen and Control Center

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        onRemoteCommand(center.playCommand) { $0.play() }
        onRemoteCommand(center.pauseCommand) { $0.pause() }
        onRemoteCommand(center.togglePlayPauseCommand) { $0.togglePlayPause() }
        onRemoteCommand(center.nextTrackCommand) { $0.next() }
        onRemoteCommand(center.previousTrackCommand) { $0.previous() }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self.seek(to: position) }
            return .success
        }
    }

    private func onRemoteCommand(_ command: MPRemoteCommand, perform action: @escaping @MainActor @Sendable (AudioPlayer) -> Void) {
        command.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in action(self) }
            return .success
        }
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let track = currentTrack else {
            center.nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artist = track.artist {
            info[MPMediaItemPropertyArtist] = artist
        }
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        center.nowPlayingInfo = info
    }
}

/// An AVPlayerItem that remembers which track it plays.
private final class QueueItem: AVPlayerItem {
    let trackID: Track.ID
    var statusObservation: NSKeyValueObservation?

    init(track: Track) {
        trackID = track.id
        super.init(asset: AVURLAsset(url: track.url), automaticallyLoadedAssetKeys: nil)
    }
}
