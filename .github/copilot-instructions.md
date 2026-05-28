# Agent Session Manager Copilot Instructions

## Build and test commands

- Prerequisite: install XcodeGen with `brew install xcodegen`
- Default local build/install flow: `./build.sh`
  - Runs `xcodegen generate`
  - Builds the `AgentSessionManager` scheme in **Release**
  - Stamps `CURRENT_PROJECT_VERSION` and `MARKETING_VERSION`
  - Installs the app to `/Applications/AgentSessionManager.app`
  - Symlinks the bundled CLI helper to `/usr/local/bin/agent-session-manager`
- CI-style package without local install: `./build.sh --ci-package --output-dir build/artifacts`
- Regenerate and open the Xcode project for local iteration: `xcodegen generate && open AgentSessionManager.xcodeproj`
- Run the full test suite: `xcodebuild -project AgentSessionManager.xcodeproj -scheme AgentSessionManager -destination 'platform=macOS' test`
- Run one test case: `xcodebuild -project AgentSessionManager.xcodeproj -scheme AgentSessionManager -destination 'platform=macOS' -only-testing:AgentSessionManagerTests/SessionSearchCLITests test`
- Run one test method: `xcodebuild -project AgentSessionManager.xcodeproj -scheme AgentSessionManager -destination 'platform=macOS' -only-testing:AgentSessionManagerTests/SessionSearchCLITests/testHumanReadableOutputShowsSeparatePlanMatches test`

## High-level architecture

- `project.yml` defines four targets: `AgentSessionManagerCore` holds the shared indexing/search/storage code, `AgentSessionManager` is the SwiftUI macOS app, `AgentSessionManagerCLI` is the bundled CLI entry point, and `AgentSessionManagerTests` exercises both app and core behavior.
- `SessionCatalog` in `Sources/Adapters.swift` is the indexing orchestrator. It owns the Copilot CLI, Cursor, and VS Code Copilot adapters, scans each source root in parallel, fingerprints session artifacts, reuses unchanged records when possible, and writes only the changed records back to the local catalog.
- `SQLiteSessionStore` in `Sources/Storage.swift` is the local persistence layer at `~/Library/Application Support/AgentSessionManager/catalog.sqlite3`. It stores normalized session metadata, star preferences, and the transcript index that powers both the app and the CLI.
- `SessionSearchService` and `SessionSearchCLI` share the same search pipeline. Toolbar search in the app and `agent-session-manager search` both rely on the same `SessionFilterState`, query parser, search evaluator, and transcript index lookups, so search behavior should stay aligned across both surfaces.
- `SessionBrowserViewModel` in `Sources/ViewModel.swift` is the app-side bridge. It wraps `SessionCatalog` behind a serial queue controller, drives refresh/rebuild/search work off the main actor, and publishes the resulting session state into `ContentView`.
- Transcript and plan loading are normalized before indexing. `TranscriptPreviewExtractor` in `Sources/Utilities.swift` turns source-specific transcript formats into shared transcript and plan documents that can be displayed in-app and searched uniformly.

## Key conventions

- Prefer the **Release** configuration for app builds by default. When building or reporting an app bundle path, use the Release app path unless the task explicitly calls for Debug.
- Treat `./build.sh` as the required local build/install command. Do not document direct `xcodebuild` app builds as the normal workflow unless the task specifically asks for them.
- Shared logic belongs in `AgentSessionManagerCore`. Keep `Sources/CLI/main.swift` as a thin entry point that delegates into `SessionSearchCLI`, and put reusable search/indexing logic in core so the app and CLI stay in sync.
- Keep source-specific parsing inside the adapters and transcript utilities. The rest of the codebase works with normalized `SessionRecord`, `TranscriptDocument`, and `TranscriptIndexEntry` values rather than raw Copilot/Cursor/VS Code storage formats.
- Preserve the incremental refresh model. Adapters fingerprint transcript, metadata, plan, and in-progress artifacts; unchanged sessions should be reused without reparsing whenever possible. `SessionCatalogRefreshTests` covers this behavior.
- Plan files are first-class searchable content. `TranscriptPreviewExtractor.searchableEntries(for:)` appends plan chunks with negative `entryIndex` values, and `SessionSearchService` interprets negative index hits as plan matches rather than transcript hits.
- The label search syntax is shared between GUI and CLI. `project:`, `branch:`, `source:`, `title:`, `model:`, `id:`, `transcript:`, and `plan:` clauses are parsed centrally; if search behavior changes, keep both app and CLI output aligned and update the parser and CLI tests together.
- Use `AppPaths` and `SourceRoots.live` instead of hardcoded filesystem locations. Live session data comes from user directories under `~/.copilot`, `~/.cursor`, and VS Code workspace storage, while the app writes only its own catalog under Application Support.
- Newton repo detection is settings-driven. `SessionCatalog.reclassifySessions` uses `NewtonProjectMatcher` with the configured repos root, so new features should not hardcode Newton-specific paths.
- After completing a coherent set of requested changes, create a git commit before finishing, and keep the commit scoped to the work you actually changed.
