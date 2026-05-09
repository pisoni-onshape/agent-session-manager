import Foundation

enum RefreshActivity: Equatable {
    case idle
    case incremental
    case rebuild
}

enum SessionFilterEvaluator {
    static func applyScopeFilters(
        _ sessions: [SessionRecord],
        filters: SessionFilterState,
        starredSessionIDs: Set<String> = []
    ) -> [SessionRecord] {
        sessions.filter { record in
            if let source = filters.selectedSource, record.source != source {
                return false
            }
            if filters.selectedProject != SessionFilterState.allProjectsToken, record.projectName != filters.selectedProject {
                return false
            }
            if filters.selectedBranch != SessionFilterState.allBranchesToken, record.branch != filters.selectedBranch {
                return false
            }
            switch filters.starFilter {
            case .all:
                break
            case .starred:
                guard starredSessionIDs.contains(record.id) else {
                    return false
                }
            case .unstarred:
                guard !starredSessionIDs.contains(record.id) else {
                    return false
                }
            }
            if filters.newtonOnly, !record.isNewtonProject {
                return false
            }
            return true
        }
    }

    static func filterSessions(_ sessions: [SessionRecord], filters: SessionFilterState) -> [SessionRecord] {
        let parsedQuery = SessionSearchQueryParser.parse(filters.searchText)
        return applyScopeFilters(sessions, filters: filters).filter { record in
            matchesMetadataSearch(record, parsedQuery: parsedQuery)
        }
    }

    static func matchesMetadataSearch(_ record: SessionRecord, parsedQuery: ParsedSessionSearchQuery) -> Bool {
        if parsedQuery.isEmpty {
            return true
        }
        if !parsedQuery.usesStructuredSyntax {
            return record.matchesBroadSearch(parsedQuery.normalizedWholeText)
        }
        if !parsedQuery.metadataFieldClauses.allSatisfy({ record.matchesFieldClause($0) }) {
            return false
        }
        return parsedQuery.freeTextTerms.allSatisfy { record.matchesBroadSearch($0) }
    }
}

enum SessionListOrdering {
    static func sort(
        _ sessions: [SessionRecord],
        filters: SessionFilterState,
        starredSessionIDs: Set<String>
    ) -> [SessionRecord] {
        sessions.sorted { lhs, rhs in
            compare(lhs, rhs, filters: filters, starredSessionIDs: starredSessionIDs)
        }
    }

