# Agent Session Manager

A native macOS app (with a companion CLI) that gives you a single, searchable view of every AI coding conversation you've had — across **GitHub Copilot CLI**, **Cursor**, **VS Code Copilot**, and **Claude Code** (CLI, VS Code, and Desktop) — all without modifying any of the original session data.

If you regularly use more than one AI coding tool, your conversation history ends up fragmented: Copilot CLI sessions live under `~/.copilot/`, Cursor transcripts under `~/.cursor/`, VS Code Copilot transcripts in `~/Library/Application Support/Code/`, and Claude Code sessions under `~/.claude/projects/`. Agent Session Manager indexes all of them into a single local catalog and lets you search, filter, star, and resume any session in seconds.

---

## Why Use It

- **One place for everything.** Stop hunting across three different storage locations to find that conversation where you debugged a tricky issue last week.
- **Deep transcript search.** Search not just session titles and metadata, but the full transcript text — find the exact conversation where you discussed a specific class, error message, or design decision.
- **Instant resume.** One click to resume a Copilot CLI or Claude Code CLI session, reopen a workspace in Cursor or VS Code, or reveal a transcript — right from the session card.
- **Star and organize.** Star important sessions so they float to the top. Filter by source, project, branch, or starred status.
- **Completely read-only.** The app never modifies your original session files. It maintains its own lightweight SQLite catalog alongside them.
- **CLI for automation.** The companion `agent-session-manager` command lets you search your session history from the terminal, pipe results as JSON into scripts, or let other AI agents query your past conversations programmatically.

---

## Key Features

### Session Browser (GUI)

| Feature | Description |
|---------|-------------|
| **Unified session list** | Card-based list showing sessions from every supported source with official app icons |
| **Rich filtering** | Filter by source (Copilot CLI / Cursor / VS Code Copilot / Claude Code CLI / Claude Code VS Code / Claude Desktop), project name, branch, starred status, and Newton repos |
| **Full-text search** | Toolbar search matches session metadata and indexed transcript contents as you type |
| **Label search syntax** | Use `title:`, `project:`, `branch:`, `source:`, `model:`, `id:`, and `transcript:` labels for precise queries |
| **Star sessions** | Persist star/unstar across refreshes — starred sessions are grouped at the top with a visual divider |
| **One-click actions** | Resume Copilot CLI and Claude Code CLI sessions, open workspaces in Cursor or VS Code, reveal transcript files in Finder |
| **Start new conversation** | Launch a new AI session in the same project workspace directly from the detail pane |
| **In-app transcript viewer** | Read the full conversation in a separate window — no need to open raw JSONL files |
| **In-app plan viewer** | Open a session's plan.md in the built-in viewer, including Cursor-linked plans stored under `~/.cursor/plans`, with a default-app fallback available from that viewer |
| **Detail pane metadata** | See project, branch, workspace path, model info, session timestamps, and first-message previews at a glance |
| **Copy buttons** | Quickly copy session ID, workspace path, or transcript path to the clipboard |
| **Auto-refresh** | Configurable timer refresh, launch refresh, and optional deferral of scheduled refreshes while the app is active |
| **Incremental refresh** | Only reparses sessions whose files actually changed — fast even with thousands of sessions |
| **Settings** | Launch at Login, Newton repos path, and auto-refresh timing/deferral controls (Settings → Preferences) |

### Companion CLI

The `agent-session-manager` command provides the same search capabilities from the terminal:

```bash
# Search across all sessions
agent-session-manager search --query 'auth bug'

# Search within transcript text for a specific term
agent-session-manager search --query 'transcript:"insertable display data"'

# Filter by project and branch
agent-session-manager search --query 'project:newton5 branch:master'

# Only Cursor sessions from the last week, as JSON
agent-session-manager search --query 'source:cursor' --within 1w --json

# Newton repos only, starred sessions
agent-session-manager search --query 'drag bug' --newton-only --starred

# Refresh the catalog first, then search
agent-session-manager search --query 'plan update' --refresh --limit 10
```

**CLI options:**

| Option | Description |
|--------|-------------|
| `--query <text>` | Search using label syntax (same as the app toolbar) |
| `--search <text>` | Top-level alias for `--query` |
| `--project <name>` | Restrict to one project |
| `--branch <name>` | Restrict to one branch |
| `--source <source>` | Restrict to one source: `copilot-cli`, `cursor`, `vscode-copilot`, `claude-code-cli`, `claude-code-vscode`, or `claude-desktop` (aliases: `claude`, `claude-cli`, `claude-code`) |
| `--newton-only` | Restrict to Newton repos only |
| `--starred` | Only starred sessions |
| `--unstarred` | Only unstarred sessions |
| `--refresh` | Refresh the catalog before searching |
| `--within <duration>` | Time window filter: `30m`, `12h`, `1d`, `1w` |
| `--limit <count>` | Cap the number of results |
| `--json` | Emit machine-readable JSON output |

**Use from other AI agents:** The `--json` flag makes it straightforward for Copilot CLI, Cursor, or any scripted workflow to query your past sessions programmatically. For example, an AI agent could search for how you solved a similar problem before, or check which branches you've been working on recently.

---

## How to Use

### Install

1. Clone the repository and run the build script:

   ```bash
   git clone <repo-url>
   cd agent-session-manager
   ./build.sh
   ```

