import Combine
import Foundation
import AgentSessionManagerCore

enum RefreshActivity: Equatable {
    case idle
    case incremental
    case rebuild
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
    private let settings: AppSettingsStore?
    private let transcriptCache = TranscriptDocumentCache()
    private var searchTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    private var settingsCancellables: Set<AnyCancellable> = []

    init(catalog: SessionCatalog?, settings: AppSettingsStore? = nil) {
        self.catalog = catalog
        self.settings = settings
        bindSettings()
        configureAutoRefresh(with: settings?.autoRefreshCadence ?? .off)
    }

    deinit {
        autoRefreshTask?.cancel()
    }

    static func makeDefault(settings: AppSettingsStore) -> SessionBrowserViewModel {
        do {
            return SessionBrowserViewModel(
                catalog: try SessionCatalog.makeDefault(settingsProvider: { settings.snapshot }),
                settings: settings
            )
        } catch {
            let viewModel = SessionBrowserViewModel(catalog: nil, settings: settings)
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

    var displayedSessionSections: SessionListSections {
        SessionListSectionBuilder.build(
            displayedSessions,
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
        SessionSearchService.scopeSignature(for: sessions)
    }

    private func scheduleSearch() {
        searchTask?.cancel()

        let request = SessionSearchRequest(filters: filters)
        let snapshot = SessionCatalogSnapshot(
            sessions: allSessions,
            starredSessionIDs: starredSessionIDs
        )
        let pendingState = SessionSearchService.makePendingSearchState(snapshot: snapshot, request: request)
        let requestedQuery = pendingState.requestedQuery
        let scopeSignature = pendingState.searchedScopeSignature

        searchState = pendingState

        guard pendingState.hasRequestedQuery, pendingState.searchedSessionCount > 0 else {
            return
        }

        guard let catalog else {
            searchState = SessionSearchState()
            return
        }

        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled {
                    return
                }

                let execution = try SessionSearchService.search(snapshot: snapshot, request: request) { sessionIDs, query in
                    try catalog.searchTranscriptIndex(sessionIDs: sessionIDs, query: query)
                }

                if Task.isCancelled {
                    return
                }

                guard filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == requestedQuery,
                       searchScopeSignature(for: scopeFilteredSessions) == scopeSignature else {
                    return
                }

                searchState = execution.searchState
            } catch is CancellationError {
                return
            } catch {
                guard filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == requestedQuery,
                       searchScopeSignature(for: scopeFilteredSessions) == scopeSignature else {
                    return
                }

                var failedState = pendingState
                failedState.isSearching = false
                failedState.lastError = error.localizedDescription
                searchState = failedState
            }
        }
    }

    private func bindSettings() {
        guard let settings else { return }

        settings.$newtonReposRootPath
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.handleNewtonReposRootPathChange()
            }
            .store(in: &settingsCancellables)

        settings.$autoRefreshCadence
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] cadence in
                self?.configureAutoRefresh(with: cadence)
            }
            .store(in: &settingsCancellables)
    }

    private func handleNewtonReposRootPathChange() {
        guard let catalog else { return }

        let reclassifiedSessions = catalog.reclassifySessions(allSessions)
        if reclassifiedSessions != allSessions {
            applySessions(reclassifiedSessions)
        }

        guard hasCompletedInitialLoad else { return }
        Task { await refreshSessionsIfIdle() }
    }

    private func configureAutoRefresh(with cadence: AutoRefreshCadence) {
        autoRefreshTask?.cancel()

        guard let intervalNanoseconds = cadence.intervalNanoseconds else {
            autoRefreshTask = nil
            return
        }

        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                } catch is CancellationError {
                    return
                } catch {
                    continue
                }

                if Task.isCancelled {
                    return
                }

                await self?.refreshSessionsIfIdle()
            }
        }
    }

    private func refreshSessionsIfIdle() async {
        guard hasCompletedInitialLoad, !isRefreshing else { return }
        await refreshSessions()
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