    private static func compare(
        _ lhs: SessionRecord,
        _ rhs: SessionRecord,
        filters: SessionFilterState,
        starredSessionIDs: Set<String>
    ) -> Bool {
        let lhsIsStarred = starredSessionIDs.contains(lhs.id)
        let rhsIsStarred = starredSessionIDs.contains(rhs.id)
        if lhsIsStarred != rhsIsStarred {
            return lhsIsStarred && !rhsIsStarred
        }

        switch filters.sortMode {
        case .recentlyUpdated:
            return compareDates(lhs.updatedAt ?? lhs.startedAt, rhs.updatedAt ?? rhs.startedAt, fallback: {
                lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            })
        case .startedAt:
            return compareDates(lhs.startedAt, rhs.startedAt, fallback: {
                lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            })
        case .project:
            if lhs.projectName != rhs.projectName {
                return lhs.projectName.localizedCaseInsensitiveCompare(rhs.projectName) == .orderedAscending
            }
            return compareDates(lhs.updatedAt ?? lhs.startedAt, rhs.updatedAt ?? rhs.startedAt, fallback: {
                lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            })
        case .source:
            if lhs.source.displayName != rhs.source.displayName {
                return lhs.source.displayName.localizedCaseInsensitiveCompare(rhs.source.displayName) == .orderedAscending
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        case .title:
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func compareDates(_ lhs: Date?, _ rhs: Date?, fallback: () -> Bool) -> Bool {
        switch (lhs, rhs) {
        case let (left?, right?) where left != right:
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return fallback()
        }
    }
}

@MainActor
final class SessionBrowserViewModel: ObservableObject {
    @Published private(set) var allSessions: [SessionRecord] = []
    @Published private(set) var starredSessionIDs: Set<String> = []
    @Published var filters = SessionFilterState() {
        didSet {
            scheduleSearch()
        }
    }
    @Published private(set) var searchState = SessionSearchState()
    @Published var selectedSessionID: String?
    @Published private(set) var refreshActivity: RefreshActivity = .idle
    @Published private(set) var hasCompletedInitialLoad = false
    @Published var errorMessage: String?
    @Published private(set) var lastRefreshDate: Date?
    @Published private(set) var loadingTranscriptTitle: String?

    private let catalog: SessionCatalog?
    private let transcriptCache = TranscriptDocumentCache()
    private var searchTask: Task<Void, Never>?

    init(catalog: SessionCatalog?) {
        self.catalog = catalog
    }

    static func makeDefault() -> SessionBrowserViewModel {
        do {
            return SessionBrowserViewModel(catalog: try SessionCatalog.makeDefault())
        } catch {
            let viewModel = SessionBrowserViewModel(catalog: nil)
            viewModel.errorMessage = error.localizedDescription
            return viewModel
        }
    }

    func loadInitialData() async {
        guard let catalog else {
            hasCompletedInitialLoad = true
            return
        }
        do {
            starredSessionIDs = try catalog.starredSessionIDs()
            let persisted = try catalog.loadPersistedSessions()
            applySessions(persisted)
            lastRefreshDate = catalogModifiedDate()
            await performRefresh(
                activity: .incremental,
                operation: { try catalog.refreshSessions() },
                completesInitialLoad: true
            )
        } catch {
            errorMessage = error.localizedDescription
            hasCompletedInitialLoad = true
        }
    }

    func refreshSessions() async {
        await performRefresh(activity: .incremental, operation: { try catalogOrThrow().refreshSessions() })
    }

    func rebuildSessions() async {
        await performRefresh(activity: .rebuild, operation: { try catalogOrThrow().rebuildSessions() })
    }

    var isRefreshing: Bool {
        refreshActivity != .idle
    }

    var lastRefreshDisplayText: String? {
        guard let lastRefreshDate else { return nil }
        return lastRefreshDate.formatted(date: .abbreviated, time: .shortened)
    }

    var refreshStatusText: String? {
        switch refreshActivity {
        case .idle:
            return nil
        case .incremental:
            return "Refreshing session index…"
        case .rebuild:
            return "Rebuilding session index…"
        }
    }

    var refreshDetailText: String {
        switch refreshActivity {
        case .idle, .incremental:
            return "Checking local sources for new or changed sessions."
        case .rebuild:
            return "Re-reading all local session data and rebuilding the catalog."
        }
    }

    var startupLoadingText: String {
        refreshStatusText ?? "Refreshing session index…"
    }

    var startupLoadingDetailText: String {
        refreshStatusText == nil ? "Loading the local session catalog." : refreshDetailText
    }

    var shouldShowLoadingPlaceholder: Bool {
        displayedSessions.isEmpty && (!hasCompletedInitialLoad || isRefreshing)
    }

    var displayedSessions: [SessionRecord] {
        SessionListOrdering.sort(
            SessionSearchEvaluator.filterSessions(
                scopeFilteredSessions,
                parsedQuery: parsedSearchQuery,
                transcriptSessionIDsByQuery: searchState.sessionIDsByQuery
            ),
            filters: filters,
            starredSessionIDs: starredSessionIDs
        )
    }

    var selectedSession: SessionRecord? {
        displayedSessions.first(where: { $0.id == selectedSessionID }) ?? displayedSessions.first
    }

    var availableProjects: [String] {
        [SessionFilterState.allProjectsToken] + Array(Set(allSessions.map(\.projectName))).sorted()
    }

    var availableBranches: [String] {
        [SessionFilterState.allBranchesToken] + Array(Set(allSessions.compactMap(\.branch))).sorted()
    }

    var sessionCountSummary: String {
        "\(displayedSessions.count) of \(allSessions.count) sessions"
    }

    var emptyStateTitle: String {
        if !filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No Search Results"
        }
        return "No Sessions Found"
    }

    var emptyStateDescription: String {
        if !filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No sessions in the current filter scope matched the current search."
        }
        return "Adjust the filters or refresh the local index."
    }

    var searchStatusText: String? {
        if let lastError = searchState.lastError {
            return lastError
        }
        guard searchState.isSearching else { return nil }
        let noun = searchState.searchedSessionCount == 1 ? "session" : "sessions"
        return "Searching transcripts in \(searchState.searchedSessionCount) \(noun)..."
    }

    var isLoadingTranscript: Bool {
        loadingTranscriptTitle != nil
    }

    var transcriptLoadingStatusText: String? {
        guard isLoadingTranscript else { return nil }
        return "Loading transcript…"
    }

    var transcriptLoadingDetailText: String? {
        loadingTranscriptTitle
    }

    var transcriptViewerSearchText: String {
        let parsedQuery = parsedSearchQuery
        if let firstTranscriptQuery = parsedQuery.transcriptQueries.first {
            return firstTranscriptQuery
        }
        return filters.searchText
    }

    func searchMatch(for record: SessionRecord) -> TranscriptSessionSearchMatch? {
        searchState.mergedResultsBySessionID[record.id]
    }

    func primaryActionLabel(for record: SessionRecord) -> String {
        switch record.resumeKind {
        case .copilotConnect:
            return "Resume in Copilot"
        case .openInCursor:
            return "Open in Cursor"
        case .openInVSCode:
            return "Open in VS Code"
        case .revealPath:
            return "Reveal Transcript"
        }
    }

    func performPrimaryAction(for record: SessionRecord) {
        do {
            try WorkspaceLauncher.performPrimaryAction(for: record)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func canStartNewConversation(for record: SessionRecord) -> Bool {
        record.workspacePath != nil
    }

    func startNewConversation(for record: SessionRecord) {
        do {
            try WorkspaceLauncher.startNewConversation(in: record.workspacePath)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyToClipboard(_ value: String) {
        WorkspaceLauncher.copyToPasteboard(value)
    }

    func copyPrimaryCommand(_ record: SessionRecord) {
        let command = WorkspaceLauncher.copilotResumeCommand(for: record)
        WorkspaceLauncher.copyToPasteboard(command)
    }

    func revealTranscript(for record: SessionRecord) {
        WorkspaceLauncher.reveal(path: record.rawTranscriptPath ?? record.rawMetadataPath)
    }

    func loadPresentedTranscript(for record: SessionRecord, initialSearchText: String = "") async -> PresentedTranscript? {
        loadingTranscriptTitle = record.title
        defer {
            loadingTranscriptTitle = nil
        }

        do {
            let presentedTranscript = PresentedTranscript(
                transcript: try await transcriptCache.document(for: record),
                initialSearchText: initialSearchText
            )
            errorMessage = nil
            return presentedTranscript
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func openPlan(for record: SessionRecord) {
        WorkspaceLauncher.openDocument(path: record.relatedPlanPath)
    }

    func isStarred(_ record: SessionRecord) -> Bool {
        starredSessionIDs.contains(record.id)
    }

    func toggleStar(for record: SessionRecord) {
        let updatedValue = !isStarred(record)

        do {
            try catalogOrThrow().setSessionStarred(updatedValue, for: record.id)
            var updatedStarredSessionIDs = starredSessionIDs
            if updatedValue {
                updatedStarredSessionIDs.insert(record.id)
            } else {
                updatedStarredSessionIDs.remove(record.id)
            }
            starredSessionIDs = updatedStarredSessionIDs
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applySessions(_ sessions: [SessionRecord]) {
        allSessions = sessions
        if selectedSessionID == nil || !sessions.contains(where: { $0.id == selectedSessionID }) {
            selectedSessionID = sessions.first?.id
        }
        scheduleSearch()
    }

    private func catalogModifiedDate() -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: AppPaths.catalogDatabaseURL.path)
        return attributes?[.modificationDate] as? Date
    }

    private var scopeFilteredSessions: [SessionRecord] {
        SessionFilterEvaluator.applyScopeFilters(
            allSessions,
            filters: filters,
            starredSessionIDs: starredSessionIDs
        )
    }

    private var parsedSearchQuery: ParsedSessionSearchQuery {
        SessionSearchQueryParser.parse(filters.searchText)
    }

    private func searchScopeSignature(for sessions: [SessionRecord]) -> String {
        sessions.map(\.id).sorted().joined(separator: "\u{1F}")
    }

    private func scheduleSearch() {
        searchTask?.cancel()

        let requestedQuery = filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedQuery = SessionSearchQueryParser.parse(requestedQuery)
        let transcriptQueries = parsedQuery.transcriptQueries
        let scope = scopeFilteredSessions
        let scopeSignature = searchScopeSignature(for: scope)

        guard !requestedQuery.isEmpty, !transcriptQueries.isEmpty else {
            searchState = SessionSearchState()
            return
        }

        guard let catalog else {
            searchState = SessionSearchState()
            return
        }

        let sessionIDs = scope.map(\.id)
        searchState.requestedQuery = requestedQuery
        searchState.searchedScopeSignature = scopeSignature
        searchState.searchedSessionCount = scope.count
        searchState.resultsByQuery = [:]
        searchState.mergedResultsBySessionID = [:]
        searchState.isSearching = !sessionIDs.isEmpty
        searchState.lastError = nil

        guard !sessionIDs.isEmpty else {
            return
        }

        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled {
                    return
                }

                var resultsByQuery: [String: [TranscriptIndexSearchHit]] = [:]
                for query in transcriptQueries {
                    resultsByQuery[query] = try catalog.searchTranscriptIndex(sessionIDs: sessionIDs, query: query)
                }

                if Task.isCancelled {
                    return
                }

                guard filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == requestedQuery,
                      searchScopeSignature(for: scopeFilteredSessions) == scopeSignature else {
                    return
                }

                searchState.requestedQuery = requestedQuery
                searchState.searchedScopeSignature = scopeSignature
                searchState.searchedSessionCount = scope.count
                searchState.resultsByQuery = resultsByQuery
                searchState.mergedResultsBySessionID = makeMergedSearchMatches(
                    from: resultsByQuery,
                    queries: transcriptQueries
                )
                searchState.isSearching = false
                searchState.lastError = nil
            } catch is CancellationError {
                return
            } catch {
                guard filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == requestedQuery,
                      searchScopeSignature(for: scopeFilteredSessions) == scopeSignature else {
                    return
                }

                searchState.requestedQuery = requestedQuery
                searchState.searchedScopeSignature = scopeSignature
                searchState.searchedSessionCount = scope.count
                searchState.resultsByQuery = [:]
                searchState.mergedResultsBySessionID = [:]
                searchState.isSearching = false
                searchState.lastError = error.localizedDescription
            }
        }
    }

    private func makeMergedSearchMatches(
        from resultsByQuery: [String: [TranscriptIndexSearchHit]],
        queries: [String]
    ) -> [String: TranscriptSessionSearchMatch] {
        let orderedHits = queries.flatMap { resultsByQuery[$0] ?? [] }
        var groupedBySession: [String: [Int: TranscriptIndexSearchHit]] = [:]

        for hit in orderedHits {
            groupedBySession[hit.sessionRecordID, default: [:]][hit.entryIndex] = hit
        }

        return Dictionary(
            uniqueKeysWithValues: groupedBySession.map { sessionID, hitsByIndex in
                let orderedEntries = hitsByIndex.values.sorted { $0.entryIndex < $1.entryIndex }
                let snippets = orderedEntries.compactMap { hit in
                    SearchTextMatcher.snippet(in: hit.text, queries: queries) ?? TextSanitizer.summarize(hit.text, limit: 120)
                }
                let uniqueSnippets = snippets.reduce(into: [String]()) { partialResult, snippet in
                    if !partialResult.contains(snippet) {
                        partialResult.append(snippet)
                    }
                }

                return (
                    sessionID,
                    TranscriptSessionSearchMatch(
                        sessionRecordID: sessionID,
                        matchCount: orderedEntries.count,
                        snippets: Array(uniqueSnippets.prefix(2))
                    )
                )
            }
        )
    }

    private func performRefresh(
        activity: RefreshActivity,
        operation: () throws -> [SessionRecord],
        completesInitialLoad: Bool = false
    ) async {
        refreshActivity = activity
        defer {
            refreshActivity = .idle
            if completesInitialLoad {
                hasCompletedInitialLoad = true
            }
        }

        do {
            let refreshed = try operation()
            applySessions(refreshed)
            lastRefreshDate = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func catalogOrThrow() throws -> SessionCatalog {
        guard let catalog else {
            throw NSError(
                domain: "SessionBrowserViewModel",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The catalog could not be initialized."]
            )
        }
        return catalog
    }

}

actor TranscriptDocumentCache {
    private struct CachedTranscript {
        let fingerprint: String
        let document: TranscriptDocument
    }

    private var documentsBySessionID: [String: CachedTranscript] = [:]

    func document(for record: SessionRecord) throws -> TranscriptDocument {
        if let cached = documentsBySessionID[record.id],
           cached.fingerprint == record.fingerprint {
            return cached.document
        }

        let document = try TranscriptPreviewExtractor.loadTranscript(for: record)
        documentsBySessionID[record.id] = CachedTranscript(
            fingerprint: record.fingerprint,
            document: document
        )
        return document
    }

    func search(records: [SessionRecord], query: String) throws -> [TranscriptSessionSearchMatch] {
        try records.compactMap { record in
            try document(for: record).sessionSearchMatch(for: query)
        }
    }
}
