import Foundation
import OSLog

struct SessionScanCandidate {
    let id: String
    let fingerprint: String
    let isInProgress: Bool
    let loadRecord: () throws -> SessionRecord?
}

protocol SessionSourceAdapter {
    func scanCandidates() throws -> [SessionScanCandidate]
}

extension SessionSourceAdapter {
    func discover() throws -> [SessionRecord] {
        try scanCandidates().compactMap { try $0.loadRecord() }
    }
}

public final class SessionCatalog {
    private let store: SQLiteSessionStore
    private let adapters: [SessionSourceAdapter]
    private let settingsProvider: () -> AppSettingsSnapshot
    private static let logger = Logger(subsystem: "com.pisoni.AgentSessionManager", category: "SessionCatalog")

    init(
        storeURL: URL,
        roots: SourceRoots = .live,
        settingsProvider: @escaping () -> AppSettingsSnapshot = { AppSettingsSnapshot.standard() },
        adaptersOverride: [SessionSourceAdapter]? = nil
    ) throws {
        store = try SQLiteSessionStore(databaseURL: storeURL)
        self.settingsProvider = settingsProvider
        adapters = adaptersOverride ?? [
            CopilotCLIAdapter(root: roots.copilotCLI),
            CursorAdapter(
                root: roots.cursorProjects,
                workspaceStorageRoot: roots.cursorWorkspaceStorage,
                globalStorageRoot: roots.cursorGlobalStorage
            ),
            VSCodeCopilotAdapter(root: roots.vscodeWorkspaceStorage),
            ClaudeCodeAdapter(root: roots.claudeProjects, desktopSessionsRoot: roots.claudeCodeSessions)
        ]
    }

    public static func makeDefault(settingsProvider: @escaping () -> AppSettingsSnapshot = { AppSettingsSnapshot.standard() }) throws -> SessionCatalog {
        try SessionCatalog(storeURL: AppPaths.catalogDatabaseURL, settingsProvider: settingsProvider)
    }

    public func loadPersistedSessions() throws -> [SessionRecord] {
        reclassifySessions(try store.fetchAll())
    }

    public func starredSessionIDs() throws -> Set<String> {
        try store.fetchStarredSessionIDs()
    }

    public func setSessionStarred(_ isStarred: Bool, for sessionID: String) throws {
        try store.setSessionStarred(isStarred, for: sessionID)
    }

    public func searchTranscriptIndex(
        sessionIDs: [String],
        query: String,
        scope: TranscriptSearchScope = .all
    ) throws -> [TranscriptIndexSearchHit] {
        try store.searchTranscriptEntries(sessionIDs: sessionIDs, query: query, scope: scope)
    }

    public func reclassifySessions(_ records: [SessionRecord]) -> [SessionRecord] {
        let matcher = NewtonProjectMatcher(reposRootPath: settingsProvider().newtonReposRootPath)
        return records.map { record in
            record.with(isNewtonProject: matcher.matches(workspacePath: record.workspacePath))
        }
    }

    public func refreshSessions() throws -> [SessionRecord] {
        let clock = ContinuousClock()
        let refreshStart = clock.now

        let stateLoadStart = clock.now
        let existingRecords = try store.fetchAll()
        let existingByID = Dictionary(uniqueKeysWithValues: existingRecords.map { ($0.id, $0) })
        let indexedSessionIDs = try store.indexedSessionIDs(for: Array(existingByID.keys))
        let stateLoadDuration = clock.now - stateLoadStart

        let scanResults = try parallelMap(adapters) { adapter in
            let scanStart = clock.now
            let scannedCandidates = try adapter.scanCandidates()
            return TimedScanResult(
                adapterName: String(describing: type(of: adapter)),
                candidates: scannedCandidates,
                duration: clock.now - scanStart
            )
        }
        let candidates = scanResults.flatMap(\.candidates)
        let adapterScanDuration = scanResults.reduce(into: Duration.zero) { partialResult, result in
            partialResult += result.duration
        }
        let adapterScanSummaries = scanResults.map {
            "\($0.adapterName): \($0.candidates.count) candidates in \(Self.formatDurationForLog($0.duration))"
        }
        let matcher = NewtonProjectMatcher(reposRootPath: settingsProvider().newtonReposRootPath)

        var refreshedRecordsByID: [String: SessionRecord] = [:]
        var changedRecords: [SessionRecord] = []
        var transcriptEntriesBySessionID: [String: [TranscriptIndexEntry]] = [:]
        var recordLoadDuration: Duration = .zero
        var transcriptExtractionDuration: Duration = .zero
        var reusedCandidateCount = 0
        var loadedCandidateCount = 0
        var fallbackCandidateCount = 0
        var candidatesNeedingLoad: [SessionScanCandidate] = []

        for candidate in candidates {
            if let existingRecord = existingByID[candidate.id],
               existingRecord.fingerprint == candidate.fingerprint,
               indexedSessionIDs.contains(candidate.id) {
                reusedCandidateCount += 1
                let reclassifiedRecord = existingRecord
                    .with(isNewtonProject: matcher.matches(workspacePath: existingRecord.workspacePath))
                    .with(isInProgress: candidate.isInProgress)
                refreshedRecordsByID[candidate.id] = reclassifiedRecord
                if reclassifiedRecord.isNewtonProject != existingRecord.isNewtonProject {
                    changedRecords.append(reclassifiedRecord)
                }
                continue
            }
            candidatesNeedingLoad.append(candidate)
        }

        let loadResults = try parallelMap(candidatesNeedingLoad) { candidate in
            let loadStart = clock.now
            let loadedRecord = try candidate.loadRecord()
            let loadDuration = clock.now - loadStart

            guard let loadedRecord else {
                return RefreshLoadResult(
                    candidateID: candidate.id,
                    isInProgress: candidate.isInProgress,
                    record: nil,
                    transcriptEntries: [],
                    loadDuration: loadDuration,
                    transcriptExtractionDuration: .zero
                )
            }

            let transcriptExtractionStart = clock.now
            let transcriptEntries = try TranscriptPreviewExtractor.searchableEntries(for: loadedRecord)
            let transcriptExtractionDuration = clock.now - transcriptExtractionStart
            return RefreshLoadResult(
                candidateID: candidate.id,
                isInProgress: candidate.isInProgress,
                record: loadedRecord,
                transcriptEntries: transcriptEntries,
                loadDuration: loadDuration,
                transcriptExtractionDuration: transcriptExtractionDuration
            )
        }
        recordLoadDuration = loadResults.reduce(into: Duration.zero) { partialResult, result in
            partialResult += result.loadDuration
        }
        transcriptExtractionDuration = loadResults.reduce(into: Duration.zero) { partialResult, result in
            partialResult += result.transcriptExtractionDuration
        }

        for result in loadResults {
            if let record = result.record {
                loadedCandidateCount += 1
                let reclassifiedRecord = record.with(isNewtonProject: matcher.matches(workspacePath: record.workspacePath))
                refreshedRecordsByID[reclassifiedRecord.id] = reclassifiedRecord
                changedRecords.append(reclassifiedRecord)
                transcriptEntriesBySessionID[reclassifiedRecord.id] = result.transcriptEntries
            } else if let existingRecord = existingByID[result.candidateID] {
                fallbackCandidateCount += 1
                let reclassifiedRecord = existingRecord
                    .with(isNewtonProject: matcher.matches(workspacePath: existingRecord.workspacePath))
                    .with(isInProgress: result.isInProgress)
                refreshedRecordsByID[result.candidateID] = reclassifiedRecord
                if reclassifiedRecord.isNewtonProject != existingRecord.isNewtonProject {
                    changedRecords.append(reclassifiedRecord)
                }
            }
        }

        let removedIDs = Set(existingByID.keys).subtracting(refreshedRecordsByID.keys)
        let storeUpdateStart = clock.now
        try store.applyIncrementalUpdate(
            records: changedRecords,
            removedIDs: Array(removedIDs),
            transcriptEntriesBySessionID: transcriptEntriesBySessionID
        )
        let storeUpdateDuration = clock.now - storeUpdateStart
        let totalDuration = clock.now - refreshStart

        Self.logger.info(
            "\(self.refreshLogSummary(candidates: candidates.count, reused: reusedCandidateCount, loaded: loadedCandidateCount, fallback: fallbackCandidateCount, removed: removedIDs.count, stateLoadDuration: stateLoadDuration, adapterScanDuration: adapterScanDuration, recordLoadDuration: recordLoadDuration, transcriptExtractionDuration: transcriptExtractionDuration, storeDuration: storeUpdateDuration, totalDuration: totalDuration), privacy: .public)"
        )
        if !adapterScanSummaries.isEmpty {
            Self.logger.info("Refresh adapter timings: \(adapterScanSummaries.joined(separator: ", "), privacy: .public)")
        }

        return refreshedRecordsByID.values.sorted(by: SessionCatalog.sort(lhs:rhs:))
    }

    public func rebuildSessions() throws -> [SessionRecord] {
        let clock = ContinuousClock()
        let rebuildStart = clock.now

        let scanResults = try parallelMap(adapters) { adapter in
            let scanStart = clock.now
            let scannedCandidates = try adapter.scanCandidates()
            return TimedScanResult(
                adapterName: String(describing: type(of: adapter)),
                candidates: scannedCandidates,
                duration: clock.now - scanStart
            )
        }
        let candidates = scanResults.flatMap(\.candidates)
        let adapterScanDuration = scanResults.reduce(into: Duration.zero) { partialResult, result in
            partialResult += result.duration
        }
        let adapterScanSummaries = scanResults.map {
            "\($0.adapterName): \($0.candidates.count) candidates in \(Self.formatDurationForLog($0.duration))"
        }

        let loadResults = try parallelMap(candidates) { candidate in
            let loadStart = clock.now
            let record = try candidate.loadRecord()
            return RebuildLoadResult(
                record: record,
                loadDuration: clock.now - loadStart
            )
        }
        let recordLoadDuration = loadResults.reduce(into: Duration.zero) { partialResult, result in
            partialResult += result.loadDuration
        }
        let loadedRecords = loadResults.compactMap(\.record)

        let records = reclassifySessions(loadedRecords.sorted(by: SessionCatalog.sort(lhs:rhs:)))
        let indexResults = try parallelMap(records) { record in
            let transcriptExtractionStart = clock.now
            let transcriptEntries = try TranscriptPreviewExtractor.searchableEntries(for: record)
            return RebuildIndexResult(
                sessionID: record.id,
                transcriptEntries: transcriptEntries,
                duration: clock.now - transcriptExtractionStart
            )
        }
        let transcriptExtractionDuration = indexResults.reduce(into: Duration.zero) { partialResult, result in
            partialResult += result.duration
        }
        let transcriptEntriesBySessionID = Dictionary(
            uniqueKeysWithValues: indexResults.map { ($0.sessionID, $0.transcriptEntries) }
        )

        let storeReplaceStart = clock.now
        try store.replaceAll(records: records, transcriptEntriesBySessionID: transcriptEntriesBySessionID)
        let storeReplaceDuration = clock.now - storeReplaceStart
        let totalDuration = clock.now - rebuildStart

        Self.logger.info(
            "\(self.rebuildLogSummary(candidates: candidates.count, records: records.count, adapterScanDuration: adapterScanDuration, recordLoadDuration: recordLoadDuration, transcriptExtractionDuration: transcriptExtractionDuration, storeDuration: storeReplaceDuration, totalDuration: totalDuration), privacy: .public)"
        )
        if !adapterScanSummaries.isEmpty {
            Self.logger.info("Rebuild adapter timings: \(adapterScanSummaries.joined(separator: ", "), privacy: .public)")
        }
        return records
    }

