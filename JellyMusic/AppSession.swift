import Foundation

@MainActor
final class AppSession: ObservableObject {
    @Published private(set) var credentials: JellyfinCredentials?
    @Published private(set) var serverProfiles: [ServerProfile] = []
    @Published private(set) var activeProfileId: String?
    @Published var albums: [JellyfinItem] = []
    @Published var tracks: [JellyfinItem] = []
    @Published var favoriteTracks: [JellyfinItem] = []
    @Published var favoriteAlbums: [JellyfinItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published private(set) var diagnosticEvents: [DiagnosticEvent] = []
    @Published var selectedTheme: AppTheme = .system {
        didSet {
            UserDefaults.standard.set(selectedTheme.rawValue, forKey: themeDefaultsKey)
        }
    }
    @Published var selectedEqualizerPresetName = "Flat" {
        didSet {
            UserDefaults.standard.set(selectedEqualizerPresetName, forKey: equalizerDefaultsKey)
        }
    }
    private let credentialsStore = CredentialsStore()
    private let themeDefaultsKey = "selectedTheme"
    private let equalizerDefaultsKey = "selectedEqualizerPreset"
    private var artworkDataCache: [String: Data] = [:]
    private(set) var client: JellyfinClient?

    init() {
        if let storedTheme = UserDefaults.standard.string(forKey: themeDefaultsKey),
           let theme = AppTheme(rawValue: storedTheme) {
            selectedTheme = theme
        }
        if let storedEqualizerPreset = UserDefaults.standard.string(forKey: equalizerDefaultsKey) {
            selectedEqualizerPresetName = storedEqualizerPreset
        }
        serverProfiles = credentialsStore.loadProfiles()
        if serverProfiles.isEmpty, let legacy = credentialsStore.load() {
            let profile = ServerProfile(
                id: legacy.serverURL.absoluteString,
                name: legacy.serverURL.host() ?? "Jellyfin",
                kind: .jellyfin,
                credentials: legacy
            )
            serverProfiles = [profile]
            credentialsStore.saveProfiles(serverProfiles)
        }

        if let active = serverProfiles.first {
            activeProfileId = active.id
            credentials = active.credentials
            client = JellyfinClient(credentials: active.credentials)
            recordDiagnostic("Loaded saved profile: \(active.name)")
        }
    }

    func signIn(server: String, username: String, password: String) async {
        await addServer(name: nil, server: server, username: username, password: password)
    }

    func addServer(name: String?, server: String, username: String, password: String) async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let normalized = server.hasPrefix("http") ? server : "https://\(server)"
            guard let url = URL(string: normalized) else {
                throw JellyfinError.invalidServerURL
            }

            let newCredentials = try await JellyfinClient.authenticate(
                serverURL: url,
                username: username,
                password: password
            )
            let profile = ServerProfile(
                id: newCredentials.serverURL.absoluteString,
                name: name?.isEmpty == false ? name! : newCredentials.serverURL.host() ?? newCredentials.username,
                kind: .jellyfin,
                credentials: newCredentials
            )
            serverProfiles.removeAll { $0.id == profile.id }
            serverProfiles.insert(profile, at: 0)
            credentialsStore.saveProfiles(serverProfiles)
            selectProfile(profile)
            recordDiagnostic("Signed in to \(profile.name)")
            await loadLibrary()
        } catch {
            errorMessage = error.localizedDescription
            recordDiagnostic("Sign in failed: \(error.localizedDescription)")
        }
    }

    func signOut() {
        credentialsStore.clear()
        credentials = nil
        client = nil
        activeProfileId = nil
        albums = []
        tracks = []
        favoriteTracks = []
        favoriteAlbums = []
        recordDiagnostic("Signed out")
    }

    func selectProfile(_ profile: ServerProfile) {
        activeProfileId = profile.id
        credentials = profile.credentials
        client = JellyfinClient(credentials: profile.credentials)
        clearLibrary()
        recordDiagnostic("Selected profile: \(profile.name)")
        Task { await loadLibrary() }
    }

    func removeProfile(_ profile: ServerProfile) {
        serverProfiles.removeAll { $0.id == profile.id }
        credentialsStore.saveProfiles(serverProfiles)

        if activeProfileId == profile.id {
            if let next = serverProfiles.first {
                selectProfile(next)
            } else {
                signOut()
            }
        }
    }

    private func clearLibrary() {
        albums = []
        tracks = []
        favoriteTracks = []
        favoriteAlbums = []
    }

    func loadLibrary() async {
        guard let client else { return }
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            async let loadedAlbums = client.fetchAlbums()
            async let loadedTracks = client.fetchTracks()
            async let loadedFavoriteTracks = client.fetchFavoriteTracks()
            async let loadedFavoriteAlbums = client.fetchFavoriteAlbums()
            albums = try await loadedAlbums
            tracks = try await loadedTracks
            favoriteTracks = try await loadedFavoriteTracks
            favoriteAlbums = try await loadedFavoriteAlbums
            recordDiagnostic("Library loaded: \(albums.count) albums, \(tracks.count) tracks")
        } catch {
            errorMessage = error.localizedDescription
            recordDiagnostic("Library load failed: \(error.localizedDescription)")
        }
    }

    func tracks(for album: JellyfinItem) async -> [JellyfinItem] {
        guard let client else { return [] }
        do {
            return try await client.fetchTracks(parentId: album.id)
        } catch {
            errorMessage = error.localizedDescription
            recordDiagnostic("Album tracks load failed: \(error.localizedDescription)")
            return []
        }
    }

    func imageURL(for item: JellyfinItem, size: Int = 160) -> URL? {
        client?.imageURL(for: item, size: size)
    }

    func imageData(for item: JellyfinItem, size: Int = 600) async -> Data? {
        guard let url = client?.imageURL(for: item, size: size) else { return nil }
        let cacheKey = "\(url.absoluteString)#\(size)"
        if let cached = artworkDataCache[cacheKey] {
            return cached
        }

        do {
            let data = try await fetchArtworkData(from: url)
            artworkDataCache[cacheKey] = data
            return data
        } catch {
            return nil
        }
    }

    private func fetchArtworkData(from url: URL) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let httpResponse = response as? HTTPURLResponse,
                   (200..<300).contains(httpResponse.statusCode) == false {
                    throw URLError(.badServerResponse)
                }
                return data
            }

            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw URLError(.timedOut)
            }

            guard let data = try await group.next() else {
                throw URLError(.unknown)
            }
            group.cancelAll()
            return data
        }
    }

    func toggleFavorite(_ item: JellyfinItem) async {
        guard let client else { return }
        let shouldFavorite = isFavorite(item) == false
        markFavorite(itemId: item.id, isFavorite: shouldFavorite)
        let itemKind = item.type == "MusicAlbum" ? "album" : "track"
        statusMessage = shouldFavorite ? "Added \(itemKind) to Favorites" : "Removed \(itemKind) from Favorites"

        do {
            try await client.setFavorite(shouldFavorite, itemId: item.id)
            async let loadedFavoriteTracks = client.fetchFavoriteTracks()
            async let loadedFavoriteAlbums = client.fetchFavoriteAlbums()
            favoriteTracks = try await loadedFavoriteTracks
            favoriteAlbums = try await loadedFavoriteAlbums
            recordDiagnostic("Favorite updated: \(item.name)")
        } catch {
            markFavorite(itemId: item.id, isFavorite: !shouldFavorite)
            errorMessage = error.localizedDescription
            statusMessage = "Favorite update failed"
            recordDiagnostic("Favorite update failed: \(error.localizedDescription)")
        }
    }

    func isFavorite(_ item: JellyfinItem) -> Bool {
        if item.userData?.isFavorite == true {
            return true
        }

        if item.type == "MusicAlbum" {
            return favoriteAlbums.contains { $0.id == item.id }
        }

        return favoriteTracks.contains { $0.id == item.id }
    }

    var selectedEqualizerPreset: EqualizerPreset {
        EqualizerPreset.presets.first { $0.name == selectedEqualizerPresetName } ?? EqualizerPreset.presets[0]
    }

    private func markFavorite(itemId: String, isFavorite: Bool) {
        func updated(_ item: JellyfinItem) -> JellyfinItem {
            guard item.id == itemId else { return item }
            var copy = item
            copy.userData = JellyfinUserData(isFavorite: isFavorite)
            return copy
        }

        tracks = tracks.map(updated)
        favoriteTracks = favoriteTracks.map(updated)
        albums = albums.map(updated)
        favoriteAlbums = favoriteAlbums.map(updated)
    }

    func itemWithCurrentFavoriteState(_ item: JellyfinItem) -> JellyfinItem {
        var copy = item
        copy.userData = JellyfinUserData(isFavorite: isFavorite(item))
        return copy
    }

    private func recordDiagnostic(_ message: String) {
        diagnosticEvents.insert(DiagnosticEvent(date: Date(), source: "Session", message: message), at: 0)
        diagnosticEvents = Array(diagnosticEvents.prefix(40))
    }
}