2. The build script installs:
   - **App** → `/Applications/AgentSessionManager.app`
   - **CLI** → `/usr/local/bin/agent-session-manager`

3. Launch the app from `/Applications` or Spotlight.

### First Launch

On first launch the app performs an initial scan of all three session stores and builds the SQLite catalog. This takes a few seconds depending on how many sessions you have. Subsequent launches use incremental refresh — only changed sessions are re-indexed.

### Searching

Type in the toolbar search field (⌘K to focus) to search across session titles, project names, branches, and transcript text. Use label prefixes for targeted searches:

```
transcript:"memory leak"          # find conversations mentioning "memory leak"
project:newton5 branch:master     # sessions in newton5 on master
source:cursor                     # only Cursor sessions
title:"plan update"               # match session titles
```

### Starring

Click the star icon on any session card to pin it. Starred sessions are grouped at the top of the list and persist across app relaunches and catalog refreshes.

### Resuming Sessions

Each session card shows a primary action button:
- **Copilot CLI** → "Resume in Copilot" — reconnects to the exact session via `copilot --resume`
- **Claude Code CLI** → "Resume in Claude" — reconnects to the exact session via `claude --resume`
- **Claude Desktop** → "Resume in Claude" (via `claude --resume`) plus "Open in Claude Desktop" — a `claude://code/new?folder=…` deep link that opens Desktop's Code section in the workspace (Desktop can't reopen an existing session by id, so this starts a new one)
- **Cursor** / **VS Code Copilot** / **Claude Code VS Code** → "Open in Cursor" / "Open in VS Code" — opens the workspace in the editor
- If the workspace path can't be resolved → "Reveal Transcript" — opens Finder to the raw file

### Viewing Transcripts

Click "View Transcript" in the detail pane to open the full conversation in a separate window. Internal tool-call events are collapsed by default for readability.

### Settings

Open **Settings** (⌘,) to configure:
- **Launch at Login** — start the app automatically
- **Newton repos path** — root directory for Newton repo detection
- **Auto Session Refresh** — timer interval, active-use deferral, and launch-trigger behavior

---

## Data Storage

| What | Where |
|------|-------|
| SQLite catalog | `~/Library/Application Support/AgentSessionManager/catalog.sqlite3` |
| Starred sessions | Stored alongside the catalog (never modifies source files) |
| Copilot CLI sessions (source) | `~/.copilot/session-state/` |
| Cursor sessions (source) | `~/.cursor/projects/` and `~/.cursor/User/workspaceStorage/` |
| VS Code Copilot sessions (source) | `~/Library/Application Support/Code/User/workspaceStorage/` |
| Claude Code sessions — CLI, VS Code & Desktop (sources) | `~/.claude/projects/` (split by each session's `entrypoint`) |
| Claude Desktop session titles | `~/Library/Application Support/Claude/claude-code-sessions/` (joined by `cliSessionId`; renames write back here) |

The app is **read-only** — it indexes the source directories but never writes to them.

---

## Building from Source

### Prerequisites

- macOS 14+
- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

### Build and Install

```bash
./build.sh
```

This:
1. Runs `xcodegen generate` to produce the Xcode project
2. Builds a Release configuration
3. Stamps the version automatically
4. Closes any running instance of the app
5. Installs to `/Applications/AgentSessionManager.app`
6. Symlinks the CLI to `/usr/local/bin/agent-session-manager`

To build the same Release app for CI without installing it locally:

```bash
./build.sh --ci-package --output-dir build/artifacts
```

That leaves a zipped app bundle in `build/artifacts/`.

### Development

For iterating in Xcode:

```bash
xcodegen generate
open AgentSessionManager.xcodeproj
```

To run tests:

```bash
xcodebuild -project AgentSessionManager.xcodeproj -scheme AgentSessionManager -destination 'platform=macOS' test
```

### GitHub Actions deploy flow

- Pushes to `master` build the Release app, zip `AgentSessionManager.app`, and upload it as a workflow artifact.
- Pushes of release tags matching `v*` do the same build/package step and also publish the zip to the matching GitHub Release.
- The workflow lives at `.github/workflows/deploy.yml`.

The easiest way to publish a new release package is:

```bash
git checkout master
git pull --ff-only
git tag -a v1.2.3 -m "Release v1.2.3"
git push origin v1.2.3
```

That tag push creates or updates the GitHub Release for `v1.2.3` and uploads the packaged app zip.

### Project Structure

| File | Purpose |
|------|---------|
| `.github/workflows/deploy.yml` | Builds Release artifacts on `master` and publishes tagged releases |
| `Sources/Models.swift` | Session types, filter/sort state, source definitions |
| `Sources/Adapters.swift` | Read-only scanners for Copilot CLI, Cursor, VS Code, and Claude Code stores |
| `Sources/Storage.swift` | SQLite catalog — persistence, search index, migrations |
| `Sources/ViewModel.swift` | App state, refresh, search, filter, and action wiring |
| `Sources/ContentView.swift` | SwiftUI list/detail browser UI |
| `Sources/SettingsView.swift` | Settings dialog |
| `Sources/SessionSearchCLI.swift` | CLI search command parser and executor |
| `Sources/Utilities.swift` | Path helpers, transcript parsing, text cleanup |
| `build.sh` | Build, version-stamp, and install script |
| `project.yml` | XcodeGen project definition |