    private static func sort(lhs: SessionRecord, rhs: SessionRecord) -> Bool {
        switch (lhs.bestTimestamp, rhs.bestTimestamp) {
        case let (left?, right?) where left != right:
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            if lhs.projectName != rhs.projectName {
                return lhs.projectName.localizedCaseInsensitiveCompare(rhs.projectName) == .orderedAscending
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func refreshLogSummary(
        candidates: Int,
        reused: Int,
        loaded: Int,
        fallback: Int,
        removed: Int,
        stateLoadDuration: Duration,
        adapterScanDuration: Duration,
        recordLoadDuration: Duration,
        transcriptExtractionDuration: Duration,
        storeDuration: Duration,
        totalDuration: Duration
    ) -> String {
        "Refresh completed in \(Self.formatDurationForLog(totalDuration)) - state load: \(Self.formatDurationForLog(stateLoadDuration)), adapter scan: \(Self.formatDurationForLog(adapterScanDuration)), record load: \(Self.formatDurationForLog(recordLoadDuration)), transcript indexing: \(Self.formatDurationForLog(transcriptExtractionDuration)), sqlite update: \(Self.formatDurationForLog(storeDuration)); candidates: \(candidates), reused: \(reused), loaded: \(loaded), fallback: \(fallback), removed: \(removed)"
    }

    private func rebuildLogSummary(
        candidates: Int,
        records: Int,
        adapterScanDuration: Duration,
        recordLoadDuration: Duration,
        transcriptExtractionDuration: Duration,
        storeDuration: Duration,
        totalDuration: Duration
    ) -> String {
        "Rebuild completed in \(Self.formatDurationForLog(totalDuration)) - adapter scan: \(Self.formatDurationForLog(adapterScanDuration)), record load: \(Self.formatDurationForLog(recordLoadDuration)), transcript indexing: \(Self.formatDurationForLog(transcriptExtractionDuration)), sqlite replace: \(Self.formatDurationForLog(storeDuration)); candidates: \(candidates), records: \(records)"
    }

    fileprivate static func formatDurationForLog(_ duration: Duration) -> String {
        let seconds = timeInterval(for: duration)
        if seconds < 1 {
            return String(format: "%.0fms", seconds * 1_000)
        }
        if seconds < 10 {
            return String(format: "%.2fs", seconds)
        }
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }

        let totalSeconds = Int(seconds.rounded())
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        if minutes < 60 {
            return "\(minutes)m \(remainingSeconds)s"
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return "\(hours)h \(remainingMinutes)m \(remainingSeconds)s"
    }

    fileprivate static func timeInterval(for duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + (TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000)
    }

    private struct TimedScanResult {
        let adapterName: String
        let candidates: [SessionScanCandidate]
        let duration: Duration
    }

    private struct RefreshLoadResult {
        let candidateID: String
        let isInProgress: Bool
        let record: SessionRecord?
        let transcriptEntries: [TranscriptIndexEntry]
        let loadDuration: Duration
        let transcriptExtractionDuration: Duration
    }

    private struct RebuildLoadResult {
        let record: SessionRecord?
        let loadDuration: Duration
    }

    private struct RebuildIndexResult {
        let sessionID: String
        let transcriptEntries: [TranscriptIndexEntry]
        let duration: Duration
    }

    private func parallelMap<Input, Output>(
        _ inputs: [Input],
        transform: @escaping (Input) throws -> Output
    ) throws -> [Output] {
        guard !inputs.isEmpty else { return [] }

        let lock = NSLock()
        var results = Array<Output?>(repeating: nil, count: inputs.count)
        var firstError: Error?

        DispatchQueue.concurrentPerform(iterations: inputs.count) { index in
            do {
                let output = try transform(inputs[index])
                lock.lock()
                results[index] = output
                lock.unlock()
            } catch {
                lock.lock()
                if firstError == nil {
                    firstError = error
                }
                lock.unlock()
            }
        }

        if let firstError {
            throw firstError
        }

        var unwrappedResults: [Output] = []
        unwrappedResults.reserveCapacity(inputs.count)
        for result in results {
            guard let result else {
                throw NSError(
                    domain: "SessionCatalog",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Parallel work completed without producing a result."
                    ]
                )
            }
            unwrappedResults.append(result)
        }
        return unwrappedResults
    }

    /// Renames a Copilot CLI session by updating workspace.yaml (name + user_named) and the catalog DB.
    /// Returns the updated SessionRecord on success, nil if the session can't be renamed.
    public func renameSession(_ session: SessionRecord, to newTitle: String) throws -> SessionRecord? {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch session.source {
        case .copilotCLI:
            // Copilot persists the title as `name` in workspace.yaml.
            guard let metadataPath = session.rawMetadataPath,
                  FlatYAMLWriter.updateValues(at: metadataPath, updates: [
                    "name": trimmed,
                    "user_named": "true"
                  ]) else { return nil }

        case .claudeDesktop where session.rawMetadataPath?.hasSuffix(".json") == true:
            // Desktop titles live in the metadata JSON; writing there round-trips with the app.
            guard let metadataPath = session.rawMetadataPath,
                  ClaudeCodeAdapter.updateDesktopTitle(atMetadataPath: metadataPath, title: trimmed) else {
                return nil
            }

        case .claudeCodeCLI, .claudeCodeVSCode, .claudeDesktop:
            // Claude titles a session by appending a `custom-title` record to its JSONL; both
            // this app and Claude Code itself use the latest such record as the title. (Also the
            // fallback for a Desktop session that has no metadata file yet.)
            guard let jsonlPath = session.rawTranscriptPath ?? session.rawMetadataPath,
                  ClaudeCodeAdapter.appendClaudeCustomTitle(at: jsonlPath, sessionId: session.sourceSessionId, title: trimmed) else {
                return nil
            }

        case .cursor, .vscodeCopilot:
            return nil
        }

        // Update the in-memory record + catalog; the next refresh re-reads the source and
        // recomputes the fingerprint (the store changed), keeping everything consistent.
        let updated = session.with(title: trimmed)
        try store.updateTitle(for: session.id, newTitle: trimmed)
        return updated
    }
}

public struct CopilotCLIAdapter: SessionSourceAdapter {
    let root: URL
    private static let logger = Logger(subsystem: "com.pisoni.AgentSessionManager", category: "CopilotCLIAdapter")

    func scanCandidates() throws -> [SessionScanCandidate] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        let clock = ContinuousClock()
        let scanStart = clock.now
        let sessionEnumerationStart = clock.now
        let sessionDirectories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter(\.hasDirectoryPath)
        let sessionEnumerationDuration = clock.now - sessionEnumerationStart

        var planLookupDuration: Duration = .zero
        var inProgressCheckDuration: Duration = .zero
        var fingerprintDuration: Duration = .zero

        let candidates = sessionDirectories.map { sessionDirectory in
            let workspaceURL = sessionDirectory.appendingPathComponent("workspace.yaml")
            let eventLogURL = sessionDirectory.appendingPathComponent("events.jsonl")
            let checkpointIndexURL = sessionDirectory.appendingPathComponent("checkpoints/index.md")
            let slackTranscriptURL = sessionDirectory.appendingPathComponent("slack-transcript.jsonl")
            let slackSessionURL = sessionDirectory.appendingPathComponent("slack-session.json")

            let planLookupStart = clock.now
            let relatedPlanPath = SessionArtifactLocator.preferredPlanPath(in: sessionDirectory)
            planLookupDuration += clock.now - planLookupStart
            let sessionID = sessionDirectory.lastPathComponent

            let inProgressCheckStart = clock.now
            let inProgressState = Self.checkInProgress(in: sessionDirectory)
            inProgressCheckDuration += clock.now - inProgressCheckStart

            let fingerprintStart = clock.now
            let fingerprint = combinedFingerprint(
                paths: [
                    workspaceURL.path,
                    FileManager.default.fileExists(atPath: eventLogURL.path) ? eventLogURL.path : checkpointIndexURL.path,
                    relatedPlanPath,
                    FileManager.default.fileExists(atPath: slackTranscriptURL.path) ? slackTranscriptURL.path : nil,
                    FileManager.default.fileExists(atPath: slackSessionURL.path) ? slackSessionURL.path : nil
                ],
                values: [inProgressState.fingerprintValue]
            )
            fingerprintDuration += clock.now - fingerprintStart

            return SessionScanCandidate(
                id: "\(SessionSource.copilotCLI.rawValue)::\(sessionID)",
                fingerprint: fingerprint,
                isInProgress: inProgressState.isActive,
                loadRecord: {
                    try loadRecord(
                        sessionDirectory: sessionDirectory,
                        workspaceURL: workspaceURL,
                        eventLogURL: eventLogURL,
                        checkpointIndexURL: checkpointIndexURL,
                        relatedPlanPath: relatedPlanPath,
                        fingerprint: fingerprint,
                        isInProgress: inProgressState.isActive
                    )
                }
            )
        }

        let totalDuration = clock.now - scanStart
        Self.logger.info(
            "Scan details - total: \(SessionCatalog.formatDurationForLog(totalDuration), privacy: .public), session enumeration: \(SessionCatalog.formatDurationForLog(sessionEnumerationDuration), privacy: .public), plan lookup: \(SessionCatalog.formatDurationForLog(planLookupDuration), privacy: .public), in-progress checks: \(SessionCatalog.formatDurationForLog(inProgressCheckDuration), privacy: .public), fingerprinting: \(SessionCatalog.formatDurationForLog(fingerprintDuration), privacy: .public); session directories: \(sessionDirectories.count), candidates: \(candidates.count)"
        )
        return candidates
    }

    /// Checks whether the session directory has an active `inuse.{PID}.lock` file with a live PID.
    public static func checkInProgress(in sessionDirectory: URL) -> InProgressState {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: sessionDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return InProgressState(isActive: false, fingerprintValue: "none")
        }

        let lockFiles = contents.filter { $0.lastPathComponent.hasPrefix("inuse.") && $0.lastPathComponent.hasSuffix(".lock") }
        guard !lockFiles.isEmpty else {
            return InProgressState(isActive: false, fingerprintValue: "none")
        }

        for lockFile in lockFiles {
            if let pidString = try? String(contentsOf: lockFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               let pid = Int32(pidString) {
                if kill(pid, 0) == 0 {
                    return InProgressState(isActive: true, fingerprintValue: "active:\(pid)")
                }
            }
        }

        return InProgressState(isActive: false, fingerprintValue: "stale:\(lockFiles.count)")
    }

    public struct InProgressState {
        public let isActive: Bool
        public let fingerprintValue: String
    }

    private func loadRecord(
        sessionDirectory: URL,
        workspaceURL: URL,
        eventLogURL: URL,
        checkpointIndexURL: URL,
        relatedPlanPath: String?,
        fingerprint: String,
        isInProgress: Bool
    ) throws -> SessionRecord? {
        guard FileManager.default.fileExists(atPath: workspaceURL.path) else { return nil }

        let yaml = try String(contentsOf: workspaceURL, encoding: .utf8)
        let metadata = FlatYAMLParser.parse(yaml)
        let eventPreview = FileManager.default.fileExists(atPath: eventLogURL.path)
            ? try? TranscriptPreviewExtractor.extractEventTranscript(from: eventLogURL)
            : nil
        let checkpointSummary = FileManager.default.fileExists(atPath: checkpointIndexURL.path)
            ? try? TranscriptPreviewExtractor.extractMarkdownSummary(from: checkpointIndexURL)
            : nil

        guard eventPreview?.firstUser != nil || eventPreview?.firstAssistant != nil else {
            return nil
        }

        let workspacePath = metadata["cwd"] ?? metadata["git_root"]
        let fallbackTitle = metadata["id"] ?? sessionDirectory.lastPathComponent
        let title = metadata["name"]
            ?? metadata["summary"]
            ?? TextSanitizer.inferTitle(from: eventPreview?.firstUser ?? checkpointSummary, fallback: fallbackTitle)

        let dates = fileDates(for: workspaceURL)
        let startedAt = ISO8601DateCoding.parse(metadata["created_at"]) ?? eventPreview?.startedAt ?? dates.created
        let updatedAt = ISO8601DateCoding.parse(metadata["updated_at"]) ?? dates.modified
        let transcriptPath = FileManager.default.fileExists(atPath: eventLogURL.path) ? eventLogURL.path : (FileManager.default.fileExists(atPath: checkpointIndexURL.path) ? checkpointIndexURL.path : nil)
        let projectName = PathUtilities.displayProjectName(workspacePath: workspacePath, fallback: metadata["repository"] ?? fallbackTitle)
        let summary = metadata["summary"] ?? eventPreview?.summary ?? checkpointSummary

        return SessionRecord(
            source: .copilotCLI,
            sourceSessionId: metadata["id"] ?? sessionDirectory.lastPathComponent,
            workspacePath: workspacePath,
            projectName: projectName,
            branch: metadata["branch"],
            conversationModel: eventPreview?.latestModel,
            startedAt: startedAt,
            updatedAt: updatedAt,
            title: title,
            summary: summary,
            firstUserPreview: eventPreview?.firstUser,
            firstAssistantPreview: eventPreview?.firstAssistant,
            rawTranscriptPath: transcriptPath,
            rawMetadataPath: workspaceURL.path,
            relatedPlanPath: relatedPlanPath,
            fingerprint: fingerprint,
            resumeKind: .copilotConnect,
            resumePayload: metadata["id"] ?? sessionDirectory.lastPathComponent,
            isNewtonProject: false,
            isInProgress: isInProgress
        )
    }
}

/// Caches the (immutable) first-record `entrypoint` classification for each session file,
/// keyed by the file's fingerprint so a changed file is re-read.
private final class ClaudeEntrypointCache {
    private struct Entry {
        let fingerprint: String
        let entrypoint: String?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// Returns `.some(entrypoint)` on a fingerprint-matched cache hit (where `entrypoint`
    /// may itself be nil), or `nil` on a miss.
    func entrypoint(for path: String, fingerprint: String) -> String?? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[path], entry.fingerprint == fingerprint else { return nil }
        return .some(entry.entrypoint)
    }

