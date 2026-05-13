import AppKit
import Foundation
import SQLite3

private let SQLITE_TRANSIENT_UTILITIES = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum AppPaths {
    public static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AgentSessionManager", isDirectory: true)
    }

    public static var catalogDirectoryURL: URL {
        catalogDatabaseURL.deletingLastPathComponent()
    }

    public static var catalogDatabaseURL: URL {
        applicationSupportDirectory.appendingPathComponent("catalog.sqlite3")
    }

    public static var homeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }
}

enum ISO8601DateCoding {
    private static func fractionalFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func regularFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    static func parse(_ rawValue: String?) -> Date? {
        guard let rawValue else { return nil }
        return fractionalFormatter().date(from: rawValue) ?? regularFormatter().date(from: rawValue)
    }

    static func string(_ date: Date?) -> String? {
        guard let date else { return nil }
        return fractionalFormatter().string(from: date)
    }
}

enum TextSanitizer {
    static func clean(_ rawText: String?) -> String? {
        sanitize(rawText, preservesLineBreaks: true)
    }

    static func compact(_ rawText: String?) -> String? {
        sanitize(rawText, preservesLineBreaks: false)
    }

    private static func sanitize(_ rawText: String?, preservesLineBreaks: Bool) -> String? {
        guard var text = rawText else { return nil }
        let patterns = [
            "(?s)<current_datetime>.*?</current_datetime>",
            "(?s)<timestamp>.*?</timestamp>",
            "(?s)<system_reminder>.*?</system_reminder>",
            "(?s)<reminder>.*?</reminder>",
            "(?s)<sql_tables>.*?</sql_tables>",
            "</?user_query>"
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        if preservesLineBreaks {
            text = text.replacingOccurrences(of: "\t", with: "    ")
            text = text.replacingOccurrences(of: "[ \t]+\n", with: "\n", options: .regularExpression)
            text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        } else {
            text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func summarize(_ rawText: String?, limit: Int = 220) -> String? {
        guard let text = compact(rawText) else { return nil }
        guard text.count > limit else { return text }
        let index = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<index]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    static func inferTitle(from rawText: String?, fallback: String) -> String {
        summarize(rawText, limit: 90) ?? fallback
    }
}

public struct HighlightedTextSegment: Equatable, Sendable {
    public let text: String
    public let isMatch: Bool

    public init(text: String, isMatch: Bool) {
        self.text = text
        self.isMatch = isMatch
    }
}

public enum SearchTextMatcher {
    public static func normalizedQuery(_ rawQuery: String?) -> String? {
        guard let rawQuery else { return nil }
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    public static func visibleText(from rawText: String) -> String {
        if let attributed = try? AttributedString(markdown: rawText) {
            return String(attributed.characters)
        }
        return rawText
    }

    public static func matchCount(in rawText: String?, query: String) -> Int {
        guard let rawText else { return 0 }
        return matchRanges(in: visibleText(from: rawText), query: query).count
    }

    public static func segments(in rawText: String, query rawQuery: String?) -> [HighlightedTextSegment] {
        guard let query = normalizedQuery(rawQuery) else {
            return [HighlightedTextSegment(text: visibleText(from: rawText), isMatch: false)]
        }

        let visible = visibleText(from: rawText)
        let ranges = matchRanges(in: visible, query: query)
        guard !ranges.isEmpty else {
            return [HighlightedTextSegment(text: visible, isMatch: false)]
        }

        var segments: [HighlightedTextSegment] = []
        var cursor = visible.startIndex
        for range in ranges {
            if cursor < range.lowerBound {
                segments.append(
                    HighlightedTextSegment(
                        text: String(visible[cursor..<range.lowerBound]),
                        isMatch: false
                    )
                )
            }
            segments.append(
                HighlightedTextSegment(
                    text: String(visible[range]),
                    isMatch: true
                )
            )
            cursor = range.upperBound
        }

        if cursor < visible.endIndex {
            segments.append(
                HighlightedTextSegment(
                    text: String(visible[cursor..<visible.endIndex]),
                    isMatch: false
                )
            )
        }

        return segments
    }

    public static func highlightedAttributedString(from rawText: String, query rawQuery: String?) -> AttributedString {
        let visible = TextSanitizer.clean(rawText) ?? rawText
        var attributed = AttributedString(visible)

        guard let query = normalizedQuery(rawQuery) else {
            return attributed
        }

        for range in matchRanges(in: visible, query: query) {
            guard let lowerBound = AttributedString.Index(range.lowerBound, within: attributed),
                  let upperBound = AttributedString.Index(range.upperBound, within: attributed) else {
                continue
            }
            attributed[lowerBound..<upperBound].backgroundColor = NSColor.systemYellow.withAlphaComponent(0.35)
        }

        return attributed
    }

    public static func snippet(in rawText: String, query rawQuery: String?, limit: Int = 120) -> String? {
        guard let query = normalizedQuery(rawQuery) else { return nil }
        let visible = visibleText(from: rawText)
        guard let range = matchRanges(in: visible, query: query).first else { return nil }

        let prefixLength = max(0, limit / 2)
        let suffixLength = max(0, limit - prefixLength)
        let start = visible.index(range.lowerBound, offsetBy: -prefixLength, limitedBy: visible.startIndex) ?? visible.startIndex
        let end = visible.index(range.upperBound, offsetBy: suffixLength, limitedBy: visible.endIndex) ?? visible.endIndex

        var snippet = String(visible[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if start > visible.startIndex {
            snippet = "..." + snippet
        }
        if end < visible.endIndex {
            snippet += "..."
        }
        return snippet
    }

    public static func snippet(in rawText: String, queries: [String], limit: Int = 120) -> String? {
        for query in queries {
            if let snippet = snippet(in: rawText, query: query, limit: limit) {
                return snippet
            }
        }
        return nil
    }

    public static func matchRanges(in text: String, query rawQuery: String?) -> [Range<String.Index>] {
        guard let query = normalizedQuery(rawQuery) else { return [] }

        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<text.endIndex
              ) {
            ranges.append(range)
            searchStart = range.upperBound
        }
        return ranges
    }
}

public enum PathUtilities {
    public static func displayProjectName(workspacePath: String?, fallback: String) -> String {
        guard let workspacePath, !workspacePath.isEmpty else { return fallback }
        let url = URL(fileURLWithPath: workspacePath)
        if url.pathExtension.lowercased() == "code-workspace" {
            return url.deletingPathExtension().lastPathComponent
        }
        return url.lastPathComponent
    }

    public static func cursorFallbackProjectName(from encodedDirectoryName: String) -> String {
        let username = AppPaths.homeDirectory.lastPathComponent
        let knownPrefixes = [
            "Users-\(username)-repos-",
            "Users-\(username)-Development-LocalProjects-"
        ]

        for prefix in knownPrefixes where encodedDirectoryName.hasPrefix(prefix) {
            let suffix = encodedDirectoryName.dropFirst(prefix.count)
            if !suffix.isEmpty {
                return String(suffix)
            }
        }

        return encodedDirectoryName
    }

    public static func normalizedDirectoryPath(
        _ rawPath: String?,
        homeDirectoryPath: String = AppPaths.homeDirectory.path
    ) -> String? {
        guard let rawPath else { return nil }

        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let expandedHome = trimmed.replacingOccurrences(of: "$HOME", with: homeDirectoryPath)
        let expandedTilde = (expandedHome as NSString).expandingTildeInPath
        let normalized = (expandedTilde as NSString).standardizingPath
        return normalized.isEmpty ? nil : normalized
    }

    public static func isNewtonProject(workspacePath: String?, reposRootPath: String) -> Bool {
        NewtonProjectMatcher(reposRootPath: reposRootPath).matches(workspacePath: workspacePath)
    }

    public static func decodeCursorWorkspacePath(from encodedDirectoryName: String) -> String? {
        let directCandidate = "/" + encodedDirectoryName.split(separator: "-").joined(separator: "/")
        if FileManager.default.fileExists(atPath: directCandidate) {
            return directCandidate
        }

        let username = AppPaths.homeDirectory.lastPathComponent
        let commonPrefix = "Users-\(username)-repos-"
        if encodedDirectoryName.hasPrefix(commonPrefix) {
            let suffix = encodedDirectoryName.dropFirst(commonPrefix.count)
            let candidate = AppPaths.homeDirectory
                .appendingPathComponent("repos", isDirectory: true)
                .appendingPathComponent(String(suffix)).path
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        let localProjectsPrefix = "Users-\(username)-Development-LocalProjects-"
        if encodedDirectoryName.hasPrefix(localProjectsPrefix) {
            let suffix = encodedDirectoryName.dropFirst(localProjectsPrefix.count)
            let candidate = AppPaths.homeDirectory
                .appendingPathComponent("Development", isDirectory: true)
                .appendingPathComponent("LocalProjects", isDirectory: true)
                .appendingPathComponent(String(suffix)).path
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    public static func cursorProjectDirectoryName(forWorkspacePath workspacePath: String) -> String {
        let trimmed = workspacePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return "" }
        return trimmed.replacingOccurrences(
            of: #"[/\s]+"#,
            with: "-",
            options: .regularExpression
        )
    }

    public static func workspacePathFromFileURI(_ uri: String?) -> String? {
        guard let uri, let url = URL(string: uri), url.isFileURL else { return nil }
        return url.path(percentEncoded: false)
    }

    public static func base64EncodedASCII(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }
}

struct NewtonProjectMatcher: Equatable, Sendable {
    let reposRootPath: String
    private let reposRootComponents: [String]

    init(reposRootPath: String) {
        let normalizedRootPath = PathUtilities.normalizedDirectoryPath(reposRootPath) ?? reposRootPath
        self.reposRootPath = normalizedRootPath
        self.reposRootComponents = URL(fileURLWithPath: normalizedRootPath, isDirectory: true)
            .standardizedFileURL
            .pathComponents
    }

    func matches(workspacePath: String?) -> Bool {
        guard let normalizedWorkspacePath = PathUtilities.normalizedDirectoryPath(workspacePath) else {
            return false
        }

        let workspaceComponents = URL(fileURLWithPath: normalizedWorkspacePath, isDirectory: true)
            .standardizedFileURL
            .pathComponents
        guard workspaceComponents.count > reposRootComponents.count,
              Array(workspaceComponents.prefix(reposRootComponents.count)) == reposRootComponents else {
            return false
        }

        let repoDirectoryName = workspaceComponents[reposRootComponents.count]
        return repoDirectoryName.lowercased().hasPrefix("newton")
    }
}

struct SourceRoots {
    let copilotCLI: URL
    let cursorProjects: URL
    let cursorWorkspaceStorage: URL
    let cursorGlobalStorage: URL
    let vscodeWorkspaceStorage: URL

    static let live = SourceRoots(
        copilotCLI: AppPaths.homeDirectory.appendingPathComponent(".copilot/session-state", isDirectory: true),
        cursorProjects: AppPaths.homeDirectory.appendingPathComponent(".cursor/projects", isDirectory: true),
        cursorWorkspaceStorage: AppPaths.homeDirectory.appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage", isDirectory: true),
        cursorGlobalStorage: AppPaths.homeDirectory.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage", isDirectory: true),
        vscodeWorkspaceStorage: AppPaths.homeDirectory.appendingPathComponent("Library/Application Support/Code/User/workspaceStorage", isDirectory: true)
    )
}

public enum WorkspaceLauncher {
    public static func performPrimaryAction(for record: SessionRecord) throws {
        switch record.resumeKind {
        case .copilotConnect:
            try resumeCopilotCLI(sessionId: record.resumePayload, workingDirectory: record.workspacePath)
        case .openInCursor:
            open(path: record.resumePayload, withApplication: "Cursor")
        case .openInVSCode:
            open(path: record.resumePayload, withApplication: "Visual Studio Code")
        case .revealPath:
            reveal(path: record.resumePayload)
        }
    }

    public static func startNewConversation(in workingDirectory: String?) throws {
        guard let workingDirectory else {
            throw NSError(domain: "WorkspaceLauncher", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "This session does not include a project workspace path."
            ])
        }

        try runTerminalCommand(
            copilotNewConversationCommand(workingDirectory: workingDirectory),
            failureDescription: "Terminal failed to launch a new Copilot conversation."
        )
    }

    public static func reveal(path: String?) {
        guard let path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    public static func openDocument(path: String?) {
        guard let path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    public static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    public static func copilotResumeCommand(for record: SessionRecord) -> String {
        var components: [String] = []
        if let workspacePath = record.workspacePath {
            components.append("cd \(shellQuote(workspacePath))")
        }
        components.append("copilot --resume \(shellQuote(record.sourceSessionId))")
        return components.joined(separator: " && ")
    }

    public static func copilotNewConversationCommand(workingDirectory: String) -> String {
        "cd \(shellQuote(workingDirectory)) && copilot"
    }

    private static func resumeCopilotCLI(sessionId: String, workingDirectory: String?) throws {
        let shellCommand = copilotResumeShellCommand(sessionId: sessionId, workingDirectory: workingDirectory)

        try runTerminalCommand(
            shellCommand,
            failureDescription: "Terminal failed to launch the Copilot resume command."
        )
    }

    private static func copilotResumeShellCommand(sessionId: String, workingDirectory: String?) -> String {
        var commandComponents: [String] = []
        if let workingDirectory {
            commandComponents.append("cd \(shellQuote(workingDirectory))")
        }
        commandComponents.append("copilot --resume \(shellQuote(sessionId))")
        return commandComponents.joined(separator: " && ")
    }

    private static func runTerminalCommand(_ shellCommand: String, failureDescription: String) throws {
        let script = """
        tell application "Terminal"
          activate
          do script \(appleScriptStringLiteral(shellCommand))
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "WorkspaceLauncher", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: failureDescription
            ])
        }
    }

    private static func open(path: String, withApplication application: String) {
        NSWorkspace.shared.openFile(path, withApplication: application)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptStringLiteral(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}

enum FlatYAMLParser {
    static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let key = line[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                values[key] = value
            }
        }
        return values
    }
}

enum SessionArtifactLocator {
    static func preferredPlanPath(in directory: URL) -> String? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }

        let directPlan = directory.appendingPathComponent("plan.md")
        if FileManager.default.fileExists(atPath: directPlan.path) {
            return directPlan.path
        }

        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var fallback: URL?
        while let next = enumerator?.nextObject() as? URL {
            guard next.pathExtension.lowercased() == "md" else { continue }
            let name = next.lastPathComponent.lowercased()
            if name == "plan.md" {
                return next.path
            }
            if name.contains("plan") && fallback == nil {
                fallback = next
            }
        }

        return fallback?.path
    }

    static func vscodePlanPath(workspaceDirectory: URL, sessionId: String) -> String? {
        let memoriesRoot = workspaceDirectory.appendingPathComponent("GitHub.copilot-chat/memory-tool/memories", isDirectory: true)
        let encodedSessionID = PathUtilities.base64EncodedASCII(sessionId)
        let sessionMemoryDirectory = memoriesRoot.appendingPathComponent(encodedSessionID, isDirectory: true)
        return preferredPlanPath(in: sessionMemoryDirectory)
    }
}

public enum TranscriptLoadingError: LocalizedError {
    case transcriptUnavailable
    case transcriptUnreadable(String)

    public var errorDescription: String? {
        switch self {
        case .transcriptUnavailable:
            return "This session does not have a readable transcript file."
        case let .transcriptUnreadable(path):
            return "The transcript at \(path) could not be read."
        }
    }
}

public enum PlanLoadingError: LocalizedError {
    case planUnavailable
    case planUnreadable(String)

    public var errorDescription: String? {
        switch self {
        case .planUnavailable:
            return "This session does not have a readable plan file."
        case let .planUnreadable(path):
            return "The plan at \(path) could not be read."
        }
    }
}

struct VSCodeSessionMetadata {
    let sessionId: String?
    let title: String?
    let startedAt: Date?
    let updatedAt: Date?
    let latestModel: String?
    let firstUser: String?
    let firstAssistant: String?

    var summary: String? {
        TextSanitizer.summarize(firstAssistant ?? firstUser)
    }
}

private enum VSCodeChatSessionPathComponent {
    case key(String)
    case index(Int)
}

public enum TranscriptPreviewExtractor {
    public static func loadTranscript(for record: SessionRecord) throws -> TranscriptDocument {
        guard let transcriptPath = record.rawTranscriptPath else {
            throw TranscriptLoadingError.transcriptUnavailable
        }

        let url = URL(fileURLWithPath: transcriptPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptLoadingError.transcriptUnreadable(url.path)
        }

        switch record.source {
        case .copilotCLI:
            return try extractEventTranscriptDocument(
                from: url,
                source: record.source,
                sessionId: record.sourceSessionId,
                title: record.title
            )
        case .vscodeCopilot:
            if isVSCodeChatSessionTranscript(url) {
                return try extractVSCodeChatSessionDocument(
                    from: url,
                    source: record.source,
                    sessionId: record.sourceSessionId,
                    title: record.title
                )
            }
            return try extractEventTranscriptDocument(
                from: url,
                source: record.source,
                sessionId: record.sourceSessionId,
                title: record.title
            )
        case .cursor:
            return try extractCursorTranscriptDocument(
                from: url,
                source: record.source,
                sessionId: record.sourceSessionId,
                title: record.title
            )
        }
    }

    public static func loadPlan(for record: SessionRecord) throws -> PlanDocument {
        guard let planPath = record.relatedPlanPath else {
            throw PlanLoadingError.planUnavailable
        }

        let url = URL(fileURLWithPath: planPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PlanLoadingError.planUnreadable(url.path)
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        return PlanDocument(
            sessionID: record.sourceSessionId,
            sessionTitle: record.title,
            source: record.source,
            rawPlanPath: url.path,
            text: text
        )
    }

    public static func searchableEntries(for record: SessionRecord) throws -> [TranscriptIndexEntry] {
        let transcript = try loadTranscript(for: record)
        var entries: [TranscriptIndexEntry] = transcript.entries.enumerated().compactMap { element in
            let (index, entry) = element
            guard entry.isChatMessage,
                  let body = TextSanitizer.compact(entry.body) else {
                return nil
            }

            return TranscriptIndexEntry(
                sessionRecordID: record.id,
                entryIndex: index,
                text: body
            )
        }

        if let plan = try? loadPlan(for: record) {
            entries.append(contentsOf: searchablePlanEntries(for: record, plan: plan))
        }

        return entries
    }

    private static func searchablePlanEntries(for record: SessionRecord, plan: PlanDocument) -> [TranscriptIndexEntry] {
        chunkedPlanText(plan.text).enumerated().map { element in
            let (index, chunk) = element
            return TranscriptIndexEntry(
                sessionRecordID: record.id,
                entryIndex: -(index + 1),
                text: chunk
            )
        }
    }

    private static func chunkedPlanText(_ rawText: String, chunkLimit: Int = 800) -> [String] {
        let visibleText = SearchTextMatcher.visibleText(from: rawText)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        let paragraphs = visibleText
            .components(separatedBy: "\n\n")
            .compactMap { TextSanitizer.compact($0) }

        var chunks: [String] = []
        for paragraph in paragraphs {
            if paragraph.count <= chunkLimit {
                chunks.append(paragraph)
                continue
            }

            var current = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: true) {
                let candidate = current.isEmpty ? String(word) : "\(current) \(word)"
                if candidate.count <= chunkLimit {
                    current = candidate
                    continue
                }

                if !current.isEmpty {
                    chunks.append(current)
                    current = String(word)
                    continue
                }

                var remaining = String(word)
                while remaining.count > chunkLimit {
                    let splitIndex = remaining.index(remaining.startIndex, offsetBy: chunkLimit)
                    chunks.append(String(remaining[..<splitIndex]))
                    remaining = String(remaining[splitIndex...])
                }
                current = remaining
            }

            if !current.isEmpty {
                chunks.append(current)
            }
        }

        return chunks
    }

    static func extractEventTranscript(from url: URL) throws -> TranscriptPreview {
        let contents = try String(contentsOf: url, encoding: .utf8)
        var preview = TranscriptPreview()

        for line in contents.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else {
                continue
            }

            switch type {
            case "session.start":
                if let payload = object["data"] as? [String: Any] {
                    preview.sessionId = payload["sessionId"] as? String ?? preview.sessionId
                    preview.startedAt = ISO8601DateCoding.parse(payload["startTime"] as? String) ?? preview.startedAt
                }
            case "session.model_change":
                if let payload = object["data"] as? [String: Any] {
                    preview.latestModel = normalizeModelIdentifier(payload["newModel"] as? String) ?? preview.latestModel
                }
            case "user.message":
                if preview.firstUser == nil {
                    preview.firstUser = TextSanitizer.clean((object["data"] as? [String: Any])?["content"] as? String)
                }
            case "assistant.message":
                if preview.firstAssistant == nil {
                    preview.firstAssistant = TextSanitizer.clean((object["data"] as? [String: Any])?["content"] as? String)
                }
            default:
                break
            }

            if preview.firstUser != nil, preview.firstAssistant != nil, preview.startedAt != nil {
                break
            }
        }

        return preview
    }

    static func extractVSCodeSessionMetadata(from url: URL) throws -> VSCodeSessionMetadata {
        if isVSCodeChatSessionTranscript(url) {
            return try extractVSCodeChatSessionMetadata(from: url)
        }

        let preview = try extractEventTranscript(from: url)
        return VSCodeSessionMetadata(
            sessionId: preview.sessionId,
            title: nil,
            startedAt: preview.startedAt,
            updatedAt: nil,
            latestModel: preview.latestModel,
            firstUser: preview.firstUser,
            firstAssistant: preview.firstAssistant
        )
    }

    private static func extractEventTranscriptDocument(
        from url: URL,
        source: SessionSource,
        sessionId: String,
        title: String
    ) throws -> TranscriptDocument {
        let contents = try String(contentsOf: url, encoding: .utf8)
        var toolNamesByCallID: [String: String] = [:]
        var entries: [TranscriptEntry] = []

        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else {
                continue
            }

            let payload = object["data"] as? [String: Any]
            let entryID = object["id"] as? String ?? UUID().uuidString
            let timestamp = eventTimestamp(in: object, payload: payload)

            if type == "tool.execution_start",
               let toolCallId = payload?["toolCallId"] as? String,
               let toolName = payload?["toolName"] as? String {
                toolNamesByCallID[toolCallId] = toolName
            }

            guard let entry = eventTranscriptEntry(
                type: type,
                payload: payload,
                timestamp: timestamp,
                entryID: entryID,
                toolNamesByCallID: toolNamesByCallID
            ) else {
                continue
            }

            entries.append(entry)
        }

        return TranscriptDocument(
            sessionID: sessionId,
            sessionTitle: title,
            source: source,
            rawTranscriptPath: url.path,
            entries: entries,
            timestampsAreComplete: true,
            timestampNotice: nil
        )
    }

    static func extractVSCodeChatSessionModel(from url: URL) throws -> String? {
        try extractVSCodeChatSessionMetadata(from: url).latestModel
    }

    static func extractCursorTranscript(from url: URL) throws -> TranscriptPreview {
        let contents = try String(contentsOf: url, encoding: .utf8)
        var preview = TranscriptPreview()

        for line in contents.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let role = object["role"] as? String else {
                continue
            }

            let text = extractCursorText(from: object)
            switch role {
            case "user" where preview.firstUser == nil:
                preview.firstUser = text
            case "assistant" where preview.firstAssistant == nil:
                preview.firstAssistant = text
            default:
                break
            }

            if preview.firstUser != nil, preview.firstAssistant != nil {
                break
            }
        }

        return preview
    }

    private static func extractCursorTranscriptDocument(
        from url: URL,
        source: SessionSource,
        sessionId: String,
        title: String
    ) throws -> TranscriptDocument {
        let contents = try String(contentsOf: url, encoding: .utf8)
        var entries: [TranscriptEntry] = []

        for (index, line) in contents.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            guard let data = line.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let role = object["role"] as? String,
                  let body = extractCursorText(from: object) else {
                continue
            }

            let entryRole: TranscriptEntryRole
            let entryTitle: String
            switch role {
            case "user":
                entryRole = .user
                entryTitle = "User"
            case "assistant":
                entryRole = .assistant
                entryTitle = "Assistant"
            default:
                entryRole = .system
                entryTitle = role.capitalized
            }

            entries.append(
                TranscriptEntry(
                    id: "\(sessionId)-\(index)",
                    role: entryRole,
                    title: entryTitle,
                    body: body,
                    timestamp: nil
                )
            )
        }

        return TranscriptDocument(
            sessionID: sessionId,
            sessionTitle: title,
            source: source,
            rawTranscriptPath: url.path,
            entries: entries,
            timestampsAreComplete: false,
            timestampNotice: "Cursor transcripts preserve message order, but the inspected local JSONL files do not include per-message timestamps."
        )
    }

    private static func extractVSCodeChatSessionDocument(
        from url: URL,
        source: SessionSource,
        sessionId: String,
        title: String
    ) throws -> TranscriptDocument {
        let root = try loadVSCodeChatSessionRoot(from: url)
        let requests = root["requests"] as? [[String: Any]] ?? []
        var entries: [TranscriptEntry] = []

        for (index, request) in requests.enumerated() {
            let requestID = request["requestId"] as? String ?? "\(sessionId)-request-\(index)"
            let requestTimestamp = dateFromEpochMilliseconds(request["timestamp"])

            if let userText = extractVSCodeChatRequestText(from: request) {
                entries.append(
                    TranscriptEntry(
                        id: "\(requestID)-user",
                        role: .user,
                        title: "User",
                        body: userText,
                        timestamp: requestTimestamp
                    )
                )
            }

            if let assistantText = extractVSCodeChatResponseText(from: request["response"]) {
                entries.append(
                    TranscriptEntry(
                        id: "\(requestID)-assistant",
                        role: .assistant,
                        title: "Assistant",
                        body: assistantText,
                        timestamp: nil
                    )
                )
            }
        }

        return TranscriptDocument(
            sessionID: sessionId,
            sessionTitle: title,
            source: source,
            rawTranscriptPath: url.path,
            entries: entries,
            timestampsAreComplete: false,
            timestampNotice: "VS Code chatSessions preserve creation and request timestamps, but the inspected local files do not expose a reliable per-response timestamp for every assistant chunk."
        )
    }

    static func extractMarkdownSummary(from url: URL) throws -> String? {
        let text = try String(contentsOf: url, encoding: .utf8)
        let cleaned = text
            .split(separator: "\n")
            .map { line in
                line.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
            }
            .joined(separator: "\n")
        return TextSanitizer.summarize(cleaned, limit: 240)
    }

    private static func extractCursorText(from object: [String: Any]) -> String? {
        if let message = object["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            let text = content.compactMap { item -> String? in
                if item["type"] as? String == "text" {
                    return item["text"] as? String
                }
                return nil
            }.joined(separator: "\n\n")
            return TextSanitizer.clean(text)
        }

        if let message = object["message"] as? String {
            return TextSanitizer.clean(message)
        }

        return nil
    }

    private static func isVSCodeChatSessionTranscript(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent == "chatSessions"
    }

    private static func extractVSCodeChatSessionMetadata(from url: URL) throws -> VSCodeSessionMetadata {
        let root = try loadVSCodeChatSessionRoot(from: url)
        let requests = root["requests"] as? [[String: Any]] ?? []
        let createdAt = dateFromEpochMilliseconds(root["creationDate"])
        let updatedAt = requests.compactMap { dateFromEpochMilliseconds($0["timestamp"]) }.max() ?? createdAt
        let firstUser = requests.lazy.compactMap { extractVSCodeChatRequestText(from: $0) }.first
        let firstAssistant = requests.lazy.compactMap { extractVSCodeChatResponseText(from: $0["response"]) }.first
        let latestModel = requests
            .reversed()
            .lazy
            .compactMap { request in
                normalizeModelIdentifier(request["modelId"] as? String)
                    ?? normalizeModelIdentifier(nestedString(in: request, path: ["agent", "modelId"]))
            }
            .first
            ?? normalizeModelIdentifier(
                nestedString(in: root, path: ["inputState", "selectedModel", "identifier"])
            )

        return VSCodeSessionMetadata(
            sessionId: root["sessionId"] as? String,
            title: TextSanitizer.compact(root["customTitle"] as? String),
            startedAt: createdAt,
            updatedAt: updatedAt,
            latestModel: latestModel,
            firstUser: firstUser,
            firstAssistant: firstAssistant
        )
    }

    private static func loadVSCodeChatSessionRoot(from url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["kind"] == nil {
            return (object["v"] as? [String: Any]) ?? object
        }

        let contents = String(decoding: data, as: UTF8.self)
        var root: [String: Any]?
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let kind = (object["kind"] as? NSNumber)?.intValue
            switch kind {
            case 0:
                root = (object["v"] as? [String: Any]) ?? object
            case 1:
                guard let path = decodeVSCodeChatSessionPath(from: object["k"]) else { continue }
                root = (setVSCodeChatSessionValue(
                    in: root ?? [:],
                    path: path,
                    value: object["v"] ?? NSNull()
                ) as? [String: Any]) ?? root
            case 2:
                guard let path = decodeVSCodeChatSessionPath(from: object["k"]) else { continue }
                let values: [Any]
                if let array = object["v"] as? [Any] {
                    values = array
                } else if let value = object["v"] {
                    values = [value]
                } else {
                    values = []
                }
                root = (appendVSCodeChatSessionValues(
                    in: root ?? [:],
                    path: path,
                    values: values
                ) as? [String: Any]) ?? root
            default:
                if root == nil {
                    root = (object["v"] as? [String: Any]) ?? object
                }
            }
        }

        guard let root else {
            throw TranscriptLoadingError.transcriptUnreadable(url.path)
        }
        return root
    }

    private static func extractVSCodeChatRequestText(from request: [String: Any]) -> String? {
        guard let message = request["message"] as? [String: Any] else {
            return nil
        }

        if let text = message["text"] as? String {
            return TextSanitizer.clean(displayVSCodeMarkdownFragment(text))
        }

        if let parts = message["parts"] as? [[String: Any]] {
            let combined = parts.compactMap { part -> String? in
                if let text = part["text"] as? String {
                    return displayVSCodeMarkdownFragment(text)
                }
                return nestedString(in: part, path: ["value", "text"]).map(displayVSCodeMarkdownFragment)
            }.joined(separator: "\n\n")
            return TextSanitizer.clean(combined)
        }

        return nil
    }

    private static func extractVSCodeChatResponseText(from rawResponse: Any?) -> String? {
        guard let responseItems = rawResponse as? [Any] else {
            return nil
        }

        let fragments = responseItems.compactMap { item -> String? in
            guard let item = item as? [String: Any] else {
                return nil
            }

            if let kind = item["kind"] as? String {
                switch kind {
                case "markdownContent":
                    return nestedString(in: item, path: ["content", "value"]).map(displayVSCodeMarkdownFragment)
                case "warningMessage":
                    return TextSanitizer.clean(displayVSCodeMarkdownFragment(item["warningMessage"] as? String ?? ""))
                default:
                    return nil
                }
            }

            return (item["value"] as? String).map(displayVSCodeMarkdownFragment)
        }

        guard !fragments.isEmpty else {
            return nil
        }

        return TextSanitizer.clean(joinTextFragments(fragments))
    }

    private static func displayVSCodeMarkdownFragment(_ text: String) -> String {
        guard text.contains("\n") || text.contains("\r") else {
            return SearchTextMatcher.visibleText(from: text)
        }
        return text
    }

    private static func joinTextFragments(_ fragments: [String]) -> String {
        guard var combined = fragments.first else { return "" }
        for fragment in fragments.dropFirst() {
            guard !fragment.isEmpty else { continue }
            if let lastCharacter = combined.last,
               let firstCharacter = fragment.first,
               !lastCharacter.isWhitespace,
               !firstCharacter.isWhitespace {
                combined += " "
            }
            combined += fragment
        }
        return combined
    }

    private static func dateFromEpochMilliseconds(_ rawValue: Any?) -> Date? {
        switch rawValue {
        case let number as NSNumber:
            return Date(timeIntervalSince1970: number.doubleValue / 1000)
        case let string as String:
            guard let milliseconds = Double(string) else { return nil }
            return Date(timeIntervalSince1970: milliseconds / 1000)
        default:
            return nil
        }
    }

    private static func decodeVSCodeChatSessionPath(from rawPath: Any?) -> [VSCodeChatSessionPathComponent]? {
        guard let rawSegments = rawPath as? [Any] else {
            return nil
        }

        let segments = rawSegments.compactMap { rawSegment -> VSCodeChatSessionPathComponent? in
            switch rawSegment {
            case let key as String:
                return .key(key)
            case let index as NSNumber:
                return .index(index.intValue)
            default:
                return nil
            }
        }

        return segments.count == rawSegments.count ? segments : nil
    }

    private static func setVSCodeChatSessionValue(
        in current: Any,
        path: [VSCodeChatSessionPathComponent],
        value: Any
    ) -> Any {
        guard let component = path.first else {
            return value
        }

        switch component {
        case .key(let key):
            var dictionary = current as? [String: Any] ?? [:]
            if path.count == 1 {
                dictionary[key] = value
            } else {
                dictionary[key] = setVSCodeChatSessionValue(
                    in: sanitizedVSCodeChatSessionValue(dictionary[key], nextPath: Array(path.dropFirst())),
                    path: Array(path.dropFirst()),
                    value: value
                )
            }
            return dictionary
        case .index(let index):
            var array = current as? [Any] ?? []
            while array.count <= index {
                array.append(NSNull())
            }
            if path.count == 1 {
                array[index] = value
            } else {
                array[index] = setVSCodeChatSessionValue(
                    in: sanitizedVSCodeChatSessionValue(array[index], nextPath: Array(path.dropFirst())),
                    path: Array(path.dropFirst()),
                    value: value
                )
            }
            return array
        }
    }

    private static func appendVSCodeChatSessionValues(
        in current: Any,
        path: [VSCodeChatSessionPathComponent],
        values: [Any]
    ) -> Any {
        guard let component = path.first else {
            var array = current as? [Any] ?? []
            array.append(contentsOf: values)
            return array
        }

        switch component {
        case .key(let key):
            var dictionary = current as? [String: Any] ?? [:]
            if path.count == 1 {
                var array = dictionary[key] as? [Any] ?? []
                array.append(contentsOf: values)
                dictionary[key] = array
            } else {
                dictionary[key] = appendVSCodeChatSessionValues(
                    in: sanitizedVSCodeChatSessionValue(dictionary[key], nextPath: Array(path.dropFirst())),
                    path: Array(path.dropFirst()),
                    values: values
                )
            }
            return dictionary
        case .index(let index):
            var array = current as? [Any] ?? []
            while array.count <= index {
                array.append(NSNull())
            }
            if path.count == 1 {
                var childArray = array[index] as? [Any] ?? []
                childArray.append(contentsOf: values)
                array[index] = childArray
            } else {
                array[index] = appendVSCodeChatSessionValues(
                    in: sanitizedVSCodeChatSessionValue(array[index], nextPath: Array(path.dropFirst())),
                    path: Array(path.dropFirst()),
                    values: values
                )
            }
            return array
        }
    }

    private static func sanitizedVSCodeChatSessionValue(
        _ value: Any?,
        nextPath: [VSCodeChatSessionPathComponent]
    ) -> Any {
        if let value, !(value is NSNull) {
            return value
        }

        guard let nextComponent = nextPath.first else {
            return [:]
        }

        switch nextComponent {
        case .key:
            return [String: Any]()
        case .index:
            return [Any]()
        }
    }

    private static func normalizeModelIdentifier(_ rawValue: String?) -> String? {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        if rawValue.hasPrefix("copilot/") {
            return String(rawValue.dropFirst("copilot/".count))
        }
        return rawValue
    }

    private static func nestedString(in object: [String: Any], path: [String]) -> String? {
        var current: Any? = object
        for key in path {
            guard let dictionary = current as? [String: Any] else { return nil }
            current = dictionary[key]
        }
        return current as? String
    }

    private static func eventTranscriptEntry(
        type: String,
        payload: [String: Any]?,
        timestamp: Date?,
        entryID: String,
        toolNamesByCallID: [String: String]
    ) -> TranscriptEntry? {
        switch type {
        case "user.message":
            let body = TextSanitizer.clean(payload?["content"] as? String)
            return body.map {
                TranscriptEntry(id: entryID, role: .user, title: "User", body: $0, timestamp: timestamp)
            }
        case "assistant.message":
            let body = TextSanitizer.clean(payload?["content"] as? String)
            return body.map {
                TranscriptEntry(id: entryID, role: .assistant, title: "Assistant", body: $0, timestamp: timestamp)
            }
        case "session.start":
            let producer = payload?["producer"] as? String
            let version = payload?["copilotVersion"] as? String
            let body = [producer, version.map { "Version \($0)" }]
                .compactMap { $0 }
                .joined(separator: " • ")
            return TranscriptEntry(
                id: entryID,
                role: .system,
                title: "Session Started",
                body: body.isEmpty ? nil : body,
                timestamp: timestamp
            )
        case "session.model_change":
            let model = normalizeModelIdentifier(payload?["newModel"] as? String) ?? "Unknown model"
            return TranscriptEntry(
                id: entryID,
                role: .system,
                title: "Model Changed",
                body: model,
                timestamp: timestamp
            )
        case "session.info":
            let infoType = prettifyEventLabel(payload?["infoType"] as? String ?? "Info")
            let body = searchableEventText(
                type: type,
                payload: payload,
                toolNamesByCallID: toolNamesByCallID
            )
            return TranscriptEntry(
                id: entryID,
                role: .system,
                title: infoType,
                body: body,
                timestamp: timestamp
            )
        case "tool.execution_start":
            let toolName = payload?["toolName"] as? String ?? "Tool"
            let body = searchableEventText(
                type: type,
                payload: payload,
                toolNamesByCallID: toolNamesByCallID
            )
            return TranscriptEntry(
                id: entryID,
                role: .tool,
                title: "Started \(toolName)",
                body: body,
                timestamp: timestamp
            )
        case "tool.execution_complete":
            let toolCallId = payload?["toolCallId"] as? String
            let toolName = toolCallId.flatMap { toolNamesByCallID[$0] } ?? "Tool"
            let success = payload?["success"] as? Bool ?? true
            let body = searchableEventText(
                type: type,
                payload: payload,
                toolNamesByCallID: toolNamesByCallID
            )
            return TranscriptEntry(
                id: entryID,
                role: .tool,
                title: success ? "Completed \(toolName)" : "Failed \(toolName)",
                body: body,
                timestamp: timestamp
            )
        default:
            return nil
        }
    }

    private static func searchableEventText(
        type: String,
        payload: [String: Any]?,
        toolNamesByCallID: [String: String]
    ) -> String? {
        switch type {
        case "user.message", "assistant.message":
            return TextSanitizer.compact(payload?["content"] as? String)
        case "session.model_change":
            return normalizeModelIdentifier(payload?["newModel"] as? String)
        case "session.info":
            return TextSanitizer.compact(payload?["message"] as? String)
        case "tool.execution_start":
            let toolName = payload?["toolName"] as? String
            let details = flattenedSearchText(from: payload?["arguments"])
            return combinedSearchText(parts: [toolName, details])
        case "tool.execution_complete":
            let toolCallId = payload?["toolCallId"] as? String
            let toolName = toolCallId.flatMap { toolNamesByCallID[$0] }
            let details = combinedSearchText(
                parts: [
                    flattenedSearchText(from: payload?["result"]),
                    TextSanitizer.compact(payload?["error"] as? String)
                ]
            )
            return combinedSearchText(parts: [toolName, details])
        default:
            return nil
        }
    }

    private static func eventTimestamp(in object: [String: Any], payload: [String: Any]?) -> Date? {
        ISO8601DateCoding.parse(object["timestamp"] as? String)
            ?? ISO8601DateCoding.parse(payload?["startTime"] as? String)
    }

    private static func prettifyEventLabel(_ rawValue: String) -> String {
        rawValue
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    private static func toolArgumentsSummary(_ value: Any?) -> String? {
        if let rawString = value as? String {
            return TextSanitizer.summarize(rawString, limit: 220)
        }

        guard let dictionary = value as? [String: Any] else { return nil }
        let preferredKeys = ["description", "question", "prompt", "command", "query", "pattern", "path", "url", "intent"]
        for key in preferredKeys {
            if let text = TextSanitizer.summarize(dictionary[key] as? String, limit: 220) {
                return text
            }
        }

        if let agentName = dictionary["agentName"] as? String {
            let detail = TextSanitizer.summarize(dictionary["description"] as? String, limit: 180)
            return [agentName, detail].compactMap { $0 }.joined(separator: " • ")
        }

        if let skill = dictionary["skill"] as? String {
            return skill
        }

        return nil
    }

    private static func toolCompletionSummary(_ payload: [String: Any]?) -> String? {
        guard let payload else { return nil }
        let success = payload["success"] as? Bool ?? true
        if !success {
            if let error = TextSanitizer.compact(payload["error"] as? String) {
                return error
            }
            if let failure = nestedString(in: payload, path: ["result", "error"]) {
                return TextSanitizer.compact(failure)
            }
        }

        if let detail = nestedString(in: payload, path: ["result", "content"]),
           detail.count <= 140 {
            return TextSanitizer.compact(detail)
        }

        if let detail = nestedString(in: payload, path: ["result", "detailedContent"]),
           detail.count <= 140 {
            return TextSanitizer.compact(detail)
        }

        return nil
    }

    private static func flattenedSearchText(from value: Any?) -> String? {
        let flattened = flattenedSearchStrings(from: value)
        guard !flattened.isEmpty else { return nil }
        return combinedSearchText(parts: flattened.map { Optional($0) })
    }

    private static func flattenedSearchStrings(from value: Any?) -> [String] {
        switch value {
        case let string as String:
            return TextSanitizer.compact(SearchTextMatcher.visibleText(from: string)).map { [$0] } ?? []
        case let array as [Any]:
            return array.flatMap(flattenedSearchStrings)
        case let dictionary as [String: Any]:
            return dictionary.keys.sorted().flatMap { key in
                flattenedSearchStrings(from: dictionary[key])
            }
        default:
            return []
        }
    }

    private static func combinedSearchText(parts: [String?]) -> String? {
        var normalizedParts: [String] = []
        for part in parts {
            guard let cleaned = TextSanitizer.compact(part),
                  !cleaned.isEmpty else {
                continue
            }
            normalizedParts.append(cleaned)
        }
        guard !normalizedParts.isEmpty else {
            return nil
        }
        return normalizedParts.joined(separator: "\n")
    }
}

func fileDates(for url: URL) -> (created: Date?, modified: Date?) {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (
        attributes?[.creationDate] as? Date,
        attributes?[.modificationDate] as? Date
    )
}

func fileFingerprint(for path: String?) -> String {
    guard let path else { return "missing" }
    let url = URL(fileURLWithPath: path)
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let modified = (attributes?[.modificationDate] as? Date).map { ISO8601DateCoding.string($0) ?? "unknown-date" } ?? "missing-date"
    let size = (attributes?[.size] as? NSNumber)?.stringValue ?? "missing-size"
    return "\(path)|\(modified)|\(size)"
}

func stringFingerprint(for value: String?) -> String {
    "value:\(value ?? "missing")"
}

func combinedFingerprint(paths: [String?], values: [String?] = []) -> String {
    (paths.map(fileFingerprint) + values.map(stringFingerprint(for:))).joined(separator: "||")
}

func loadJSONDictionary(from url: URL) throws -> [String: Any]? {
    let data = try Data(contentsOf: url)
    return try JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func withSQLiteItemTableDatabase<T>(
    at databaseURL: URL,
    _ body: (OpaquePointer) throws -> T
) throws -> T {
    var database: OpaquePointer?
    // Use READWRITE so SQLite can create the SHM file required by WAL-mode databases.
    // READONLY fails when WAL/SHM files are absent (e.g. Cursor's state.vscdb after clean exit).
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
        let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Unknown SQLite open error"
        sqlite3_close(database)
        throw SQLiteStoreError.openFailed(message)
    }
    defer { sqlite3_close(database) }

    guard let database else {
        throw SQLiteStoreError.openFailed("Unknown SQLite open error")
    }

    return try body(database)
}

func loadSQLiteItemValue(from databaseURL: URL, key: String) throws -> String? {
    try withSQLiteItemTableDatabase(at: databaseURL) { database in
        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = sqlite3_errmsg(database).map { String(cString: $0) } ?? "Unknown SQLite prepare error"
            throw SQLiteStoreError.prepareFailed(message)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT_UTILITIES)
        let stepResult = sqlite3_step(statement)
        switch stepResult {
        case SQLITE_ROW:
            guard let text = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: text)
        case SQLITE_DONE:
            return nil
        default:
            let message = sqlite3_errmsg(database).map { String(cString: $0) } ?? "Unknown SQLite step error"
            throw SQLiteStoreError.stepFailed(message)
        }
    }
}

func loadSQLiteItemValues(from databaseURL: URL, keyLike pattern: String) throws -> [String: String] {
    try withSQLiteItemTableDatabase(at: databaseURL) { database in
        let sql = """
        SELECT key, value
        FROM ItemTable
        WHERE key LIKE ?
        ORDER BY key ASC;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = sqlite3_errmsg(database).map { String(cString: $0) } ?? "Unknown SQLite prepare error"
            throw SQLiteStoreError.prepareFailed(message)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, pattern, -1, SQLITE_TRANSIENT_UTILITIES)

        var values: [String: String] = [:]
        while true {
            let stepResult = sqlite3_step(statement)
            switch stepResult {
            case SQLITE_ROW:
                guard let key = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
                      let value = sqlite3_column_text(statement, 1).map({ String(cString: $0) }) else {
                    continue
                }
                values[key] = value
            case SQLITE_DONE:
                return values
            default:
                let message = sqlite3_errmsg(database).map { String(cString: $0) } ?? "Unknown SQLite step error"
                throw SQLiteStoreError.stepFailed(message)
            }
        }
    }
}
