import Foundation

public struct SessionCatalogSnapshot: Equatable, Sendable {
    public let sessions: [SessionRecord]
    public let starredSessionIDs: Set<String>

    public init(sessions: [SessionRecord], starredSessionIDs: Set<String>) {
        self.sessions = sessions
        self.starredSessionIDs = starredSessionIDs
    }
}

public struct SessionSearchRequest: Equatable, Sendable {
    public let filters: SessionFilterState
    public let resultLimit: Int?
    public let updatedWithin: TimeInterval?

    public init(
        filters: SessionFilterState,
        resultLimit: Int? = nil,
        updatedWithin: TimeInterval? = nil
    ) {
        self.filters = filters
        self.resultLimit = resultLimit
        self.updatedWithin = updatedWithin
    }
}

public struct SessionSearchExecution: Equatable, Sendable {
    public let snapshot: SessionCatalogSnapshot
    public let scopeSessions: [SessionRecord]
    public let parsedQuery: ParsedSessionSearchQuery
    public let searchState: SessionSearchState
    public let displayedSessions: [SessionRecord]
}

public enum SessionSearchService {
    public static func loadSnapshot(from catalog: SessionCatalog, refresh: Bool = false) throws -> SessionCatalogSnapshot {
        let sessions = refresh ? try catalog.refreshSessions() : try catalog.loadPersistedSessions()
        return SessionCatalogSnapshot(
            sessions: sessions,
            starredSessionIDs: try catalog.starredSessionIDs()
        )
    }

    public static func makePendingSearchState(
        snapshot: SessionCatalogSnapshot,
        request: SessionSearchRequest,
        referenceDate: Date = Date()
    ) -> SessionSearchState {
        let requestedQuery = request.filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedQuery = SessionSearchQueryParser.parse(requestedQuery)
        guard !requestedQuery.isEmpty, !parsedQuery.scopedSearchQueries.isEmpty else {
            return SessionSearchState()
        }

        let scope = scopeSessions(in: snapshot, request: request, referenceDate: referenceDate)
        return SessionSearchState(
            requestedQuery: requestedQuery,
            searchedScopeSignature: scopeSignature(for: scope),
            searchedSessionCount: scope.count,
            resultsByQuery: [:],
            mergedResultsBySessionID: [:],
            isSearching: !scope.isEmpty,
            lastError: nil
        )
    }

    public static func search(
        using catalog: SessionCatalog,
        request: SessionSearchRequest,
        refresh: Bool = false,
        referenceDate: Date = Date()
    ) throws -> SessionSearchExecution {
        let snapshot = try loadSnapshot(from: catalog, refresh: refresh)
        return try search(snapshot: snapshot, request: request, referenceDate: referenceDate) { sessionIDs, query, scope in
            try catalog.searchTranscriptIndex(sessionIDs: sessionIDs, query: query, scope: scope)
        }
    }

    public static func search(
        snapshot: SessionCatalogSnapshot,
        request: SessionSearchRequest,
        referenceDate: Date = Date(),
        transcriptSearcher: ([String], String, TranscriptSearchScope) throws -> [TranscriptIndexSearchHit]
    ) throws -> SessionSearchExecution {
        let scope = scopeSessions(in: snapshot, request: request, referenceDate: referenceDate)
        let parsedQuery = SessionSearchQueryParser.parse(request.filters.searchText)
        var searchState = makePendingSearchState(snapshot: snapshot, request: request, referenceDate: referenceDate)

        if searchState.hasRequestedQuery, searchState.searchedSessionCount > 0 {
            let sessionIDs = scope.map(\.id)
            var resultsByQuery: [String: [TranscriptIndexSearchHit]] = [:]
            for scopedQuery in parsedQuery.scopedSearchQueries {
                resultsByQuery[scopedQuery.resultKey] = try transcriptSearcher(
                    sessionIDs,
                    scopedQuery.query,
                    scopedQuery.scope
                )
            }

            searchState = SessionSearchState(
                requestedQuery: searchState.requestedQuery,
                searchedScopeSignature: searchState.searchedScopeSignature,
                searchedSessionCount: searchState.searchedSessionCount,
                resultsByQuery: resultsByQuery,
                mergedResultsBySessionID: makeMergedSearchMatches(
                    from: resultsByQuery,
                    queries: parsedQuery.scopedSearchQueries
                ),
                isSearching: false,
                lastError: nil
            )
        }

        var displayedSessions = SessionListOrdering.sort(
            SessionSearchEvaluator.filterSessions(
                scope,
                parsedQuery: parsedQuery,
                transcriptSessionIDsByQuery: searchState.sessionIDsByQuery
            ),
            filters: request.filters
        )

        if let resultLimit = request.resultLimit, resultLimit >= 0 {
            displayedSessions = Array(displayedSessions.prefix(resultLimit))
        }

        return SessionSearchExecution(
            snapshot: snapshot,
            scopeSessions: scope,
            parsedQuery: parsedQuery,
            searchState: searchState,
            displayedSessions: displayedSessions
        )
    }

