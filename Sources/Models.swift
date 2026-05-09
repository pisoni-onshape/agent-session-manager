import Foundation

enum SessionSource: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case copilotCLI = "copilot-cli"
    case cursor
    case vscodeCopilot = "vscode-copilot"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .copilotCLI:
            return "Copilot CLI"
        case .cursor:
            return "Cursor"
        case .vscodeCopilot:
            return "VS Code Copilot"
        }
    }

    var systemImageName: String {
        switch self {
        case .copilotCLI:
            return "terminal"
        case .cursor:
            return "cursorarrow.rays"
        case .vscodeCopilot:
            return "chevron.left.forwardslash.chevron.right"
        }
    }
}

enum ResumeActionKind: String, Codable, Sendable {
    case copilotConnect
    case openInCursor
    case openInVSCode
    case revealPath
}

enum SessionSortMode: String, CaseIterable, Identifiable, Sendable {
    case recentlyUpdated
    case startedAt
    case project
    case source
    case title

    var id: String { rawValue }

    var displayName: String {
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

enum SessionStarFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case starred
    case unstarred

    var id: String { rawValue }

    var displayName: String {
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

struct SessionRecord: Identifiable, Equatable, Sendable {
    let source: SessionSource
    let sourceSessionId: String
    let workspacePath: String?
    let projectName: String
    let branch: String?
    let conversationModel: String?
    let startedAt: Date?
    let updatedAt: Date?
    let title: String
    let summary: String?
    let firstUserPreview: String?
    let firstAssistantPreview: String?
    let rawTranscriptPath: String?
    let rawMetadataPath: String?
    let relatedPlanPath: String?
    let fingerprint: String
    let resumeKind: ResumeActionKind
    let resumePayload: String
    let isNewtonProject: Bool

    var id: String {
        "\(source.rawValue)::\(sourceSessionId)"
    }

    var subtitle: String {
        [projectName, branch].compactMap { $0 }.joined(separator: " • ")
    }

    var bestTimestamp: Date? {
        updatedAt ?? startedAt
    }

    var detailSummary: String {
        summary ?? firstAssistantPreview ?? firstUserPreview ?? "No preview available."
    }
}

enum SessionSearchField: String, CaseIterable, Sendable {
    case title
    case project
    case branch
    case source
    case model
    case id
    case transcript
}

struct SessionSearchFieldClause: Equatable, Sendable {
    let field: SessionSearchField
    let value: String
}

struct ParsedSessionSearchQuery: Equatable, Sendable {
    let rawText: String
    let fieldClauses: [SessionSearchFieldClause]
    let freeTextTerms: [String]
    let usesStructuredSyntax: Bool

    var hasFieldClauses: Bool {
        !fieldClauses.isEmpty
    }

    var isEmpty: Bool {
        rawText.isEmpty
    }

    var normalizedWholeText: String {
        rawText.lowercased()
    }

    var metadataFieldClauses: [SessionSearchFieldClause] {
        fieldClauses.filter { $0.field != .transcript }
    }

    var transcriptFieldValues: [String] {
        fieldClauses
            .filter { $0.field == .transcript }
            .map(\.value)
    }

    var transcriptQueries: [String] {
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

enum SessionSearchQueryParser {
    static func parse(_ rawQuery: String) -> ParsedSessionSearchQuery {
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

struct TranscriptPreview: Sendable {
    var sessionId: String?
    var startedAt: Date?
    var latestModel: String?
    var firstUser: String?
    var firstAssistant: String?

    var summary: String? {
        TextSanitizer.summarize(firstAssistant ?? firstUser)
    }
}

struct SessionFilterState: Equatable, Sendable {
    static let allProjectsToken = "__all_projects__"
    static let allBranchesToken = "__all_branches__"
    static let allSourcesToken = "__all_sources__"

    var searchText = ""
    var selectedSourceRawValue = allSourcesToken
    var selectedProject = allProjectsToken
    var selectedBranch = allBranchesToken
    var starFilter: SessionStarFilter = .all
    var newtonOnly = false
    var sortMode: SessionSortMode = .recentlyUpdated

    var selectedSource: SessionSource? {
        SessionSource(rawValue: selectedSourceRawValue)
    }

    var hasCustomSourceSelection: Bool {
        selectedSourceRawValue != Self.allSourcesToken
    }

    var hasCustomProjectSelection: Bool {
        selectedProject != Self.allProjectsToken
    }

    var hasCustomBranchSelection: Bool {
        selectedBranch != Self.allBranchesToken
    }

    var hasCustomStarFilter: Bool {
        starFilter != .all
    }

    var hasCustomSortMode: Bool {
        sortMode != .recentlyUpdated
    }
}

struct TranscriptViewerSearchResult: Equatable, Sendable {
    let displayItems: [TranscriptDisplayItem]
    let totalMatchCount: Int
    let matchingEntryCount: Int
    let highlightQuery: String?

    var isActive: Bool {
        highlightQuery != nil
    }
}

struct PresentedTranscript: Codable, Hashable, Identifiable, Sendable {
    let transcript: TranscriptDocument
    let initialSearchText: String

    var id: String {
        transcript.id
    }
}

struct TranscriptSessionSearchMatch: Identifiable, Equatable, Sendable {
    let sessionRecordID: String
    let matchCount: Int
    let snippets: [String]

    var id: String {
        sessionRecordID
    }
}

struct TranscriptIndexEntry: Equatable, Sendable {
    let sessionRecordID: String
    let entryIndex: Int
    let text: String
}

struct TranscriptIndexSearchHit: Equatable, Sendable {
    let sessionRecordID: String
    let entryIndex: Int
    let text: String
}

struct SessionSearchState: Equatable, Sendable {
    var requestedQuery = ""
    var searchedScopeSignature = ""
    var searchedSessionCount = 0
    var resultsByQuery: [String: [TranscriptIndexSearchHit]] = [:]
    var mergedResultsBySessionID: [String: TranscriptSessionSearchMatch] = [:]
    var isSearching = false
    var lastError: String?

    var sessionIDsByQuery: [String: Set<String>] {
        Dictionary(
            uniqueKeysWithValues: resultsByQuery.map { query, hits in
                (query, Set(hits.map(\.sessionRecordID)))
            }
        )
    }

    var totalMatchCount: Int {
        mergedResultsBySessionID.values.reduce(0) { $0 + $1.matchCount }
    }

    var hasRequestedQuery: Bool {
        !requestedQuery.isEmpty
    }
}

enum SessionSearchEvaluator {
    static func filterSessions(
        _ sessions: [SessionRecord],
        parsedQuery: ParsedSessionSearchQuery,
        transcriptSessionIDsByQuery: [String: Set<String>]
    ) -> [SessionRecord] {
        sessions.filter { matches($0, parsedQuery: parsedQuery, transcriptSessionIDsByQuery: transcriptSessionIDsByQuery) }
    }

    static func matches(
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

enum TranscriptEntryRole: String, Codable, Hashable, Sendable {
    case user
    case assistant
    case tool
    case system
}

struct TranscriptEntry: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let role: TranscriptEntryRole
    let title: String
    let body: String?
    let timestamp: Date?

    var isChatMessage: Bool {
        role == .user || role == .assistant
    }
}

struct TranscriptDocument: Codable, Hashable, Identifiable, Sendable {
    let sessionID: String
    let sessionTitle: String
    let source: SessionSource
    let rawTranscriptPath: String
    let entries: [TranscriptEntry]
    let timestampsAreComplete: Bool
    let timestampNotice: String?

    var id: String {
        "\(source.rawValue)::\(sessionID)"
    }
}

enum TranscriptDisplayItem: Identifiable, Equatable, Sendable {
    case entry(TranscriptEntry)
    case collapsedEvents(id: String, entries: [TranscriptEntry])

    var id: String {
        switch self {
        case let .entry(entry):
            return entry.id
        case let .collapsedEvents(id, _):
            return id
        }
    }

    var timestamp: Date? {
        switch self {
        case let .entry(entry):
            return entry.timestamp
        case let .collapsedEvents(_, entries):
            return entries.compactMap(\.timestamp).first
        }
    }
}

extension TranscriptDocument {
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
