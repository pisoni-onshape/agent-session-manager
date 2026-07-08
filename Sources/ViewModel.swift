import Combine
import Foundation
import AgentSessionManagerCore

enum RefreshActivity: Equatable {
    case idle
    case incremental
    case rebuild
}

private final class SessionCatalogController: @unchecked Sendable {
    private let catalog: SessionCatalog
    private let queue = DispatchQueue(label: "com.pisoni.AgentSessionManager.catalog", qos: .userInitiated)

    init(catalog: SessionCatalog) {
        self.catalog = catalog
    }

    func loadPersistedSessions() async throws -> [SessionRecord] {
        try await run { catalog in
            try catalog.loadPersistedSessions()
        }
    }

    func starredSessionIDs() async throws -> Set<String> {
        try await run { catalog in
            try catalog.starredSessionIDs()
        }
    }

    func refreshSessions() async throws -> [SessionRecord] {
        try await run { catalog in
            try catalog.refreshSessions()
        }
    }

    func rebuildSessions() async throws -> [SessionRecord] {
        try await run { catalog in
            try catalog.rebuildSessions()
        }
    }

    func setSessionStarred(_ isStarred: Bool, for sessionID: String) async throws {
        try await run { catalog in
            try catalog.setSessionStarred(isStarred, for: sessionID)
        }
    }

