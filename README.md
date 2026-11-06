# itchPocket

A native SwiftUI starter for an iOS itch.io companion client.

## Current scope

- Four-tab SwiftUI shell: Discover, Library, Downloads, Me
- iOS 26 Liquid Glass styling with a Material fallback on earlier iOS versions
- XcodeGen project definition
- GitHub Actions simulator build workflow

This is a foundation, not a finished itch.io client. Authentication, API integration, owned-game retrieval, and the download engine are intentionally not wired yet.

## Requirements

- Xcode 26 or newer
- iOS deployment target: 18.0
- XcodeGen (`brew install xcodegen`)

## Build locally

```bash
xcodegen generate
xcodebuild -project itchPocket.xcodeproj \
  -scheme itchPocket \
  -destination 'generic/platform=iOS Simulator' build
```

## Project structure

```text
Sources/
  App/
    itchPocketApp.swift
  Views/
    ContentView.swift
    DiscoverView.swift
    LibraryView.swift
    DownloadsView.swift
    ProfileView.swift
```

## Next implementation milestones

1. Verify itch.io OAuth flow and API permissions.
2. Implement typed API models and a safe token store (Keychain).
3. Build Discover, game detail, and owned Library screens.
4. Implement URLSession background downloads and persistent task state.
5. Add file export through the iOS share sheet / Files.
