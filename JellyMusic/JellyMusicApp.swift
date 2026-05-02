import SwiftUI
import UIKit

@main
struct JellyMusicApp: App {
    @StateObject private var session = AppSession()
    @StateObject private var player = PlayerService()
    @StateObject private var downloads = DownloadManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(player)
                .environmentObject(downloads)
                .task {
                    player.configureAudioSession()
                    player.setEqualizerPreset(session.selectedEqualizerPreset)
                    player.setArtworkProvider { track in
                        await session.imageData(for: track, size: 700)
                    }
                    downloads.configure(clientProvider: { session.client })
                }
                .onChange(of: session.selectedEqualizerPresetName) { _, _ in
                    player.setEqualizerPreset(session.selectedEqualizerPreset)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                    player.stopPlayback(deactivateSession: true)
                }
        }
    }
}