    func store(entrypoint: String?, for path: String, fingerprint: String) {
        lock.lock()
        entries[path] = Entry(fingerprint: fingerprint, entrypoint: entrypoint)
        lock.unlock()
    }

    func prune(keepingPaths: Set<String>) {
        lock.lock()
        entries = entries.filter { keepingPaths.contains($0.key) }
        lock.unlock()
    }
}

/// Indexes Claude Code sessions from the shared `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl`
/// store, splitting them into three sources by each session's first-record `entrypoint`:
/// `cli` → Claude Code CLI, `claude-vscode` → VS Code, `claude-desktop` → Desktop. Sessions with
/// any other entrypoint (e.g. `sdk-ts` background agents) are skipped.
public struct ClaudeCodeAdapter: SessionSourceAdapter {
    let root: URL
    /// Claude Desktop's per-session metadata store; `nil` disables Desktop title enrichment.
    let desktopSessionsRoot: URL?
    private let cache = ClaudeEntrypointCache()
    private static let logger = Logger(subsystem: "com.pisoni.AgentSessionManager", category: "ClaudeCodeAdapter")

    init(root: URL, desktopSessionsRoot: URL? = nil) {
        self.root = root
        self.desktopSessionsRoot = desktopSessionsRoot
    }

    /// Title metadata Claude Desktop keeps for its "Code" tab sessions, keyed by `cliSessionId`.
    struct DesktopSessionMeta {
        let title: String?
        let titleSource: String?
        let metadataPath: String
    }

    /// Builds a `cliSessionId → DesktopSessionMeta` map from the Desktop metadata store. This is
    /// what Claude Desktop displays as the session title, so Desktop sessions prefer it.
    ///
    /// A `cliSessionId` can have MORE THAN ONE metadata file: resuming a session via the
    /// `claude://resume` deep link makes Desktop write a second, title-less `local_<cliSessionId>`
    /// file (shown in Desktop as "General coding session"). We must not let that null-title
    /// duplicate clobber the real title, so per session we keep the best entry: a usable title
    /// beats none, a user-set title beats an auto one, and newer breaks ties.
    private func loadDesktopMetadata() -> [String: DesktopSessionMeta] {
        guard let desktopSessionsRoot,
              FileManager.default.fileExists(atPath: desktopSessionsRoot.path),
              let enumerator = FileManager.default.enumerator(
                at: desktopSessionsRoot,
                includingPropertiesForKeys: [.contentModificationDateKey]
              ) else {
            return [:]
        }

        struct Candidate {
            let meta: DesktopSessionMeta
            let rank: Int
            let modified: Date
        }

        var best: [String: Candidate] = [:]
        for case let url as URL in enumerator
        where url.lastPathComponent.hasPrefix("local_") && url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cliSessionId = object["cliSessionId"] as? String else {
                continue
            }

            let title = object["title"] as? String
            let titleSource = object["titleSource"] as? String
            let hasTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let rank = hasTitle ? (titleSource == "user" ? 2 : 1) : 0
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let candidate = Candidate(
                meta: DesktopSessionMeta(title: title, titleSource: titleSource, metadataPath: url.path),
                rank: rank,
                modified: modified
            )

            if let existing = best[cliSessionId] {
                if rank > existing.rank || (rank == existing.rank && modified > existing.modified) {
                    best[cliSessionId] = candidate
                }
            } else {
                best[cliSessionId] = candidate
            }
        }

        return best.mapValues(\.meta)
    }

