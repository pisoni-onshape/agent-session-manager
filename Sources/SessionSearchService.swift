import Foundation

struct SessionCatalogSnapshot: Equatable, Sendable {
    let sessions: [SessionRecord]
    let starredSessionIDs: Set<String>
}

struct SessionSearchRequest: Equatable, Sendable {
    let filters: SessionFilterState
    let resultLimit: Int?
    let updatedWithin: TimeInterval?

    init(
        filters: SessionFilterState,
        resultLimit: Int? = nil,
        updatedWithin: TimeInterval? = nil
    ) {
        self.filters = filters
        self.resultLimit = resultLimit
        self.updatedWithin = updatedWithin
    }
}

struct SessionSearchExecution: Equatable, Sendable {
    let snapshot: SessionCatalogSnapshot
    let scopeSessions: [SessionRecord]
    let parsedQuery: ParsedSessionSearchQuery
    let searchState: SessionSearchState
    let displayedSessions: [SessionRecord]
}

enum SessionSearchService {
    static func loadSnapshot(from catalog: SessionCatalog, refresh: Bool = false) throws -> SessionCatalogSnapshot {
        let sessions = refresh ? try catalog.refreshSessions() : try catalog.loadPersistedSessions()
        return SessionCatalogSnapshot(
            sessions: sessions,
            starredSessionIDs: try catalog.starredSessionIDs()
        )
    }

    static func makePendingSearchState(
        snapshot: SessionCatalogSnapshot,
        request: SessionSearchRequest,
        referenceDate: Date = Date()
    ) -> SessionSearchState {
        let requestedQuery = request.filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedQuery = SessionSearchQueryParser.parse(requestedQuery)
        guard !requestedQuery.isEmpty, !parsedQuery.transcriptQueries.isEmpty else {
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

    static func search(
        using catalog: SessionCatalog,
        request: SessionSearchRequest,
        refresh: Bool = false,
        referenceDate: Date = Date()
    ) throws -> SessionSearchExecution {
        let snapshot = try loadSnapshot(from: catalog, refresh: refresh)
        return try search(snapshot: snapshot, request: request, referenceDate: referenceDate) { sessionIDs, query in
            try catalog.searchTranscriptIndex(sessionIDs: sessionIDs, query: query)
        }
    }

    static func search(
        snapshot: SessionCatalogSnapshot,
        request: SessionSearchRequest,
        referenceDate: Date = Date(),
        transcriptSearcher: ([String], String) throws -> [TranscriptIndexSearchHit]
    ) throws -> SessionSearchExecution {
        let scope = scopeSessions(in: snapshot, request: request, referenceDate: referenceDate)
        let parsedQuery = SessionSearchQueryParser.parse(request.filters.searchText)
        var searchState = makePendingSearchState(snapshot: snapshot, request: request, referenceDate: referenceDate)

        if searchState.hasRequestedQuery, searchState.searchedSessionCount > 0 {
            let sessionIDs = scope.map(\.id)
            var resultsByQuery: [String: [TranscriptIndexSearchHit]] = [:]
            for query in parsedQuery.transcriptQueries {
                resultsByQuery[query] = try transcriptSearcher(sessionIDs, query)
            }

            searchState = SessionSearchState(
                requestedQuery: searchState.requestedQuery,
                searchedScopeSignature: searchState.searchedScopeSignature,
                searchedSessionCount: searchState.searchedSessionCount,
                resultsByQuery: resultsByQuery,
                mergedResultsBySessionID: makeMergedSearchMatches(
                    from: resultsByQuery,
                    queries: parsedQuery.transcriptQueries
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
            filters: request.filters,
            starredSessionIDs: snapshot.starredSessionIDs
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

    static func scopeSignature(for sessions: [SessionRecord]) -> String {
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
}
