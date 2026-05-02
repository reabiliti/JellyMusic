import Foundation

struct JellyfinCredentials: Codable, Equatable {
    var serverURL: URL
    var userId: String
    var accessToken: String
    var username: String
}

struct ServerProfile: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var kind: MediaServerKind
    var credentials: JellyfinCredentials

    var subtitle: String {
        credentials.serverURL.absoluteString
    }
}

enum MediaServerKind: String, Codable, CaseIterable, Identifiable {
    case jellyfin = "Jellyfin"

    var id: String { rawValue }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }
}

enum RepeatMode: String, CaseIterable, Identifiable {
    case off = "Off"
    case one = "One"
    case all = "All"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .off:
            "repeat"
        case .one:
            "repeat.1"
        case .all:
            "repeat"
        }
    }
}

struct EqualizerPreset: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var gains: [Double]

    static let bands = ["60", "170", "310", "600", "1k", "3k", "6k", "12k", "14k", "16k"]
    static let bandFrequencies: [Double] = [60, 170, 310, 600, 1_000, 3_000, 6_000, 12_000, 14_000, 16_000]

    static let presets: [EqualizerPreset] = [
        EqualizerPreset(name: "Flat", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        EqualizerPreset(name: "Rock", gains: [4, 3, -1, -2, 0, 2, 4, 5, 5, 4]),
        EqualizerPreset(name: "Pop", gains: [-1, 2, 4, 4, 1, -1, -1, 2, 3, 3]),
        EqualizerPreset(name: "Hip-Hop", gains: [5, 4, 2, 0, -1, 1, 2, 3, 4, 4]),
        EqualizerPreset(name: "Electronic", gains: [4, 3, 1, 0, -1, 1, 2, 4, 5, 5]),
        EqualizerPreset(name: "Jazz", gains: [3, 2, 1, 2, -1, -1, 0, 2, 3, 4]),
        EqualizerPreset(name: "Classical", gains: [3, 2, 0, 0, -1, -1, 0, 2, 3, 4]),
        EqualizerPreset(name: "Acoustic", gains: [3, 2, 1, 1, 0, 2, 3, 4, 3, 2]),
        EqualizerPreset(name: "Vocal", gains: [-2, -1, 0, 2, 4, 4, 3, 1, 0, -1]),
        EqualizerPreset(name: "Bass Boost", gains: [6, 5, 4, 2, 0, -1, -2, -2, -1, 0])
    ]
}

struct AuthRequest: Encodable {
    var username: String
    var pw: String
}

struct AuthResponse: Decodable {
    var accessToken: String
    var user: JellyfinUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "AccessToken"
        case user = "User"
    }
}

struct JellyfinUser: Decodable {
    var id: String
    var name: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
    }
}

struct JellyfinItemsResponse: Decodable {
    var items: [JellyfinItem]

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

struct JellyfinItem: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var type: String
    var albumId: String?
    var albumArtist: String?
    var album: String?
    var artists: [String]?
    var indexNumber: Int?
    var parentIndexNumber: Int?
    var runTimeTicks: Int64?
    var imageTags: [String: String]?
    var albumPrimaryImageTag: String?
    var userData: JellyfinUserData?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case albumId = "AlbumId"
        case albumArtist = "AlbumArtist"
        case album = "Album"
        case artists = "Artists"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case runTimeTicks = "RunTimeTicks"
        case imageTags = "ImageTags"
        case albumPrimaryImageTag = "AlbumPrimaryImageTag"
        case userData = "UserData"
    }

    var displayArtist: String {
        albumArtist ?? artists?.joined(separator: ", ") ?? "Unknown Artist"
    }

    var durationText: String {
        guard let runTimeTicks else { return "" }
        let seconds = Int(runTimeTicks / 10_000_000)
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

struct JellyfinUserData: Codable, Hashable {
    var isFavorite: Bool?

    enum CodingKeys: String, CodingKey {
        case isFavorite = "IsFavorite"
    }
}

struct DownloadedTrack: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var artist: String
    var albumId: String?
    var album: String?
    var indexNumber: Int?
    var parentIndexNumber: Int?
    var runTimeTicks: Int64?
    var albumPrimaryImageTag: String?
    var localFileName: String
    var downloadedAt: Date
    var storageReason: StorageReason?

    var asJellyfinItem: JellyfinItem {
        JellyfinItem(
            id: id,
            name: name,
            type: "Audio",
            albumId: albumId,
            albumArtist: artist,
            album: album,
            artists: [artist],
            indexNumber: indexNumber,
            parentIndexNumber: parentIndexNumber,
            runTimeTicks: runTimeTicks,
            imageTags: nil,
            albumPrimaryImageTag: albumPrimaryImageTag,
            userData: nil
        )
    }
}

enum StorageReason: String, Codable, Hashable {
    case offline
    case cache
}

struct DownloadQueueItem: Identifiable, Hashable {
    var id: String
    var title: String
    var subtitle: String
    var progress: Double
    var status: DownloadQueueStatus
    var errorMessage: String?
}

enum DownloadQueueStatus: String, Hashable {
    case queued = "Queued"
    case downloading = "Downloading"
    case finished = "Finished"
    case failed = "Failed"
}

struct OfflineAlbum: Identifiable, Hashable {
    var id: String
    var title: String
    var artist: String
    var tracks: [DownloadedTrack]
}

enum PlaybackSource: Equatable {
    case remote(URL)
    case local(URL)
}

struct DiagnosticEvent: Identifiable, Hashable {
    let id = UUID()
    var date: Date
    var source: String
    var message: String
}
