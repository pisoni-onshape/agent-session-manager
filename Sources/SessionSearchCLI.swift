import Foundation

public struct SessionSearchCLIResult: Equatable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

private enum SessionSearchCLIOutputFormat {
    case humanReadable
    case json
}

private struct SessionSearchCLICommand {
    let request: SessionSearchRequest
    let refresh: Bool
    let outputFormat: SessionSearchCLIOutputFormat
    let withinArgument: String?
}

private enum SessionSearchCLIParseError: Error, Equatable {
    case help(topic: HelpTopic)
    case usage(String)

    enum HelpTopic: Equatable {
        case topLevel
        case search
    }
}

public enum SessionSearchCLI {
    private static let executableName = "agent-session-manager"
    private static let searchSourceValues = SessionSource.allCases.map(\.rawValue).joined(separator: ", ")

    public static func execute(
        arguments: [String] = CommandLine.arguments,
        referenceDate: Date = Date(),
        catalogFactory: () throws -> SessionCatalog = {
            try SessionCatalog.makeDefault(settingsProvider: { AppSettingsPersistence.loadSnapshot() })
        }
    ) -> SessionSearchCLIResult {
        do {
            let command = try parse(arguments: arguments)
            let catalog = try catalogFactory()
            let execution = try SessionSearchService.search(
                using: catalog,
                request: command.request,
                refresh: command.refresh,
                referenceDate: referenceDate
            )
            let output = try render(execution: execution, command: command)
            return SessionSearchCLIResult(exitCode: 0, standardOutput: output, standardError: "")
        } catch let error as SessionSearchCLIParseError {
            return parseErrorResult(error)
        } catch {
            return SessionSearchCLIResult(exitCode: 1, standardOutput: "", standardError: "Error: \(error.localizedDescription)\n")
        }
    }

    public static func execute(
        arguments: [String],
        snapshot: SessionCatalogSnapshot,
        referenceDate: Date = Date(),
        transcriptSearcher: ([String], String, TranscriptSearchScope) throws -> [TranscriptIndexSearchHit]
    ) -> SessionSearchCLIResult {
        do {
            let command = try parse(arguments: arguments)
            let execution = try SessionSearchService.search(
                snapshot: snapshot,
                request: command.request,
                referenceDate: referenceDate,
                transcriptSearcher: transcriptSearcher
            )
            let output = try render(execution: execution, command: command)
            return SessionSearchCLIResult(exitCode: 0, standardOutput: output, standardError: "")
        } catch let error as SessionSearchCLIParseError {
            return parseErrorResult(error)
        } catch {
            return SessionSearchCLIResult(exitCode: 1, standardOutput: "", standardError: "Error: \(error.localizedDescription)\n")
        }
    }

    public static var helpText: String {
        """
        Usage:
          \(executableName) search --query <text> [options]
          \(executableName) --search <text> [options]
          \(executableName) -h | --help

        Commands:
          search               Search the local session catalog.

        Common options:
          -h, --help           Show help for the tool or subcommand.

        Examples:
          \(executableName) search --query 'project:newton2 transcript:"drag bug"' --newton-only --branch main
          \(executableName) --search 'title:"plan update"' --within 1w --limit 10
          \(executableName) search --query 'source:cursor branch:main plan:"search service"' --json
        """
    }

    public static var searchHelpText: String {
        """
        Usage:
          \(executableName) search --query <text> [options]
          \(executableName) --search <text> [options]

        Search options:
          --query <text>       Search using the same label syntax as the app toolbar.
          --search <text>      Top-level alias for --query.
          --project <name>     Restrict to one project name.
          --branch <name>      Restrict to one branch name.
          --source <source>    Restrict to one source: \(searchSourceValues).
          --newton-only        Restrict to Newton repos only.
          --starred            Restrict to starred sessions.
          --unstarred          Restrict to unstarred sessions.
          --refresh            Refresh the catalog before searching.
          --within <duration>  Restrict by time window, e.g. 30m, 12h, 1d, 1w.
          --limit <count>      Limit the number of returned sessions.
          --json               Emit machine-readable JSON.
          -h, --help           Show this help text.
        """
    }

    private static func parse(arguments: [String]) throws -> SessionSearchCLICommand {
        let rawArguments = Array(arguments.dropFirst())
        guard let firstArgument = rawArguments.first else {
            throw SessionSearchCLIParseError.help(topic: .topLevel)
        }

        if isHelpFlag(firstArgument) {
            throw SessionSearchCLIParseError.help(topic: .topLevel)
        }

        if firstArgument == "search" {
            return try parseSearch(arguments: Array(rawArguments.dropFirst()))
        }

        return try parseSearch(arguments: rawArguments)
    }