    public static func scopeSignature(for sessions: [SessionRecord]) -> String {
        sessions.map(\.id).sorted().joined(separator: "\u{1F}")
    }

    private static func scopeSessions(
        in snapshot: SessionCatalogSnapshot,
        request: SessionSearchRequest,
        referenceDate: Date
    ) -> [SessionRecord] {
        let scope = SessionFilterEvaluator.applyScopeFilters(
            snapshot.sessions,
            filters: request.filters,
            starredSessionIDs: snapshot.starredSessionIDs
        )
        return applyUpdatedTimeWindow(scope, within: request.updatedWithin, referenceDate: referenceDate)
    }

    private static func applyUpdatedTimeWindow(
        _ sessions: [SessionRecord],
        within timeInterval: TimeInterval?,
        referenceDate: Date
    ) -> [SessionRecord] {
        guard let timeInterval, timeInterval > 0 else {
            return sessions
        }

        let lowerBound = referenceDate.addingTimeInterval(-timeInterval)
        return sessions.filter { record in
            guard let bestTimestamp = record.bestTimestamp else {
                return false
            }
            return bestTimestamp >= lowerBound
        }
    }

    private static func makeMergedSearchMatches(
        from resultsByQuery: [String: [TranscriptIndexSearchHit]],
        queries: [ScopedTranscriptSearchQuery]
    ) -> [String: SessionSearchMatch] {
        let transcriptQueries = queries
            .filter { $0.scope == .all || $0.scope == .transcript }
            .map(\.query)
        let planQueries = queries
            .filter { $0.scope == .all || $0.scope == .plan }
            .map(\.query)

        var groupedBySession: [String: [TranscriptSearchScope: [Int: TranscriptIndexSearchHit]]] = [:]
        for scopedQuery in queries {
            for hit in resultsByQuery[scopedQuery.resultKey] ?? [] {
                let resultScope: TranscriptSearchScope = hit.entryIndex < 0 ? .plan : .transcript
                groupedBySession[hit.sessionRecordID, default: [:]][resultScope, default: [:]][hit.entryIndex] = hit
            }
        }

        return Dictionary(
            uniqueKeysWithValues: groupedBySession.map { sessionID, hitsByScope in
                let transcriptEntries = orderedHits(
                    Array(hitsByScope[.transcript, default: [:]].values),
                    scope: .transcript
                )
                let planEntries = orderedHits(
                    Array(hitsByScope[.plan, default: [:]].values),
                    scope: .plan
                )
                let transcriptSnippets = uniqueSnippets(for: transcriptEntries, queries: transcriptQueries)
                let planSnippets = uniqueSnippets(for: planEntries, queries: planQueries)

                return (
                    sessionID,
                    SessionSearchMatch(
                        sessionRecordID: sessionID,
                        transcriptMatchCount: transcriptEntries.count,
                        planMatchCount: planEntries.count,
                        transcriptSnippets: Array(transcriptSnippets.prefix(2)),
                        planSnippets: Array(planSnippets.prefix(2))
                    )
                )
            }
        )
    }

    private static func orderedHits<S: Sequence>(
        _ hits: S,
        scope: TranscriptSearchScope
    ) -> [TranscriptIndexSearchHit] where S.Element == TranscriptIndexSearchHit {
        hits.sorted {
            switch scope {
            case .plan:
                return $0.entryIndex > $1.entryIndex
            case .all, .transcript:
                return $0.entryIndex < $1.entryIndex
            }
        }
    }

    private static func uniqueSnippets(
        for hits: [TranscriptIndexSearchHit],
        queries: [String]
    ) -> [String] {
        hits.compactMap { hit in
            SearchTextMatcher.snippet(in: hit.text, queries: queries) ?? TextSanitizer.summarize(hit.text, limit: 120)
        }
        .reduce(into: [String]()) { partialResult, snippet in
            if !partialResult.contains(snippet) {
                partialResult.append(snippet)
            }
        }
    }
}
