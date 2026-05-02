import SwiftUI

private let miniPlayerScrollClearance: CGFloat = 180

struct RootView: View {
    @EnvironmentObject private var session: AppSession

    private var preferredColorScheme: ColorScheme? {
        switch session.selectedTheme {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    var body: some View {
        Group {
            if session.credentials == nil {
                LoginView()
            } else {
                LibraryView()
            }
        }
        .preferredColorScheme(preferredColorScheme)
    }
}

struct LoginView: View {
    @EnvironmentObject private var session: AppSession
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server URL", text: $server)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $password)
                }

                if let error = session.errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                Button {
                    Task { await session.signIn(server: server, username: username, password: password) }
                } label: {
                    if session.isLoading {
                        ProgressView()
                    } else {
                        Label("Sign In", systemImage: "person.crop.circle.badge.checkmark")
                    }
                }
                .disabled(server.isEmpty || username.isEmpty || password.isEmpty || session.isLoading)
            }
            .navigationTitle("Jelly Music")
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var downloads: DownloadManager
    @State private var selectedTab = 0
    @State private var isShowingNowPlaying = false

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                NavigationStack {
                    AlbumListView()
                }
                .safeAreaInset(edge: .bottom) {
                    miniPlayer
                }
                .tabItem { Label("Albums", systemImage: "rectangle.stack") }
                .tag(0)

                NavigationStack {
                    TrackListView(tracks: session.tracks, title: "Tracks")
                }
                .safeAreaInset(edge: .bottom) {
                    miniPlayer
                }
                .tabItem { Label("Tracks", systemImage: "music.note.list") }
                .tag(1)

                NavigationStack {
                    FavoritesView()
                }
                .safeAreaInset(edge: .bottom) {
                    miniPlayer
                }
                .tabItem { Label("Liked", systemImage: "heart") }
                .tag(2)

                NavigationStack {
                    OfflineAlbumsView()
                }
                .safeAreaInset(edge: .bottom) {
                    miniPlayer
                }
                .tabItem { Label("Offline", systemImage: "arrow.down.circle") }
                .tag(3)

