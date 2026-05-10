# Agent Session Manager

Agent Session Manager is a macOS SwiftUI desktop app with a companion CLI that aggregates local session history from:

- GitHub Copilot CLI
- Cursor
- GitHub Copilot in VS Code

It keeps a read-only local SQLite catalog, lets you search/filter/sort sessions, and exposes the best available source-aware action for each session:

- **Copilot CLI**: exact resume via `copilot --resume <session-id>`
- **Cursor**: open the workspace in Cursor when the workspace path can be reconstructed, otherwise reveal the transcript
- **VS Code**: open the workspace in VS Code

It also supports an in-app read-only transcript viewer so you can inspect the conversation without opening raw JSONL files in Finder, and the main toolbar search now searches indexed transcript contents as you type in addition to session metadata.

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

3. Use the project build script for normal app builds and installs. It builds **Release**, stamps the app version automatically, closes any running `/Applications/AgentSessionManager.app`, and replaces the installed app:

    ```bash
    ./build.sh
     ```

4. The standard installed app location after `./build.sh` completes is:

    ```bash
    /Applications/AgentSessionManager.app
    ```

5. `./build.sh` also installs a PATH-visible CLI link at:

    ```bash
    /usr/local/bin/agent-session-manager
    ```

6. For manual testing without changing the build/install flow, you can still run tests directly:

    ```bash
    xcodebuild -project AgentSessionManager.xcodeproj -scheme AgentSessionManager -destination 'platform=macOS' test
    ```

`AGENTS.md` in the repository root and `.github/copilot-instructions.md` tell Copilot to use `./build.sh` as the standard build path for this project.

## Notes

- The app is intentionally **read-only** with respect to the original session stores.
- The local SQLite catalog lives under `~/Library/Application Support/AgentSessionManager/catalog.sqlite3`.
- The app now stores its own **local-only starred session preferences** alongside the catalog so stars survive refreshes and app relaunches without modifying the original session sources.
- The app now runs an **incremental refresh automatically on launch** and the main **Refresh** button uses that same incremental path.
- The app now includes a standard macOS **Settings** dialog for **Launch at Login**, a configurable **Newton repos path**, and an **Auto Session Refresh** section with a timer plus separate controls for refresh on the first app launch after system startup and on subsequent launches. The default refresh setup is **Every day**, **first launch after startup on**, and **subsequent launches off**.
- The app now includes a **CLI** menu with **Install CLI to PATH**, which installs a user-level `agent-session-manager` command and, when needed, adds `~/.local/bin` to `~/.zprofile`.
- Incremental refresh still scans the source directories, but it only reparses sessions whose transcript/metadata files changed and only upserts/deletes affected rows in SQLite, including the persisted transcript search index.
- The **Newton repos only** filter now matches only workspace paths that live under the configured Newton repos root and whose repo directory starts with `newton`, with path normalization handling either `/path/to/repos` or `/path/to/repos/`.
- The main session browser now exposes first-class **Open Plan**, persistent metadata **copy buttons**, a **Starred / Unstarred / All** filter with starred sessions grouped ahead of unstarred ones and separated by an inline divider, wider multi-row **Project/Branch** filters, and the conversation **workspace path** directly in metadata.
- The main toolbar search supports the existing metadata labels plus a new **`transcript:`** label for transcript-only matching; unlabeled searches can match either metadata or indexed transcript text.
- **Catalog** menu actions now include **Open Index Folder** for quickly revealing the directory that contains `catalog.sqlite3`.
- A **Rebuild Session Index** command remains available under the **Catalog** menu as a recovery/debug path.
- Cursor sessions now prefer Cursor workspace metadata from `workspaceStorage/workspace.json` for canonical workspace paths and display names, with the `~/.cursor/projects/<slug>` directory only used as a fallback when that metadata is missing.
- VS Code Copilot sessions are indexed from both the older `GitHub.copilot-chat/transcripts` store and the current `chatSessions` store; the current `chatSessions` format also preserves the custom chat title you see in VS Code.
- Model metadata is currently surfaced where it is stored reliably: Copilot CLI (`events.jsonl` model-change events) and VS Code Copilot (legacy event transcripts or current `chatSessions` request model IDs). Cursor transcripts did not show a stable per-session model field in the inspected local store.
- The in-app transcript viewer now opens in a separate window instead of an attached sheet, preserving the same UI while avoiding parent-window repositioning.
- The in-app transcript viewer preserves exact per-event timestamps for Copilot CLI and legacy VS Code event transcripts. Current VS Code `chatSessions` and Cursor transcripts are still readable in-app, but the inspected local files do not expose a complete per-message timestamp for every assistant response.
- The companion CLI supports `agent-session-manager search --query <text>`, `agent-session-manager --search <text>`, `--refresh`, `--within`, `--limit`, `--json`, and `-h` / `--help`.
- `./build.sh` computes the marketing version as `<incrementing-build-number>.<commit-derived-8-digit-number>`, installs the finished Release app into `/Applications`, and installs `/usr/local/bin/agent-session-manager` as a symlink to the bundled CLI helper.

## CLI usage

```bash
agent-session-manager --help
agent-session-manager search --query 'project:newton2 transcript:"drag bug"' --newton-only --branch main
agent-session-manager --search 'title:"plan update"' --within 1w --limit 10
agent-session-manager search --query 'source:cursor branch:main' --refresh --json
```

The CLI search accepts the same label syntax as the app toolbar search:

- `title:`
- `project:`
- `branch:`
- `source:`
- `model:`
- `id:`
- `transcript:`