    /// Rewrites the `title`/`titleSource` fields of a Desktop metadata JSON file (preserving the
    /// rest), so a rename here round-trips with the Claude Desktop app. Returns false if the file
    /// is not a Desktop metadata file or cannot be written.
    static func updateDesktopTitle(atMetadataPath path: String, title: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["cliSessionId"] != nil else {
            return false
        }
        object["title"] = title
        object["titleSource"] = "user"
        guard let output = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return false
        }
        do {
            try output.write(to: url)
            return true
        } catch {
            return false
        }
    }

    func scanCandidates() throws -> [SessionScanCandidate] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        let projectDirectories = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.filter(\.hasDirectoryPath) ?? []

        let desktopMetadata = loadDesktopMetadata()
        var candidates: [SessionScanCandidate] = []
        var seenPaths: Set<String> = []

        for projectDirectory in projectDirectories {
            // Only top-level `.jsonl` files are sessions; the `<uuid>/` subdirectories hold
            // subagent + tool-result sidecars and must never be treated as sessions.
            let sessionFiles = (try? FileManager.default.contentsOfDirectory(
                at: projectDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ))?.filter { !$0.hasDirectoryPath && $0.pathExtension.lowercased() == "jsonl" } ?? []

            for sessionFile in sessionFiles {
                seenPaths.insert(sessionFile.path)
                let classificationFingerprint = fileFingerprint(for: sessionFile.path)
                let entrypoint: String? = cache.entrypoint(for: sessionFile.path, fingerprint: classificationFingerprint)
                    ?? {
                        let resolved = Self.classifyEntrypoint(of: sessionFile)
                        cache.store(entrypoint: resolved, for: sessionFile.path, fingerprint: classificationFingerprint)
                        return resolved
                    }()

                guard let source = Self.source(forEntrypoint: entrypoint) else { continue }

                let sessionID = sessionFile.deletingPathExtension().lastPathComponent
                // Desktop sessions carry their authoritative title in the Desktop metadata store;
                // fold its path into the fingerprint so title changes there trigger a re-index.
                let desktopMeta = source == .claudeDesktop ? desktopMetadata[sessionID] : nil
                let fingerprint = combinedFingerprint(
                    paths: [sessionFile.path, desktopMeta?.metadataPath],
                    values: [source.rawValue]
                )

                candidates.append(
                    SessionScanCandidate(
                        id: "\(source.rawValue)::\(sessionID)",
                        fingerprint: fingerprint,
                        isInProgress: false,
                        loadRecord: {
                            try Self.loadRecord(
                                sessionFile: sessionFile,
                                source: source,
                                sessionId: sessionID,
                                fingerprint: fingerprint,
                                desktopMeta: desktopMeta
                            )
                        }
                    )
                )
            }
        }

        cache.prune(keepingPaths: seenPaths)
        Self.logger.info("Scanned \(projectDirectories.count) Claude project directories, \(candidates.count) candidates")
        return candidates
    }

    /// Reads a bounded prefix of the file and returns the first record's `entrypoint`. The very
    /// first line is often a metadata record (`mode`/`summary`) without an entrypoint, so we scan
    /// forward to the first record that carries one.
    static func classifyEntrypoint(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 262_144) else { return nil }

        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("\"entrypoint\"") else { continue }
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let entrypoint = object["entrypoint"] as? String else {
                continue
            }
            return entrypoint
        }
        return nil
    }

    /// Appends a `{"type":"custom-title", ...}` record to a Claude session JSONL, ensuring it
    /// starts on its own line. Both this app and Claude Code treat the latest such record as the
    /// session title. Returns false if the file cannot be written.
    static func appendClaudeCustomTitle(at path: String, sessionId: String, title: String) -> Bool {
        let record: [String: Any] = ["type": "custom-title", "customTitle": title, "sessionId": sessionId]
        // `forUpdatingAtPath` (read+write) is required: we read the last byte to decide whether a
        // separating newline is needed. A write-only handle would fail that read with EBADF.
        guard let recordData = try? JSONSerialization.data(withJSONObject: record),
              let handle = FileHandle(forUpdatingAtPath: path) else {
            return false
        }
        defer { try? handle.close() }

        do {
            let end = try handle.seekToEnd()
            var payload = Data()
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                let lastByte = try handle.read(upToCount: 1)
                if lastByte != Data([0x0A]) { payload.append(0x0A) }
                try handle.seekToEnd()
            }
            payload.append(recordData)
            payload.append(0x0A)
            try handle.write(contentsOf: payload)
            return true
        } catch {
            return false
        }
    }

    static func source(forEntrypoint entrypoint: String?) -> SessionSource? {
        switch entrypoint {
        case "cli":
            return .claudeCodeCLI
        case "claude-vscode":
            return .claudeCodeVSCode
        case "claude-desktop":
            return .claudeDesktop
        default:
            // `sdk-ts`, unknown, or missing → not a user-facing Claude Code session.
            return nil
        }
    }

    private static func loadRecord(
        sessionFile: URL,
        source: SessionSource,
        sessionId: String,
        fingerprint: String,
        desktopMeta: DesktopSessionMeta?
    ) throws -> SessionRecord? {
        let preview = try TranscriptPreviewExtractor.extractClaudeCodePreview(from: sessionFile)
        guard preview.firstUser != nil || preview.firstAssistant != nil else { return nil }

        let workspacePath = preview.cwd
        // Desktop sessions prefer the title the Claude Desktop app shows (its metadata store);
        // otherwise use Claude's own JSONL titles (user-set, then AI-generated), then infer one.
        let title = TextSanitizer.compact(desktopMeta?.title)
            ?? TextSanitizer.compact(preview.customTitle)
            ?? TextSanitizer.compact(preview.aiTitle)
            ?? TextSanitizer.inferTitle(from: preview.firstUser ?? preview.firstAssistant, fallback: sessionId)
        let dates = fileDates(for: sessionFile)
        let projectName = PathUtilities.displayProjectName(workspacePath: workspacePath, fallback: sessionId)

        // Prefer the most recently referenced plan file that actually exists — the transcript may
        // also mention example or superseded plan paths that were never written.
        let relatedPlanPath: String? = preview.planPaths
            .reversed()
            .lazy
            .map { ($0 as NSString).expandingTildeInPath }
            .first(where: { FileManager.default.fileExists(atPath: $0) })

        // Rename target: Desktop sessions write back to their metadata JSON (round-trips with the
        // Desktop app); CLI/VS Code sessions append a custom-title record to the JSONL itself.
        let metadataPath = desktopMeta?.metadataPath ?? sessionFile.path

        let resumeKind: ResumeActionKind
        let resumePayload: String
        switch source {
        case .claudeCodeVSCode:
            resumeKind = .openInVSCode
            resumePayload = workspacePath ?? sessionFile.path
        case .claudeDesktop:
            // Resume the exact conversation back inside the Desktop app it came from.
            resumeKind = .resumeInClaudeDesktop
            resumePayload = sessionId
        default: // .claudeCodeCLI resumes in Terminal.
            resumeKind = .claudeResume
            resumePayload = sessionId
        }

        return SessionRecord(
            source: source,
            sourceSessionId: sessionId,
            workspacePath: workspacePath,
            projectName: projectName,
            branch: preview.gitBranch,
            conversationModel: preview.latestModel,
            startedAt: preview.startedAt ?? dates.created,
            updatedAt: preview.updatedAt ?? dates.modified,
            title: title,
            summary: preview.summary,
            firstUserPreview: preview.firstUser,
            firstAssistantPreview: preview.firstAssistant,
            rawTranscriptPath: sessionFile.path,
            rawMetadataPath: metadataPath,
            relatedPlanPath: relatedPlanPath,
            fingerprint: fingerprint,
            resumeKind: resumeKind,
            resumePayload: resumePayload,
            isNewtonProject: false,
            isInProgress: false
        )
    }
}

struct CursorAdapter: SessionSourceAdapter {
    let root: URL
    let workspaceStorageRoot: URL
    let globalStorageRoot: URL
    private static let logger = Logger(subsystem: "com.pisoni.AgentSessionManager", category: "CursorAdapter")

