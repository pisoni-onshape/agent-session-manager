import Foundation

@MainActor
final class SessionBrowserViewModel: ObservableObject {
    @Published private(set) var allSessions: [SessionRecord] = []
    @Published var filters = SessionFilterState()
    @Published var selectedSessionID: String?
    @Published private(set) var isRefreshing = false
    @Published var errorMessage: String?
    @Published private(set) var lastRefreshDate: Date?

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
        guard let catalog else { return }
        do {
            let persisted = try catalog.loadPersistedSessions()
            applySessions(persisted)
            lastRefreshDate = catalogModifiedDate()
            if persisted.isEmpty {
                await refreshSessions()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshSessions() async {
        guard let catalog else {
            errorMessage = "The catalog could not be initialized."
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let refreshed = try catalog.refreshSessions()
            applySessions(refreshed)
            lastRefreshDate = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
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
}
