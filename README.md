# Jelly Music

Jelly Music is a minimal native iOS music client for Jellyfin. It focuses on a
small, practical MVP: sign in to a Jellyfin server, browse albums and tracks,
play music, download albums for offline listening, and keep playback available
from the Lock Screen and Control Center.

The app is written in Swift and SwiftUI, uses the Jellyfin API directly, stores
tokens in Keychain, and keeps offline music on the device.

## Features

- Jellyfin server login with credentials stored in Keychain.
- Multiple saved Jellyfin server profiles.
- Albums, tracks, artists, favorites, and offline library views.
- Remote streaming through Jellyfin audio endpoints.
- Offline album and track downloads.
- Offline playback from local files.
- Mini player and full player screens.
- Lock Screen / Control Center metadata and playback controls.
- Lock Screen seek support.
- Last playback state restore after relaunch.
- Queue view with jump-to-track, shuffle, repeat all, and repeat one controls.
- Offline equalizer presets and custom band controls.
- Album artwork for online and downloaded content.
- Diagnostics view for connection, playback, downloads, and recent events.
- Light and dark appearance support.
- English and Russian localization resources.

## Current Status

The project is in MVP state. The main playback and offline flows are usable, but
the app is not yet polished for a public App Store release.

Known MVP limitations:

- Equalizer processing is currently available for offline playback.
- Streaming playback uses `AVQueuePlayer`; offline playback uses `AVAudioEngine`.
- The included app icon is an MVP placeholder and should be replaced before a
  public release.
- Automated test coverage is intentionally small and focused on pure MVP logic.

## Requirements

- macOS with Xcode installed.
- iOS 17 or newer target device or simulator.
- A Jellyfin server with music library access.
- Apple Developer signing setup for installing on a physical device.

## Getting Started

Clone the repository:

```sh
git clone https://github.com/your-name/JellyMusic.git
cd JellyMusic
```

Open the project in Xcode:

```sh
open JellyMusic.xcodeproj
```

Then:

1. Select the `JellyMusic` scheme.
2. Choose your development team in Signing & Capabilities.
3. Update the bundle identifier if needed.
4. Build and run on a simulator or physical iPhone.
5. Sign in with your Jellyfin server URL, username, and password.

## Command-Line Build

For a local unsigned build:

```sh
xcodebuild \
  -project JellyMusic.xcodeproj \
  -scheme JellyMusic \
  -configuration Debug \
  -destination generic/platform=iOS \
  -derivedDataPath ./DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Tests

The project includes a small XCTest target for pure library logic:

```sh
xcodebuild \
  -project JellyMusic.xcodeproj \
  -scheme JellyMusic \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.0' \
  -derivedDataPath ./DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
```

The shared Xcode scheme is committed, and GitHub Actions runs build and unit
test checks on pushes and pull requests.

## Privacy

- Jellyfin access tokens are stored in the iOS Keychain.
- Downloaded tracks and artwork are stored locally on the device.
- The app does not include analytics or third-party tracking.
- Network requests are made to the Jellyfin servers configured by the user.

## Roadmap

Useful improvements for the next MVP pass:

- Replace the placeholder app icon with a final brand icon.
- Add real screenshots to `docs/screenshots`.
- Improve download retry, cancellation, and failed-download recovery.
- Add tests for offline metadata, playback restore, and download finalization.
- Add UI tests for login, album browsing, downloads, and offline playback.
- Finish full-string localization beyond the MVP labels.
- Continue reviewing accessibility labels, Dynamic Type, and VoiceOver behavior.
- Prepare TestFlight release notes and a privacy policy.

## Contributing

Issues and pull requests are welcome. For larger changes, open an issue first so
the direction can be discussed before implementation.

## License

Jelly Music is released under the MIT License. See [LICENSE](LICENSE).