    func scanCandidates() throws -> [SessionScanCandidate] {
        let hasProjectsRoot = FileManager.default.fileExists(atPath: root.path)
        let hasWorkspaceStorage = FileManager.default.fileExists(atPath: workspaceStorageRoot.path)
        let hasGlobalStorage = FileManager.default.fileExists(atPath: globalStorageRoot.path)
        guard hasProjectsRoot || hasWorkspaceStorage || hasGlobalStorage else { return [] }

        let clock = ContinuousClock()
        let scanStart = clock.now
        let stateDatabaseURL = globalStorageRoot.appendingPathComponent("state.vscdb")

        let workspaceReferenceLoadStart = clock.now
        let workspaceReferences = try loadWorkspaceReferences()
        let workspaceReferenceLoadDuration = clock.now - workspaceReferenceLoadStart
        let workspaceReferencesByProjectDirectory = Dictionary(
            uniqueKeysWithValues: workspaceReferences.compactMap { reference in
                reference.projectDirectoryName.map { ($0, reference) }
            }
        )
        let workspaceReferencesByPath = Dictionary(
            uniqueKeysWithValues: workspaceReferences.map { ($0.workspacePath, $0) }
        )

        let composerHeaderLoadStart = clock.now
        let composerHeadersBySessionID = try loadComposerHeadersBySessionID(from: stateDatabaseURL)
        let composerHeaderLoadDuration = clock.now - composerHeaderLoadStart

        let workspaceComposerLoadStart = clock.now
        let workspaceComposerMetadataBySessionID = try loadWorkspaceComposerMetadataBySessionID(
            workspaceReferences: workspaceReferences
        )
        let workspaceComposerLoadDuration = clock.now - workspaceComposerLoadStart

        let planReferenceLoadStart = clock.now
        let planReferences = try loadPlanReferencesBySessionID(from: stateDatabaseURL)
        let planReferenceLoadDuration = clock.now - planReferenceLoadStart

        let fileBackedCandidates = try loadFileBackedCandidates(
            workspaceReferencesByProjectDirectory: workspaceReferencesByProjectDirectory,
            composerHeadersBySessionID: composerHeadersBySessionID,
            workspaceComposerMetadataBySessionID: workspaceComposerMetadataBySessionID,
            planReferences: planReferences
        )
        let workspaceChatCandidates = try loadWorkspaceChatCandidates(
            workspaceReferences: workspaceReferences,
            planReferences: planReferences
        )
        let globalComposerCandidates = try loadGlobalComposerCandidates(
            stateDatabaseURL: stateDatabaseURL,
            workspaceReferencesByPath: workspaceReferencesByPath,
            composerHeadersBySessionID: composerHeadersBySessionID,
            workspaceComposerMetadataBySessionID: workspaceComposerMetadataBySessionID,
            planReferences: planReferences
        )

        var candidatesByID: [String: PrioritizedCursorCandidate] = [:]
        for candidate in fileBackedCandidates + globalComposerCandidates + workspaceChatCandidates {
            if let existing = candidatesByID[candidate.candidate.id] {
                if candidate.priority < existing.priority {
                    candidatesByID[candidate.candidate.id] = candidate
                }
            } else {
                candidatesByID[candidate.candidate.id] = candidate
            }
        }
        let candidates = candidatesByID.values
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return lhs.priority < rhs.priority
                }
                return lhs.candidate.id.localizedStandardCompare(rhs.candidate.id) == .orderedAscending
            }
            .map(\.candidate)

        let totalDuration = clock.now - scanStart
        Self.logger.info(
            "Scan details - total: \(SessionCatalog.formatDurationForLog(totalDuration), privacy: .public), workspace references: \(SessionCatalog.formatDurationForLog(workspaceReferenceLoadDuration), privacy: .public), composer headers: \(SessionCatalog.formatDurationForLog(composerHeaderLoadDuration), privacy: .public), workspace composer metadata: \(SessionCatalog.formatDurationForLog(workspaceComposerLoadDuration), privacy: .public), plan references: \(SessionCatalog.formatDurationForLog(planReferenceLoadDuration), privacy: .public); workspace references: \(workspaceReferences.count), workspace composer sessions: \(workspaceComposerMetadataBySessionID.count), file candidates: \(fileBackedCandidates.count), workspace chat candidates: \(workspaceChatCandidates.count), global composer candidates: \(globalComposerCandidates.count), deduped candidates: \(candidates.count)"
        )
        return candidates
    }

    private func loadWorkspaceReferences() throws -> [CursorWorkspaceReference] {
        guard FileManager.default.fileExists(atPath: workspaceStorageRoot.path) else { return [] }

        let workspaceDirectories = try FileManager.default.contentsOfDirectory(
            at: workspaceStorageRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter(\.hasDirectoryPath)

        var references: [CursorWorkspaceReference] = []
        for workspaceDirectory in workspaceDirectories {
            let workspaceJSONURL = workspaceDirectory.appendingPathComponent("workspace.json")
            guard FileManager.default.fileExists(atPath: workspaceJSONURL.path),
                  let metadata = try loadJSONDictionary(from: workspaceJSONURL),
                  let workspaceURI = (metadata["folder"] as? String) ?? (metadata["workspace"] as? String),
                  let workspacePath = PathUtilities.workspacePathFromFileURI(workspaceURI) else {
                continue
            }

            let projectDirectoryName = PathUtilities.cursorProjectDirectoryName(forWorkspacePath: workspacePath)
            references.append(
                CursorWorkspaceReference(
                    workspaceDirectory: workspaceDirectory,
                    projectDirectoryName: projectDirectoryName.isEmpty ? nil : projectDirectoryName,
                    workspacePath: workspacePath,
                    projectName: PathUtilities.displayProjectName(
                        workspacePath: workspacePath,
                        fallback: workspaceDirectory.lastPathComponent
                    ),
                    metadataPath: workspaceJSONURL.path
                )
            )
        }
        return references
    }

    private func loadComposerHeadersBySessionID(from stateDatabaseURL: URL) throws -> [String: CursorComposerHeader] {
        guard FileManager.default.fileExists(atPath: stateDatabaseURL.path),
              let rawValue = try loadSQLiteItemValue(from: stateDatabaseURL, key: "composer.composerHeaders"),
              let data = rawValue.data(using: .utf8) else {
            return [:]
        }

        let payload = try JSONDecoder().decode(CursorComposerHeadersPayload.self, from: data)
        return Dictionary(
            uniqueKeysWithValues: payload.allComposers.compactMap { header in
                guard !header.composerId.isEmpty else {
                    return nil
                }
                return (header.composerId, header)
            }
        )
    }

    private func loadBubbleEvidenceBySessionID(from stateDatabaseURL: URL) throws -> [String: CursorBubbleSessionEvidence] {
        guard FileManager.default.fileExists(atPath: stateDatabaseURL.path) else {
            return [:]
        }

        let rawValues: [String: String]
        do {
            rawValues = try loadSQLiteValues(from: stateDatabaseURL, table: "cursorDiskKV", keyLike: "bubbleId:%:%")
        } catch {
            if isMissingSQLiteTableError(error, table: "cursorDiskKV") {
                return [:]
            }
            throw error
        }

        var rowsBySessionID: [String: [(String, String)]] = [:]
        for (key, rawValue) in rawValues {
            guard let sessionID = parseBubbleSessionID(from: key) else {
                continue
            }
            rowsBySessionID[sessionID, default: []].append((key, rawValue))
        }

        return rowsBySessionID.mapValues(CursorBubbleSessionEvidence.init(rows:))
    }

    private func loadWorkspaceComposerMetadataBySessionID(
        workspaceReferences: [CursorWorkspaceReference]
    ) throws -> [String: CursorWorkspaceComposerMetadata] {
        var metadataBySessionID: [String: CursorWorkspaceComposerMetadata] = [:]

        for workspaceReference in workspaceReferences {
            let stateDatabaseURL = workspaceReference.workspaceDirectory.appendingPathComponent("state.vscdb")
            guard FileManager.default.fileExists(atPath: stateDatabaseURL.path) else {
                continue
            }

            let rawValue: String?
            do {
                rawValue = try loadSQLiteItemValue(from: stateDatabaseURL, key: "composer.composerData")
            } catch {
                if isMissingSQLiteTableError(error, table: "ItemTable") {
                    continue
                }
                throw error
            }

            guard let rawValue,
                  let data = rawValue.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(CursorWorkspaceComposerDataPayload.self, from: data) else {
                continue
            }

            for composer in payload.allComposers where !composer.composerId.isEmpty {
                let candidate = CursorWorkspaceComposerMetadata(
                    workspaceReference: workspaceReference,
                    title: composer.title,
                    branch: composer.createdOnBranch?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                    updatedAt: composer.updatedAtDate
                )
                if let existing = metadataBySessionID[composer.composerId] {
                    if candidate.shouldReplace(existing) {
                        metadataBySessionID[composer.composerId] = candidate
                    }
                } else {
                    metadataBySessionID[composer.composerId] = candidate
                }
            }
        }

        return metadataBySessionID
    }

    private func loadFileBackedCandidates(
        workspaceReferencesByProjectDirectory: [String: CursorWorkspaceReference],
        composerHeadersBySessionID: [String: CursorComposerHeader],
        workspaceComposerMetadataBySessionID: [String: CursorWorkspaceComposerMetadata],
        planReferences: [String: CursorPlanReference]
    ) throws -> [PrioritizedCursorCandidate] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        let projectDirectories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter(\.hasDirectoryPath)

        return try projectDirectories.flatMap { projectDirectory -> [PrioritizedCursorCandidate] in
            let transcriptRoot = projectDirectory.appendingPathComponent("agent-transcripts", isDirectory: true)
            guard FileManager.default.fileExists(atPath: transcriptRoot.path) else { return [] }

            let workspaceReference = workspaceReferencesByProjectDirectory[projectDirectory.lastPathComponent]
            let workspacePath = workspaceReference?.workspacePath
                ?? PathUtilities.decodeCursorWorkspacePath(from: projectDirectory.lastPathComponent)
            let fallbackProjectName = workspaceReference?.projectName
                ?? PathUtilities.cursorFallbackProjectName(from: projectDirectory.lastPathComponent)
            let projectName = PathUtilities.displayProjectName(workspacePath: workspacePath, fallback: fallbackProjectName)

            let sessionDirectories = try FileManager.default.contentsOfDirectory(
                at: transcriptRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter(\.hasDirectoryPath)

            return sessionDirectories.map { sessionDirectory in
                let sessionID = sessionDirectory.lastPathComponent
                let transcriptFile = sessionDirectory.appendingPathComponent("\(sessionDirectory.lastPathComponent).jsonl")
                let relatedPlanPath = planReferences[sessionID]?.path
                    ?? SessionArtifactLocator.preferredPlanPath(in: sessionDirectory)
                let composerHeader = composerHeadersBySessionID[sessionID]
                let workspaceComposerMetadata = workspaceComposerMetadataBySessionID[sessionID]
                let preferredTitle = composerHeader?.title ?? workspaceComposerMetadata?.title
                let branch = workspaceComposerMetadata?.branch

                let fingerprint = combinedFingerprint(
                    paths: [transcriptFile.path, relatedPlanPath, workspaceReference?.metadataPath],
                    values: [preferredTitle, composerHeader?.versionFingerprint, branch]
                )

                return PrioritizedCursorCandidate(
                    priority: 0,
                    candidate: SessionScanCandidate(
                        id: "\(SessionSource.cursor.rawValue)::\(sessionID)",
                        fingerprint: fingerprint,
                        isInProgress: false,
                        loadRecord: {
                            try loadFileBackedRecord(
                                sessionID: sessionID,
                                transcriptFile: transcriptFile,
                                workspacePath: workspacePath,
                                projectName: projectName,
                                branch: branch,
                                preferredTitle: preferredTitle,
                                relatedPlanPath: relatedPlanPath,
                                fingerprint: fingerprint
                            )
                        }
                    )
                )
            }
        }
    }

    private func loadWorkspaceChatCandidates(
        workspaceReferences: [CursorWorkspaceReference],
        planReferences: [String: CursorPlanReference]
    ) throws -> [PrioritizedCursorCandidate] {
        try workspaceReferences.flatMap { workspaceReference -> [PrioritizedCursorCandidate] in
            let chatSessionsDirectory = workspaceReference.workspaceDirectory.appendingPathComponent("chatSessions", isDirectory: true)
            guard FileManager.default.fileExists(atPath: chatSessionsDirectory.path) else {
                return []
            }

            let chatSessionFiles = try FileManager.default.contentsOfDirectory(
                at: chatSessionsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter { ["json", "jsonl"].contains($0.pathExtension.lowercased()) }
            .sorted { lhs, rhs in
                let lhsPriority = lhs.pathExtension.lowercased() == "json" ? 0 : 1
                let rhsPriority = rhs.pathExtension.lowercased() == "json" ? 0 : 1
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
            }

            var sessionsByID: [String: CursorWorkspaceChatSession] = [:]
            for chatSessionFile in chatSessionFiles {
                let metadata = try TranscriptPreviewExtractor.extractWorkspaceChatSessionMetadata(from: chatSessionFile)
                let sessionID = metadata.sessionId ?? chatSessionFile.deletingPathExtension().lastPathComponent
                if sessionsByID[sessionID] != nil {
                    continue
                }
                sessionsByID[sessionID] = CursorWorkspaceChatSession(
                    transcriptFile: chatSessionFile,
                    metadata: metadata
                )
            }

            return sessionsByID.map { sessionID, session in
                let title = session.metadata.title ?? TextSanitizer.inferTitle(
                    from: session.metadata.firstUser,
                    fallback: sessionID
                )
                let relatedPlanPath = planReferences[sessionID]?.path
                    ?? SessionArtifactLocator.vscodePlanPath(
                        workspaceDirectory: workspaceReference.workspaceDirectory,
                        sessionId: sessionID
                    )
                let fingerprint = combinedFingerprint(
                    paths: [session.transcriptFile.path, workspaceReference.metadataPath, relatedPlanPath],
                    values: [title, session.metadata.latestModel]
                )

                return PrioritizedCursorCandidate(
                    priority: 2,
                    candidate: SessionScanCandidate(
                        id: "\(SessionSource.cursor.rawValue)::\(sessionID)",
                        fingerprint: fingerprint,
                        isInProgress: false,
                        loadRecord: {
                            try loadWorkspaceChatRecord(
                                transcriptFile: session.transcriptFile,
                                workspaceReference: workspaceReference,
                                relatedPlanPath: relatedPlanPath,
                                sessionID: sessionID,
                                sessionMetadata: session.metadata,
                                title: title,
                                fingerprint: fingerprint
                            )
                        }
                    )
                )
            }
        }
    }

    private func loadGlobalComposerCandidates(
        stateDatabaseURL: URL,
        workspaceReferencesByPath: [String: CursorWorkspaceReference],
        composerHeadersBySessionID: [String: CursorComposerHeader],
        workspaceComposerMetadataBySessionID: [String: CursorWorkspaceComposerMetadata],
        planReferences: [String: CursorPlanReference]
    ) throws -> [PrioritizedCursorCandidate] {
        guard FileManager.default.fileExists(atPath: stateDatabaseURL.path) else {
            return []
        }

        let bubbleEvidenceBySessionID = try loadBubbleEvidenceBySessionID(from: stateDatabaseURL)
        let sessionIDs = Set(composerHeadersBySessionID.keys)
            .union(bubbleEvidenceBySessionID.keys)
            .union(workspaceComposerMetadataBySessionID.keys)

        return sessionIDs.sorted().map { sessionID in
            let composerHeader = composerHeadersBySessionID[sessionID]
            let workspaceComposerMetadata = workspaceComposerMetadataBySessionID[sessionID]
            let bubbleEvidence = bubbleEvidenceBySessionID[sessionID]
            let workspacePath = composerHeader?.workspacePath ?? workspaceComposerMetadata?.workspaceReference.workspacePath
            let workspaceReference = workspacePath.flatMap { workspaceReferencesByPath[$0] }
                ?? workspaceComposerMetadata?.workspaceReference
            let projectName = PathUtilities.displayProjectName(
                workspacePath: workspacePath,
                fallback: workspaceReference?.projectName ?? sessionID
            )
            let relatedPlanPath = planReferences[sessionID]?.path
            let preferredTitle = composerHeader?.title ?? workspaceComposerMetadata?.title
            let branch = workspaceComposerMetadata?.branch
            let startedAt = composerHeader?.startedAtDate ?? bubbleEvidence?.startedAt
            let updatedAt = composerHeader?.updatedAtDate
                ?? workspaceComposerMetadata?.updatedAt
                ?? bubbleEvidence?.updatedAt
                ?? composerHeader?.startedAtDate
                ?? bubbleEvidence?.startedAt
            let fingerprint = combinedFingerprint(
                paths: [relatedPlanPath, workspaceReference?.metadataPath],
                values: [
                    preferredTitle,
                    composerHeader?.versionFingerprint,
                    workspaceComposerMetadata?.versionFingerprint,
                    workspacePath,
                    branch,
                    bubbleEvidence?.fingerprint
                ]
            )

            return PrioritizedCursorCandidate(
                priority: 1,
                candidate: SessionScanCandidate(
                    id: "\(SessionSource.cursor.rawValue)::\(sessionID)",
                    fingerprint: fingerprint,
                    isInProgress: false,
                    loadRecord: {
                        try loadGlobalComposerRecord(
                            sessionID: sessionID,
                            stateDatabaseURL: stateDatabaseURL,
                            workspaceReference: workspaceReference,
                            fallbackWorkspacePath: workspacePath,
                            fallbackProjectName: projectName,
                            branch: branch,
                            preferredTitle: preferredTitle,
                            startedAt: startedAt,
                            updatedAt: updatedAt,
                            relatedPlanPath: relatedPlanPath,
                            fingerprint: fingerprint
                        )
                    }
                )
            )
        }
    }

    private func loadPlanReferencesBySessionID(from stateDatabaseURL: URL) throws -> [String: CursorPlanReference] {
        guard FileManager.default.fileExists(atPath: stateDatabaseURL.path),
              let rawRegistry = try loadSQLiteItemValue(from: stateDatabaseURL, key: "composer.planRegistry"),
              let registryData = rawRegistry.data(using: .utf8) else {
            return [:]
        }

        let registryPayload = try JSONDecoder().decode(CursorPlanRegistryPayload.self, from: registryData)
        let planPathByID = registryPayload.planEntriesByID.compactMapValues(\.resolvedPath)
        guard !planPathByID.isEmpty else {
            return [:]
        }

        let tabStateValues = try loadSQLiteItemValues(
            from: stateDatabaseURL,
            keyLike: "cursor/glass.tabs.v2/%/state.json"
        )
        guard !tabStateValues.isEmpty else {
            return [:]
        }

        let decoder = JSONDecoder()
        var referencesBySessionID: [String: CursorPlanReference] = [:]
        for rawValue in tabStateValues.values {
            guard let data = rawValue.data(using: .utf8) else { continue }
            let tabState = try decoder.decode(CursorGlassTabsState.self, from: data)

            for planTab in tabState.planTabs {
                guard let planID = planTab.props?.planId,
                      let planPath = planPathByID[planID] else {
                    continue
                }

                let sessionID = planTab.props?.ownerAgentId ?? tabState.agentId
                guard let sessionID, !sessionID.isEmpty else {
                    continue
                }

                let candidate = CursorPlanReference(
                    path: planPath,
                    planID: planID,
                    lastActiveTime: planTab.lastActiveTime ?? 0
                )
                if let existing = referencesBySessionID[sessionID] {
                    if candidate.shouldReplace(existing) {
                        referencesBySessionID[sessionID] = candidate
                    }
                } else {
                    referencesBySessionID[sessionID] = candidate
                }
            }
        }

        return referencesBySessionID
    }

    private func loadFileBackedRecord(
        sessionID: String,
        transcriptFile: URL,
        workspacePath: String?,
        projectName: String,
        branch: String?,
        preferredTitle: String?,
        relatedPlanPath: String?,
        fingerprint: String
    ) throws -> SessionRecord? {
        guard FileManager.default.fileExists(atPath: transcriptFile.path) else { return nil }

        let preview = try TranscriptPreviewExtractor.extractCursorTranscript(from: transcriptFile)
        let dates = fileDates(for: transcriptFile)
        let title = preferredTitle ?? TextSanitizer.inferTitle(from: preview.firstUser, fallback: sessionID)

        guard preview.firstUser != nil || preview.firstAssistant != nil else {
            return nil
        }

        return SessionRecord(
            source: .cursor,
            sourceSessionId: sessionID,
            workspacePath: workspacePath,
            projectName: projectName,
            branch: branch,
            conversationModel: nil,
            startedAt: dates.created,
            updatedAt: dates.modified,
            title: title,
            summary: preview.summary,
            firstUserPreview: preview.firstUser,
            firstAssistantPreview: preview.firstAssistant,
            rawTranscriptPath: transcriptFile.path,
            rawMetadataPath: nil,
            relatedPlanPath: relatedPlanPath,
            fingerprint: fingerprint,
            resumeKind: workspacePath == nil ? .revealPath : .openInCursor,
            resumePayload: workspacePath ?? transcriptFile.path,
            isNewtonProject: false
        )
    }

    private func loadWorkspaceChatRecord(
        transcriptFile: URL,
        workspaceReference: CursorWorkspaceReference,
        relatedPlanPath: String?,
        sessionID: String,
        sessionMetadata: VSCodeSessionMetadata,
        title: String,
        fingerprint: String
    ) throws -> SessionRecord? {
        guard FileManager.default.fileExists(atPath: transcriptFile.path),
              FileManager.default.fileExists(atPath: workspaceReference.metadataPath) else {
            return nil
        }

        let dates = fileDates(for: transcriptFile)
        guard sessionMetadata.firstUser != nil || sessionMetadata.firstAssistant != nil else {
            return nil
        }

        return SessionRecord(
            source: .cursor,
            sourceSessionId: sessionID,
            workspacePath: workspaceReference.workspacePath,
            projectName: workspaceReference.projectName,
            branch: nil,
            conversationModel: sessionMetadata.latestModel,
            startedAt: sessionMetadata.startedAt ?? dates.created,
            updatedAt: sessionMetadata.updatedAt ?? dates.modified,
            title: title,
            summary: sessionMetadata.summary,
            firstUserPreview: sessionMetadata.firstUser,
            firstAssistantPreview: sessionMetadata.firstAssistant,
            rawTranscriptPath: transcriptFile.path,
            rawMetadataPath: workspaceReference.metadataPath,
            relatedPlanPath: relatedPlanPath,
            fingerprint: fingerprint,
            resumeKind: .openInCursor,
            resumePayload: workspaceReference.workspacePath,
            isNewtonProject: false
        )
    }

    private func loadGlobalComposerRecord(
        sessionID: String,
        stateDatabaseURL: URL,
        workspaceReference: CursorWorkspaceReference?,
        fallbackWorkspacePath: String?,
        fallbackProjectName: String,
        branch: String?,
        preferredTitle: String?,
        startedAt: Date?,
        updatedAt: Date?,
        relatedPlanPath: String?,
        fingerprint: String
    ) throws -> SessionRecord? {
        guard FileManager.default.fileExists(atPath: stateDatabaseURL.path) else {
            return nil
        }

        let preview = try TranscriptPreviewExtractor.extractCursorBubbleTranscript(
            from: stateDatabaseURL,
            sessionId: sessionID
        )
        guard preview.firstUser != nil || preview.firstAssistant != nil else {
            return nil
        }

        let workspacePath = fallbackWorkspacePath ?? workspaceReference?.workspacePath
        let title = preferredTitle ?? TextSanitizer.inferTitle(from: preview.firstUser, fallback: sessionID)

        return SessionRecord(
            source: .cursor,
            sourceSessionId: sessionID,
            workspacePath: workspacePath,
            projectName: PathUtilities.displayProjectName(workspacePath: workspacePath, fallback: fallbackProjectName),
            branch: branch,
            conversationModel: nil,
            startedAt: startedAt ?? preview.startedAt,
            updatedAt: updatedAt ?? preview.startedAt ?? startedAt,
            title: title,
            summary: preview.summary,
            firstUserPreview: preview.firstUser,
            firstAssistantPreview: preview.firstAssistant,
            rawTranscriptPath: stateDatabaseURL.path,
            rawMetadataPath: workspaceReference?.metadataPath,
            relatedPlanPath: relatedPlanPath,
            fingerprint: fingerprint,
            resumeKind: workspacePath == nil ? .revealPath : .openInCursor,
            resumePayload: workspacePath ?? stateDatabaseURL.path,
            isNewtonProject: false
        )
    }

    private func parseBubbleSessionID(from key: String) -> String? {
        guard key.hasPrefix("bubbleId:") else {
            return nil
        }
        let remainder = key.dropFirst("bubbleId:".count)
        guard let separator = remainder.firstIndex(of: ":") else {
            return nil
        }
        let sessionID = String(remainder[..<separator])
        return sessionID.isEmpty ? nil : sessionID
    }
}

private struct PrioritizedCursorCandidate {
    let priority: Int
    let candidate: SessionScanCandidate
}

private struct CursorWorkspaceChatSession {
    let transcriptFile: URL
    let metadata: VSCodeSessionMetadata
}

private struct CursorWorkspaceReference {
    let workspaceDirectory: URL
    let projectDirectoryName: String?
    let workspacePath: String
    let projectName: String
    let metadataPath: String
}

private struct CursorWorkspaceComposerMetadata {
    let workspaceReference: CursorWorkspaceReference
    let title: String?
    let branch: String?
    let updatedAt: Date?

    var versionFingerprint: String? {
        [branch, updatedAt.map { String(Int64($0.timeIntervalSince1970 * 1000)) }]
            .compactMap { $0 }
            .joined(separator: "|")
            .nilIfEmpty
    }

    func shouldReplace(_ existing: CursorWorkspaceComposerMetadata) -> Bool {
        switch (updatedAt, existing.updatedAt) {
        case let (lhs?, rhs?) where lhs != rhs:
            return lhs > rhs
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }

        if let title, let existingTitle = existing.title, title != existingTitle {
            return title.localizedStandardCompare(existingTitle) == .orderedAscending
        }
        return workspaceReference.workspacePath.localizedStandardCompare(existing.workspaceReference.workspacePath) == .orderedAscending
    }
}

private struct CursorPlanReference {
    let path: String
    let planID: String
    let lastActiveTime: Int64

    func shouldReplace(_ existing: CursorPlanReference) -> Bool {
        if lastActiveTime != existing.lastActiveTime {
            return lastActiveTime > existing.lastActiveTime
        }
        if planID != existing.planID {
            return planID.localizedStandardCompare(existing.planID) == .orderedAscending
        }
        return path.localizedStandardCompare(existing.path) == .orderedAscending
    }
}

private struct CursorBubbleSessionEvidence {
    let startedAt: Date?
    let updatedAt: Date?
    let fingerprint: String

    init(rows: [(String, String)]) {
        let sortedRows = rows.sorted { lhs, rhs in
            lhs.0.localizedStandardCompare(rhs.0) == .orderedAscending
        }

        var timestamps: [Date] = []
        var fingerprintComponents: [String] = []
        fingerprintComponents.reserveCapacity(sortedRows.count * 2)

        for (key, rawValue) in sortedRows {
            fingerprintComponents.append(key)
            fingerprintComponents.append(rawValue)

            guard let data = rawValue.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if let timestamp = cursorBubbleTimestamp(from: object["createdAt"]) {
                timestamps.append(timestamp)
            }
        }

        startedAt = timestamps.min()
        updatedAt = timestamps.max()
        fingerprint = stableCursorSessionFingerprint(for: fingerprintComponents)
    }
}

private struct CursorComposerHeadersPayload: Decodable {
    let allComposers: [CursorComposerHeader]
}

private struct CursorWorkspaceComposerDataPayload: Decodable {
    let allComposers: [CursorWorkspaceComposerEntry]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allComposers = try container.decodeIfPresent([CursorWorkspaceComposerEntry].self, forKey: .allComposers) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case allComposers
    }
}

