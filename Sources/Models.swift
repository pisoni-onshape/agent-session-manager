import Foundation

public enum SessionSource: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case copilotCLI = "copilot-cli"
    case cursor
    case vscodeCopilot = "vscode-copilot"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .copilotCLI:
            return "Copilot CLI"
        case .cursor:
            return "Cursor"
        case .vscodeCopilot:
            return "VS Code Copilot"
        }
    }

    public var systemImageName: String {
        switch self {
        case .copilotCLI:
            return "terminal"
        case .cursor:
            return "cursorarrow.rays"
        case .vscodeCopilot:
            return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// Asset catalog image name for sources that have a custom app icon.
    /// Returns `nil` for sources that should fall back to SF Symbols.
    public var appIconAssetName: String? {
        switch self {
        case .copilotCLI:
            return nil
        case .cursor:
            return "CursorIcon"
        case .vscodeCopilot:
            return "VSCodeIcon"
        }
    }
}

public enum ResumeActionKind: String, Codable, Sendable {
    case copilotConnect
    case openInCursor
    case openInVSCode
    case revealPath
}

public enum SessionSortMode: String, CaseIterable, Identifiable, Sendable {
    case recentlyUpdated
    case startedAt
    case project
    case source
    case title

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .recentlyUpdated:
            return "Recently Updated"
        case .startedAt:
            return "Started Time"
        case .project:
            return "Project"
        case .source:
            return "Source"
        case .title:
            return "Title"
        }
    }
}

public enum SessionStarFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case starred
    case unstarred

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all:
            return "All Sessions"
        case .starred:
            return "Starred"
        case .unstarred:
            return "Unstarred"
        }
    }
}

public struct SessionRecord: Identifiable, Equatable, Sendable {
    public let source: SessionSource
    public let sourceSessionId: String
    public let workspacePath: String?
    public let projectName: String
    public let branch: String?
    public let conversationModel: String?
    public let startedAt: Date?
    public let updatedAt: Date?
    public let title: String
    public let summary: String?
    public let firstUserPreview: String?
    public let firstAssistantPreview: String?
    public let rawTranscriptPath: String?
    public let rawMetadataPath: String?
    public let relatedPlanPath: String?
    public let fingerprint: String
    public let resumeKind: ResumeActionKind
    public let resumePayload: String
    public let isNewtonProject: Bool

    public init(
        source: SessionSource,
        sourceSessionId: String,
        workspacePath: String?,
        projectName: String,
        branch: String?,
        conversationModel: String?,
        startedAt: Date?,
        updatedAt: Date?,
        title: String,
        summary: String?,
        firstUserPreview: String?,
        firstAssistantPreview: String?,
        rawTranscriptPath: String?,
        rawMetadataPath: String?,
        relatedPlanPath: String?,
        fingerprint: String,
        resumeKind: ResumeActionKind,
        resumePayload: String,
        isNewtonProject: Bool
    ) {
        self.source = source
        self.sourceSessionId = sourceSessionId
        self.workspacePath = workspacePath
        self.projectName = projectName
        self.branch = branch
        self.conversationModel = conversationModel
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.title = title
        self.summary = summary
        self.firstUserPreview = firstUserPreview
        self.firstAssistantPreview = firstAssistantPreview
        self.rawTranscriptPath = rawTranscriptPath
        self.rawMetadataPath = rawMetadataPath
        self.relatedPlanPath = relatedPlanPath
        self.fingerprint = fingerprint
        self.resumeKind = resumeKind
        self.resumePayload = resumePayload
        self.isNewtonProject = isNewtonProject
    }

    public var id: String {
        "\(source.rawValue)::\(sourceSessionId)"
    }

    public var subtitle: String {
        [projectName, branch].compactMap { $0 }.joined(separator: " • ")
    }

    public var bestTimestamp: Date? {
        updatedAt ?? startedAt
    }

    public var detailSummary: String {
        summary
            ?? TextSanitizer.summarize(firstAssistantPreview ?? firstUserPreview)
            ?? "No preview available."
    }

    public func with(isNewtonProject: Bool) -> SessionRecord {
        SessionRecord(
            source: source,
            sourceSessionId: sourceSessionId,
            workspacePath: workspacePath,
            projectName: projectName,
            branch: branch,
            conversationModel: conversationModel,
            startedAt: startedAt,
            updatedAt: updatedAt,
            title: title,
            summary: summary,
            firstUserPreview: firstUserPreview,
            firstAssistantPreview: firstAssistantPreview,
            rawTranscriptPath: rawTranscriptPath,
            rawMetadataPath: rawMetadataPath,
            relatedPlanPath: relatedPlanPath,
            fingerprint: fingerprint,
            resumeKind: resumeKind,
            resumePayload: resumePayload,
            isNewtonProject: isNewtonProject
        )
    }
}

