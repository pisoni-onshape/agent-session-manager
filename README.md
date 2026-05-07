# Agent Session Manager

Agent Session Manager is a macOS SwiftUI desktop app that aggregates local session history from:

- GitHub Copilot CLI
- Cursor
- GitHub Copilot in VS Code

It keeps a read-only local SQLite catalog, lets you search/filter/sort sessions, and exposes the best available source-aware action for each session:

- **Copilot CLI**: exact resume via `copilot --resume <session-id>`
- **Cursor**: open the workspace in Cursor when the workspace path can be reconstructed, otherwise reveal the transcript
- **VS Code**: open the workspace in VS Code

It also supports an in-app read-only transcript viewer so you can inspect the conversation without opening raw JSONL files in Finder.

## Project shape

- `Sources/Models.swift` — normalized session types and filter/sort state
- `Sources/Utilities.swift` — path helpers, text cleanup, transcript preview extraction, and app launch helpers
- `Sources/Storage.swift` — SQLite-backed catalog
- `Sources/Adapters.swift` — read-only scanners for the three local stores
- `Sources/ViewModel.swift` — app state, refresh, search, filter, and action wiring
- `Sources/ContentView.swift` — SwiftUI list/detail UI

## Build and run

1. Generate the Xcode project:

    ```bash
    xcodegen generate
    ```

2. Open the app in Xcode:

   ```bash
   open AgentSessionManager.xcodeproj
   ```

3. Run it from Xcode with the `AgentSessionManager` scheme, or build/test from the command line:

   ```bash
    xcodebuild -project AgentSessionManager.xcodeproj -scheme AgentSessionManager -destination 'platform=macOS' build
    xcodebuild -project AgentSessionManager.xcodeproj -scheme AgentSessionManager -destination 'platform=macOS' test
    ```

4. To launch the built app directly from the command line after a build:

   ```bash
   open ~/Library/Developer/Xcode/DerivedData/AgentSessionManager-*/Build/Products/Debug/AgentSessionManager.app
   ```

5. For a project-local CLI build shortcut:

   ```bash
   ./build.sh
   ```

## Notes

- The app is intentionally **read-only** with respect to the original session stores.
- The local SQLite catalog lives under `~/Library/Application Support/AgentSessionManager/catalog.sqlite3`.
- Cursor project path reconstruction is heuristic because its local project directory name is lossy for paths that contain hyphens; when reconstruction fails, the app falls back to transcript reveal.
- Model metadata is currently surfaced where it is stored reliably: Copilot CLI (`events.jsonl` model-change events) and VS Code Copilot (`chatSessions` selected model). Cursor transcripts did not show a stable per-session model field in the inspected local store.
- The in-app transcript viewer preserves exact per-event timestamps for Copilot CLI and VS Code Copilot. Cursor transcripts are still readable in-app, but the inspected local JSONL files do not expose per-message timestamps.
