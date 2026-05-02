import Foundation

final class LocalLibraryStore {
    private let fileManager = FileManager.default

    var audioDirectory: URL {
        documentsDirectory.appending(path: "OfflineAudio", directoryHint: .isDirectory)
    }

    private var databaseURL: URL {
        documentsDirectory.appending(path: "offline-library.json")
    }

    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func load() -> [DownloadedTrack] {
        guard let data = try? Data(contentsOf: databaseURL) else { return [] }
        return (try? JSONDecoder().decode([DownloadedTrack].self, from: data)) ?? []
    }

    func save(_ tracks: [DownloadedTrack]) {
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        try? data.write(to: databaseURL, options: .atomic)
    }

    func prepareAudioDirectory() throws {
        try fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
    }

    func removeFile(for track: DownloadedTrack) {
        let url = audioDirectory.appending(path: track.localFileName)
        try? fileManager.removeItem(at: url)
    }
}