public enum SessionSearchField: String, CaseIterable, Sendable {
    case title
    case project
    case branch
    case source
    case model
    case id
    case transcript
}

public struct SessionSearchFieldClause: Equatable, Sendable {
    public let field: SessionSearchField
    public let value: String

    public init(field: SessionSearchField, value: String) {
        self.field = field
        self.value = value
    }
}

public struct ParsedSessionSearchQuery: Equatable, Sendable {
    public let rawText: String
    public let fieldClauses: [SessionSearchFieldClause]
    public let freeTextTerms: [String]
    public let usesStructuredSyntax: Bool

    public var hasFieldClauses: Bool {
        !fieldClauses.isEmpty
    }

    public var isEmpty: Bool {
        rawText.isEmpty
    }

    public var normalizedWholeText: String {
        rawText.lowercased()
    }

    public var metadataFieldClauses: [SessionSearchFieldClause] {
        fieldClauses.filter { $0.field != .transcript }
    }

    public var transcriptFieldValues: [String] {
        fieldClauses
            .filter { $0.field == .transcript }
            .map(\.value)
    }

    public var transcriptQueries: [String] {
        if isEmpty {
            return []
        }
        if !usesStructuredSyntax {
            return [normalizedWholeText]
        }
        return orderedUnique(transcriptFieldValues + freeTextTerms)
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for value in values where !value.isEmpty {
            if seen.insert(value).inserted {
                ordered.append(value)
            }
        }
        return ordered
    }
}

public enum SessionSearchQueryParser {
    public static func parse(_ rawQuery: String) -> ParsedSessionSearchQuery {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ParsedSessionSearchQuery(rawText: "", fieldClauses: [], freeTextTerms: [], usesStructuredSyntax: false)
        }

        var fieldClauses: [SessionSearchFieldClause] = []
        var freeTextTerms: [String] = []
        var usesStructuredSyntax = false
        var index = trimmed.startIndex

        while let token = nextToken(in: trimmed, from: &index) {
            switch token {
            case let .field(rawKey, rawValue, rawToken):
                usesStructuredSyntax = true
                let normalizedValue = rawValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let field = SessionSearchField(rawValue: rawKey.lowercased()),
                   let normalizedValue,
                   !normalizedValue.isEmpty {
                    fieldClauses.append(SessionSearchFieldClause(field: field, value: normalizedValue.lowercased()))
                } else if let normalizedValue, !normalizedValue.isEmpty {
                    freeTextTerms.append(normalizedValue.lowercased())
                } else {
                    freeTextTerms.append(rawToken.lowercased())
                }
            case let .freeText(rawText, wasQuoted):
                usesStructuredSyntax = usesStructuredSyntax || wasQuoted
                let normalized = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty {
                    freeTextTerms.append(normalized.lowercased())
                }
            }
        }

        return ParsedSessionSearchQuery(
            rawText: trimmed,
            fieldClauses: fieldClauses,
            freeTextTerms: freeTextTerms,
            usesStructuredSyntax: usesStructuredSyntax
        )
    }

    private enum Token {
        case field(rawKey: String, rawValue: String?, rawToken: String)
        case freeText(String, wasQuoted: Bool)
    }

    private static func nextToken(in query: String, from index: inout String.Index) -> Token? {
        skipWhitespace(in: query, from: &index)
        guard index < query.endIndex else { return nil }

        let tokenStart = index
        if query[index] == "\"" {
            let value = consumeQuotedText(in: query, from: &index)
            return .freeText(value, wasQuoted: true)
        }

        let keyStart = index
        while index < query.endIndex,
              query[index].isLetter {
            index = query.index(after: index)
        }

        if index < query.endIndex,
           query[index] == ":",
           keyStart != index {
            let key = String(query[keyStart..<index])
            index = query.index(after: index)

            let value: String?
            if index < query.endIndex, query[index] == "\"" {
                value = consumeQuotedText(in: query, from: &index)
            } else {
                let valueStart = index
                while index < query.endIndex, !query[index].isWhitespace {
                    index = query.index(after: index)
                }
                value = valueStart == index ? nil : String(query[valueStart..<index])
            }

            let rawToken = String(query[tokenStart..<index])
            return .field(rawKey: key, rawValue: value, rawToken: rawToken)
        }

        index = tokenStart
        while index < query.endIndex, !query[index].isWhitespace {
            index = query.index(after: index)
        }
        return .freeText(String(query[tokenStart..<index]), wasQuoted: false)
    }

    private static func skipWhitespace(in query: String, from index: inout String.Index) {
        while index < query.endIndex, query[index].isWhitespace {
            index = query.index(after: index)
        }
    }

    private static func consumeQuotedText(in query: String, from index: inout String.Index) -> String {
        guard index < query.endIndex, query[index] == "\"" else { return "" }
        index = query.index(after: index)
        let valueStart = index
        while index < query.endIndex, query[index] != "\"" {
            index = query.index(after: index)
        }
        let value = String(query[valueStart..<index])
        if index < query.endIndex, query[index] == "\"" {
            index = query.index(after: index)
        }
        return value
    }
}

