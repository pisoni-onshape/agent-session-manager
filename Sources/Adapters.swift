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
            VSCodeCopilotAdapter(root: roots.vscodeWorkspaceStorage)
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

    private static func formatDurationForLog(_ duration: Duration) -> String {
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

    private static func timeInterval(for duration: Duration) -> TimeInterval {
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
        guard session.source == .copilotCLI,
              let metadataPath = session.rawMetadataPath else { return nil }

        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Write name and user_named to workspace.yaml
        guard FlatYAMLWriter.updateValues(at: metadataPath, updates: [
            "name": trimmed,
            "user_named": "true"
        ]) else { return nil }

        // Update the in-memory record
        let updated = session.with(title: trimmed)
        try store.updateTitle(for: session.id, newTitle: trimmed)
        return updated
    }
}

public struct CopilotCLIAdapter: SessionSourceAdapter {
    let root: URL

    func scanCandidates() throws -> [SessionScanCandidate] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        let sessionDirectories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter(\.hasDirectoryPath)

        return sessionDirectories.map { sessionDirectory in
            let workspaceURL = sessionDirectory.appendingPathComponent("workspace.yaml")
            let eventLogURL = sessionDirectory.appendingPathComponent("events.jsonl")
            let checkpointIndexURL = sessionDirectory.appendingPathComponent("checkpoints/index.md")
            let relatedPlanPath = SessionArtifactLocator.preferredPlanPath(in: sessionDirectory)
            let sessionID = sessionDirectory.lastPathComponent
            let inProgressState = Self.checkInProgress(in: sessionDirectory)
            let fingerprint = combinedFingerprint(
                paths: [
                    workspaceURL.path,
                    FileManager.default.fileExists(atPath: eventLogURL.path) ? eventLogURL.path : checkpointIndexURL.path,
                    relatedPlanPath
                ],
                values: [inProgressState.fingerprintValue]
            )

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

struct CursorAdapter: SessionSourceAdapter {
    let root: URL
    let workspaceStorageRoot: URL
    let globalStorageRoot: URL

    func scanCandidates() throws -> [SessionScanCandidate] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        let stateDatabaseURL = globalStorageRoot.appendingPathComponent("state.vscdb")
        let workspaceReferences = try loadWorkspaceReferencesByProjectDirectory()
        let titleReferences = try loadTitleReferencesBySessionID(from: stateDatabaseURL)
        let planReferences = try loadPlanReferencesBySessionID(from: stateDatabaseURL)
        let projectDirectories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter(\.hasDirectoryPath)

        return try projectDirectories.flatMap { projectDirectory -> [SessionScanCandidate] in
            let transcriptRoot = projectDirectory.appendingPathComponent("agent-transcripts", isDirectory: true)
            guard FileManager.default.fileExists(atPath: transcriptRoot.path) else { return [] }

            let workspaceReference = workspaceReferences[projectDirectory.lastPathComponent]
            let workspacePath = workspaceReference?.workspacePath
                ?? PathUtilities.decodeCursorWorkspacePath(from: projectDirectory.lastPathComponent)
            let fallbackProjectName = workspaceReference?.projectName
                ?? PathUtilities.cursorFallbackProjectName(from: projectDirectory.lastPathComponent)
            let projectName = PathUtilities.displayProjectName(workspacePath: workspacePath, fallback: fallbackProjectName)

            let sessionDirectories = try FileManager.default.contentsOfDirectory(at: transcriptRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                .filter(\.hasDirectoryPath)

            return sessionDirectories.map { sessionDirectory in
                let sessionID = sessionDirectory.lastPathComponent
                let transcriptFile = sessionDirectory.appendingPathComponent("\(sessionDirectory.lastPathComponent).jsonl")
                let relatedPlanPath = planReferences[sessionID]?.path
                    ?? SessionArtifactLocator.preferredPlanPath(in: sessionDirectory)
                let titleReference = titleReferences[sessionID]
                let fingerprint = combinedFingerprint(
                    paths: [transcriptFile.path, relatedPlanPath, workspaceReference?.metadataPath],
                    values: [titleReference?.title]
                )

                return SessionScanCandidate(
                    id: "\(SessionSource.cursor.rawValue)::\(sessionID)",
                    fingerprint: fingerprint,
                    isInProgress: false,
                    loadRecord: {
                        try loadRecord(
                            sessionID: sessionID,
                            transcriptFile: transcriptFile,
                            workspacePath: workspacePath,
                            projectName: projectName,
                            preferredTitle: titleReference?.title,
                            relatedPlanPath: relatedPlanPath,
                            fingerprint: fingerprint
                        )
                    }
                )
            }
        }
    }

    private func loadWorkspaceReferencesByProjectDirectory() throws -> [String: CursorWorkspaceReference] {
        guard FileManager.default.fileExists(atPath: workspaceStorageRoot.path) else { return [:] }

        let workspaceDirectories = try FileManager.default.contentsOfDirectory(
            at: workspaceStorageRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter(\.hasDirectoryPath)

        var references: [String: CursorWorkspaceReference] = [:]
        for workspaceDirectory in workspaceDirectories {
            let workspaceJSONURL = workspaceDirectory.appendingPathComponent("workspace.json")
            guard FileManager.default.fileExists(atPath: workspaceJSONURL.path),
                  let metadata = try loadJSONDictionary(from: workspaceJSONURL),
                  let workspaceURI = (metadata["folder"] as? String) ?? (metadata["workspace"] as? String),
                  let workspacePath = PathUtilities.workspacePathFromFileURI(workspaceURI) else {
                continue
            }

            let projectDirectoryName = PathUtilities.cursorProjectDirectoryName(forWorkspacePath: workspacePath)
            guard !projectDirectoryName.isEmpty else { continue }
            references[projectDirectoryName] = CursorWorkspaceReference(
                workspacePath: workspacePath,
                projectName: PathUtilities.displayProjectName(
                    workspacePath: workspacePath,
                    fallback: workspaceDirectory.lastPathComponent
                ),
                metadataPath: workspaceJSONURL.path
            )
        }
        return references
    }

    private func loadTitleReferencesBySessionID(from stateDatabaseURL: URL) throws -> [String: CursorTitleReference] {
        guard FileManager.default.fileExists(atPath: stateDatabaseURL.path),
              let rawValue = try loadSQLiteItemValue(from: stateDatabaseURL, key: "composer.composerHeaders"),
              let data = rawValue.data(using: .utf8) else {
            return [:]
        }

        let payload = try JSONDecoder().decode(CursorComposerHeadersPayload.self, from: data)
        return Dictionary(
            uniqueKeysWithValues: payload.allComposers.compactMap { header in
                guard let title = header.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty else {
                    return nil
                }
                return (header.composerId, CursorTitleReference(title: title))
            }
        )
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

    private func loadRecord(
        sessionID: String,
        transcriptFile: URL,
        workspacePath: String?,
        projectName: String,
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
            branch: nil,
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
}

private struct CursorWorkspaceReference {
    let workspacePath: String
    let projectName: String
    let metadataPath: String
}

private struct CursorTitleReference {
    let title: String
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

private struct CursorComposerHeadersPayload: Decodable {
    let allComposers: [CursorComposerHeader]
}

private struct CursorComposerHeader: Decodable {
    let composerId: String
    let name: String?
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

private struct VSCodeSessionReference {
    let sessionID: String
    let transcriptFile: URL
}

public struct VSCodeCopilotAdapter: SessionSourceAdapter {
    let root: URL

    func scanCandidates() throws -> [SessionScanCandidate] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        let workspaceDirectories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter(\.hasDirectoryPath)

        return try workspaceDirectories.flatMap { workspaceDirectory -> [SessionScanCandidate] in
            let workspaceJSONURL = workspaceDirectory.appendingPathComponent("workspace.json")
            guard FileManager.default.fileExists(atPath: workspaceJSONURL.path) else {
                return []
            }

            let metadata = try loadJSONDictionary(from: workspaceJSONURL)
            let workspacePath = PathUtilities.workspacePathFromFileURI((metadata?["folder"] as? String) ?? (metadata?["workspace"] as? String))
            let projectName = PathUtilities.displayProjectName(workspacePath: workspacePath, fallback: workspaceDirectory.lastPathComponent)
            let sessionReferences = try discoverSessionReferences(in: workspaceDirectory)
            guard !sessionReferences.isEmpty else {
                return []
            }

            let activeSessionIDs = Self.activeSessionIDs(in: workspaceDirectory)

            return try sessionReferences.map { reference in
                let sessionMetadata = try TranscriptPreviewExtractor.extractVSCodeSessionMetadata(from: reference.transcriptFile)
                let sessionID = sessionMetadata.sessionId ?? reference.sessionID
                let title = sessionMetadata.title ?? TextSanitizer.inferTitle(
                    from: sessionMetadata.firstUser,
                    fallback: sessionID
                )
                let relatedPlanPath = SessionArtifactLocator.vscodePlanPath(workspaceDirectory: workspaceDirectory, sessionId: sessionID)
                let isActive = activeSessionIDs.contains(sessionID)
                let fingerprint = combinedFingerprint(
                    paths: [
                        reference.transcriptFile.path,
                        workspaceJSONURL.path,
                        relatedPlanPath
                    ],
                    values: [isActive ? "active" : "inactive"]
                )

                return SessionScanCandidate(
                    id: "\(SessionSource.vscodeCopilot.rawValue)::\(sessionID)",
                    fingerprint: fingerprint,
                    isInProgress: isActive,
                    loadRecord: {
                        try loadRecord(
                            transcriptFile: reference.transcriptFile,
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

    private func discoverSessionReferences(in workspaceDirectory: URL) throws -> [VSCodeSessionReference] {
        var referencesBySessionID: [String: VSCodeSessionReference] = [:]
        let legacyTranscriptDirectory = workspaceDirectory.appendingPathComponent("GitHub.copilot-chat/transcripts", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacyTranscriptDirectory.path) {
            let transcriptFiles = try FileManager.default.contentsOfDirectory(
                at: legacyTranscriptDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension.lowercased() == "jsonl" }

            for transcriptFile in transcriptFiles {
                let preview = try TranscriptPreviewExtractor.extractEventTranscript(from: transcriptFile)
                let sessionID = preview.sessionId ?? transcriptFile.deletingPathExtension().lastPathComponent
                referencesBySessionID[sessionID] = VSCodeSessionReference(
                    sessionID: sessionID,
                    transcriptFile: transcriptFile
                )
            }
        }

        let chatSessionsDirectory = workspaceDirectory.appendingPathComponent("chatSessions", isDirectory: true)
        if FileManager.default.fileExists(atPath: chatSessionsDirectory.path) {
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

            for chatSessionFile in chatSessionFiles {
                let sessionMetadata = try TranscriptPreviewExtractor.extractVSCodeSessionMetadata(from: chatSessionFile)
                let sessionID = sessionMetadata.sessionId ?? chatSessionFile.deletingPathExtension().lastPathComponent
                if let existing = referencesBySessionID[sessionID],
                   existing.transcriptFile.deletingLastPathComponent().lastPathComponent == "chatSessions" {
                    continue
                }

                referencesBySessionID[sessionID] = VSCodeSessionReference(
                    sessionID: sessionID,
                    transcriptFile: chatSessionFile
                )
            }
        }

        return referencesBySessionID.values.sorted {
            $0.sessionID.localizedCaseInsensitiveCompare($1.sessionID) == .orderedAscending
        }
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
