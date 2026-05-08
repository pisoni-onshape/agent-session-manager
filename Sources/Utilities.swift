import AppKit
import Foundation

enum AppPaths {
    static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AgentSessionManager", isDirectory: true)
    }

    static var catalogDatabaseURL: URL {
        applicationSupportDirectory.appendingPathComponent("catalog.sqlite3")
    }

    static var homeDirectory: URL {
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
        guard var text = rawText else { return nil }
        let patterns = [
            "(?s)<current_datetime>.*?</current_datetime>",
            "(?s)<system_reminder>.*?</system_reminder>",
            "(?s)<reminder>.*?</reminder>",
            "(?s)<sql_tables>.*?</sql_tables>",
            "</?user_query>"
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\n+", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func summarize(_ rawText: String?, limit: Int = 220) -> String? {
        guard let text = clean(rawText) else { return nil }
        guard text.count > limit else { return text }
        let index = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<index]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    static func inferTitle(from rawText: String?, fallback: String) -> String {
        summarize(rawText, limit: 90) ?? fallback
    }
}

struct HighlightedTextSegment: Equatable, Sendable {
    let text: String
    let isMatch: Bool
}

enum SearchTextMatcher {
    static func normalizedQuery(_ rawQuery: String?) -> String? {
        guard let rawQuery else { return nil }
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    static func visibleText(from rawText: String) -> String {
        if let attributed = try? AttributedString(markdown: rawText) {
            return String(attributed.characters)
        }
        return rawText
    }

    static func matchCount(in rawText: String?, query: String) -> Int {
        guard let rawText else { return 0 }
        return matchRanges(in: visibleText(from: rawText), query: query).count
    }

    static func segments(in rawText: String, query rawQuery: String?) -> [HighlightedTextSegment] {
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

    static func highlightedAttributedString(from rawText: String, query rawQuery: String?) -> AttributedString {
        let visible = visibleText(from: rawText)
        var attributed = AttributedString(visible)

        guard let query = normalizedQuery(rawQuery) else {
            return attributed
        }

        for range in matchRanges(in: visible, query: query) {
            guard let lowerBound = AttributedString.Index(range.lowerBound, within: attributed),
                  let upperBound = AttributedString.Index(range.upperBound, within: attributed) else {
                continue
            }
            attributed[lowerBound..<upperBound].backgroundColor = .yellow.opacity(0.35)
        }

        return attributed
    }

    static func snippet(in rawText: String, query rawQuery: String?, limit: Int = 120) -> String? {
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

    static func matchRanges(in text: String, query rawQuery: String?) -> [Range<String.Index>] {
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

enum PathUtilities {
    static func displayProjectName(workspacePath: String?, fallback: String) -> String {
        guard let workspacePath, !workspacePath.isEmpty else { return fallback }
        return URL(fileURLWithPath: workspacePath).lastPathComponent
    }

    static func isNewtonProject(_ workspacePath: String?) -> Bool {
        guard let workspacePath else { return false }
        let normalized = workspacePath.lowercased()
        return normalized.contains("/newton") || normalized.contains("newton")
    }

    static func decodeCursorWorkspacePath(from encodedDirectoryName: String) -> String? {
        let directCandidate = "/" + encodedDirectoryName.split(separator: "-").joined(separator: "/")
        if FileManager.default.fileExists(atPath: directCandidate) {
            return directCandidate
        }

        let commonPrefix = "Users-pisoni-repos-"
        if encodedDirectoryName.hasPrefix(commonPrefix) {
            let suffix = encodedDirectoryName.dropFirst(commonPrefix.count)
            let candidate = "/Users/pisoni/repos/\(suffix)"
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        let localProjectsPrefix = "Users-pisoni-Development-LocalProjects-"
        if encodedDirectoryName.hasPrefix(localProjectsPrefix) {
            let suffix = encodedDirectoryName.dropFirst(localProjectsPrefix.count)
            let candidate = "/Users/pisoni/Development/LocalProjects/\(suffix)"
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    static func workspacePathFromFileURI(_ uri: String?) -> String? {
        guard let uri, let url = URL(string: uri), url.isFileURL else { return nil }
        return url.path(percentEncoded: false)
    }

    static func base64EncodedASCII(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }
}

struct SourceRoots {
    let copilotCLI: URL
    let cursorProjects: URL
    let vscodeWorkspaceStorage: URL

    static let live = SourceRoots(
        copilotCLI: AppPaths.homeDirectory.appendingPathComponent(".copilot/session-state", isDirectory: true),
        cursorProjects: AppPaths.homeDirectory.appendingPathComponent(".cursor/projects", isDirectory: true),
        vscodeWorkspaceStorage: AppPaths.homeDirectory.appendingPathComponent("Library/Application Support/Code/User/workspaceStorage", isDirectory: true)
    )
}

enum WorkspaceLauncher {
    static func performPrimaryAction(for record: SessionRecord) throws {
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

    static func reveal(path: String?) {
        guard let path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func openDocument(path: String?) {
        guard let path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func copilotResumeCommand(for record: SessionRecord) -> String {
        var components: [String] = []
        if let workspacePath = record.workspacePath {
            components.append("cd \(shellQuote(workspacePath))")
        }
        components.append("copilot --resume \(shellQuote(record.sourceSessionId))")
        return components.joined(separator: " && ")
    }

    private static func resumeCopilotCLI(sessionId: String, workingDirectory: String?) throws {
        var commandComponents: [String] = []
        if let workingDirectory {
            commandComponents.append("cd \(shellQuote(workingDirectory))")
        }
        commandComponents.append("copilot --resume \(shellQuote(sessionId))")
        let shellCommand = commandComponents.joined(separator: " && ")

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
                NSLocalizedDescriptionKey: "Terminal failed to launch the Copilot resume command."
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

enum TranscriptLoadingError: LocalizedError {
    case transcriptUnavailable
    case transcriptUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .transcriptUnavailable:
            return "This session does not have a readable transcript file."
        case let .transcriptUnreadable(path):
            return "The transcript at \(path) could not be read."
        }
    }
}

enum TranscriptPreviewExtractor {
    static func loadTranscript(for record: SessionRecord) throws -> TranscriptDocument {
        guard let transcriptPath = record.rawTranscriptPath else {
            throw TranscriptLoadingError.transcriptUnavailable
        }

        let url = URL(fileURLWithPath: transcriptPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptLoadingError.transcriptUnreadable(url.path)
        }

        switch record.source {
        case .copilotCLI, .vscodeCopilot:
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
        let contents = try String(contentsOf: url, encoding: .utf8)
        guard let firstLine = contents.split(separator: "\n", omittingEmptySubsequences: true).first,
              let data = firstLine.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let selectedModel = nestedString(
            in: object,
            path: ["v", "inputState", "selectedModel", "identifier"]
        )
        return normalizeModelIdentifier(selectedModel)
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
            let body = TextSanitizer.clean(payload?["message"] as? String)
            return TranscriptEntry(
                id: entryID,
                role: .system,
                title: infoType,
                body: body,
                timestamp: timestamp
            )
        case "tool.execution_start":
            let toolName = payload?["toolName"] as? String ?? "Tool"
            let body = toolArgumentsSummary(payload?["arguments"])
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
            let body = toolCompletionSummary(payload)
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
            if let error = TextSanitizer.clean(payload["error"] as? String) {
                return error
            }
            if let failure = nestedString(in: payload, path: ["result", "error"]) {
                return TextSanitizer.clean(failure)
            }
        }

        if let detail = nestedString(in: payload, path: ["result", "content"]),
           detail.count <= 140 {
            return TextSanitizer.clean(detail)
        }

        if let detail = nestedString(in: payload, path: ["result", "detailedContent"]),
           detail.count <= 140 {
            return TextSanitizer.clean(detail)
        }

        return nil
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

func combinedFingerprint(paths: [String?]) -> String {
    paths.map(fileFingerprint).joined(separator: "||")
}

func loadJSONDictionary(from url: URL) throws -> [String: Any]? {
    let data = try Data(contentsOf: url)
    return try JSONSerialization.jsonObject(with: data) as? [String: Any]
}