extension SessionRecord {
    func matchesBroadSearch(_ query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        return broadSearchHaystack.contains(normalized)
    }

    func matchesFieldClause(_ clause: SessionSearchFieldClause) -> Bool {
        searchableValues(for: clause.field).contains { $0.contains(clause.value) }
    }

    private var broadSearchHaystack: String {
        [
            title,
            projectName,
            branch,
            conversationModel,
            summary,
            firstUserPreview,
            firstAssistantPreview,
            sourceSessionId
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: "\n")
    }

    private func searchableValues(for field: SessionSearchField) -> [String] {
        switch field {
        case .title:
            return [title.lowercased()]
        case .project:
            return [projectName.lowercased()]
        case .branch:
            return [branch?.lowercased()].compactMap { $0 }
        case .source:
            return [source.rawValue.lowercased(), source.displayName.lowercased()]
        case .model:
            return [conversationModel?.lowercased()].compactMap { $0 }
        case .id:
            return [sourceSessionId.lowercased(), id.lowercased()]
        case .transcript:
            return []
        }
    }
}

public struct TranscriptPreview: Sendable {
    public var sessionId: String?
    public var startedAt: Date?
    public var latestModel: String?
    public var firstUser: String?
    public var firstAssistant: String?

    public init(
        sessionId: String? = nil,
        startedAt: Date? = nil,
        latestModel: String? = nil,
        firstUser: String? = nil,
        firstAssistant: String? = nil
    ) {
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.latestModel = latestModel
        self.firstUser = firstUser
        self.firstAssistant = firstAssistant
    }

    public var summary: String? {
        TextSanitizer.summarize(firstAssistant ?? firstUser)
    }
}

public struct SessionFilterState: Equatable, Sendable {
    public static let allProjectsToken = "__all_projects__"
    public static let allBranchesToken = "__all_branches__"
    public static let allSourcesToken = "__all_sources__"

    public var searchText = ""
    public var selectedSourceRawValue = allSourcesToken
    public var selectedProject = allProjectsToken
    public var selectedBranch = allBranchesToken
    public var starFilter: SessionStarFilter = .all
    public var newtonOnly = false
    public var sortMode: SessionSortMode = .recentlyUpdated

    public init() {}

    public var selectedSource: SessionSource? {
        SessionSource(rawValue: selectedSourceRawValue)
    }

    public var hasCustomSourceSelection: Bool {
        selectedSourceRawValue != Self.allSourcesToken
    }

    public var hasCustomProjectSelection: Bool {
        selectedProject != Self.allProjectsToken
    }

    public var hasCustomBranchSelection: Bool {
        selectedBranch != Self.allBranchesToken
    }

    public var hasCustomStarFilter: Bool {
        starFilter != .all
    }

    public var hasCustomSortMode: Bool {
        sortMode != .recentlyUpdated
    }
}

public struct TranscriptViewerSearchResult: Equatable, Sendable {
    public let displayItems: [TranscriptDisplayItem]
    public let totalMatchCount: Int
    public let matchingEntryCount: Int
    public let highlightQuery: String?

    public var isActive: Bool {
        highlightQuery != nil
    }
}

public struct PresentedTranscript: Codable, Hashable, Identifiable, Sendable {
    public let transcript: TranscriptDocument
    public let initialSearchText: String

    public init(transcript: TranscriptDocument, initialSearchText: String) {
        self.transcript = transcript
        self.initialSearchText = initialSearchText
    }

    public var id: String {
        transcript.id
    }
}

