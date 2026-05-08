import Foundation

enum RefreshActivity: Equatable {
    case idle
    case incremental
    case rebuild
}

enum SessionFilterEvaluator {
    static func filterSessions(_ sessions: [SessionRecord], filters: SessionFilterState) -> [SessionRecord] {
        let parsedQuery = SessionSearchQueryParser.parse(filters.searchText)
        return sessions.filter { record in
            matches(record, filters: filters, parsedQuery: parsedQuery)
        }
    }

    private static func matches(
        _ record: SessionRecord,
        filters: SessionFilterState,
        parsedQuery: ParsedSessionSearchQuery
    ) -> Bool {
        if let source = filters.selectedSource, record.source != source {
            return false
        }
        if filters.selectedProject != SessionFilterState.allProjectsToken, record.projectName != filters.selectedProject {
            return false
        }
        if filters.selectedBranch != SessionFilterState.allBranchesToken, record.branch != filters.selectedBranch {
            return false
        }
        if filters.newtonOnly, !record.isNewtonProject {
            return false
        }
        if parsedQuery.isEmpty {
            return true
        }
        if !parsedQuery.usesStructuredSyntax {
            return record.matchesBroadSearch(parsedQuery.normalizedWholeText)
        }
        if !parsedQuery.fieldClauses.allSatisfy({ record.matchesFieldClause($0) }) {
            return false
        }
        return parsedQuery.freeTextTerms.allSatisfy { record.matchesBroadSearch($0) }
    }
}

@MainActor
final class SessionBrowserViewModel: ObservableObject {
    @Published private(set) var allSessions: [SessionRecord] = []
    @Published var filters = SessionFilterState()
    @Published var transcriptSearch = TranscriptSessionSearchState()
    @Published var selectedSessionID: String?
    @Published private(set) var refreshActivity: RefreshActivity = .idle
    @Published private(set) var hasCompletedInitialLoad = false
    @Published var errorMessage: String?
    @Published private(set) var lastRefreshDate: Date?
    @Published var presentedTranscript: TranscriptDocument?