                NavigationStack {
                    SettingsView()
                }
                .safeAreaInset(edge: .bottom) {
                    miniPlayer
                }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(4)
            }

        }
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: player.currentTrack?.id)
        .sheet(isPresented: $isShowingNowPlaying) {
            NowPlayingView()
        }
        .overlay(alignment: .top) {
            if let status = session.statusMessage ?? player.playbackError {
                Text(status)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial)
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.9), value: session.statusMessage)
        .animation(.spring(response: 0.25, dampingFraction: 0.9), value: player.playbackError)
        .onChange(of: session.statusMessage) { _, message in
            guard message != nil else { return }
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                await MainActor.run {
                    session.statusMessage = nil
                }
            }
        }
        .onChange(of: player.playbackError) { _, message in
            guard message != nil else { return }
            Task {
                try? await Task.sleep(for: .seconds(2.2))
                await MainActor.run {
                    player.playbackError = nil
                }
            }
        }
        .task {
            player.setSourceProvider { track in
                if let localURL = downloads.localURL(for: track) {
                    return .local(localURL)
                }
                guard let client = session.client else {
                    throw JellyfinError.missingClient
                }
                return .remote(client.streamURL(for: track))
            }
            await session.loadLibrary()
            let offlineTracks = downloads.downloadedTracks.map(\.asJellyfinItem)
            await player.restoreLastPlayback(availableTracks: session.tracks + offlineTracks)
        }
    }

    @ViewBuilder
    private var miniPlayer: some View {
        if player.currentTrack != nil {
            PlayerBar()
                .onTapGesture {
                    isShowingNowPlaying = true
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

struct AlbumListView: View {
    @EnvironmentObject private var session: AppSession
    @State private var searchText = ""

    private var filteredAlbums: [JellyfinItem] {
        LibraryFilters.albums(session.albums, matching: searchText)
    }

    var body: some View {
        List(filteredAlbums) { album in
            NavigationLink {
                AlbumDetailView(album: album)
            } label: {
                AlbumRow(album: album)
            }
            .swipeActions {
                Button {
                    Task { await session.toggleFavorite(album) }
                } label: {
                    FavoriteActionLabel(isFavorite: session.isFavorite(album))
                }
                .tint(.pink)
            }
        }
        .contentMargins(.bottom, miniPlayerScrollClearance, for: .scrollContent)
        .navigationTitle("Albums")
        .searchable(text: $searchText, prompt: "Artist or album")
        .toolbar {
            Button {
                Task { await session.loadLibrary() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("Refresh Library")
            Button(role: .destructive) {
                session.signOut()
            } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
            }
            .accessibilityLabel("Sign Out")
        }
    }
}

struct AlbumDetailView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var downloads: DownloadManager
    let album: JellyfinItem
    @State private var tracks: [JellyfinItem] = []

    var body: some View {
        TrackListView(tracks: tracks, title: album.name)
            .toolbar {
                Button {
                    Task { await session.toggleFavorite(album) }
                } label: {
                    Image(systemName: session.isFavorite(album) ? "heart.fill" : "heart")
                        .foregroundStyle(session.isFavorite(album) ? .pink : .primary)
                }
                Button {
                    downloads.downloadAlbum(album, tracks: tracks)
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .disabled(tracks.isEmpty || tracks.allSatisfy { downloads.isExplicitlyDownloaded($0) })
            }
            .task {
                tracks = await session.tracks(for: album)
            }
    }
}

struct TrackListView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var downloads: DownloadManager
    @State private var searchText = ""
    let tracks: [JellyfinItem]
    let title: String
    var showsFavoriteIcon = true

    private var filteredTracks: [JellyfinItem] {
        LibraryFilters.tracks(tracks, matching: searchText)
    }

    var body: some View {
        List {
            if let error = downloads.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            ForEach(filteredTracks) { track in
                Button {
                    Task { await player.play(filteredTracks, startingAt: track) }
                } label: {
                    TrackRow(track: track, showsFavoriteIcon: showsFavoriteIcon)
                }
                .swipeActions {
                    if downloads.isExplicitlyDownloaded(track) == false {
                        Button {
                            downloads.download(track)
                        } label: {
                            Label("Download", systemImage: "arrow.down.circle")
                        }
                    }
                    Button {
                        Task { await session.toggleFavorite(track) }
                    } label: {
                        FavoriteActionLabel(isFavorite: session.isFavorite(track))
                    }
                    .tint(.pink)
                }
                .accessibilityLabel(trackAccessibilityLabel(track))
            }
        }
        .contentMargins(.bottom, miniPlayerScrollClearance, for: .scrollContent)
        .navigationTitle(title)
        .searchable(text: $searchText, prompt: "Artist or song")
    }

    private func trackAccessibilityLabel(_ track: JellyfinItem) -> String {
        var parts = [track.name, track.displayArtist]
        if player.currentTrack?.id == track.id {
            parts.append(player.isPlaying ? "currently playing" : "current track")
        }
        if downloads.isExplicitlyDownloaded(track) {
            parts.append("available offline")
        }
        return parts.joined(separator: ", ")
    }
}

struct SettingsView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var downloads: DownloadManager
    @State private var isAddingServer = false

    var body: some View {
        List {
            Section("Media Servers") {
                ForEach(session.serverProfiles) { profile in
                    Button {
                        session.selectProfile(profile)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "server.rack")
                                .foregroundStyle(.blue)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.name)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(profile.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(profile.kind.rawValue)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if session.activeProfileId == profile.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            session.removeProfile(profile)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }

                Button {
                    isAddingServer = true
                } label: {
                    Label("Add Server", systemImage: "plus.circle")
                }
            }

            Section("Active Connection") {
                if let credentials = session.credentials {
                    LabeledContent("Server", value: credentials.serverURL.absoluteString)
                    LabeledContent("User", value: credentials.username)
                }
            }

            Section("Appearance") {
                Picker("Theme", selection: $session.selectedTheme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.rawValue).tag(theme)
                    }
                }
            }

            Section("Equalizer") {
                NavigationLink {
                    EqualizerSettingsView()
                } label: {
                    LabeledContent("Preset", value: session.selectedEqualizerPreset.name)
                }
            }

            Section("Storage") {
                Button(role: .destructive) {
                    downloads.removeAllOfflineDownloads()
                    session.statusMessage = "Offline downloads removed"
                } label: {
                    Label("Clear Offline Downloads", systemImage: "trash.slash")
                }
                .disabled(downloads.hasOfflineDownloads == false)
            }

            Section("Downloads") {
                NavigationLink {
                    DownloadQueueView()
                } label: {
                    LabeledContent("Queue", value: "\(downloads.downloadQueue.count)")
                }
            }

            Section("Diagnostics") {
                NavigationLink {
                    DiagnosticsView()
                } label: {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
            }
        }
        .contentMargins(.bottom, miniPlayerScrollClearance, for: .scrollContent)
        .navigationTitle("Settings")
        .sheet(isPresented: $isAddingServer) {
            NavigationStack {
                AddServerView()
            }
        }
    }
}

struct AddServerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession
    @State private var name = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        Form {
            Section("Server") {
                TextField("Name", text: $name)
                Picker("Type", selection: .constant(MediaServerKind.jellyfin)) {
                    Text(MediaServerKind.jellyfin.rawValue).tag(MediaServerKind.jellyfin)
                }
                TextField("Server URL", text: $server)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                if server.lowercased().hasPrefix("http://") && isLocalServer(server) == false {
                    Text("Use HTTPS for remote servers.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section("Account") {
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                SecureField("Password", text: $password)
            }

            if let error = session.errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Add Server")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        await session.addServer(name: name, server: server, username: username, password: password)
                        if session.errorMessage == nil {
                            dismiss()
                        }
                    }
                }
                .disabled(server.isEmpty || username.isEmpty || password.isEmpty || session.isLoading)
            }
        }
    }

    private func isLocalServer(_ value: String) -> Bool {
        guard let host = URL(string: value)?.host()?.lowercased() else { return false }
        return host == "localhost" ||
            host.hasPrefix("127.") ||
            host.hasPrefix("10.") ||
            host.hasPrefix("192.168.") ||
            host.range(of: #"^172\.(1[6-9]|2[0-9]|3[0-1])\."#, options: .regularExpression) != nil
    }
}