public struct TranscriptSessionSearchMatch: Identifiable, Equatable, Sendable {
    public let sessionRecordID: String
    public let matchCount: Int
    public let snippets: [String]

    public var id: String {
        sessionRecordID
    }
}

public struct TranscriptIndexEntry: Equatable, Sendable {
    public let sessionRecordID: String
    public let entryIndex: Int
    public let text: String

    public init(sessionRecordID: String, entryIndex: Int, text: String) {
        self.sessionRecordID = sessionRecordID
        self.entryIndex = entryIndex
        self.text = text
    }
}

public struct TranscriptIndexSearchHit: Equatable, Sendable {
    public let sessionRecordID: String
    public let entryIndex: Int
    public let text: String

    public init(sessionRecordID: String, entryIndex: Int, text: String) {
        self.sessionRecordID = sessionRecordID
        self.entryIndex = entryIndex
        self.text = text
    }
}

public struct SessionSearchState: Equatable, Sendable {
    public var requestedQuery = ""
    public var searchedScopeSignature = ""
    public var searchedSessionCount = 0
    public var resultsByQuery: [String: [TranscriptIndexSearchHit]] = [:]
    public var mergedResultsBySessionID: [String: TranscriptSessionSearchMatch] = [:]
    public var isSearching = false
    public var lastError: String?

    public init(
        requestedQuery: String = "",
        searchedScopeSignature: String = "",
        searchedSessionCount: Int = 0,
        resultsByQuery: [String: [TranscriptIndexSearchHit]] = [:],
        mergedResultsBySessionID: [String: TranscriptSessionSearchMatch] = [:],
        isSearching: Bool = false,
        lastError: String? = nil
    ) {
        self.requestedQuery = requestedQuery
        self.searchedScopeSignature = searchedScopeSignature
        self.searchedSessionCount = searchedSessionCount
        self.resultsByQuery = resultsByQuery
        self.mergedResultsBySessionID = mergedResultsBySessionID
        self.isSearching = isSearching
        self.lastError = lastError
    }

    public var sessionIDsByQuery: [String: Set<String>] {
        Dictionary(
            uniqueKeysWithValues: resultsByQuery.map { query, hits in
                (query, Set(hits.map(\.sessionRecordID)))
            }
        )
    }

    public var totalMatchCount: Int {
        mergedResultsBySessionID.values.reduce(0) { $0 + $1.matchCount }
    }

    public var hasRequestedQuery: Bool {
        !requestedQuery.isEmpty
    }
}

public enum SessionSearchEvaluator {
    public static func filterSessions(
        _ sessions: [SessionRecord],
        parsedQuery: ParsedSessionSearchQuery,
        transcriptSessionIDsByQuery: [String: Set<String>]
    ) -> [SessionRecord] {
        sessions.filter { matches($0, parsedQuery: parsedQuery, transcriptSessionIDsByQuery: transcriptSessionIDsByQuery) }
    }

    public static func matches(
        _ record: SessionRecord,
        parsedQuery: ParsedSessionSearchQuery,
        transcriptSessionIDsByQuery: [String: Set<String>]
    ) -> Bool {
        if parsedQuery.isEmpty {
            return true
        }

        if !parsedQuery.usesStructuredSyntax {
            return record.matchesBroadSearch(parsedQuery.normalizedWholeText)
                || transcriptSessionIDsByQuery[parsedQuery.normalizedWholeText]?.contains(record.id) == true
        }

        guard parsedQuery.metadataFieldClauses.allSatisfy(record.matchesFieldClause) else {
            return false
        }

        for transcriptQuery in parsedQuery.transcriptFieldValues {
            guard transcriptSessionIDsByQuery[transcriptQuery]?.contains(record.id) == true else {
                return false
            }
        }

        for freeTextTerm in parsedQuery.freeTextTerms {
            if record.matchesBroadSearch(freeTextTerm) {
                continue
            }
            guard transcriptSessionIDsByQuery[freeTextTerm]?.contains(record.id) == true else {
                return false
            }
        }

        return true
    }
}

public enum TranscriptEntryRole: String, Codable, Hashable, Sendable {
    case user
    case assistant
    case tool
    case system
}

public struct TranscriptEntry: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let role: TranscriptEntryRole
    public let title: String
    public let body: String?
    public let timestamp: Date?

    public init(id: String, role: TranscriptEntryRole, title: String, body: String?, timestamp: Date?) {
        self.id = id
        self.role = role
        self.title = title
        self.body = body
        self.timestamp = timestamp
    }

    public var isChatMessage: Bool {
        role == .user || role == .assistant
    }
}