    func reclassifySessions(_ records: [SessionRecord]) async -> [SessionRecord] {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.catalog.reclassifySessions(records))
            }
        }
    }

    func renameSession(_ session: SessionRecord, to newTitle: String) async throws -> SessionRecord? {
        try await run { catalog in
            try catalog.renameSession(session, to: newTitle)
        }
    }

    func search(snapshot: SessionCatalogSnapshot, request: SessionSearchRequest) async throws -> SessionSearchExecution {
        try await run { catalog in
            try SessionSearchService.search(snapshot: snapshot, request: request) { sessionIDs, query, scope in
                try catalog.searchTranscriptIndex(sessionIDs: sessionIDs, query: query, scope: scope)
            }
        }
    }

    private func run<T: Sendable>(_ operation: @escaping @Sendable (SessionCatalog) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try operation(self.catalog))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
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
    @Published private(set) var lastRefreshDuration: Duration?
    @Published private(set) var loadingTranscriptTitle: String?
    @Published private(set) var nextScheduledRefreshDate: Date?

    private let catalogController: SessionCatalogController?
    private let settings: AppSettingsStore?
    private let transcriptCache = TranscriptDocumentCache()
    private var searchTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    private var autoRefreshIntervalNanoseconds: UInt64?
    private var settingsCancellables: Set<AnyCancellable> = []
    private(set) var hasPendingScheduledRefresh = false
    private var isWindowFocused = false

    init(catalog: SessionCatalog?, settings: AppSettingsStore? = nil) {
        self.catalogController = catalog.map(SessionCatalogController.init)
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
        guard let catalogController else {
            hasCompletedInitialLoad = true
            return
        }
        do {
            starredSessionIDs = try await catalogController.starredSessionIDs()
            let persisted = try await catalogController.loadPersistedSessions()
            applySessions(persisted)
            applyInProgressStateToAll()
            lastRefreshDate = settings?.lastSuccessfulRefreshDate() ?? catalogModifiedDate()
            lastRefreshDuration = nil
            if shouldRefreshOnLaunch() {
                await performRefresh(
                    activity: .incremental,
                    operation: { try await catalogController.refreshSessions() },
                    completesInitialLoad: true
                )
            } else {
                hasCompletedInitialLoad = true
            }
        } catch {
            errorMessage = error.localizedDescription
            hasCompletedInitialLoad = true
        }
    }

    func refreshSessions() async {
        await performRefresh(activity: .incremental, operation: { try await self.catalogOrThrow().refreshSessions() })
    }

    func rebuildSessions() async {
        await performRefresh(activity: .rebuild, operation: { try await self.catalogOrThrow().rebuildSessions() })
    }

    /// Performs a lightweight live check of in-progress state for a single session and updates the model.
    func checkInProgressState(for sessionID: String) {
        guard let index = allSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let session = allSessions[index]
        let isActive = Self.liveInProgressCheck(for: session)
        guard isActive != session.isInProgress else { return }
        allSessions[index] = session.with(isInProgress: isActive)
    }

    /// Applies in-progress state to all sessions by checking lock files / PIDs.
    private func applyInProgressStateToAll() {
        var vscodeCaches: [String: Set<String>] = [:]
        for i in allSessions.indices {
            let session = allSessions[i]
            let isActive: Bool
            switch session.source {
            case .copilotCLI:
                guard let metadataPath = session.rawMetadataPath else { continue }
                let dir = URL(fileURLWithPath: metadataPath).deletingLastPathComponent()
                isActive = CopilotCLIAdapter.checkInProgress(in: dir).isActive
            case .vscodeCopilot:
                guard let metadataPath = session.rawMetadataPath else { continue }
                let workspaceDir = URL(fileURLWithPath: metadataPath).deletingLastPathComponent()
                let cacheKey = workspaceDir.path
                if vscodeCaches[cacheKey] == nil {
                    vscodeCaches[cacheKey] = VSCodeCopilotAdapter.activeSessionIDs(in: workspaceDir)
                }
                isActive = vscodeCaches[cacheKey]!.contains(session.sourceSessionId)
            case .cursor, .claudeCodeCLI, .claudeCodeVSCode, .claudeDesktop:
                continue
            }
            if isActive != session.isInProgress {
                allSessions[i] = session.with(isInProgress: isActive)
            }
        }
    }

    /// Renames a Copilot CLI session. Updates workspace.yaml, the catalog DB, and in-memory state.
    func renameSession(_ session: SessionRecord, to newTitle: String) async {
        guard let controller = catalogController else { return }
        do {
            if let updated = try await controller.renameSession(session, to: newTitle) {
                if let index = allSessions.firstIndex(where: { $0.id == session.id }) {
                    allSessions[index] = updated.with(isInProgress: allSessions[index].isInProgress)
                }
            }
        } catch {
            errorMessage = "Rename failed: \(error.localizedDescription)"
        }
    }

    private static func liveInProgressCheck(for session: SessionRecord) -> Bool {
        switch session.source {
        case .copilotCLI:
            guard let metadataPath = session.rawMetadataPath else { return false }
            let sessionDirectory = URL(fileURLWithPath: metadataPath).deletingLastPathComponent()
            return CopilotCLIAdapter.checkInProgress(in: sessionDirectory).isActive
        case .vscodeCopilot:
            guard let metadataPath = session.rawMetadataPath else { return false }
            let workspaceDirectory = URL(fileURLWithPath: metadataPath).deletingLastPathComponent()
            let activeIDs = VSCodeCopilotAdapter.activeSessionIDs(in: workspaceDirectory)
            return activeIDs.contains(session.sourceSessionId)
        case .cursor, .claudeCodeCLI, .claudeCodeVSCode, .claudeDesktop:
            return false
        }
    }

    func setWindowIsFocused(_ isFocused: Bool) {
        guard isWindowFocused != isFocused else { return }

        isWindowFocused = isFocused

        Task { [weak self] in
            guard let self else { return }
            if !isFocused, self.hasPendingScheduledRefresh {
                await self.runPendingScheduledRefreshIfNeeded(ignoreWindowFocus: true)
            } else {
                await self.reconcileAutoRefreshSchedule()
            }
        }
    }

    var isRefreshing: Bool {
        refreshActivity != .idle
    }

    var lastRefreshDisplayText: String? {
        guard let lastRefreshDate else { return nil }
        let timestamp = lastRefreshDate.formatted(date: .abbreviated, time: .shortened)
        var text = lastRefreshDuration.map { "Last refreshed at: \(timestamp) in \(Self.formatRefreshDuration($0))" }
            ?? "Last refreshed at: \(timestamp)"
        if let next = nextScheduledRefreshDate {
            let nextTime = next.formatted(date: .omitted, time: .shortened)
            text += " (next auto-refresh at \(nextTime))"
        }
        return text
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
            filters: filters
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
        if let firstTranscriptQuery = parsedQuery.firstSearchQuery(includedScopes: [.all, .transcript]) {
            return firstTranscriptQuery
        }
        return filters.searchText
    }

    var planViewerSearchText: String {
        let parsedQuery = parsedSearchQuery
        if let firstPlanQuery = parsedQuery.firstSearchQuery(includedScopes: [.all, .plan]) {
            return firstPlanQuery
        }
        return filters.searchText
    }

    func searchMatch(for record: SessionRecord) -> SessionSearchMatch? {
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
        case .claudeResume:
            return "Resume in Claude"
        case .resumeInClaudeDesktop:
            return "Resume in Claude Desktop"
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
        // Desktop sessions use the dedicated "Open in Claude Desktop" action instead of a
        // Terminal-launched new conversation.
        record.workspacePath != nil && record.source != .claudeDesktop
    }

    func startNewConversation(for record: SessionRecord) {
        do {
            try WorkspaceLauncher.startNewConversation(for: record)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Secondary "Resume in Claude Desktop" action for Claude sources that resume elsewhere by
    /// default (CLI → Terminal, VS Code → editor). Desktop sessions already resume in Desktop as
    /// their primary action, so they don't need the duplicate secondary button.
    func canResumeInClaudeDesktop(for record: SessionRecord) -> Bool {
        record.source.isClaudeSource && record.resumeKind != .resumeInClaudeDesktop
    }

    func resumeInClaudeDesktop(for record: SessionRecord) {
        WorkspaceLauncher.resumeInClaudeDesktop(sessionId: record.sourceSessionId)
    }

    /// Desktop sessions carry Claude Desktop's own session id in `resumePayload`, so we can offer a
    /// copyable `claude://resume?session=…` link that reopens the session in Desktop with no duplicate.
    func canCopyClaudeDesktopLink(for record: SessionRecord) -> Bool {
        record.source == .claudeDesktop && WorkspaceLauncher.claudeDesktopResumeURL(sessionId: record.resumePayload) != nil
    }

    func copyClaudeDesktopLink(for record: SessionRecord) {
        guard let url = WorkspaceLauncher.claudeDesktopResumeURL(sessionId: record.resumePayload) else { return }
        WorkspaceLauncher.copyToPasteboard(url.absoluteString)
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

    func loadPresentedPlan(for record: SessionRecord, initialSearchText: String = "") async -> PresentedPlan? {
        do {
            let presentedPlan = PresentedPlan(
                plan: try TranscriptPreviewExtractor.loadPlan(for: record),
                initialSearchText: initialSearchText
            )
            errorMessage = nil
            return presentedPlan
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func isStarred(_ record: SessionRecord) -> Bool {
        starredSessionIDs.contains(record.id)
    }

    func toggleStar(for record: SessionRecord) {
        let updatedValue = !isStarred(record)

        Task {
            do {
                try await catalogOrThrow().setSessionStarred(updatedValue, for: record.id)
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

        guard let catalogController else {
            searchState = SessionSearchState()
            return
        }

        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled {
                    return
                }

                let execution = try await catalogController.search(snapshot: snapshot, request: request)

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

        settings.$deferRefreshWhileAppIsActive
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] isEnabled in
                self?.handleDeferRefreshWhileAppIsActiveChange(isEnabled)
            }
            .store(in: &settingsCancellables)
    }

    private func handleNewtonReposRootPathChange() {
        guard let catalogController else { return }

        Task {
            let reclassifiedSessions = await catalogController.reclassifySessions(allSessions)
            if reclassifiedSessions != allSessions {
                applySessions(reclassifiedSessions)
            }

            guard hasCompletedInitialLoad else { return }
            await refreshSessionsIfPossible()
        }
    }

    private func configureAutoRefresh(with cadence: AutoRefreshCadence) {
        autoRefreshTask?.cancel()
        autoRefreshIntervalNanoseconds = cadence.intervalNanoseconds
        hasPendingScheduledRefresh = false

        guard autoRefreshIntervalNanoseconds != nil else {
            autoRefreshTask = nil
            nextScheduledRefreshDate = nil
            return
        }

        scheduleNextAutoRefreshTimer()
    }

    private func handleDeferRefreshWhileAppIsActiveChange(_ isEnabled: Bool) {
        guard !isEnabled, hasPendingScheduledRefresh else { return }

        Task { [weak self] in
            await self?.runPendingScheduledRefreshIfNeeded(ignoreWindowFocus: true)
        }
    }

    func handleScheduledRefreshTrigger() async {
        guard hasCompletedInitialLoad else {
            scheduleNextAutoRefreshTimer()
            return
        }

        if shouldDeferScheduledRefreshWhileWindowIsFocused {
            hasPendingScheduledRefresh = true
            scheduleNextAutoRefreshTimer()
            return
        }

        await refreshSessionsIfPossible()
    }

    func reconcileAutoRefreshSchedule(referenceDate: Date = Date()) async {
        guard autoRefreshIntervalNanoseconds != nil, hasCompletedInitialLoad, !isRefreshing else { return }

        guard let nextScheduledRefreshDate else {
            scheduleNextAutoRefreshTimer(referenceDate: referenceDate)
            return
        }

        guard nextScheduledRefreshDate <= referenceDate else { return }

        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        self.nextScheduledRefreshDate = nil
        await handleScheduledRefreshTrigger()
    }

    private func runPendingScheduledRefreshIfNeeded(ignoreWindowFocus: Bool = false) async {
        guard hasPendingScheduledRefresh else { return }
        guard ignoreWindowFocus || !isWindowFocused else { return }
        hasPendingScheduledRefresh = false
        await refreshSessionsIfPossible()
    }

    private func refreshSessionsIfPossible() async {
        guard hasCompletedInitialLoad, !isRefreshing else { return }
        await refreshSessions()
    }

    private var shouldDeferScheduledRefreshWhileWindowIsFocused: Bool {
        guard let settings else { return false }
        return settings.autoRefreshCadence != .off && settings.deferRefreshWhileAppIsActive && isWindowFocused
    }

    private func scheduleNextAutoRefreshTimer(referenceDate: Date = Date()) {
        autoRefreshTask?.cancel()

        guard let intervalNanoseconds = autoRefreshIntervalNanoseconds else {
            autoRefreshTask = nil
            nextScheduledRefreshDate = nil
            return
        }

        let fireDate = referenceDate.addingTimeInterval(TimeInterval(intervalNanoseconds) / 1_000_000_000)
        nextScheduledRefreshDate = fireDate

        autoRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: intervalNanoseconds)
            } catch is CancellationError {
                return
            } catch {
                self?.scheduleNextAutoRefreshTimer()
                return
            }

            guard let self, !Task.isCancelled else {
                return
            }

            self.autoRefreshTask = nil
            self.nextScheduledRefreshDate = nil
            await self.handleScheduledRefreshTrigger()
        }
    }

    private func shouldRefreshOnLaunch() -> Bool {
        guard let settings else { return true }
        return settings.consumeLaunchRefreshDecision().shouldRefresh
    }

    private func performRefresh(
        activity: RefreshActivity,
        operation: @escaping () async throws -> [SessionRecord],
        completesInitialLoad: Bool = false
    ) async {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        hasPendingScheduledRefresh = false
        nextScheduledRefreshDate = nil
        refreshActivity = activity
        let clock = ContinuousClock()
        let refreshStart = clock.now
        await Task.yield()
        defer {
            refreshActivity = .idle
            if completesInitialLoad {
                hasCompletedInitialLoad = true
            }
            if autoRefreshIntervalNanoseconds != nil, hasCompletedInitialLoad {
                scheduleNextAutoRefreshTimer()
            }
        }

        do {
            let refreshed = try await operation()
            applySessions(refreshed)
            lastRefreshDuration = clock.now - refreshStart
            let completedAt = Date()
            lastRefreshDate = completedAt
            settings?.recordLastSuccessfulRefreshDate(completedAt)
            errorMessage = nil
        } catch {
            errorMessage = RefreshFailurePresentation.message(for: error) ?? error.localizedDescription
        }
    }

    private func catalogOrThrow() throws -> SessionCatalogController {
        guard let catalogController else {
            throw NSError(
                domain: "SessionBrowserViewModel",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The catalog could not be initialized."]
            )
        }
        return catalogController
    }

    private static func formatRefreshDuration(_ duration: Duration) -> String {
        let seconds = timeInterval(for: duration)
        if seconds < 1 {
            return String(format: "%.0fms", seconds * 1_000)
        }
        if seconds < 10 {
            return String(format: "%.1fs", seconds)
        }
        if seconds < 60 {
            return "\(Int(seconds.rounded()))s"
        }

        let totalSeconds = Int(seconds.rounded())
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        if minutes < 60 {
            return "\(minutes)m \(remainingSeconds)s"
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return "\(hours)h \(remainingMinutes)m \(remainingSeconds)s"
    }

    private static func timeInterval(for duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + (TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000)
    }
}