struct DownloadQueueView: View {
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        List {
            if downloads.downloadQueue.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle")
            } else {
                ForEach(downloads.downloadQueue) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(.headline)
                                Text(item.subtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(item.status.rawValue)
                                .font(.caption)
                                .foregroundStyle(statusColor(item.status))
                        }

                        if item.status == .downloading || item.status == .queued {
                            ProgressView(value: item.progress)
                        }

                        if let error = item.errorMessage {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Downloads")
        .contentMargins(.bottom, miniPlayerScrollClearance, for: .scrollContent)
        .toolbar {
            Button {
                downloads.clearFinishedQueueItems()
            } label: {
                Image(systemName: "checkmark.circle")
            }
            .disabled(downloads.downloadQueue.contains { $0.status == .finished } == false)
        }
    }

    private func statusColor(_ status: DownloadQueueStatus) -> Color {
        switch status {
        case .queued:
            .secondary
        case .downloading:
            .blue
        case .finished:
            .green
        case .failed:
            .red
        }
    }
}

struct EqualizerSettingsView: View {
    @EnvironmentObject private var session: AppSession

    var body: some View {
        List {
            Section("Presets") {
                ForEach(EqualizerPreset.presets) { preset in
                    Button {
                        session.selectedEqualizerPresetName = preset.name
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(preset.name)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                EqualizerBarsView(gains: preset.gains)
                            }
                            Spacer()
                            if session.selectedEqualizerPresetName == preset.name {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }
            }

            Section("Bands") {
                ForEach(Array(zip(EqualizerPreset.bands, session.selectedEqualizerPreset.gains)), id: \.0) { band, gain in
                    LabeledContent("\(band) Hz", value: String(format: "%.1f dB", gain))
                }
            }
        }
        .navigationTitle("Equalizer")
        .contentMargins(.bottom, miniPlayerScrollClearance, for: .scrollContent)
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var downloads: DownloadManager

    private var events: [DiagnosticEvent] {
        (session.diagnosticEvents + player.diagnosticEvents + downloads.diagnosticEvents)
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        List {
            Section("Connection") {
                if let credentials = session.credentials {
                    LabeledContent("Server", value: credentials.serverURL.host() ?? credentials.serverURL.absoluteString)
                    LabeledContent("User", value: credentials.username)
                } else {
                    Text("No active server")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Albums", value: "\(session.albums.count)")
                LabeledContent("Tracks", value: "\(session.tracks.count)")
            }

            Section("Playback") {
                LabeledContent("State", value: player.isPlaying ? "Playing" : "Paused")
                LabeledContent("Mode", value: downloads.isExplicitlyDownloaded(player.currentTrack ?? emptyTrack) ? "Offline" : "Streaming")
                LabeledContent("Queue", value: "\(player.queue.count)")
                LabeledContent("Shuffle", value: player.isShuffleEnabled ? "On" : "Off")
                LabeledContent("Repeat", value: player.repeatMode.rawValue)
                if let track = player.currentTrack {
                    LabeledContent("Track", value: track.name)
                }
                if let error = player.playbackError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }

            Section("Downloads") {
                LabeledContent("Offline tracks", value: "\(downloads.downloadedTracks.count)")
                LabeledContent("Active", value: "\(downloads.activeDownloads.count)")
                LabeledContent("Queue", value: "\(downloads.downloadQueue.count)")
                if let error = downloads.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }

            Section("Recent Events") {
                if events.isEmpty {
                    ContentUnavailableView("No Events", systemImage: "list.bullet.rectangle")
                } else {
                    ForEach(events) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(event.source)
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text(event.date, style: .time)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(event.message)
                                .font(.subheadline)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .contentMargins(.bottom, miniPlayerScrollClearance, for: .scrollContent)
    }

    private var emptyTrack: JellyfinItem {
        JellyfinItem(id: "", name: "", type: "Audio")
    }
}

struct EqualizerBarsView: View {
    let gains: [Double]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(gains.enumerated()), id: \.offset) { _, gain in
                Capsule()
                    .fill(gain >= 0 ? Color.blue.opacity(0.75) : Color.secondary.opacity(0.55))
                    .frame(width: 5, height: CGFloat(10 + abs(gain) * 2.2))
            }
        }
        .frame(height: 26, alignment: .center)
    }
}

struct FavoritesView: View {
    @EnvironmentObject private var session: AppSession
    @State private var selectedKind = FavoriteKind.tracks
    @State private var searchText = ""

    private enum FavoriteKind: String, CaseIterable, Identifiable {
        case tracks = "Tracks"
        case albums = "Albums"

        var id: String { rawValue }
    }

    private var filteredAlbums: [JellyfinItem] {
        LibraryFilters.albums(session.favoriteAlbums, matching: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Liked", selection: $selectedKind) {
                ForEach(FavoriteKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            if selectedKind == .tracks {
                TrackListView(tracks: session.favoriteTracks, title: "Liked", showsFavoriteIcon: false)
            } else {
                List(filteredAlbums) { album in
                    NavigationLink {
                        AlbumDetailView(album: album)
                    } label: {
                        AlbumRow(album: album, showsFavoriteIcon: false)
                    }
                    .swipeActions {
                        Button {
                            Task { await session.toggleFavorite(album) }
                        } label: {
                            FavoriteActionLabel(isFavorite: session.isFavorite(album))
                        }
                        .tint(.pink)
                    }
                }
                .contentMargins(.bottom, miniPlayerScrollClearance, for: .scrollContent)
                .searchable(text: $searchText, prompt: "Artist or album")
            }
        }
        .navigationTitle("Liked")
    }
}

struct OfflineAlbumsView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        List {
            if let error = downloads.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            ForEach(downloads.offlineAlbums()) { album in
                NavigationLink {
                    OfflineAlbumView(album: album)
                } label: {
                    HStack(spacing: 12) {
                        ArtworkView(url: albumArtworkURL(for: album), size: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(album.title)
                                .font(.headline)
                            Text("\(album.artist) - \(album.tracks.count) tracks")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        downloads.removeAlbum(album)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
        }
        .contentMargins(.bottom, miniPlayerScrollClearance, for: .scrollContent)
        .navigationTitle("Offline")
        .toolbar {
            Button(role: .destructive) {
                downloads.removeAllOfflineDownloads()
                session.statusMessage = "Offline downloads removed"
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Clear Offline Downloads")
            .disabled(downloads.hasOfflineDownloads == false)
        }
    }

    private func albumArtworkURL(for album: OfflineAlbum) -> URL? {
        album.tracks
            .lazy
            .map(\.asJellyfinItem)
            .compactMap { session.imageURL(for: $0, size: 120) }
            .first
    }
}

struct OfflineAlbumView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var player: PlayerService
    let album: OfflineAlbum

    var body: some View {
        let tracks = album.tracks.map(\.asJellyfinItem)

        List(album.tracks) { downloadedTrack in
            let track = downloadedTrack.asJellyfinItem
            Button {
                Task { await player.play(tracks, startingAt: track) }
            } label: {
                TrackRow(track: track)
            }
            .swipeActions {
                Button(role: .destructive) {
                    downloads.removeTrack(downloadedTrack)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
        .contentMargins(.bottom, miniPlayerScrollClearance, for: .scrollContent)
        .navigationTitle(album.title)
        .toolbar {
            Button(role: .destructive) {
                downloads.removeAlbum(album)
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Remove Offline Album")
        }
    }
}

struct TrackRow: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var player: PlayerService
    let track: JellyfinItem
    var showsFavoriteIcon = true

    private var isCurrentTrack: Bool {
        player.currentTrack?.id == track.id
    }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: session.imageURL(for: track, size: 120), size: 46)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(track.name)
                        .font(.headline)
                        .foregroundStyle(isCurrentTrack ? .blue : .primary)
                        .lineLimit(1)
                    if isCurrentTrack {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    if showsFavoriteIcon {
                        FavoriteStateIcon(isFavorite: session.isFavorite(track))
                    }
                }
                Text(track.displayArtist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if downloads.activeDownloads.contains(track.id) {
                ProgressView()
            } else if downloads.isExplicitlyDownloaded(track) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Text(track.durationText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct AlbumRow: View {
    @EnvironmentObject private var session: AppSession
    let album: JellyfinItem
    var showsFavoriteIcon = true

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: session.imageURL(for: album, size: 120), size: 52)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(album.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if showsFavoriteIcon {
                        FavoriteStateIcon(isFavorite: session.isFavorite(album))
                    }
                }
                Text(album.displayArtist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct FavoriteStateIcon: View {
    let isFavorite: Bool

    @ViewBuilder
    var body: some View {
        if isFavorite {
            Image(systemName: "heart.fill")
                .font(.caption)
                .foregroundStyle(.pink)
                .accessibilityLabel("Favorite")
        }
    }
}

struct FavoriteActionLabel: View {
    let isFavorite: Bool

    var body: some View {
        Label(
            isFavorite ? "Unfavorite" : "Favorite",
            systemImage: isFavorite ? "heart.slash.fill" : "heart.fill"
        )
    }
}

struct ArtworkView: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            default:
                ZStack {
                    Color.secondary.opacity(0.16)
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct NowPlayingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        NavigationStack {
            ScrollView {
                if let track = player.currentTrack {
                    VStack(spacing: 24) {
                        ArtworkView(url: session.imageURL(for: track, size: 800), size: 280)
                            .shadow(color: .black.opacity(0.2), radius: 22, y: 12)
                            .padding(.top, 18)

                        VStack(spacing: 7) {
                            Text(track.name)
                                .font(.title2.bold())
                                .multilineTextAlignment(.center)
                            Text(track.displayArtist)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            if let album = track.album {
                                Text(album)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .padding(.horizontal)

                        VStack(spacing: 6) {
                            Slider(
                                value: Binding(
                                    get: { player.progress },
                                    set: { player.seek(toProgress: $0) }
                                ),
                                in: 0...1
                            )
                            HStack {
                                Text(formatTime(player.elapsedTime))
                                Spacer()
                                Text("-\(formatTime(player.remainingTime))")
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 24)

                        HStack(spacing: 16) {
                            Button {
                                player.toggleShuffle()
                            } label: {
                                Image(systemName: "shuffle")
                                    .font(.title2)
                                    .foregroundStyle(player.isShuffleEnabled ? Color.blue : Color.primary)
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel(player.isShuffleEnabled ? "Disable Shuffle" : "Enable Shuffle")

                            Button {
                                Task {
                                    await session.toggleFavorite(track)
                                    player.refreshTrackMetadata(session.itemWithCurrentFavoriteState(track))
                                }
                            } label: {
                                Image(systemName: session.isFavorite(track) ? "heart.fill" : "heart")
                                    .font(.title2)
                                    .foregroundStyle(session.isFavorite(track) ? .pink : .primary)
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel(session.isFavorite(track) ? "Remove From Favorites" : "Add To Favorites")

                            Button {
                                player.previous()
                            } label: {
                                Image(systemName: "backward.fill")
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("Previous Track")

                            Button {
                                player.togglePlayPause()
                            } label: {
                                if player.isBuffering {
                                    ProgressView()
                                        .controlSize(.large)
                                        .frame(width: 68, height: 68)
                                } else {
                                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                        .font(.system(size: 68))
                                }
                            }
                            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                            Button {
                                player.next()
                            } label: {
                                Image(systemName: "forward.fill")
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("Next Track")

                            Button {
                                player.cycleRepeatMode()
                            } label: {
                                Image(systemName: player.repeatMode.systemImage)
                                    .font(.title2)
                                    .foregroundStyle(player.repeatMode == .off ? Color.primary : Color.blue)
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("Repeat \(player.repeatMode.rawValue)")
                        }
                        .buttonStyle(.plain)

                        HStack(spacing: 16) {
                            Label(downloads.isExplicitlyDownloaded(track) ? "Offline" : "Streaming",
                                  systemImage: downloads.isExplicitlyDownloaded(track) ? "checkmark.circle.fill" : "wifi")
                            Label(session.selectedEqualizerPreset.name, systemImage: "slider.horizontal.3")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        if player.queue.isEmpty == false {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Queue")
                                    .font(.headline)
                                    .padding(.horizontal)

                                ForEach(Array(player.queue.enumerated()), id: \.element.id) { index, queuedTrack in
                                    Button {
                                        Task { await player.playQueuedTrack(queuedTrack) }
                                    } label: {
                                        HStack(spacing: 10) {
                                            if queuedTrack.id == player.currentTrack?.id {
                                                Image(systemName: "speaker.wave.2.fill")
                                                    .foregroundStyle(.blue)
                                                    .frame(width: 20)
                                            } else {
                                                Text("\(index + 1)")
                                                    .font(.caption.monospacedDigit())
                                                    .foregroundStyle(.secondary)
                                                    .frame(width: 20)
                                            }
                                            TrackRow(track: queuedTrack)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .padding(.horizontal)
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

struct PlayerBar: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: PlayerService

    var body: some View {
        if let track = player.currentTrack {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    ArtworkView(url: session.imageURL(for: track, size: 120), size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text(track.displayArtist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                            Button {
                                player.togglePlayPause()
                            } label: {
                                if player.isBuffering {
                                    ProgressView()
                                        .frame(width: 36, height: 36)
                                } else {
                                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                        .frame(width: 36, height: 36)
                                }
                            }
                    Button {
                        player.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("Next Track")
                }

                VStack(spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { player.progress },
                            set: { player.seek(toProgress: $0) }
                        ),
                        in: 0...1
                    )
                    HStack {
                        Text(formatTime(player.elapsedTime))
                        Spacer()
                        Text("-\(formatTime(player.remainingTime))")
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Mini Player, \(track.name), \(track.displayArtist)")
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}