public struct TranscriptDocument: Codable, Hashable, Identifiable, Sendable {
    public let sessionID: String
    public let sessionTitle: String
    public let source: SessionSource
    public let rawTranscriptPath: String
    public let entries: [TranscriptEntry]
    public let timestampsAreComplete: Bool
    public let timestampNotice: String?

    public init(
        sessionID: String,
        sessionTitle: String,
        source: SessionSource,
        rawTranscriptPath: String,
        entries: [TranscriptEntry],
        timestampsAreComplete: Bool,
        timestampNotice: String?
    ) {
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
        self.source = source
        self.rawTranscriptPath = rawTranscriptPath
        self.entries = entries
        self.timestampsAreComplete = timestampsAreComplete
        self.timestampNotice = timestampNotice
    }

    public var id: String {
        "\(source.rawValue)::\(sessionID)"
    }
}

public enum TranscriptDisplayItem: Identifiable, Equatable, Sendable {
    case entry(TranscriptEntry)
    case collapsedEvents(id: String, entries: [TranscriptEntry])

    public var id: String {
        switch self {
        case let .entry(entry):
            return entry.id
        case let .collapsedEvents(id, _):
            return id
        }
    }

    public var timestamp: Date? {
        switch self {
        case let .entry(entry):
            return entry.timestamp
        case let .collapsedEvents(_, entries):
            return entries.compactMap(\.timestamp).first
        }
    }
}

public extension TranscriptDocument {
    var displayItems: [TranscriptDisplayItem] {
        var items: [TranscriptDisplayItem] = []
        var pendingEvents: [TranscriptEntry] = []

        func flushPendingEvents() {
            guard !pendingEvents.isEmpty else { return }
            let groupID = pendingEvents.map(\.id).joined(separator: "::")
            items.append(.collapsedEvents(id: groupID, entries: pendingEvents))
            pendingEvents.removeAll()
        }

        for entry in entries {
            if entry.isChatMessage {
                flushPendingEvents()
                items.append(.entry(entry))
            } else {
                pendingEvents.append(entry)
            }
        }

        flushPendingEvents()
        return items
    }

    var chatDisplayItems: [TranscriptDisplayItem] {
        entries
            .filter(\.isChatMessage)
            .map(TranscriptDisplayItem.entry)
    }

    func viewerSearchResult(for rawQuery: String) -> TranscriptViewerSearchResult {
        guard let query = SearchTextMatcher.normalizedQuery(rawQuery) else {
            return TranscriptViewerSearchResult(
                displayItems: displayItems,
                totalMatchCount: 0,
                matchingEntryCount: 0,
                highlightQuery: nil
            )
        }

        let matches = entries.compactMap { entry -> (TranscriptEntry, Int)? in
            guard entry.isChatMessage else { return nil }
            let matchCount = SearchTextMatcher.matchCount(in: entry.body, query: query)
            guard matchCount > 0 else { return nil }
            return (entry, matchCount)
        }

        return TranscriptViewerSearchResult(
            displayItems: matches.map { .entry($0.0) },
            totalMatchCount: matches.reduce(0) { $0 + $1.1 },
            matchingEntryCount: matches.count,
            highlightQuery: query
        )
    }

    func sessionSearchMatch(for rawQuery: String) -> TranscriptSessionSearchMatch? {
        guard let query = SearchTextMatcher.normalizedQuery(rawQuery) else { return nil }

        var totalMatchCount = 0
        var snippets: [String] = []

        for entry in entries {
            let searchableParts = [entry.title, entry.body].compactMap { $0 }
            var entryMatchCount = 0
            var entrySnippet: String?

            for part in searchableParts {
                let matchCount = SearchTextMatcher.matchCount(in: part, query: query)
                guard matchCount > 0 else { continue }
                entryMatchCount += matchCount
                if entrySnippet == nil {
                    entrySnippet = SearchTextMatcher.snippet(in: part, query: query)
                }
            }

            guard entryMatchCount > 0 else { continue }
            totalMatchCount += entryMatchCount
            if let entrySnippet, !snippets.contains(entrySnippet) {
                snippets.append(entrySnippet)
            }
        }

        guard totalMatchCount > 0 else { return nil }
        return TranscriptSessionSearchMatch(
            sessionRecordID: id,
            matchCount: totalMatchCount,
            snippets: Array(snippets.prefix(2))
        )
    }
}