    private static func parseSearch(arguments: [String]) throws -> SessionSearchCLICommand {
        var filters = SessionFilterState()
        var refresh = false
        var outputFormat: SessionSearchCLIOutputFormat = .humanReadable
        var resultLimit: Int?
        var updatedWithin: TimeInterval?
        var withinArgument: String?
        var queryText: String?
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                throw SessionSearchCLIParseError.help(topic: .search)
            case "--query", "--search":
                queryText = try consumeValue(for: argument, arguments: arguments, index: &index)
            case "--project":
                filters.selectedProject = try consumeValue(for: argument, arguments: arguments, index: &index)
            case "--branch":
                filters.selectedBranch = try consumeValue(for: argument, arguments: arguments, index: &index)
            case "--source":
                let rawSource = try consumeValue(for: argument, arguments: arguments, index: &index)
                guard let source = parseSource(rawSource) else {
                    throw SessionSearchCLIParseError.usage("Unknown source '\(rawSource)'. Expected one of: \(searchSourceValues).")
                }
                filters.selectedSourceRawValue = source.rawValue
            case "--newton-only":
                filters.newtonOnly = true
            case "--starred":
                guard filters.starFilter != .unstarred else {
                    throw SessionSearchCLIParseError.usage("Choose only one of --starred or --unstarred.")
                }
                filters.starFilter = .starred
            case "--unstarred":
                guard filters.starFilter != .starred else {
                    throw SessionSearchCLIParseError.usage("Choose only one of --starred or --unstarred.")
                }
                filters.starFilter = .unstarred
            case "--refresh":
                refresh = true
            case "--limit":
                let rawLimit = try consumeValue(for: argument, arguments: arguments, index: &index)
                guard let parsedLimit = Int(rawLimit), parsedLimit > 0 else {
                    throw SessionSearchCLIParseError.usage("Expected --limit to be a positive integer.")
                }
                resultLimit = parsedLimit
            case "--within":
                let rawDuration = try consumeValue(for: argument, arguments: arguments, index: &index)
                updatedWithin = try parseDuration(rawDuration)
                withinArgument = rawDuration
            case "--json":
                outputFormat = .json
            default:
                throw SessionSearchCLIParseError.usage("Unknown argument '\(argument)'.")
            }
            index += 1
        }

        guard let queryText, !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SessionSearchCLIParseError.usage("Missing required search text. Use --query <text> or --search <text>.")
        }
        filters.searchText = queryText

        return SessionSearchCLICommand(
            request: SessionSearchRequest(
                filters: filters,
                resultLimit: resultLimit,
                updatedWithin: updatedWithin
            ),
            refresh: refresh,
            outputFormat: outputFormat,
            withinArgument: withinArgument
        )
    }

    private static func render(
        execution: SessionSearchExecution,
        command: SessionSearchCLICommand
    ) throws -> String {
        switch command.outputFormat {
        case .humanReadable:
            return renderHumanReadable(execution: execution)
        case .json:
            return try renderJSON(execution: execution, command: command)
        }
    }

    private static func renderHumanReadable(execution: SessionSearchExecution) -> String {
        guard !execution.displayedSessions.isEmpty else {
            return "No sessions found.\n"
        }

        var lines: [String] = []
        lines.append("Found \(execution.displayedSessions.count) session\(execution.displayedSessions.count == 1 ? "" : "s").")

        for (index, session) in execution.displayedSessions.enumerated() {
            lines.append("")
            lines.append("\(index + 1). \(session.title)")
            lines.append("   source: \(session.source.displayName)")
            lines.append("   session id: \(session.sourceSessionId)")
            lines.append("   project: \(session.projectName)")
            if let branch = session.branch {
                lines.append("   branch: \(branch)")
            }
            if let model = session.conversationModel {
                lines.append("   model: \(model)")
            }
            if let startedAt = ISO8601DateCoding.string(session.startedAt) {
                lines.append("   started: \(startedAt)")
            }
            if let updatedAt = ISO8601DateCoding.string(session.updatedAt) {
                lines.append("   updated: \(updatedAt)")
            }
            if let workspacePath = session.workspacePath {
                lines.append("   workspace: \(workspacePath)")
            }
            if let summary = session.summary {
                lines.append("   summary: \(summary)")
            }
            lines.append("   starred: \(execution.snapshot.starredSessionIDs.contains(session.id) ? "yes" : "no")")
            lines.append("   newton: \(session.isNewtonProject ? "yes" : "no")")
            if let transcriptPath = session.rawTranscriptPath {
                lines.append("   transcript: \(transcriptPath)")
            }
            if let metadataPath = session.rawMetadataPath {
                lines.append("   metadata: \(metadataPath)")
            }
            if let planPath = session.relatedPlanPath {
                lines.append("   plan: \(planPath)")
            }
            if let match = execution.searchState.mergedResultsBySessionID[session.id] {
                if match.transcriptMatchCount > 0 {
                    lines.append("   transcript matches: \(match.transcriptMatchCount)")
                    for snippet in match.transcriptSnippets {
                        lines.append("   transcript snippet: \(snippet)")
                    }
                }
                if match.planMatchCount > 0 {
                    lines.append("   plan matches: \(match.planMatchCount)")
                    for snippet in match.planSnippets {
                        lines.append("   plan snippet: \(snippet)")
                    }
                }
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func renderJSON(
        execution: SessionSearchExecution,
        command: SessionSearchCLICommand
    ) throws -> String {
        let payload = SessionSearchCLIJSONPayload(
            query: command.request.filters.searchText,
            refreshed: command.refresh,
            within: command.withinArgument,
            limit: command.request.resultLimit,
            resultCount: execution.displayedSessions.count,
            searchedSessionCount: execution.searchState.searchedSessionCount,
            sessions: execution.displayedSessions.map { session in
                let match = execution.searchState.mergedResultsBySessionID[session.id]
                return SessionSearchCLIJSONSession(
                    source: session.source.rawValue,
                    sourceDisplayName: session.source.displayName,
                    sessionID: session.sourceSessionId,
                    title: session.title,
                    project: session.projectName,
                    branch: session.branch,
                    model: session.conversationModel,
                    startedAt: ISO8601DateCoding.string(session.startedAt),
                    updatedAt: ISO8601DateCoding.string(session.updatedAt),
                    workspacePath: session.workspacePath,
                    summary: session.summary,
                    transcriptPath: session.rawTranscriptPath,
                    metadataPath: session.rawMetadataPath,
                     planPath: session.relatedPlanPath,
                     starred: execution.snapshot.starredSessionIDs.contains(session.id),
                     newtonProject: session.isNewtonProject,
                     transcriptMatchCount: match?.transcriptMatchCount,
                     planMatchCount: match?.planMatchCount,
                     transcriptSnippets: match?.transcriptSnippets ?? [],
                     planSnippets: match?.planSnippets ?? []
                 )
             }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private static func parseErrorResult(_ error: SessionSearchCLIParseError) -> SessionSearchCLIResult {
        switch error {
        case let .help(topic):
            let text = topic == .topLevel ? helpText : searchHelpText
            return SessionSearchCLIResult(exitCode: 0, standardOutput: text + "\n", standardError: "")
        case let .usage(message):
            return SessionSearchCLIResult(
                exitCode: 64,
                standardOutput: "",
                standardError: "Error: \(message)\n\n\(searchHelpText)\n"
            )
        }
    }

    private static func consumeValue(for option: String, arguments: [String], index: inout Int) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw SessionSearchCLIParseError.usage("Missing value for \(option).")
        }
        let value = arguments[valueIndex]
        guard !value.isEmpty else {
            throw SessionSearchCLIParseError.usage("Missing value for \(option).")
        }
        index = valueIndex
        return value
    }

    private static func parseSource(_ rawValue: String) -> SessionSource? {
        let normalized = rawValue.lowercased()
        if let source = SessionSource(rawValue: normalized) {
            return source
        }
        switch normalized {
        case "copilot":
            return .copilotCLI
        case "vscode", "code":
            return .vscodeCopilot
        default:
            return nil
        }
    }

    private static func parseDuration(_ rawValue: String) throws -> TimeInterval {
        guard let suffix = rawValue.last else {
            throw SessionSearchCLIParseError.usage("Expected --within to use a duration such as 30m, 12h, 1d, or 1w.")
        }

        let numericPortion = String(rawValue.dropLast())
        guard let quantity = Double(numericPortion), quantity > 0 else {
            throw SessionSearchCLIParseError.usage("Expected --within to use a positive duration such as 30m, 12h, 1d, or 1w.")
        }

        switch suffix.lowercased() {
        case "m":
            return quantity * 60
        case "h":
            return quantity * 60 * 60
        case "d":
            return quantity * 24 * 60 * 60
        case "w":
            return quantity * 7 * 24 * 60 * 60
        default:
            throw SessionSearchCLIParseError.usage("Expected --within to use one of the suffixes m, h, d, or w.")
        }
    }

    private static func isHelpFlag(_ argument: String) -> Bool {
        argument == "-h" || argument == "--help"
    }
}

private struct SessionSearchCLIJSONPayload: Encodable {
    let query: String
    let refreshed: Bool
    let within: String?
    let limit: Int?
    let resultCount: Int
    let searchedSessionCount: Int
    let sessions: [SessionSearchCLIJSONSession]
}

private struct SessionSearchCLIJSONSession: Encodable {
    let source: String
    let sourceDisplayName: String
    let sessionID: String
    let title: String
    let project: String
    let branch: String?
    let model: String?
    let startedAt: String?
    let updatedAt: String?
    let workspacePath: String?
    let summary: String?
    let transcriptPath: String?
    let metadataPath: String?
    let planPath: String?
    let starred: Bool
    let newtonProject: Bool
    let transcriptMatchCount: Int?
    let planMatchCount: Int?
    let transcriptSnippets: [String]
    let planSnippets: [String]
}
