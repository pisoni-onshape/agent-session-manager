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

enum TranscriptPreviewExtractor {
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
}

func fileDates(for url: URL) -> (created: Date?, modified: Date?) {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (
        attributes?[.creationDate] as? Date,
        attributes?[.modificationDate] as? Date
    )
}

func loadJSONDictionary(from url: URL) throws -> [String: Any]? {
    let data = try Data(contentsOf: url)
    return try JSONSerialization.jsonObject(with: data) as? [String: Any]
}
