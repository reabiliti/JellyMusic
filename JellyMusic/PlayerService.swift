import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

@MainActor
final class PlayerService: ObservableObject {
    @Published private(set) var currentTrack: JellyfinItem?
    @Published private(set) var isPlaying = false
    @Published private(set) var queue: [JellyfinItem] = []
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isBuffering = false
    @Published private(set) var isShuffleEnabled = false
    @Published private(set) var repeatMode: RepeatMode = .off
    @Published private(set) var diagnosticEvents: [DiagnosticEvent] = []
    @Published var playbackError: String?

    private let player = AVQueuePlayer()
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let equalizer = AVAudioUnitEQ(numberOfBands: EqualizerPreset.bands.count)
    private var playerItems: [String: AVPlayerItem] = [:]
    private var sourceProvider: ((JellyfinItem) async throws -> PlaybackSource)?
    private var timeObserver: Any?
    private var progressTask: Task<Void, Never>?
    private var playbackMode = PlaybackMode.remote
    private var isEngineConfigured = false
    private var currentSourceURL: URL?
    private var currentLocalFile: AVAudioFile?
    private var localStartFrame: AVAudioFramePosition = 0
    private var localCurrentFrame: AVAudioFramePosition = 0
    private var localScheduleToken = UUID()
    private var currentQueueIndex = 0
    private var artworkProvider: ((JellyfinItem) async -> Data?)?
    private var artworkTask: Task<Void, Never>?
    private var remoteCommandsConfigured = false
    private var itemEndObservers: [NSObjectProtocol] = []
    private let savedPlaybackStateKey = "savedPlaybackState"

    private enum PlaybackMode {
        case remote
        case local
    }

    private struct SavedPlaybackState: Codable {
        var trackId: String
        var queueIds: [String]
        var elapsedTime: TimeInterval
    }

