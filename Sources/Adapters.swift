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

final class SessionCatalog {
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

    static func makeDefault(settingsProvider: @escaping () -> AppSettingsSnapshot = { AppSettingsSnapshot.standard() }) throws -> SessionCatalog {
        try SessionCatalog(storeURL: AppPaths.catalogDatabaseURL, settingsProvider: settingsProvider)
    }

    func loadPersistedSessions() throws -> [SessionRecord] {
        reclassifySessions(try store.fetchAll())
    }

    func starredSessionIDs() throws -> Set<String> {
        try store.fetchStarredSessionIDs()
    }

    func setSessionStarred(_ isStarred: Bool, for sessionID: String) throws {
        try store.setSessionStarred(isStarred, for: sessionID)
    }

    func searchTranscriptIndex(sessionIDs: [String], query: String) throws -> [TranscriptIndexSearchHit] {
        try store.searchTranscriptEntries(sessionIDs: sessionIDs, query: query)
    }

    func reclassifySessions(_ records: [SessionRecord]) -> [SessionRecord] {
        let matcher = NewtonProjectMatcher(reposRootPath: settingsProvider().newtonReposRootPath)
        return records.map { record in
            record.with(isNewtonProject: matcher.matches(workspacePath: record.workspacePath))
        }
    }

    func refreshSessions() throws -> [SessionRecord] {
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

    func rebuildSessions() throws -> [SessionRecord] {
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
}

struct CopilotCLIAdapter: SessionSourceAdapter {
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
            let fingerprint = combinedFingerprint(
                paths: [
                    workspaceURL.path,
                    FileManager.default.fileExists(atPath: eventLogURL.path) ? eventLogURL.path : checkpointIndexURL.path,
                    relatedPlanPath
                ]
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
                        fingerprint: fingerprint
                    )
                }
            )
        }
    }

    private func loadRecord(
        sessionDirectory: URL,
        workspaceURL: URL,
        eventLogURL: URL,
        checkpointIndexURL: URL,
        relatedPlanPath: String?,
        fingerprint: String
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
            isNewtonProject: false
        )
    }
}

struct CursorAdapter: SessionSourceAdapter {
    let root: URL
    let workspaceStorageRoot: URL
    let globalStorageRoot: URL

    func scanCandidates() throws -> [SessionScanCandidate] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        let workspaceReferences = try loadWorkspaceReferencesByProjectDirectory()
        let titleReferences = try loadTitleReferencesBySessionID()
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
                let relatedPlanPath = SessionArtifactLocator.preferredPlanPath(in: sessionDirectory)
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

    private func loadTitleReferencesBySessionID() throws -> [String: CursorTitleReference] {
        let stateDatabaseURL = globalStorageRoot.appendingPathComponent("state.vscdb")
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

private struct CursorComposerHeadersPayload: Decodable {
    let allComposers: [CursorComposerHeader]
}

private struct CursorComposerHeader: Decodable {
    let composerId: String
    let name: String?
}

struct VSCodeCopilotAdapter: SessionSourceAdapter {
    let root: URL

    func scanCandidates() throws -> [SessionScanCandidate] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        let workspaceDirectories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter(\.hasDirectoryPath)

        return try workspaceDirectories.flatMap { workspaceDirectory -> [SessionScanCandidate] in
            let workspaceJSONURL = workspaceDirectory.appendingPathComponent("workspace.json")
            let transcriptDirectory = workspaceDirectory.appendingPathComponent("GitHub.copilot-chat/transcripts", isDirectory: true)
            guard FileManager.default.fileExists(atPath: workspaceJSONURL.path),
                  FileManager.default.fileExists(atPath: transcriptDirectory.path) else {
                return []
            }

            let metadata = try loadJSONDictionary(from: workspaceJSONURL)
            let workspacePath = PathUtilities.workspacePathFromFileURI((metadata?["folder"] as? String) ?? (metadata?["workspace"] as? String))
            let projectName = PathUtilities.displayProjectName(workspacePath: workspacePath, fallback: workspaceDirectory.lastPathComponent)
            let transcriptFiles = try FileManager.default.contentsOfDirectory(at: transcriptDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                .filter { $0.pathExtension == "jsonl" }

            return try transcriptFiles.map { transcriptFile in
                let preview = try TranscriptPreviewExtractor.extractEventTranscript(from: transcriptFile)
                let sessionID = preview.sessionId ?? transcriptFile.deletingPathExtension().lastPathComponent
                let title = TextSanitizer.inferTitle(from: preview.firstUser, fallback: sessionID)
                let chatSessionURL = workspaceDirectory.appendingPathComponent("chatSessions/\(sessionID).jsonl")
                let relatedPlanPath = SessionArtifactLocator.vscodePlanPath(workspaceDirectory: workspaceDirectory, sessionId: sessionID)
                let fingerprint = combinedFingerprint(
                    paths: [
                        transcriptFile.path,
                        workspaceJSONURL.path,
                        FileManager.default.fileExists(atPath: chatSessionURL.path) ? chatSessionURL.path : nil,
                        relatedPlanPath
                    ]
                )

                return SessionScanCandidate(
                    id: "\(SessionSource.vscodeCopilot.rawValue)::\(sessionID)",
                    fingerprint: fingerprint,
                    loadRecord: {
                        try loadRecord(
                            transcriptFile: transcriptFile,
                            workspaceJSONURL: workspaceJSONURL,
                            chatSessionURL: chatSessionURL,
                            workspacePath: workspacePath,
                            projectName: projectName,
                            relatedPlanPath: relatedPlanPath,
                            sessionID: sessionID,
                            preview: preview,
                            title: title,
                            fingerprint: fingerprint
                        )
                    }
                )
            }
        }
    }

    private func loadRecord(
        transcriptFile: URL,
        workspaceJSONURL: URL,
        chatSessionURL: URL,
        workspacePath: String?,
        projectName: String,
        relatedPlanPath: String?,
        sessionID: String,
        preview: TranscriptPreview,
        title: String,
        fingerprint: String
    ) throws -> SessionRecord? {
        guard FileManager.default.fileExists(atPath: transcriptFile.path),
              FileManager.default.fileExists(atPath: workspaceJSONURL.path) else {
            return nil
        }

        let dates = fileDates(for: transcriptFile)
        let chatSessionModel = FileManager.default.fileExists(atPath: chatSessionURL.path)
            ? try? TranscriptPreviewExtractor.extractVSCodeChatSessionModel(from: chatSessionURL)
            : nil

        guard preview.firstUser != nil || preview.firstAssistant != nil else {
            return nil
        }

        return SessionRecord(
            source: .vscodeCopilot,
            sourceSessionId: sessionID,
            workspacePath: workspacePath,
            projectName: projectName,
            branch: nil,
            conversationModel: preview.latestModel ?? chatSessionModel ?? nil,
            startedAt: preview.startedAt ?? dates.created,
            updatedAt: dates.modified,
            title: title,
            summary: preview.summary,
            firstUserPreview: preview.firstUser,
            firstAssistantPreview: preview.firstAssistant,
            rawTranscriptPath: transcriptFile.path,
            rawMetadataPath: workspaceJSONURL.path,
            relatedPlanPath: relatedPlanPath,
            fingerprint: fingerprint,
            resumeKind: workspacePath == nil ? .revealPath : .openInVSCode,
            resumePayload: workspacePath ?? transcriptFile.path,
            isNewtonProject: false
        )
    }
}