    private let catalog: SessionCatalog?
    private let transcriptCache = TranscriptDocumentCache()

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
        applyTranscriptSearch(to: baseFilteredSessions).sorted(by: sort(lhs:rhs:))
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
        if transcriptSearch.hasAppliedQuery, !transcriptSearchScopeNeedsRefresh {
            return "No Transcript Matches"
        }
        return "No Sessions Found"
    }

    var emptyStateDescription: String {
        if transcriptSearch.hasAppliedQuery, !transcriptSearchScopeNeedsRefresh {
            return "No sessions in the current filter scope matched the transcript search."
        }
        return "Adjust the filters or refresh the local index."
    }

    var transcriptSearchScopeNeedsRefresh: Bool {
        transcriptSearch.hasAppliedQuery &&
            transcriptSearch.searchedScopeSignature != transcriptSearchScopeSignature(for: baseFilteredSessions)
    }

    var transcriptSearchStatusText: String? {
        if let lastError = transcriptSearch.lastError {
            return lastError
        }
        if transcriptSearch.isSearching {
            let noun = transcriptSearch.searchedSessionCount == 1 ? "session" : "sessions"
            return "Searching \(transcriptSearch.searchedSessionCount) \(noun)..."
        }
        if transcriptSearchScopeNeedsRefresh {
            return "Filters changed. Run transcript search again for the current scope."
        }
        guard transcriptSearch.hasAppliedQuery else { return nil }

        let sessionCount = transcriptSearch.resultsBySessionID.count
        let sessionNoun = sessionCount == 1 ? "session" : "sessions"
        let matchNoun = transcriptSearch.totalMatchCount == 1 ? "match" : "matches"
        return "\(sessionCount) \(sessionNoun) matched, \(transcriptSearch.totalMatchCount) \(matchNoun)."
    }

    func transcriptSearchMatch(for record: SessionRecord) -> TranscriptSessionSearchMatch? {
        guard transcriptSearch.hasAppliedQuery, !transcriptSearchScopeNeedsRefresh else { return nil }
        return transcriptSearch.resultsBySessionID[record.id]
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

    func copySessionID(_ record: SessionRecord) {
        WorkspaceLauncher.copyToPasteboard(record.sourceSessionId)
    }

    func copyPrimaryCommand(_ record: SessionRecord) {
        let command = WorkspaceLauncher.copilotResumeCommand(for: record)
        WorkspaceLauncher.copyToPasteboard(command)
    }

    func revealTranscript(for record: SessionRecord) {
        WorkspaceLauncher.reveal(path: record.rawTranscriptPath ?? record.rawMetadataPath)
    }

    func openTranscript(for record: SessionRecord) {
        Task {
            do {
                presentedTranscript = try await transcriptCache.document(for: record)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func openPlan(for record: SessionRecord) {
        WorkspaceLauncher.openDocument(path: record.relatedPlanPath)
    }

    func submitTranscriptSearch() {
        let query = transcriptSearch.queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            clearTranscriptSearch()
            return
        }

        let scope = baseFilteredSessions.sorted(by: sort(lhs:rhs:))
        let scopeSignature = transcriptSearchScopeSignature(for: scope)

        transcriptSearch.appliedQuery = query
        transcriptSearch.searchedScopeSignature = scopeSignature
        transcriptSearch.searchedSessionCount = scope.count
        transcriptSearch.resultsBySessionID = [:]
        transcriptSearch.totalMatchCount = 0
        transcriptSearch.isSearching = true
        transcriptSearch.lastError = nil
        transcriptSearch.isExpanded = true

        Task {
            do {
                let matches = try await transcriptCache.search(records: scope, query: query)
                guard transcriptSearch.appliedQuery == query,
                      transcriptSearch.searchedScopeSignature == scopeSignature else {
                    return
                }

                transcriptSearch.resultsBySessionID = Dictionary(
                    uniqueKeysWithValues: matches.map { ($0.sessionRecordID, $0) }
                )
                transcriptSearch.totalMatchCount = matches.reduce(0) { $0 + $1.matchCount }
                transcriptSearch.isSearching = false
            } catch {
                guard transcriptSearch.appliedQuery == query,
                      transcriptSearch.searchedScopeSignature == scopeSignature else {
                    return
                }
                transcriptSearch.resultsBySessionID = [:]
                transcriptSearch.totalMatchCount = 0
                transcriptSearch.isSearching = false
                transcriptSearch.lastError = error.localizedDescription
            }
        }
    }

    func clearTranscriptSearch() {
        transcriptSearch.queryText = ""
        transcriptSearch.appliedQuery = ""
        transcriptSearch.searchedScopeSignature = ""
        transcriptSearch.searchedSessionCount = 0
        transcriptSearch.resultsBySessionID = [:]
        transcriptSearch.totalMatchCount = 0
        transcriptSearch.isSearching = false
        transcriptSearch.lastError = nil
    }

    private func applySessions(_ sessions: [SessionRecord]) {
        allSessions = sessions
        if selectedSessionID == nil || !sessions.contains(where: { $0.id == selectedSessionID }) {
            selectedSessionID = sessions.first?.id
        }
    }

    private func sort(lhs: SessionRecord, rhs: SessionRecord) -> Bool {
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

    private func compareDates(_ lhs: Date?, _ rhs: Date?, fallback: () -> Bool) -> Bool {
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

    private func catalogModifiedDate() -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: AppPaths.catalogDatabaseURL.path)
        return attributes?[.modificationDate] as? Date
    }

    private var baseFilteredSessions: [SessionRecord] {
        SessionFilterEvaluator.filterSessions(allSessions, filters: filters)
    }

    private func applyTranscriptSearch(to sessions: [SessionRecord]) -> [SessionRecord] {
        guard transcriptSearch.hasAppliedQuery, !transcriptSearchScopeNeedsRefresh else {
            return sessions
        }

        let matchingIDs = Set(transcriptSearch.resultsBySessionID.keys)
        return sessions.filter { matchingIDs.contains($0.id) }
    }

    private func transcriptSearchScopeSignature(for sessions: [SessionRecord]) -> String {
        sessions.map(\.id).sorted().joined(separator: "\u{1F}")
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
