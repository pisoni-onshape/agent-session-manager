import Foundation

public enum SessionFilterEvaluator {
    public static func applyScopeFilters(
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
            if filters.inProgressOnly, !record.isInProgress {
                return false
            }
            return true
        }
    }

    public static func filterSessions(_ sessions: [SessionRecord], filters: SessionFilterState) -> [SessionRecord] {
        let parsedQuery = SessionSearchQueryParser.parse(filters.searchText)
        return applyScopeFilters(sessions, filters: filters).filter { record in
            matchesMetadataSearch(record, parsedQuery: parsedQuery)
        }
    }

    public static func matchesMetadataSearch(_ record: SessionRecord, parsedQuery: ParsedSessionSearchQuery) -> Bool {
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

public enum SessionListOrdering {
    public static func sort(
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

public struct SessionListSections: Equatable {
    public let starred: [SessionRecord]
    public let unstarred: [SessionRecord]
    public let showsUnstarredDivider: Bool
}

public enum SessionListSectionBuilder {
    public static func build(
        _ sessions: [SessionRecord],
        filters: SessionFilterState,
        starredSessionIDs: Set<String>
    ) -> SessionListSections {
        let starred = sessions.filter { starredSessionIDs.contains($0.id) }
        let unstarred = sessions.filter { !starredSessionIDs.contains($0.id) }

        return SessionListSections(
            starred: starred,
            unstarred: unstarred,
            showsUnstarredDivider: filters.starFilter == .all && !starred.isEmpty && !unstarred.isEmpty
        )
    }
}