    func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            configureEngineIfNeeded()
            configureRemoteCommands()
        } catch {
            print("Audio session error: \(error)")
        }
    }

    func setSourceProvider(_ provider: @escaping (JellyfinItem) async throws -> PlaybackSource) {
        sourceProvider = provider
    }

    func setArtworkProvider(_ provider: @escaping (JellyfinItem) async -> Data?) {
        artworkProvider = provider
    }

    func setEqualizerPreset(_ preset: EqualizerPreset) {
        configureEngineIfNeeded()
        for (index, gain) in preset.gains.enumerated() where index < equalizer.bands.count {
            let band = equalizer.bands[index]
            band.filterType = .parametric
            band.frequency = Float(EqualizerPreset.bandFrequencies[index])
            band.bandwidth = 1.0
            band.gain = Float(gain)
            band.bypass = false
        }
        recordDiagnostic("Equalizer preset: \(preset.name)")
    }

    func stopPlayback(deactivateSession: Bool = false) {
        savePlaybackState()
        artworkTask?.cancel()
        artworkTask = nil
        progressTask?.cancel()
        progressTask = nil

        stopRemotePlayback()
        stopLocalPlayback()
        engine.stop()

        currentTrack = nil
        isPlaying = false
        isBuffering = false
        playbackError = nil
        elapsedTime = 0
        duration = 0
        currentQueueIndex = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        recordDiagnostic("Playback stopped")

        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func play(_ tracks: [JellyfinItem], startingAt selected: JellyfinItem) async {
        guard sourceProvider != nil else { return }
        playbackError = nil
        isBuffering = true
        queue = tracks
        currentQueueIndex = tracks.firstIndex(of: selected) ?? 0

        do {
            let source = try await sourceProvider?(selected)
            switch source {
            case .local(let url):
                recordDiagnostic("Starting offline playback: \(selected.name)")
                playLocal(tracks, startingAt: selected, url: url)
            case .remote, .none:
                recordDiagnostic("Starting streaming playback: \(selected.name)")
                await playRemote(tracks, startingAt: selected)
            }
        } catch {
            playbackError = "Unable to prepare \(selected.name)"
            recordDiagnostic("Prepare failed: \(selected.name) - \(error.localizedDescription)")
            isBuffering = false
            print("Unable to prepare \(selected.name): \(error)")
        }
    }

    func playQueuedTrack(_ track: JellyfinItem) async {
        guard queue.contains(track) else { return }
        await play(queue, startingAt: track)
    }

    func togglePlayPause() {
        if isPlaying {
            pauseCurrent()
        } else {
            resumeCurrent()
        }
        isPlaying.toggle()
        updatePlaybackRate()
        recordDiagnostic(isPlaying ? "Playback resumed" : "Playback paused")
    }

    func next() {
        guard queue.isEmpty == false else { return }
        guard let nextIndex = PlaybackQueuePolicy.nextIndex(
            queueCount: queue.count,
            currentIndex: currentQueueIndex,
            repeatMode: repeatMode,
            shuffle: isShuffleEnabled,
            automatic: false
        ) else { return }
        let nextTrack = queue[nextIndex]
        Task { await play(queue, startingAt: nextTrack) }
    }

    func previous() {
        guard queue.isEmpty == false else { return }
        if elapsedTime > 3 {
            seek(toProgress: 0)
            return
        }

        guard let previousIndex = PlaybackQueuePolicy.previousIndex(queueCount: queue.count, currentIndex: currentQueueIndex) else { return }
        let previousTrack = queue[previousIndex]
        Task { await play(queue, startingAt: previousTrack) }
    }

    func toggleShuffle() {
        isShuffleEnabled.toggle()
        recordDiagnostic(isShuffleEnabled ? "Shuffle enabled" : "Shuffle disabled")
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off:
            repeatMode = .all
        case .all:
            repeatMode = .one
        case .one:
            repeatMode = .off
        }
        recordDiagnostic("Repeat mode: \(repeatMode.rawValue)")
    }

    func seek(toProgress progress: Double) {
        guard duration > 0 else { return }
        let target = duration * min(max(progress, 0), 1)

        switch playbackMode {
        case .remote:
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] _ in
                Task { @MainActor in
                    self?.elapsedTime = target
                    self?.updatePlaybackRate()
                    self?.savePlaybackState()
                }
            }
        case .local:
            seekLocal(to: target)
            elapsedTime = target
            updatePlaybackRate()
            savePlaybackState()
        }
    }

    var remainingTime: TimeInterval {
        max(duration - elapsedTime, 0)
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(elapsedTime / duration, 0), 1)
    }

    var upcomingTracks: [JellyfinItem] {
        guard queue.indices.contains(currentQueueIndex + 1) else { return [] }
        return Array(queue[(currentQueueIndex + 1)...])
    }

    func refreshTrackMetadata(_ track: JellyfinItem) {
        if currentTrack?.id == track.id {
            currentTrack = track
        }
        queue = queue.map { $0.id == track.id ? track : $0 }
        savePlaybackState()
    }

    func restoreLastPlayback(availableTracks: [JellyfinItem]) async {
        guard currentTrack == nil,
              let data = UserDefaults.standard.data(forKey: savedPlaybackStateKey),
              let state = try? JSONDecoder().decode(SavedPlaybackState.self, from: data) else { return }

        var tracksById: [String: JellyfinItem] = [:]
        for track in availableTracks {
            tracksById[track.id] = track
        }

        guard let selected = tracksById[state.trackId] else { return }
        let restoredQueue = state.queueIds.compactMap { tracksById[$0] }
        let queue = restoredQueue.isEmpty ? [selected] : restoredQueue

        do {
            let source = try await sourceProvider?(selected)
            switch source {
            case .local(let url):
                recordDiagnostic("Restored offline playback: \(selected.name)")
                playLocal(queue, startingAt: selected, url: url, autoPlay: false, startTime: state.elapsedTime)
            case .remote, .none:
                recordDiagnostic("Restored streaming playback: \(selected.name)")
                await playRemote(queue, startingAt: selected, autoPlay: false, startTime: state.elapsedTime)
            }
        } catch {
            playbackError = "Unable to restore \(selected.name)"
            recordDiagnostic("Restore failed: \(selected.name) - \(error.localizedDescription)")
            isBuffering = false
            print("Unable to restore \(selected.name): \(error)")
        }
    }

    private func configureRemoteCommands() {
        guard remoteCommandsConfigured == false else { return }
        remoteCommandsConfigured = true

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.stopCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true

        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.resumeCurrent()
                self?.isPlaying = true
                self?.updatePlaybackRate()
            }
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.pauseCurrent()
                self?.isPlaying = false
                self?.updatePlaybackRate()
            }
            return .success
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        commandCenter.stopCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.stopPlayback(deactivateSession: true) }
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }

            Task { @MainActor in
                self?.seek(toTime: event.positionTime)
            }
            return .success
        }
    }

    private func playRemote(
        _ tracks: [JellyfinItem],
        startingAt selected: JellyfinItem,
        autoPlay: Bool = true,
        startTime: TimeInterval = 0
    ) async {
        guard let sourceProvider else { return }
        playbackMode = .remote
        stopLocalPlayback()
        player.removeAllItems()
        playerItems.removeAll()
        removeItemEndObservers()

        do {
            let source = try await sourceProvider(selected)
            let url: URL
            switch source {
            case .remote(let remoteURL), .local(let remoteURL):
                url = remoteURL
            }
            let item = AVPlayerItem(url: url)
            playerItems[selected.id] = item
            player.insert(item, after: nil)
            observeRemoteItemEvents(item, trackID: selected.id)
        } catch {
            playbackError = "Unable to prepare \(selected.name)"
            recordDiagnostic("Remote prepare failed: \(selected.name) - \(error.localizedDescription)")
            isBuffering = false
            print("Unable to prepare \(selected.name): \(error)")
            return
        }

        currentTrack = selected
        queue = tracks
        currentQueueIndex = tracks.firstIndex(of: selected) ?? 0
        elapsedTime = max(startTime, 0)
        refreshDuration()
        updateNowPlaying(for: selected)
        startRemoteProgressObserver()
        if startTime > 0 {
            await player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
        }
        if autoPlay {
            player.play()
        } else {
            player.pause()
        }
        isPlaying = autoPlay
        isBuffering = autoPlay
        savePlaybackState()
    }

    private func playLocal(
        _ tracks: [JellyfinItem],
        startingAt track: JellyfinItem,
        url: URL,
        autoPlay: Bool = true,
        startTime: TimeInterval = 0
    ) {
        playbackMode = .local
        stopRemotePlayback()
        configureEngineIfNeeded()

        do {
            let file = try AVAudioFile(forReading: url)
            currentTrack = track
            queue = tracks
            currentQueueIndex = tracks.firstIndex(of: track) ?? 0
            currentSourceURL = url
            currentLocalFile = file
            localStartFrame = min(max(AVAudioFramePosition(startTime * file.processingFormat.sampleRate), 0), file.length)
            localCurrentFrame = localStartFrame
            duration = Double(file.length) / file.processingFormat.sampleRate
            elapsedTime = min(max(startTime, 0), duration)
            scheduleLocalFile(file, startingFrame: localStartFrame, trackID: track.id)
            try engine.start()
            if autoPlay {
                playerNode.play()
            }
            isPlaying = autoPlay
            isBuffering = false
            playbackError = nil
            updateNowPlaying(for: track)
            startLocalProgressObserver()
            savePlaybackState()
        } catch {
            playbackError = "Unable to play \(track.name)"
            recordDiagnostic("Offline playback failed: \(track.name) - \(error.localizedDescription)")
            isBuffering = false
            print("Unable to play local file: \(error)")
        }
    }

    private func scheduleLocalFile(_ file: AVAudioFile, startingFrame: AVAudioFramePosition, trackID: String) {
        localScheduleToken = UUID()
        let scheduleToken = localScheduleToken
        playerNode.stop()
        let remainingFrames = AVAudioFrameCount(max(file.length - startingFrame, 0))
        file.framePosition = startingFrame
        playerNode.scheduleSegment(
            file,
            startingFrame: startingFrame,
            frameCount: remainingFrames,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      self.playbackMode == .local,
                      self.localScheduleToken == scheduleToken,
                      self.currentTrack?.id == trackID else { return }
                self.advanceAfterCurrentTrackFinished()
            }
        }
    }

    private func seekLocal(to seconds: TimeInterval) {
        guard let file = currentLocalFile else { return }
        let targetFrame = AVAudioFramePosition(seconds * file.processingFormat.sampleRate)
        localStartFrame = min(max(targetFrame, 0), file.length)
        localCurrentFrame = localStartFrame
        scheduleLocalFile(file, startingFrame: localStartFrame, trackID: currentTrack?.id ?? "")
        if isPlaying {
            playerNode.play()
        }
    }

    private func seek(toTime time: TimeInterval) {
        guard duration > 0 else { return }
        let target = min(max(time, 0), duration)

        switch playbackMode {
        case .remote:
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] _ in
                Task { @MainActor in
                    self?.elapsedTime = target
                    self?.updatePlaybackRate()
                    self?.savePlaybackState()
                }
            }
        case .local:
            seekLocal(to: target)
            elapsedTime = target
            updatePlaybackRate()
            savePlaybackState()
        }
    }

    private func updateNowPlaying(for track: JellyfinItem) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: track.name,
            MPMediaItemPropertyArtist: track.displayArtist,
            MPMediaItemPropertyAlbumTitle: track.album ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            await self?.updateNowPlayingArtwork(for: track)
        }
    }

    private func updatePlaybackRate() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        savePlaybackState()
    }

    private func savePlaybackState() {
        guard let currentTrack else { return }
        let state = SavedPlaybackState(
            trackId: currentTrack.id,
            queueIds: queue.map(\.id),
            elapsedTime: elapsedTime
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: savedPlaybackStateKey)
        }
    }

    private func updateNowPlayingArtwork(for track: JellyfinItem) async {
        guard let artworkProvider,
              let data = await artworkProvider(track),
              Task.isCancelled == false,
              let image = UIImage(data: data) else { return }

        await MainActor.run {
            guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo,
                  self.currentTrack?.id == track.id else { return }
            info[MPMediaItemPropertyArtwork] = Self.makeArtwork(from: image)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    nonisolated private static func makeArtwork(from image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in
            image
        }
    }

    private func observeRemoteItemEvents(_ item: AVPlayerItem, trackID: String) {
        let endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleRemoteItemFinished(trackID: trackID)
            }
        }
        itemEndObservers.append(endObserver)

        let failedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in
                self?.handleRemoteItemFailed(trackID: trackID, error: error)
            }
        }
        itemEndObservers.append(failedObserver)

        let stalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleRemoteItemStalled(trackID: trackID)
            }
        }
        itemEndObservers.append(stalledObserver)
    }

    private func handleRemoteItemFinished(trackID: String) {
        guard playbackMode == .remote,
              queue.indices.contains(currentQueueIndex),
              queue[currentQueueIndex].id == trackID else { return }

        advanceAfterCurrentTrackFinished()
    }

    private func advanceAfterCurrentTrackFinished() {
        guard let nextIndex = PlaybackQueuePolicy.nextIndex(
            queueCount: queue.count,
            currentIndex: currentQueueIndex,
            repeatMode: repeatMode,
            shuffle: isShuffleEnabled,
            automatic: true
        ) else {
            elapsedTime = duration
            isPlaying = false
            updatePlaybackRate()
            return
        }

        Task { await play(queue, startingAt: queue[nextIndex]) }
    }

    private func handleRemoteItemFailed(trackID: String, error: Error?) {
        guard playbackMode == .remote,
              queue.indices.contains(currentQueueIndex),
              queue[currentQueueIndex].id == trackID else { return }

        playbackError = "Unable to play \(queue[currentQueueIndex].name). Skipping."
        recordDiagnostic("Remote playback failed: \(queue[currentQueueIndex].name)")
        isBuffering = false

        let nextIndex = currentQueueIndex + 1
        guard queue.indices.contains(nextIndex) else {
            isPlaying = false
            updatePlaybackRate()
            print("Playback failed: \(error?.localizedDescription ?? "Unknown error")")
            return
        }

        Task { await play(queue, startingAt: queue[nextIndex]) }
        print("Playback failed: \(error?.localizedDescription ?? "Unknown error")")
    }

    private func handleRemoteItemStalled(trackID: String) {
        guard playbackMode == .remote,
              queue.indices.contains(currentQueueIndex),
              queue[currentQueueIndex].id == trackID else { return }
        isBuffering = true
        recordDiagnostic("Remote playback stalled: \(queue[currentQueueIndex].name)")
    }

    private func startRemoteProgressObserver() {
        progressTask?.cancel()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.elapsedTime = time.seconds.isFinite ? time.seconds : 0
                self?.refreshDuration()
                self?.isBuffering = self?.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                self?.updatePlaybackRate()
            }
        }
    }

    private func startLocalProgressObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(for: .milliseconds(500))
                await MainActor.run {
                    self?.refreshLocalProgress()
                    self?.updatePlaybackRate()
                }
            }
        }
    }

    private func refreshLocalProgress() {
        guard let file = currentLocalFile else { return }
        if let nodeTime = playerNode.lastRenderTime,
           let playerTime = playerNode.playerTime(forNodeTime: nodeTime) {
            localCurrentFrame = localStartFrame + AVAudioFramePosition(playerTime.sampleTime)
        }
        elapsedTime = min(Double(localCurrentFrame) / file.processingFormat.sampleRate, duration)
    }

    private func refreshDuration() {
        if playbackMode == .local, let file = currentLocalFile {
            duration = Double(file.length) / file.processingFormat.sampleRate
        } else if let seconds = player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 {
            duration = seconds
        } else if let runTimeTicks = currentTrack?.runTimeTicks {
            duration = TimeInterval(runTimeTicks / 10_000_000)
        } else {
            duration = 0
        }
    }

    private func pauseCurrent() {
        switch playbackMode {
        case .remote:
            player.pause()
        case .local:
            refreshLocalProgress()
            localStartFrame = localCurrentFrame
            playerNode.pause()
        }
    }

    private func resumeCurrent() {
        switch playbackMode {
        case .remote:
            player.play()
        case .local:
            if playerNode.isPlaying == false {
                playerNode.play()
            }
        }
    }

    private func stopRemotePlayback() {
        player.pause()
        player.removeAllItems()
        playerItems.removeAll()
        removeItemEndObservers()
        isBuffering = false
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func stopLocalPlayback() {
        localScheduleToken = UUID()
        playerNode.stop()
        progressTask?.cancel()
        progressTask = nil
        currentLocalFile = nil
        currentSourceURL = nil
        isBuffering = false
    }

    private func removeItemEndObservers() {
        for observer in itemEndObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        itemEndObservers.removeAll()
    }

    private func configureEngineIfNeeded() {
        guard isEngineConfigured == false else { return }
        engine.attach(playerNode)
        engine.attach(equalizer)
        engine.connect(playerNode, to: equalizer, format: nil)
        engine.connect(equalizer, to: engine.mainMixerNode, format: nil)
        isEngineConfigured = true
    }

    private func recordDiagnostic(_ message: String) {
        diagnosticEvents.insert(DiagnosticEvent(date: Date(), source: "Player", message: message), at: 0)
        diagnosticEvents = Array(diagnosticEvents.prefix(40))
    }
}
