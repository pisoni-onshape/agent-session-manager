import Foundation

protocol SessionSourceAdapter {
    func discover() throws -> [SessionRecord]
}

final class SessionCatalog {
    private let store: SQLiteSessionStore
    private let adapters: [SessionSourceAdapter]

    init(storeURL: URL, roots: SourceRoots = .live) throws {
        store = try SQLiteSessionStore(databaseURL: storeURL)
        adapters = [
            CopilotCLIAdapter(root: roots.copilotCLI),
            CursorAdapter(root: roots.cursorProjects),
            VSCodeCopilotAdapter(root: roots.vscodeWorkspaceStorage)
        ]
    }

    static func makeDefault() throws -> SessionCatalog {
        try SessionCatalog(storeURL: AppPaths.catalogDatabaseURL)
    }

    func loadPersistedSessions() throws -> [SessionRecord] {
        try store.fetchAll()
    }

    func refreshSessions() throws -> [SessionRecord] {
        let records = try adapters
            .flatMap { try $0.discover() }
            .sorted(by: SessionCatalog.sort(lhs:rhs:))
        try store.replaceAll(records: records)
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

    func discover() throws -> [SessionRecord] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        let sessionDirectories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter(\.hasDirectoryPath)

        return try sessionDirectories.compactMap { sessionDirectory in
            let workspaceURL = sessionDirectory.appendingPathComponent("workspace.yaml")
            guard FileManager.default.fileExists(atPath: workspaceURL.path) else { return nil }

            let yaml = try String(contentsOf: workspaceURL, encoding: .utf8)
            let metadata = FlatYAMLParser.parse(yaml)
            let eventLogURL = sessionDirectory.appendingPathComponent("events.jsonl")
            let checkpointIndexURL = sessionDirectory.appendingPathComponent("checkpoints/index.md")
            let relatedPlanPath = SessionArtifactLocator.preferredPlanPath(in: sessionDirectory)

            let eventPreview = FileManager.default.fileExists(atPath: eventLogURL.path)
                ? try? TranscriptPreviewExtractor.extractEventTranscript(from: eventLogURL)
                : nil
            let checkpointSummary = FileManager.default.fileExists(atPath: checkpointIndexURL.path)
                ? try? TranscriptPreviewExtractor.extractMarkdownSummary(from: checkpointIndexURL)
                : nil

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
                resumeKind: .copilotConnect,
                resumePayload: metadata["id"] ?? sessionDirectory.lastPathComponent,
                isNewtonProject: PathUtilities.isNewtonProject(workspacePath)
            )
        }
    }
}

struct CursorAdapter: SessionSourceAdapter {
    let root: URL

    func discover() throws -> [SessionRecord] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        let projectDirectories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter(\.hasDirectoryPath)

        return try projectDirectories.flatMap { projectDirectory -> [SessionRecord] in
            let transcriptRoot = projectDirectory.appendingPathComponent("agent-transcripts", isDirectory: true)
            guard FileManager.default.fileExists(atPath: transcriptRoot.path) else { return [SessionRecord]() }

            let workspacePath = PathUtilities.decodeCursorWorkspacePath(from: projectDirectory.lastPathComponent)
            let fallbackProjectName = projectDirectory.lastPathComponent.replacingOccurrences(of: "-", with: "/")
            let projectName = PathUtilities.displayProjectName(workspacePath: workspacePath, fallback: fallbackProjectName)

            let sessionDirectories = try FileManager.default.contentsOfDirectory(at: transcriptRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                .filter(\.hasDirectoryPath)

            return try sessionDirectories.compactMap { sessionDirectory in
                let transcriptFile = sessionDirectory.appendingPathComponent("\(sessionDirectory.lastPathComponent).jsonl")
                guard FileManager.default.fileExists(atPath: transcriptFile.path) else { return nil }

                let preview = try TranscriptPreviewExtractor.extractCursorTranscript(from: transcriptFile)
                let dates = fileDates(for: transcriptFile)
                let sessionId = sessionDirectory.lastPathComponent
                let title = TextSanitizer.inferTitle(from: preview.firstUser, fallback: sessionId)
                let relatedPlanPath = SessionArtifactLocator.preferredPlanPath(in: sessionDirectory)

                return SessionRecord(
                    source: .cursor,
                    sourceSessionId: sessionId,
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
                    resumeKind: workspacePath == nil ? .revealPath : .openInCursor,
                    resumePayload: workspacePath ?? transcriptFile.path,
                    isNewtonProject: PathUtilities.isNewtonProject(workspacePath ?? projectName)
                )
            }
        }
    }
}

struct VSCodeCopilotAdapter: SessionSourceAdapter {
    let root: URL

    func discover() throws -> [SessionRecord] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        let workspaceDirectories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter(\.hasDirectoryPath)

        return try workspaceDirectories.flatMap { workspaceDirectory -> [SessionRecord] in
            let workspaceJSONURL = workspaceDirectory.appendingPathComponent("workspace.json")
            let transcriptDirectory = workspaceDirectory.appendingPathComponent("GitHub.copilot-chat/transcripts", isDirectory: true)
            guard FileManager.default.fileExists(atPath: workspaceJSONURL.path),
                  FileManager.default.fileExists(atPath: transcriptDirectory.path) else {
                return [SessionRecord]()
            }

            let metadata = try loadJSONDictionary(from: workspaceJSONURL)
            let workspacePath = PathUtilities.workspacePathFromFileURI((metadata?["folder"] as? String) ?? (metadata?["workspace"] as? String))
            let projectName = PathUtilities.displayProjectName(workspacePath: workspacePath, fallback: workspaceDirectory.lastPathComponent)
            let transcriptFiles = try FileManager.default.contentsOfDirectory(at: transcriptDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                .filter { $0.pathExtension == "jsonl" }

            return try transcriptFiles.compactMap { transcriptFile in
                let preview = try TranscriptPreviewExtractor.extractEventTranscript(from: transcriptFile)
                let dates = fileDates(for: transcriptFile)
                let sessionID = preview.sessionId ?? transcriptFile.deletingPathExtension().lastPathComponent
                let title = TextSanitizer.inferTitle(from: preview.firstUser, fallback: sessionID)
                let chatSessionURL = workspaceDirectory.appendingPathComponent("chatSessions/\(sessionID).jsonl")
                let chatSessionModel = FileManager.default.fileExists(atPath: chatSessionURL.path)
                    ? try? TranscriptPreviewExtractor.extractVSCodeChatSessionModel(from: chatSessionURL)
                    : nil
                let relatedPlanPath = SessionArtifactLocator.vscodePlanPath(workspaceDirectory: workspaceDirectory, sessionId: sessionID)

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
                    resumeKind: workspacePath == nil ? .revealPath : .openInVSCode,
                    resumePayload: workspacePath ?? transcriptFile.path,
                    isNewtonProject: PathUtilities.isNewtonProject(workspacePath ?? projectName)
                )
            }
        }
    }
}
