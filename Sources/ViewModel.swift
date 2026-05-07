import Foundation

enum RefreshActivity: Equatable {
    case idle
    case incremental
    case rebuild
}

@MainActor
final class SessionBrowserViewModel: ObservableObject {
    @Published private(set) var allSessions: [SessionRecord] = []
    @Published var filters = SessionFilterState()
    @Published var selectedSessionID: String?
    @Published private(set) var refreshActivity: RefreshActivity = .idle
    @Published private(set) var hasCompletedInitialLoad = false
    @Published var errorMessage: String?
    @Published private(set) var lastRefreshDate: Date?
    @Published var presentedTranscript: TranscriptDocument?

    private let catalog: SessionCatalog?

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
        let filtered = allSessions.filter { record in
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

            let query = filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.isEmpty {
                return true
            }

            let haystack = [
                record.title,
                record.projectName,
                record.branch,
                record.conversationModel,
                record.summary,
                record.firstUserPreview,
                record.firstAssistantPreview,
                record.sourceSessionId
            ]
                .compactMap { $0?.lowercased() }
                .joined(separator: "\n")

            return haystack.contains(query.lowercased())
        }

        return filtered.sorted(by: sort(lhs:rhs:))
    }

    var selectedSession: SessionRecord? {
        let sessions = displayedSessions.isEmpty ? allSessions : displayedSessions
        return sessions.first(where: { $0.id == selectedSessionID }) ?? sessions.first
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
        do {
            presentedTranscript = try TranscriptPreviewExtractor.loadTranscript(for: record)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openPlan(for record: SessionRecord) {
        WorkspaceLauncher.openDocument(path: record.relatedPlanPath)
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
