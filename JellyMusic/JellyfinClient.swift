import Foundation

enum JellyfinError: LocalizedError {
    case invalidServerURL
    case badResponse
    case downloadFailed(Int)
    case missingClient

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            "Invalid Jellyfin server URL."
        case .badResponse:
            "Jellyfin returned an unexpected response."
        case .downloadFailed(let statusCode):
            "Jellyfin download failed with status \(statusCode)."
        case .missingClient:
            "Jellyfin client is not configured."
        }
    }
}

final class JellyfinClient: Sendable {
    let credentials: JellyfinCredentials

    init(credentials: JellyfinCredentials) {
        self.credentials = credentials
    }

    static func authenticate(serverURL: URL, username: String, password: String) async throws -> JellyfinCredentials {
        var request = URLRequest(url: serverURL.appending(path: "Users/AuthenticateByName"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorizationHeader(token: nil), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(AuthRequest(username: username, pw: password))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw JellyfinError.badResponse
        }

        let decoded = try JSONDecoder().decode(AuthResponse.self, from: data)
        return JellyfinCredentials(
            serverURL: serverURL,
            userId: decoded.user.id,
            accessToken: decoded.accessToken,
            username: decoded.user.name
        )
    }

    func fetchAlbums() async throws -> [JellyfinItem] {
        try await fetchItems(query: [
            URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "EnableUserData", value: "true"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending")
        ])
    }

    func fetchTracks(parentId: String? = nil) async throws -> [JellyfinItem] {
        var query = [
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "Recursive", value: parentId == nil ? "true" : "false"),
            URLQueryItem(name: "EnableUserData", value: "true"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary"),
            URLQueryItem(name: "Fields", value: "AlbumPrimaryImageTag"),
            URLQueryItem(name: "SortBy", value: "ParentIndexNumber,IndexNumber,SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending")
        ]

        if let parentId {
            query.append(URLQueryItem(name: "ParentId", value: parentId))
        }

        return try await fetchItems(query: query)
    }

    func fetchFavoriteTracks() async throws -> [JellyfinItem] {
        try await fetchItems(query: [
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Filters", value: "IsFavorite"),
            URLQueryItem(name: "EnableUserData", value: "true"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary"),
            URLQueryItem(name: "Fields", value: "AlbumPrimaryImageTag"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending")
        ])
    }

    func fetchFavoriteAlbums() async throws -> [JellyfinItem] {
        try await fetchItems(query: [
            URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Filters", value: "IsFavorite"),
            URLQueryItem(name: "EnableUserData", value: "true"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending")
        ])
    }

    func streamURL(for item: JellyfinItem) -> URL {
        var components = URLComponents(
            url: credentials.serverURL.appending(path: "Audio/\(item.id)/universal"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "UserId", value: credentials.userId),
            URLQueryItem(name: "DeviceId", value: UIDeviceIdentifier.current),
            URLQueryItem(name: "Container", value: "flac,m4a|aac,mp3,alac,wav,ogg,opus"),
            URLQueryItem(name: "AudioCodec", value: "aac"),
            URLQueryItem(name: "TranscodingContainer", value: "ts"),
            URLQueryItem(name: "TranscodingProtocol", value: "hls"),
            URLQueryItem(name: "EnableRedirection", value: "true"),
            URLQueryItem(name: "EnableRemoteMedia", value: "true"),
            URLQueryItem(name: "api_key", value: credentials.accessToken)
        ]
        return components.url!
    }

    func downloadURL(for item: JellyfinItem) -> URL {
        var components = URLComponents(
            url: credentials.serverURL.appending(path: "Items/\(item.id)/Download"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: credentials.accessToken)
        ]
        return components.url!
    }

    func downloadFile(
        for item: JellyfinItem,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> JellyfinDownloadedFile {
        let (bytes, response) = try await URLSession.shared.bytes(for: downloadRequest(for: item))
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JellyfinError.badResponse
        }
        let statusCode = httpResponse.statusCode
        guard (200...299).contains(statusCode) else {
            throw JellyfinError.downloadFailed(statusCode)
        }

        let location = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).download")
        FileManager.default.createFile(atPath: location.path, contents: nil)
        let handle = try FileHandle(forWritingTo: location)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(64 * 1_024)
        var receivedBytes: Int64 = 0
        let expectedBytes = httpResponse.expectedContentLength

        for try await byte in bytes {
            buffer.append(byte)
            receivedBytes += 1

            if buffer.count >= 64 * 1_024 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }

            if expectedBytes > 0, receivedBytes % 32_768 == 0 {
                onProgress?(min(Double(receivedBytes) / Double(expectedBytes), 1))
            }
        }

        if buffer.isEmpty == false {
            try handle.write(contentsOf: buffer)
        }
        onProgress?(1)

        return JellyfinDownloadedFile(
            location: location,
            suggestedFileName: httpResponse.suggestedFilename,
            mimeType: httpResponse.value(forHTTPHeaderField: "Content-Type")
        )
    }

    private func downloadRequest(for item: JellyfinItem) -> URLRequest {
        var request = URLRequest(url: downloadURL(for: item))
        request.setValue(Self.authorizationHeader(token: credentials.accessToken), forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accessToken, forHTTPHeaderField: "X-Emby-Token")
        return request
    }

    func imageURL(for item: JellyfinItem, size: Int = 160) -> URL? {
        let imageItemId: String
        let tag: String?

        if item.type == "Audio", let albumId = item.albumId {
            imageItemId = albumId
            tag = item.albumPrimaryImageTag
        } else {
            imageItemId = item.id
            tag = item.imageTags?["Primary"]
        }

        var components = URLComponents(
            url: credentials.serverURL.appending(path: "Items/\(imageItemId)/Images/Primary"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "fillWidth", value: "\(size)"),
            URLQueryItem(name: "fillHeight", value: "\(size)"),
            URLQueryItem(name: "quality", value: "90"),
            URLQueryItem(name: "api_key", value: credentials.accessToken)
        ]

        if let tag {
            components.queryItems?.append(URLQueryItem(name: "tag", value: tag))
        }

        return components.url
    }

    func setFavorite(_ isFavorite: Bool, itemId: String) async throws {
        var components = URLComponents(
            url: credentials.serverURL.appending(path: "Users/\(credentials.userId)/FavoriteItems/\(itemId)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: credentials.accessToken)
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = isFavorite ? "POST" : "DELETE"
        request.setValue(Self.authorizationHeader(token: credentials.accessToken), forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accessToken, forHTTPHeaderField: "X-Emby-Token")

        let (_, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(statusCode) else {
            throw JellyfinError.badResponse
        }
    }

    private func fetchItems(query: [URLQueryItem]) async throws -> [JellyfinItem] {
        var components = URLComponents(
            url: credentials.serverURL.appending(path: "Users/\(credentials.userId)/Items"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = query

        var request = URLRequest(url: components.url!)
        request.setValue(Self.authorizationHeader(token: credentials.accessToken), forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accessToken, forHTTPHeaderField: "X-Emby-Token")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw JellyfinError.badResponse
        }

        return try JSONDecoder().decode(JellyfinItemsResponse.self, from: data).items
    }

    private static func authorizationHeader(token: String?) -> String {
        var parts = [
            "Client=\"JellyMusic\"",
            "Device=\"iPhone\"",
            "DeviceId=\"\(UIDeviceIdentifier.current)\"",
            "Version=\"1.0.0\""
        ]

        if let token {
            parts.append("Token=\"\(token)\"")
        }

        return "MediaBrowser \(parts.joined(separator: ", "))"
    }
}

enum UIDeviceIdentifier {
    static let current = "JellyMusic-iOS"
}

struct JellyfinDownloadedFile {
    var location: URL
    var suggestedFileName: String?
    var mimeType: String?
}
