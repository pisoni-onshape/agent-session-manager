import Foundation

struct SessionScanCandidate {
    let id: String
    let fingerprint: String
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
        let existingRecords = try store.fetchAll()
        let existingByID = Dictionary(uniqueKeysWithValues: existingRecords.map { ($0.id, $0) })
        let indexedSessionIDs = try store.indexedSessionIDs(for: Array(existingByID.keys))
        let candidates = try adapters.flatMap { try $0.scanCandidates() }
        let matcher = NewtonProjectMatcher(reposRootPath: settingsProvider().newtonReposRootPath)

        var refreshedRecordsByID: [String: SessionRecord] = [:]
        var changedRecords: [SessionRecord] = []
        var transcriptEntriesBySessionID: [String: [TranscriptIndexEntry]] = [:]

        for candidate in candidates {
            if let existingRecord = existingByID[candidate.id],
               existingRecord.fingerprint == candidate.fingerprint,
               indexedSessionIDs.contains(candidate.id) {
                let reclassifiedRecord = existingRecord.with(
                    isNewtonProject: matcher.matches(workspacePath: existingRecord.workspacePath)
                )
                refreshedRecordsByID[candidate.id] = reclassifiedRecord
                if reclassifiedRecord.isNewtonProject != existingRecord.isNewtonProject {
                    changedRecords.append(reclassifiedRecord)
                }
                continue
            }

            if let record = try candidate.loadRecord() {
                let reclassifiedRecord = record.with(isNewtonProject: matcher.matches(workspacePath: record.workspacePath))
                refreshedRecordsByID[reclassifiedRecord.id] = reclassifiedRecord
                changedRecords.append(reclassifiedRecord)
                transcriptEntriesBySessionID[reclassifiedRecord.id] = try TranscriptPreviewExtractor.searchableEntries(for: reclassifiedRecord)
            } else if let existingRecord = existingByID[candidate.id] {
                let reclassifiedRecord = existingRecord.with(
                    isNewtonProject: matcher.matches(workspacePath: existingRecord.workspacePath)
                )
                refreshedRecordsByID[candidate.id] = reclassifiedRecord
                if reclassifiedRecord.isNewtonProject != existingRecord.isNewtonProject {
                    changedRecords.append(reclassifiedRecord)
                }
            }
        }

        let removedIDs = Set(existingByID.keys).subtracting(refreshedRecordsByID.keys)
        try store.applyIncrementalUpdate(
            records: changedRecords,
            removedIDs: Array(removedIDs),
            transcriptEntriesBySessionID: transcriptEntriesBySessionID
        )

        return refreshedRecordsByID.values.sorted(by: SessionCatalog.sort(lhs:rhs:))
    }

    public func rebuildSessions() throws -> [SessionRecord] {
        let records = reclassifySessions(
            try adapters
            .flatMap { try $0.discover() }
            .sorted(by: SessionCatalog.sort(lhs:rhs:))
        )
        let transcriptEntriesBySessionID = try Dictionary(
            uniqueKeysWithValues: records.map { record in
                (record.id, try TranscriptPreviewExtractor.searchableEntries(for: record))
            }
        )
        try store.replaceAll(records: records, transcriptEntriesBySessionID: transcriptEntriesBySessionID)
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