private struct CursorComposerHeader: Decodable {
    let composerId: String
    let name: String?
    let createdAt: Double?
    let lastUpdatedAt: Double?
    let workspaceIdentifier: CursorWorkspaceIdentifier?

    var title: String? {
        name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    var workspacePath: String? {
        workspaceIdentifier?.uri?.resolvedFilePath
    }

    var startedAtDate: Date? {
        createdAt.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    var updatedAtDate: Date? {
        lastUpdatedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    var versionFingerprint: String? {
        [createdAt, lastUpdatedAt]
            .compactMap { $0.map { String(Int64($0)) } }
            .joined(separator: "|")
            .nilIfEmpty
    }
}

private struct CursorWorkspaceComposerEntry: Decodable {
    let composerId: String
    let name: String?
    let createdOnBranch: String?
    let lastUpdatedAt: Double?

    var title: String? {
        name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    var updatedAtDate: Date? {
        lastUpdatedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

private struct CursorWorkspaceIdentifier: Decodable {
    let id: String?
    let uri: CursorPlanURI?
}

private struct CursorPlanRegistryPayload: Decodable {
    let planEntriesByID: [String: CursorPlanRegistryEntry]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        planEntriesByID = try container.decode([String: CursorPlanRegistryEntry].self)
    }
}

private struct CursorPlanRegistryEntry: Decodable {
    let uri: CursorPlanURI

    var resolvedPath: String? {
        uri.resolvedFilePath.flatMap { path in
            FileManager.default.fileExists(atPath: path) ? path : nil
        }
    }
}

private struct CursorPlanURI: Decodable {
    let fsPath: String?
    let path: String?
    let external: String?

    var resolvedFilePath: String? {
        if let fsPath, !fsPath.isEmpty {
            return URL(fileURLWithPath: fsPath).standardizedFileURL.path
        }
        if let external,
           let url = URL(string: external),
           url.isFileURL {
            return url.standardizedFileURL.path
        }
        if let path, !path.isEmpty, path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        return nil
    }
}

private struct CursorGlassTabsState: Decodable {
    let agentId: String?
    let planTabs: [CursorGlassPlanTab]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentId = try container.decodeIfPresent(String.self, forKey: .agentId)
        planTabs = try container.decodeIfPresent([CursorGlassPlanTab].self, forKey: .planTabs) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case agentId
        case planTabs
    }
}

private struct CursorGlassPlanTab: Decodable {
    let props: CursorGlassPlanTabProps?
    let lastActiveTime: Int64?
}

private struct CursorGlassPlanTabProps: Decodable {
    let planId: String?
    let ownerAgentId: String?
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private func stableCursorSessionFingerprint(for values: [String]) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    let prime: UInt64 = 0x100000001b3

    for value in values {
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        hash ^= 0xff
        hash &*= prime
    }

    return String(format: "cursor-bubbles:%016llx", hash)
}

private func cursorBubbleTimestamp(from rawValue: Any?) -> Date? {
    if let string = rawValue as? String {
        if let parsed = ISO8601DateCoding.parse(string) {
            return parsed
        }
        if let milliseconds = Double(string) {
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
    }

    if let number = rawValue as? NSNumber {
        return Date(timeIntervalSince1970: number.doubleValue / 1000)
    }

    if let milliseconds = rawValue as? Double {
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    if let milliseconds = rawValue as? Int64 {
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    if let milliseconds = rawValue as? Int {
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    return nil
}

private struct VSCodeScannedSession {
    let sessionID: String
    let transcriptFile: URL
    let sessionMetadata: VSCodeSessionMetadata
}

private struct VSCodeMetadataCacheEntry {
    let fingerprint: String
    let session: VSCodeScannedSession
}

private final class VSCodeMetadataCache {
    private let lock = NSLock()
    private var entries: [String: VSCodeMetadataCacheEntry] = [:]

    func session(for transcriptFile: URL, fingerprint: String) -> VSCodeScannedSession? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[transcriptFile.path], entry.fingerprint == fingerprint else {
            return nil
        }
        return entry.session
    }

    func store(_ session: VSCodeScannedSession, fingerprint: String) {
        lock.lock()
        entries[session.transcriptFile.path] = VSCodeMetadataCacheEntry(
            fingerprint: fingerprint,
            session: session
        )
        lock.unlock()
    }

    func prune(keepingPaths: Set<String>) {
        lock.lock()
        entries = entries.filter { keepingPaths.contains($0.key) }
        lock.unlock()
    }
}

private struct VSCodeSessionDiscoveryResult {
    let sessions: [VSCodeScannedSession]
    let seenPaths: Set<String>
    let legacyTranscriptCount: Int
    let legacyEnumerationDuration: Duration
    let legacyPreviewExtractionDuration: Duration
    let chatSessionFileCount: Int
    let chatSessionEnumerationDuration: Duration
    let chatMetadataExtractionDuration: Duration
    let metadataCacheHitCount: Int
    let metadataCacheMissCount: Int
}

public struct VSCodeCopilotAdapter: SessionSourceAdapter {
    let root: URL
    private let metadataCache: VSCodeMetadataCache
    private static let logger = Logger(subsystem: "com.pisoni.AgentSessionManager", category: "VSCodeCopilotAdapter")

    init(root: URL) {
        self.root = root
        metadataCache = VSCodeMetadataCache()
    }

    func scanCandidates() throws -> [SessionScanCandidate] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        let clock = ContinuousClock()
        let scanStart = clock.now
        let workspaceEnumerationStart = clock.now
        let workspaceDirectories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter(\.hasDirectoryPath)
        let workspaceEnumerationDuration = clock.now - workspaceEnumerationStart

        var workspaceMetadataLoadDuration: Duration = .zero
        var discoveryDuration: Duration = .zero
        var legacyTranscriptCount = 0
        var legacyEnumerationDuration: Duration = .zero
        var legacyPreviewExtractionDuration: Duration = .zero
        var chatSessionFileCount = 0
        var chatSessionEnumerationDuration: Duration = .zero
        var chatMetadataExtractionDuration: Duration = .zero
        var metadataCacheHitCount = 0
        var metadataCacheMissCount = 0
        var activeSessionLookupDuration: Duration = .zero
        var candidateConstructionDuration: Duration = .zero
        var seenPaths: Set<String> = []

        let candidates = try workspaceDirectories.flatMap { workspaceDirectory -> [SessionScanCandidate] in
            let workspaceJSONURL = workspaceDirectory.appendingPathComponent("workspace.json")
            guard FileManager.default.fileExists(atPath: workspaceJSONURL.path) else {
                return []
            }

            let workspaceMetadataLoadStart = clock.now
            let metadata = try loadJSONDictionary(from: workspaceJSONURL)
            workspaceMetadataLoadDuration += clock.now - workspaceMetadataLoadStart
            let workspacePath = PathUtilities.workspacePathFromFileURI((metadata?["folder"] as? String) ?? (metadata?["workspace"] as? String))
            let projectName = PathUtilities.displayProjectName(workspacePath: workspacePath, fallback: workspaceDirectory.lastPathComponent)

            let discoveryStart = clock.now
            let discoveryResult = try discoverSessionReferences(in: workspaceDirectory)
            discoveryDuration += clock.now - discoveryStart
            legacyTranscriptCount += discoveryResult.legacyTranscriptCount
            legacyEnumerationDuration += discoveryResult.legacyEnumerationDuration
            legacyPreviewExtractionDuration += discoveryResult.legacyPreviewExtractionDuration
            chatSessionFileCount += discoveryResult.chatSessionFileCount
            chatSessionEnumerationDuration += discoveryResult.chatSessionEnumerationDuration
            chatMetadataExtractionDuration += discoveryResult.chatMetadataExtractionDuration
            metadataCacheHitCount += discoveryResult.metadataCacheHitCount
            metadataCacheMissCount += discoveryResult.metadataCacheMissCount
            seenPaths.formUnion(discoveryResult.seenPaths)

            guard !discoveryResult.sessions.isEmpty else {
                return []
            }

            let activeSessionLookupStart = clock.now
            let activeSessionIDs = Self.activeSessionIDs(in: workspaceDirectory)
            activeSessionLookupDuration += clock.now - activeSessionLookupStart

            return discoveryResult.sessions.map { session in
                let candidateConstructionStart = clock.now
                let sessionID = session.sessionID
                let sessionMetadata = session.sessionMetadata
                let title = sessionMetadata.title ?? TextSanitizer.inferTitle(
                    from: sessionMetadata.firstUser,
                    fallback: sessionID
                )
                let relatedPlanPath = SessionArtifactLocator.vscodePlanPath(workspaceDirectory: workspaceDirectory, sessionId: sessionID)
                let isActive = activeSessionIDs.contains(sessionID)
                let fingerprint = combinedFingerprint(
                    paths: [
                        session.transcriptFile.path,
                        workspaceJSONURL.path,
                        relatedPlanPath
                    ],
                    values: [isActive ? "active" : "inactive"]
                )
                candidateConstructionDuration += clock.now - candidateConstructionStart

                return SessionScanCandidate(
                    id: "\(SessionSource.vscodeCopilot.rawValue)::\(sessionID)",
                    fingerprint: fingerprint,
                    isInProgress: isActive,
                    loadRecord: {
                        try loadRecord(
                            transcriptFile: session.transcriptFile,
                            workspaceJSONURL: workspaceJSONURL,
                            workspacePath: workspacePath,
                            projectName: projectName,
                            relatedPlanPath: relatedPlanPath,
                            sessionID: sessionID,
                            sessionMetadata: sessionMetadata,
                            title: title,
                            fingerprint: fingerprint,
                            isInProgress: isActive
                        )
                    }
                )
            }
        }

        metadataCache.prune(keepingPaths: seenPaths)

        let totalDuration = clock.now - scanStart
        Self.logger.info(
            "Scan details - total: \(SessionCatalog.formatDurationForLog(totalDuration), privacy: .public), workspace enumeration: \(SessionCatalog.formatDurationForLog(workspaceEnumerationDuration), privacy: .public), workspace metadata: \(SessionCatalog.formatDurationForLog(workspaceMetadataLoadDuration), privacy: .public), session discovery: \(SessionCatalog.formatDurationForLog(discoveryDuration), privacy: .public), legacy transcript enumeration: \(SessionCatalog.formatDurationForLog(legacyEnumerationDuration), privacy: .public), legacy preview extraction: \(SessionCatalog.formatDurationForLog(legacyPreviewExtractionDuration), privacy: .public), chat session enumeration: \(SessionCatalog.formatDurationForLog(chatSessionEnumerationDuration), privacy: .public), chat metadata extraction: \(SessionCatalog.formatDurationForLog(chatMetadataExtractionDuration), privacy: .public), active session lookup: \(SessionCatalog.formatDurationForLog(activeSessionLookupDuration), privacy: .public), candidate construction: \(SessionCatalog.formatDurationForLog(candidateConstructionDuration), privacy: .public); metadata cache hits: \(metadataCacheHitCount), misses: \(metadataCacheMissCount), workspaces: \(workspaceDirectories.count), legacy transcripts: \(legacyTranscriptCount), chat session files: \(chatSessionFileCount), candidates: \(candidates.count)"
        )
        return candidates
    }

    /// Reads `chat.terminalSessions` from the workspace's state.vscdb and returns session IDs with at least one live PID.
    public static func activeSessionIDs(in workspaceDirectory: URL) -> Set<String> {
        let stateDBURL = workspaceDirectory.appendingPathComponent("state.vscdb")
        guard FileManager.default.fileExists(atPath: stateDBURL.path) else { return [] }

        guard let jsonString = try? loadSQLiteItemValue(from: stateDBURL, key: "chat.terminalSessions"),
              let jsonData = jsonString.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return []
        }

        // parsed is {pidString: {sessionId: "...", ...}, ...}
        var liveSessionIDs: Set<String> = []
        for (pidString, value) in parsed {
            guard let pid = Int32(pidString),
                  let info = value as? [String: Any],
                  let sessionId = info["sessionId"] as? String else {
                continue
            }
            if kill(pid, 0) == 0 {
                liveSessionIDs.insert(sessionId)
            }
        }
        return liveSessionIDs
    }

    private func discoverSessionReferences(in workspaceDirectory: URL) throws -> VSCodeSessionDiscoveryResult {
        let clock = ContinuousClock()
        var sessionsByID: [String: VSCodeScannedSession] = [:]
        var seenPaths: Set<String> = []
        var legacyTranscriptCount = 0
        var legacyEnumerationDuration: Duration = .zero
        var legacyPreviewExtractionDuration: Duration = .zero
        var metadataCacheHitCount = 0
        var metadataCacheMissCount = 0
        let legacyTranscriptDirectory = workspaceDirectory.appendingPathComponent("GitHub.copilot-chat/transcripts", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacyTranscriptDirectory.path) {
            let legacyEnumerationStart = clock.now
            let transcriptFiles = try FileManager.default.contentsOfDirectory(
                at: legacyTranscriptDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension.lowercased() == "jsonl" }
            legacyEnumerationDuration += clock.now - legacyEnumerationStart
            legacyTranscriptCount = transcriptFiles.count

            for transcriptFile in transcriptFiles {
                seenPaths.insert(transcriptFile.path)
                let fingerprint = fileFingerprint(for: transcriptFile.path)
                if let cachedSession = metadataCache.session(for: transcriptFile, fingerprint: fingerprint) {
                    metadataCacheHitCount += 1
                    sessionsByID[cachedSession.sessionID] = cachedSession
                    continue
                }

                metadataCacheMissCount += 1
                let previewExtractionStart = clock.now
                let preview = try TranscriptPreviewExtractor.extractEventTranscript(from: transcriptFile)
                legacyPreviewExtractionDuration += clock.now - previewExtractionStart
                let sessionID = preview.sessionId ?? transcriptFile.deletingPathExtension().lastPathComponent
                let session = VSCodeScannedSession(
                    sessionID: sessionID,
                    transcriptFile: transcriptFile,
                    sessionMetadata: VSCodeSessionMetadata(
                        sessionId: preview.sessionId,
                        title: nil,
                        startedAt: preview.startedAt,
                        updatedAt: nil,
                        latestModel: preview.latestModel,
                        firstUser: preview.firstUser,
                        firstAssistant: preview.firstAssistant
                    )
                )
                metadataCache.store(session, fingerprint: fingerprint)
                sessionsByID[sessionID] = session
            }
        }

        var chatSessionFileCount = 0
        var chatSessionEnumerationDuration: Duration = .zero
        var chatMetadataExtractionDuration: Duration = .zero
        let chatSessionsDirectory = workspaceDirectory.appendingPathComponent("chatSessions", isDirectory: true)
        if FileManager.default.fileExists(atPath: chatSessionsDirectory.path) {
            let chatSessionEnumerationStart = clock.now
            let chatSessionFiles = try FileManager.default.contentsOfDirectory(
                at: chatSessionsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter { ["json", "jsonl"].contains($0.pathExtension.lowercased()) }
            .sorted { lhs, rhs in
                let lhsPriority = lhs.pathExtension.lowercased() == "json" ? 0 : 1
                let rhsPriority = rhs.pathExtension.lowercased() == "json" ? 0 : 1
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
            }
            chatSessionEnumerationDuration += clock.now - chatSessionEnumerationStart
            chatSessionFileCount = chatSessionFiles.count

            for chatSessionFile in chatSessionFiles {
                seenPaths.insert(chatSessionFile.path)
                let fingerprint = fileFingerprint(for: chatSessionFile.path)
                let session: VSCodeScannedSession
                if let cachedSession = metadataCache.session(for: chatSessionFile, fingerprint: fingerprint) {
                    metadataCacheHitCount += 1
                    session = cachedSession
                } else {
                    metadataCacheMissCount += 1
                    let metadataExtractionStart = clock.now
                    let sessionMetadata = try TranscriptPreviewExtractor.extractVSCodeSessionMetadata(from: chatSessionFile)
                    chatMetadataExtractionDuration += clock.now - metadataExtractionStart
                    let sessionID = sessionMetadata.sessionId ?? chatSessionFile.deletingPathExtension().lastPathComponent
                    session = VSCodeScannedSession(
                        sessionID: sessionID,
                        transcriptFile: chatSessionFile,
                        sessionMetadata: sessionMetadata
                    )
                    metadataCache.store(session, fingerprint: fingerprint)
                }

                let sessionID = session.sessionID
                if let existing = sessionsByID[sessionID],
                   existing.transcriptFile.deletingLastPathComponent().lastPathComponent == "chatSessions" {
                    continue
                }

                sessionsByID[sessionID] = session
            }
        }

        return VSCodeSessionDiscoveryResult(
            sessions: sessionsByID.values.sorted {
                $0.sessionID.localizedCaseInsensitiveCompare($1.sessionID) == .orderedAscending
            },
            seenPaths: seenPaths,
            legacyTranscriptCount: legacyTranscriptCount,
            legacyEnumerationDuration: legacyEnumerationDuration,
            legacyPreviewExtractionDuration: legacyPreviewExtractionDuration,
            chatSessionFileCount: chatSessionFileCount,
            chatSessionEnumerationDuration: chatSessionEnumerationDuration,
            chatMetadataExtractionDuration: chatMetadataExtractionDuration,
            metadataCacheHitCount: metadataCacheHitCount,
            metadataCacheMissCount: metadataCacheMissCount
        )
    }

    private func loadRecord(
        transcriptFile: URL,
        workspaceJSONURL: URL,
        workspacePath: String?,
        projectName: String,
        relatedPlanPath: String?,
        sessionID: String,
        sessionMetadata: VSCodeSessionMetadata,
        title: String,
        fingerprint: String,
        isInProgress: Bool
    ) throws -> SessionRecord? {
        guard FileManager.default.fileExists(atPath: transcriptFile.path),
              FileManager.default.fileExists(atPath: workspaceJSONURL.path) else {
            return nil
        }

        let dates = fileDates(for: transcriptFile)

        guard sessionMetadata.firstUser != nil || sessionMetadata.firstAssistant != nil else {
            return nil
        }

        return SessionRecord(
            source: .vscodeCopilot,
            sourceSessionId: sessionID,
            workspacePath: workspacePath,
            projectName: projectName,
            branch: nil,
            conversationModel: sessionMetadata.latestModel,
            startedAt: sessionMetadata.startedAt ?? dates.created,
            updatedAt: sessionMetadata.updatedAt ?? dates.modified,
            title: title,
            summary: sessionMetadata.summary,
            firstUserPreview: sessionMetadata.firstUser,
            firstAssistantPreview: sessionMetadata.firstAssistant,
            rawTranscriptPath: transcriptFile.path,
            rawMetadataPath: workspaceJSONURL.path,
            relatedPlanPath: relatedPlanPath,
            fingerprint: fingerprint,
            resumeKind: workspacePath == nil ? .revealPath : .openInVSCode,
            resumePayload: workspacePath ?? transcriptFile.path,
            isNewtonProject: false,
            isInProgress: isInProgress
        )
    }
}
