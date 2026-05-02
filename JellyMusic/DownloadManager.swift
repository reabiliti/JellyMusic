import Foundation

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    @Published private(set) var downloadedTracks: [DownloadedTrack] = []
    @Published private(set) var activeDownloads: Set<String> = []
    @Published var lastError: String?
    @Published private(set) var downloadQueue: [DownloadQueueItem] = []
    @Published private(set) var diagnosticEvents: [DiagnosticEvent] = []

    private var clientProvider: (() -> JellyfinClient?)?
    private var albumNamesByTrackId: [String: String] = [:]
    private var albumIdsByTrackId: [String: String] = [:]

    private let libraryStore = LocalLibraryStore()

    override init() {
        super.init()
        downloadedTracks = libraryStore.load()
    }

    func configure(clientProvider: @escaping () -> JellyfinClient?) {
        self.clientProvider = clientProvider
    }

    func localURL(for item: JellyfinItem) -> URL? {
        downloadedTracks.lazy
            .filter { $0.id == item.id }
            .filter { ($0.storageReason ?? .offline) == .offline }
            .filter { $0.localFileName.hasSuffix(".audio") == false }
            .compactMap { downloaded -> URL? in
                let url = self.libraryStore.audioDirectory.appending(path: downloaded.localFileName)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
            .first
    }

    func isExplicitlyDownloaded(_ item: JellyfinItem) -> Bool {
        guard let downloaded = downloadedTracks.first(where: { $0.id == item.id }) else { return false }
        guard (downloaded.storageReason ?? .offline) == .offline else { return false }
        return localURL(for: item) != nil
    }

    func offlineAlbums() -> [OfflineAlbum] {
        let playableTracks = downloadedTracks.filter { track in
            (track.storageReason ?? .offline) == .offline &&
                track.localFileName.hasSuffix(".audio") == false &&
                FileManager.default.fileExists(atPath: libraryStore.audioDirectory.appending(path: track.localFileName).path)
        }
        let grouped = Dictionary(grouping: playableTracks) { track in
            canonicalAlbumKey(for: track, in: playableTracks)
        }

        return grouped.map { key, tracks in
            let sortedTracks = tracks.sorted {
                ($0.parentIndexNumber ?? 0, $0.indexNumber ?? 0, $0.name) <
                    ($1.parentIndexNumber ?? 0, $1.indexNumber ?? 0, $1.name)
            }
            let first = sortedTracks[0]
            return OfflineAlbum(
                id: key,
                title: first.album ?? "Unknown Album",
                artist: first.artist,
                tracks: sortedTracks
            )
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func download(_ item: JellyfinItem) {
        guard isExplicitlyDownloaded(item) == false,
              let client = clientProvider?(),
              activeDownloads.contains(item.id) == false else { return }
        lastError = nil
        activeDownloads.insert(item.id)
        recordDiagnostic("Queued download: \(item.name)")
        Task {
            do {
                upsertQueueItem(for: item, status: .queued, progress: 0, error: nil)
                let file = try await client.downloadFile(for: item) { [weak self] progress in
                    Task { @MainActor in
                        self?.upsertQueueItem(for: item, status: .downloading, progress: progress, error: nil)
                    }
                }
                finishDownload(downloadedFile: file, item: item, reason: .offline)
                upsertQueueItem(for: item, status: .finished, progress: 1, error: nil)
                recordDiagnostic("Download finished: \(item.name)")
            } catch {
                activeDownloads.remove(item.id)
                albumNamesByTrackId.removeValue(forKey: item.id)
                albumIdsByTrackId.removeValue(forKey: item.id)
                lastError = error.localizedDescription
                upsertQueueItem(for: item, status: .failed, progress: 0, error: error.localizedDescription)
                recordDiagnostic("Download failed: \(item.name) - \(error.localizedDescription)")
                print("Download failed: \(error)")
            }
        }
    }

    func downloadAlbum(_ tracks: [JellyfinItem]) {
        for track in tracks {
            download(track)
        }
    }

    func downloadAlbum(_ album: JellyfinItem, tracks: [JellyfinItem]) {
        for track in tracks {
            albumNamesByTrackId[track.id] = album.name
            albumIdsByTrackId[track.id] = album.id
            download(track)
        }
    }

    func removeTrack(_ track: DownloadedTrack) {
        libraryStore.removeFile(for: track)
        downloadedTracks.removeAll { $0.id == track.id }
        libraryStore.save(downloadedTracks)
        recordDiagnostic("Removed offline track: \(track.name)")
    }

    func removeAllOfflineDownloads() {
        let offlineTracks = downloadedTracks.filter { ($0.storageReason ?? .offline) == .offline }
        for track in offlineTracks {
            libraryStore.removeFile(for: track)
        }
        downloadedTracks.removeAll { ($0.storageReason ?? .offline) == .offline }
        libraryStore.save(downloadedTracks)
        recordDiagnostic("Removed all offline downloads")
    }

    func removeAlbum(_ album: OfflineAlbum) {
        for track in album.tracks {
            libraryStore.removeFile(for: track)
            downloadedTracks.removeAll { $0.id == track.id }
        }
        libraryStore.save(downloadedTracks)
        recordDiagnostic("Removed offline album: \(album.title)")
    }

    var hasOfflineDownloads: Bool {
        downloadedTracks.contains { track in
            (track.storageReason ?? .offline) == .offline &&
                FileManager.default.fileExists(atPath: libraryStore.audioDirectory.appending(path: track.localFileName).path)
        }
    }

    func clearFinishedQueueItems() {
        downloadQueue.removeAll { $0.status == .finished }
    }

    private func finishDownload(downloadedFile: JellyfinDownloadedFile, item: JellyfinItem, reason: StorageReason) {
        let fileName = "\(item.id).\(fileExtension(for: downloadedFile))"
        let destination = libraryStore.audioDirectory.appending(path: fileName)

        do {
            try libraryStore.prepareAudioDirectory()
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: downloadedFile.location, to: destination)

            let downloaded = DownloadedTrack(
                id: item.id,
                name: item.name,
                artist: item.displayArtist,
                albumId: resolvedAlbumId(for: item),
                album: resolvedAlbumName(for: item),
                indexNumber: item.indexNumber,
                parentIndexNumber: item.parentIndexNumber,
                runTimeTicks: item.runTimeTicks,
                albumPrimaryImageTag: item.albumPrimaryImageTag,
                localFileName: fileName,
                downloadedAt: Date(),
                storageReason: reason
            )

            downloadedTracks.removeAll { $0.id == item.id }
            downloadedTracks.append(downloaded)
            libraryStore.save(downloadedTracks)
            activeDownloads.remove(item.id)
            albumNamesByTrackId.removeValue(forKey: item.id)
            albumIdsByTrackId.removeValue(forKey: item.id)
        } catch {
            print("Download finalization failed: \(error)")
            activeDownloads.remove(item.id)
            lastError = error.localizedDescription
            recordDiagnostic("Download finalization failed: \(item.name) - \(error.localizedDescription)")
        }
    }

    private func fileExtension(for file: JellyfinDownloadedFile) -> String {
        if let suggested = file.suggestedFileName {
            let ext = URL(fileURLWithPath: suggested).pathExtension.lowercased()
            if ext.isEmpty == false {
                return normalizedExtension(ext)
            }
        }

        let mimeType = file.mimeType?.lowercased().components(separatedBy: ";").first ?? ""
        switch mimeType {
        case "audio/mpeg":
            return "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/aac":
            return "m4a"
        case "audio/flac", "audio/x-flac":
            return "flac"
        case "audio/wav", "audio/x-wav":
            return "wav"
        case "audio/ogg":
            return "ogg"
        case "audio/opus":
            return "opus"
        default:
            return "m4a"
        }
    }

    private func normalizedExtension(_ ext: String) -> String {
        switch ext {
        case "mpeg":
            "mp3"
        case "aac":
            "m4a"
        default:
            ext
        }
    }

    private func resolvedAlbumId(for item: JellyfinItem) -> String? {
        if let albumId = albumIdsByTrackId[item.id] ?? item.albumId {
            return albumId
        }

        return downloadedTracks.first { downloaded in
            downloaded.id != item.id &&
                downloaded.albumId != nil &&
                downloaded.album == item.album &&
                downloaded.artist == item.displayArtist
        }?.albumId
    }

    private func resolvedAlbumName(for item: JellyfinItem) -> String? {
        if let albumName = albumNamesByTrackId[item.id] ?? item.album {
            return albumName
        }

        return downloadedTracks.first { downloaded in
            downloaded.id != item.id &&
                downloaded.albumId == item.albumId &&
                downloaded.artist == item.displayArtist
        }?.album
    }

    private func canonicalAlbumKey(for track: DownloadedTrack, in tracks: [DownloadedTrack]) -> String {
        if let albumId = track.albumId {
            return albumId
        }

        if let matchedAlbumId = tracks.first(where: { candidate in
            candidate.albumId != nil &&
                candidate.album == track.album &&
                candidate.artist == track.artist
        })?.albumId {
            return matchedAlbumId
        }

        return [track.album, track.artist]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.isEmpty == false }
            .joined(separator: "#")
    }

    private func upsertQueueItem(
        for item: JellyfinItem,
        status: DownloadQueueStatus,
        progress: Double,
        error: String?
    ) {
        let queueItem = DownloadQueueItem(
            id: item.id,
            title: item.name,
            subtitle: item.displayArtist,
            progress: progress,
            status: status,
            errorMessage: error
        )

        if let index = downloadQueue.firstIndex(where: { $0.id == item.id }) {
            downloadQueue[index] = queueItem
        } else {
            downloadQueue.insert(queueItem, at: 0)
        }
    }

    private func recordDiagnostic(_ message: String) {
        diagnosticEvents.insert(DiagnosticEvent(date: Date(), source: "Downloads", message: message), at: 0)
        diagnosticEvents = Array(diagnosticEvents.prefix(40))
    }
}
