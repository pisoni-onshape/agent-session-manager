import Foundation
import XCTest
@testable import AgentSessionManagerCore

final class TranscriptParsingTests: XCTestCase {
    func testFieldedSearchParserKeepsRecognizedClausesAndFallbackTerms() {
        let query = SessionSearchQueryParser.parse(#"project:"agent session manager" branch:main title:"session index" foo:refresh"#)

        XCTAssertEqual(
            query.fieldClauses,
            [
                SessionSearchFieldClause(field: .project, value: "agent session manager"),
                SessionSearchFieldClause(field: .branch, value: "main"),
                SessionSearchFieldClause(field: .title, value: "session index")
            ]
        )
        XCTAssertEqual(query.freeTextTerms, ["refresh"])
        XCTAssertTrue(query.usesStructuredSyntax)
    }

    func testFieldedSearchParserRecognizesTranscriptClauses() {
        let query = SessionSearchQueryParser.parse(#"project:newton transcript:"drag bug" transcript:cursor"#)

        XCTAssertEqual(
            query.fieldClauses,
            [
                SessionSearchFieldClause(field: .project, value: "newton"),
                SessionSearchFieldClause(field: .transcript, value: "drag bug"),
                SessionSearchFieldClause(field: .transcript, value: "cursor")
            ]
        )
        XCTAssertEqual(query.metadataFieldClauses, [SessionSearchFieldClause(field: .project, value: "newton")])
        XCTAssertEqual(query.transcriptFieldValues, ["drag bug", "cursor"])
    }

    func testFieldedSearchParserRecognizesPlanClausesAndScopedQueries() {
        let query = SessionSearchQueryParser.parse(#"project:newton transcript:"drag bug" plan:"search service" refactor"#)

        XCTAssertEqual(
            query.fieldClauses,
            [
                SessionSearchFieldClause(field: .project, value: "newton"),
                SessionSearchFieldClause(field: .transcript, value: "drag bug"),
                SessionSearchFieldClause(field: .plan, value: "search service")
            ]
        )
        XCTAssertEqual(query.planFieldValues, ["search service"])
        XCTAssertEqual(
            query.scopedSearchQueries,
            [
                ScopedTranscriptSearchQuery(query: "drag bug", scope: .transcript),
                ScopedTranscriptSearchQuery(query: "search service", scope: .plan),
                ScopedTranscriptSearchQuery(query: "refactor", scope: .all)
            ]
        )
    }

    func testFieldedSearchParserTrimsWhitespaceAfterColon() {
        // "project: newton" (space after colon) should parse identically to "project:newton"
        let withSpace = SessionSearchQueryParser.parse("project: newton")
        let withoutSpace = SessionSearchQueryParser.parse("project:newton")

        XCTAssertEqual(withSpace.fieldClauses, withoutSpace.fieldClauses)
        XCTAssertEqual(withSpace.freeTextTerms, withoutSpace.freeTextTerms)
    }

    func testFieldedSearchParserTrimsMultipleSpacesAndLeadingTrailingWhitespace() {
        let query = SessionSearchQueryParser.parse("  project:  agent-session-manager  ")

        XCTAssertEqual(query.fieldClauses, [SessionSearchFieldClause(field: .project, value: "agent-session-manager")])
        XCTAssertEqual(query.freeTextTerms, [])
    }

    func testUnlabeledToolbarSearchKeepsWholeQueryBehavior() {
        var filters = SessionFilterState()
        filters.searchText = "refresh behavior"

        let contiguous = makeRecord(
            sessionID: "contiguous",
            title: "Refresh fix",
            summary: "Investigated refresh behavior in the transcript browser."
        )
        let splitAcrossFields = makeRecord(
            sessionID: "split",
            title: "Refresh",
            summary: "Behavior only appears in a separate summary field."
        )

        let filtered = SessionFilterEvaluator.filterSessions([contiguous, splitAcrossFields], filters: filters)

        XCTAssertEqual(filtered.map(\.sourceSessionId), ["contiguous"])
    }

    func testSessionSearchEvaluatorAllowsTranscriptMatchesForStructuredFreeTextTerms() {
        let parsedQuery = SessionSearchQueryParser.parse("project:agent drag")
        let record = makeRecord(sessionID: "drag-session", title: "Investigate", summary: "No metadata drag hint here.")

        let matches = SessionSearchEvaluator.matches(
            record,
            parsedQuery: parsedQuery,
            transcriptSessionIDsByQuery: [ScopedTranscriptSearchQuery(query: "drag", scope: .all).resultKey: [record.id]]
        )

        XCTAssertTrue(matches)
    }

    func testScopeFiltersRespectStarredState() {
        let starred = makeRecord(sessionID: "starred", title: "Starred Session", summary: nil)
        let unstarred = makeRecord(sessionID: "plain", title: "Plain Session", summary: nil)

        var filters = SessionFilterState()
        filters.starFilter = .starred
        XCTAssertEqual(
            SessionFilterEvaluator
                .applyScopeFilters([starred, unstarred], filters: filters, starredSessionIDs: [starred.id])
                .map(\.sourceSessionId),
            ["starred"]
        )

        filters.starFilter = .unstarred
        XCTAssertEqual(
            SessionFilterEvaluator
                .applyScopeFilters([starred, unstarred], filters: filters, starredSessionIDs: [starred.id])
                .map(\.sourceSessionId)
                .sorted(),
            ["plain"]
        )
    }

    func testSessionListOrderingSortsPurelyBySortMode() {
        let olderSession = makeRecord(sessionID: "older", title: "Zebra", summary: nil)
        let newerSession = SessionRecord(
            source: .copilotCLI,
            sourceSessionId: "newer",
            workspacePath: "/Users/pisoni/Development/LocalProjects/agent-session-manager",
            projectName: "agent-session-manager",
            branch: "main",
            conversationModel: "gpt-5.4",
            startedAt: ISO8601DateCoding.parse("2026-05-07T06:18:14.516Z"),
            updatedAt: ISO8601DateCoding.parse("2026-05-08T06:30:14.516Z"),
            title: "Alpha",
            summary: nil,
            firstUserPreview: "Prompt",
            firstAssistantPreview: "Response",
            rawTranscriptPath: "/tmp/test.jsonl",
            rawMetadataPath: nil,
            relatedPlanPath: nil,
            fingerprint: "fingerprint-newer",
            resumeKind: .copilotConnect,
            resumePayload: "newer",
            isNewtonProject: false
        )

        let sorted = SessionListOrdering.sort(
            [olderSession, newerSession],
            filters: SessionFilterState()
        )

        XCTAssertEqual(sorted.map(\.sourceSessionId), ["newer", "older"])
    }

    func testCursorFallbackProjectNamePreservesKnownProjectName() {
        XCTAssertEqual(
            PathUtilities.cursorFallbackProjectName(from: "Users-pisoni-repos-newton-env-manager"),
            "newton-env-manager"
        )
        XCTAssertEqual(
            PathUtilities.cursorFallbackProjectName(from: "Users-pisoni-Development-LocalProjects-agent-session-manager"),
            "agent-session-manager"
        )
    }

    func testCursorFallbackProjectNameDoesNotInventSlashSeparatedPseudoPath() {
        XCTAssertEqual(
            PathUtilities.cursorFallbackProjectName(from: "some-arbitrary-encoded-project-name"),
            "some-arbitrary-encoded-project-name"
        )
    }

    func testEventTranscriptExtractionFindsSessionAndPreview() throws {
        let url = try temporaryFile(
            named: "event.jsonl",
            contents: """
            {"type":"session.start","data":{"sessionId":"abc-123","startTime":"2026-05-07T06:18:14.516Z"}}
            {"type":"user.message","data":{"content":"<user_query>Find the terminal drag/drop bug.</user_query>"}}
            {"type":"assistant.message","data":{"content":"I’ll trace the terminal initialization path first."}}
            """
        )

        let preview = try TranscriptPreviewExtractor.extractEventTranscript(from: url)
        XCTAssertEqual(preview.sessionId, "abc-123")
        XCTAssertEqual(preview.firstUser, "Find the terminal drag/drop bug.")
        XCTAssertEqual(preview.firstAssistant, "I’ll trace the terminal initialization path first.")
        XCTAssertNotNil(preview.startedAt)
    }

    func testEventTranscriptExtractionPreservesBasicAssistantFormatting() throws {
        let url = try temporaryFile(
            named: "event-formatted.jsonl",
            contents: """
            {"type":"assistant.message","data":{"content":"Here's my analysis:\\n\\nRoot cause\\n\\tIndented detail\\n\\n1. First item\\n2. Second item"}}
            """
        )

        let preview = try TranscriptPreviewExtractor.extractEventTranscript(from: url)
        XCTAssertEqual(
            preview.firstAssistant,
            """
            Here's my analysis:

            Root cause
                Indented detail

            1. First item
            2. Second item
            """
        )
    }

    func testCursorTranscriptExtractionFindsFirstTurns() throws {
        let url = try temporaryFile(
            named: "cursor.jsonl",
            contents: """
            {"role":"user","message":{"content":[{"type":"text","text":"Please explain how body edges become quads."}]}}
            {"role":"assistant","message":{"content":[{"type":"text","text":"I’ll inspect the edge rendering pipeline first."}]}}
            """
        )

        let preview = try TranscriptPreviewExtractor.extractCursorTranscript(from: url)
        XCTAssertEqual(preview.firstUser, "Please explain how body edges become quads.")
        XCTAssertEqual(preview.firstAssistant, "I’ll inspect the edge rendering pipeline first.")
    }

    func testTranscriptLoaderBuildsTimestampedEventTranscript() throws {
        let url = try temporaryFile(
            named: "event-full.jsonl",
            contents: """
            {"type":"session.start","data":{"sessionId":"abc-123","producer":"copilot-agent","copilotVersion":"1.0.43","startTime":"2026-05-07T06:18:14.516Z"},"id":"evt-1","timestamp":"2026-05-07T06:18:14.516Z"}
            {"type":"session.model_change","data":{"newModel":"copilot/gpt-5.4"},"id":"evt-2","timestamp":"2026-05-07T06:18:15.000Z"}
            {"type":"user.message","data":{"content":"<user_query>Find the terminal drag/drop bug.</user_query>"},"id":"evt-3","timestamp":"2026-05-07T06:19:00.000Z"}
            {"type":"tool.execution_start","data":{"toolCallId":"call-1","toolName":"view","arguments":{"path":"/tmp/file.swift"}},"id":"evt-4","timestamp":"2026-05-07T06:19:05.000Z"}
            {"type":"tool.execution_complete","data":{"toolCallId":"call-1","success":true,"result":{"content":"done"}},"id":"evt-5","timestamp":"2026-05-07T06:19:06.000Z"}
            {"type":"assistant.message","data":{"content":"I’ll trace the terminal initialization path first."},"id":"evt-6","timestamp":"2026-05-07T06:19:10.000Z"}
            """
        )

        let record = SessionRecord(
            source: .copilotCLI,
            sourceSessionId: "abc-123",
            workspacePath: nil,
            projectName: "agent-session-manager",
            branch: nil,
            conversationModel: nil,
            startedAt: nil,
            updatedAt: nil,
            title: "Find terminal bug",
            summary: nil,
            firstUserPreview: nil,
            firstAssistantPreview: nil,
            rawTranscriptPath: url.path,
            rawMetadataPath: nil,
            relatedPlanPath: nil,
            fingerprint: "fingerprint-event",
            resumeKind: .copilotConnect,
            resumePayload: "abc-123",
            isNewtonProject: false
        )

        let transcript = try TranscriptPreviewExtractor.loadTranscript(for: record)
        XCTAssertEqual(transcript.entries.count, 6)
        XCTAssertTrue(transcript.timestampsAreComplete)
        XCTAssertNil(transcript.timestampNotice)
        XCTAssertEqual(transcript.entries[1].body, "gpt-5.4")
        XCTAssertEqual(transcript.entries[3].title, "Started view")
        XCTAssertEqual(transcript.entries[4].title, "Completed view")
        XCTAssertEqual(transcript.entries[5].body, "I’ll trace the terminal initialization path first.")

        let displayItems = transcript.displayItems
        XCTAssertEqual(displayItems.count, 4)
        guard case let .collapsedEvents(_, leadingEvents) = displayItems[0] else {
            return XCTFail("Expected leading non-chat entries to be collapsed.")
        }
        XCTAssertEqual(leadingEvents.count, 2)
        guard case let .collapsedEvents(_, toolEvents) = displayItems[2] else {
            return XCTFail("Expected tool entries to be collapsed.")
        }
        XCTAssertEqual(toolEvents.count, 2)
    }

    func testClaudeTranscriptParsesStringAndBlockContent() throws {
        let url = try temporaryFile(
            named: "claude-code.jsonl",
            contents: """
            {"type":"mode","mode":"normal","sessionId":"cc-1"}
            {"type":"user","message":{"role":"user","content":"Fix the failing test."},"entrypoint":"cli","timestamp":"2026-07-01T10:00:00.000Z","uuid":"u1"}
            {"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-8","content":[{"type":"text","text":"Looking now."},{"type":"tool_use","name":"Bash","input":{"command":"ls -la"}}]},"timestamp":"2026-07-01T10:00:05.000Z","uuid":"a1"}
            {"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"file.txt"}]},"timestamp":"2026-07-01T10:00:06.000Z","uuid":"u2"}
            """
        )

        let record = SessionRecord(
            source: .claudeCodeCLI,
            sourceSessionId: "cc-1",
            workspacePath: "/Users/pisoni/repos/newton3",
            projectName: "newton3",
            branch: "main",
            conversationModel: "claude-opus-4-8",
            startedAt: nil,
            updatedAt: nil,
            title: "Fix the failing test.",
            summary: nil,
            firstUserPreview: nil,
            firstAssistantPreview: nil,
            rawTranscriptPath: url.path,
            rawMetadataPath: nil,
            relatedPlanPath: nil,
            fingerprint: "fingerprint-claude",
            resumeKind: .claudeResume,
            resumePayload: "cc-1",
            isNewtonProject: false
        )

        let transcript = try TranscriptPreviewExtractor.loadTranscript(for: record)

        XCTAssertEqual(transcript.entries.count, 4)
        XCTAssertEqual(transcript.entries[0].role, .user)
        XCTAssertEqual(transcript.entries[0].body, "Fix the failing test.")
        XCTAssertEqual(transcript.entries[1].role, .assistant)
        XCTAssertEqual(transcript.entries[1].body, "Looking now.")
        XCTAssertEqual(transcript.entries[2].role, .tool)
        XCTAssertEqual(transcript.entries[2].title, "Tool: Bash")
        XCTAssertEqual(transcript.entries[2].body, "ls -la")
        XCTAssertEqual(transcript.entries[3].role, .tool)
        XCTAssertEqual(transcript.entries[3].title, "Tool Result")
        XCTAssertTrue(transcript.timestampsAreComplete)
    }

    func testTranscriptLoaderPreservesBasicMessageFormatting() throws {
        let url = try temporaryFile(
            named: "event-multiline.jsonl",
            contents: """
            {"type":"assistant.message","data":{"content":"Here's my analysis:\\n\\nRoot cause\\n\\tIndented detail\\n\\n1. First item\\n2. Second item"},"id":"evt-1","timestamp":"2026-05-07T06:19:10.000Z"}
            """
        )

        let record = SessionRecord(
            source: .copilotCLI,
            sourceSessionId: "abc-123",
            workspacePath: nil,
            projectName: "agent-session-manager",
            branch: nil,
            conversationModel: nil,
            startedAt: nil,
            updatedAt: nil,
            title: "Formatted transcript",
            summary: nil,
            firstUserPreview: nil,
            firstAssistantPreview: nil,
            rawTranscriptPath: url.path,
            rawMetadataPath: nil,
            relatedPlanPath: nil,
            fingerprint: "fingerprint-formatted-event",
            resumeKind: .copilotConnect,
            resumePayload: "abc-123",
            isNewtonProject: false
        )

        let transcript = try TranscriptPreviewExtractor.loadTranscript(for: record)
        XCTAssertEqual(
            transcript.entries.first?.body,
            """
            Here's my analysis:

            Root cause
                Indented detail

            1. First item
            2. Second item
            """
        )
    }

    func testTranscriptLoaderBuildsCursorTranscriptWithoutTimestamps() throws {
        let url = try temporaryFile(
            named: "cursor-full.jsonl",
            contents: """
            {"role":"user","message":{"content":[{"type":"text","text":"Please explain how body edges become quads."}]}}
            {"role":"assistant","message":{"content":[{"type":"text","text":"I’ll inspect the edge rendering pipeline first."}]}}
            """
        )

        let record = SessionRecord(
            source: .cursor,
            sourceSessionId: "cursor-1",
            workspacePath: nil,
            projectName: "newton",
            branch: nil,
            conversationModel: nil,
            startedAt: nil,
            updatedAt: nil,
            title: "Cursor transcript",
            summary: nil,
            firstUserPreview: nil,
            firstAssistantPreview: nil,
            rawTranscriptPath: url.path,
            rawMetadataPath: nil,
            relatedPlanPath: nil,
            fingerprint: "fingerprint-cursor",
            resumeKind: .revealPath,
            resumePayload: url.path,
            isNewtonProject: true
        )

        let transcript = try TranscriptPreviewExtractor.loadTranscript(for: record)
        XCTAssertEqual(transcript.entries.count, 2)
        XCTAssertFalse(transcript.timestampsAreComplete)
        XCTAssertNotNil(transcript.timestampNotice)
        XCTAssertNil(transcript.entries[0].timestamp)
        XCTAssertEqual(transcript.entries[0].title, "User")
        XCTAssertEqual(transcript.entries[1].title, "Assistant")
    }

    func testViewerSearchOnlyMatchesChatMessages() {
        let transcript = TranscriptDocument(
            sessionID: "viewer-search",
            sessionTitle: "Viewer Search",
            source: .copilotCLI,
            rawTranscriptPath: "/tmp/viewer-search.jsonl",
            entries: [
                TranscriptEntry(id: "u1", role: .user, title: "User", body: "Find the quads regression.", timestamp: nil),
                TranscriptEntry(id: "t1", role: .tool, title: "Started view", body: "Memory cache diagnostics", timestamp: nil),
                TranscriptEntry(id: "a1", role: .assistant, title: "Assistant", body: "I will inspect the edge path next.", timestamp: nil)
            ],
            timestampsAreComplete: false,
            timestampNotice: nil
        )

        let result = transcript.viewerSearchResult(for: "quads")

        XCTAssertEqual(result.totalMatchCount, 1)
        XCTAssertEqual(result.matchingEntryCount, 1)
        XCTAssertEqual(result.displayItems.count, 1)
        guard case let .entry(entry) = result.displayItems[0] else {
            return XCTFail("Expected a matching chat entry.")
        }
        XCTAssertEqual(entry.id, "u1")
    }

    func testChatDisplayItemsExcludeInternalEvents() {
        let transcript = TranscriptDocument(
            sessionID: "chat-only-display",
            sessionTitle: "Chat Only Display",
            source: .copilotCLI,
            rawTranscriptPath: "/tmp/chat-only-display.jsonl",
            entries: [
                TranscriptEntry(id: "s1", role: .system, title: "Session Started", body: nil, timestamp: nil),
                TranscriptEntry(id: "u1", role: .user, title: "User", body: "hello", timestamp: nil),
                TranscriptEntry(id: "t1", role: .tool, title: "Started view", body: "tool body", timestamp: nil),
                TranscriptEntry(id: "a1", role: .assistant, title: "Assistant", body: "world", timestamp: nil)
            ],
            timestampsAreComplete: false,
            timestampNotice: nil
        )

        let items = transcript.chatDisplayItems

        XCTAssertEqual(items.count, 2)
        guard case let .entry(firstEntry) = items[0],
              case let .entry(secondEntry) = items[1] else {
            return XCTFail("Expected only chat entries in chat display items.")
        }
        XCTAssertEqual(firstEntry.id, "u1")
        XCTAssertEqual(secondEntry.id, "a1")
    }

    func testSearchTextMatcherProducesHighlightedSegments() {
        let segments = SearchTextMatcher.segments(in: "Refresh the refresh flow", query: "refresh")

        XCTAssertEqual(
            segments,
            [
                HighlightedTextSegment(text: "Refresh", isMatch: true),
                HighlightedTextSegment(text: " the ", isMatch: false),
                HighlightedTextSegment(text: "refresh", isMatch: true),
                HighlightedTextSegment(text: " flow", isMatch: false)
            ]
        )
    }

    func testTranscriptSetSearchReturnsPerSessionMatches() async throws {
        let matchingURL = try temporaryFile(
            named: "matching.jsonl",
            contents: """
            {"type":"user.message","data":{"content":"Find the terminal drag bug."},"id":"evt-1","timestamp":"2026-05-07T06:19:00.000Z"}
            {"type":"assistant.message","data":{"content":"I’ll inspect the drag target next."},"id":"evt-2","timestamp":"2026-05-07T06:19:10.000Z"}
            """
        )
        let nonMatchingURL = try temporaryFile(
            named: "other.jsonl",
            contents: """
            {"type":"user.message","data":{"content":"Please summarize the search improvements plan."},"id":"evt-1","timestamp":"2026-05-07T06:19:00.000Z"}
            {"type":"assistant.message","data":{"content":"I’ll outline the filter changes."},"id":"evt-2","timestamp":"2026-05-07T06:19:10.000Z"}
            """
        )

        let matchingRecord = makeRecord(
            sessionID: "matching",
            title: "Find drag bug",
            summary: nil,
            rawTranscriptPath: matchingURL.path
        )
        let nonMatchingRecord = makeRecord(
            sessionID: "other",
            title: "Search plan",
            summary: nil,
            rawTranscriptPath: nonMatchingURL.path
        )

        let cache = TranscriptDocumentCache()
        let matches = try await cache.search(records: [matchingRecord, nonMatchingRecord], query: "drag")

        XCTAssertEqual(matches.map(\.sessionRecordID), [matchingRecord.id])
        XCTAssertEqual(matches.first?.transcriptMatchCount, 2)
        XCTAssertEqual(matches.first?.transcriptSnippets.count, 2)
    }

    func testSessionSearchServiceReturnsTranscriptMatchesForStructuredQueries() throws {
        var filters = SessionFilterState()
        filters.searchText = "project:agent drag"

        let matching = makeRecord(sessionID: "matching", title: "Investigate drag", summary: "No direct metadata hit here.")
        let other = makeRecord(sessionID: "other", title: "Other session", summary: "Also in the same project.")
        let snapshot = SessionCatalogSnapshot(sessions: [matching, other], starredSessionIDs: [])

        let execution = try SessionSearchService.search(snapshot: snapshot, request: SessionSearchRequest(filters: filters)) { sessionIDs, query, scope in
            XCTAssertEqual(Set(sessionIDs), Set([matching.id, other.id]))
            XCTAssertEqual(query, "drag")
            XCTAssertEqual(scope, .all)
            return [
                TranscriptIndexSearchHit(
                    sessionRecordID: matching.id,
                    entryIndex: 0,
                    text: "Find the terminal drag bug."
                )
            ]
        }

        XCTAssertEqual(execution.displayedSessions.map(\.sourceSessionId), ["matching"])
        XCTAssertEqual(execution.searchState.searchedSessionCount, 2)
        XCTAssertEqual(execution.searchState.totalMatchCount, 1)
        XCTAssertEqual(execution.searchState.mergedResultsBySessionID[matching.id]?.transcriptSnippets.count, 1)
    }

    func testSessionSearchServiceSeparatesTranscriptAndPlanMatches() throws {
        var filters = SessionFilterState()
        filters.searchText = "drag"

        let matching = makeRecord(sessionID: "matching", title: "Investigate drag", summary: nil)
        let snapshot = SessionCatalogSnapshot(sessions: [matching], starredSessionIDs: [])

        let execution = try SessionSearchService.search(snapshot: snapshot, request: SessionSearchRequest(filters: filters)) { sessionIDs, query, scope in
            XCTAssertEqual(sessionIDs, [matching.id])
            XCTAssertEqual(query, "drag")
            XCTAssertEqual(scope, .all)
            return [
                TranscriptIndexSearchHit(
                    sessionRecordID: matching.id,
                    entryIndex: 0,
                    text: "Find the terminal drag bug."
                ),
                TranscriptIndexSearchHit(
                    sessionRecordID: matching.id,
                    entryIndex: -1,
                    text: "Plan the drag bug search flow."
                )
            ]
        }

        let match = execution.searchState.mergedResultsBySessionID[matching.id]
        XCTAssertEqual(match?.transcriptMatchCount, 1)
        XCTAssertEqual(match?.planMatchCount, 1)
        XCTAssertEqual(match?.transcriptSnippets.count, 1)
        XCTAssertEqual(match?.planSnippets.count, 1)
    }

    func testSessionSearchServiceSkipsTranscriptSearchForMetadataOnlyQueries() throws {
        var filters = SessionFilterState()
        filters.searchText = "project:agent"

        let matching = makeRecord(sessionID: "matching", title: "Agent session", summary: nil)
        let other = makeRecord(sessionID: "other", title: "Different project", summary: nil).withProjectName("other-project")
        let snapshot = SessionCatalogSnapshot(sessions: [matching, other], starredSessionIDs: [])

        let execution = try SessionSearchService.search(snapshot: snapshot, request: SessionSearchRequest(filters: filters)) { _, _, _ in
            XCTFail("Metadata-only searches should not hit the transcript index.")
            return []
        }

        XCTAssertEqual(execution.displayedSessions.map(\.sourceSessionId), ["matching"])
        XCTAssertFalse(execution.searchState.hasRequestedQuery)
    }

    func testSearchableTranscriptEntriesOnlyIncludeChatMessages() throws {
        let url = try temporaryFile(
            named: "searchable.jsonl",
            contents: """
            {"type":"user.message","data":{"content":"Find the terminal drag bug."},"id":"evt-1","timestamp":"2026-05-07T06:19:00.000Z"}
            {"type":"tool.execution_start","data":{"toolCallId":"call-1","toolName":"view","arguments":{"path":"/tmp/file.swift"}},"id":"evt-2","timestamp":"2026-05-07T06:19:05.000Z"}
            {"type":"assistant.message","data":{"content":"I’ll inspect the drag target next."},"id":"evt-3","timestamp":"2026-05-07T06:19:10.000Z"}
            """
        )

        let record = makeRecord(
            sessionID: "searchable",
            title: "Searchable transcript",
            summary: nil,
            rawTranscriptPath: url.path
        )

        let entries = try TranscriptPreviewExtractor.searchableEntries(for: record)

        XCTAssertEqual(entries.map(\.entryIndex), [0, 2])
        XCTAssertEqual(entries.map(\.text), ["Find the terminal drag bug.", "I’ll inspect the drag target next."])
    }

    func testSearchableEntriesIncludePlanChunksWithNegativeIndices() throws {
        let transcriptURL = try temporaryFile(
            named: "searchable-plan.jsonl",
            contents: """
            {"type":"user.message","data":{"content":"Find the terminal drag bug."},"id":"evt-1","timestamp":"2026-05-07T06:19:00.000Z"}
            """
        )
        let planURL = try temporaryFile(
            named: "plan.md",
            contents: """
            # Plan

            Search service refactor for plan indexing.

            Add scoped search and viewer wiring.
            """
        )

        let record = makeRecord(
            sessionID: "searchable-plan",
            title: "Searchable plan",
            summary: nil,
            rawTranscriptPath: transcriptURL.path,
            relatedPlanPath: planURL.path
        )

        let entries = try TranscriptPreviewExtractor.searchableEntries(for: record)

        XCTAssertEqual(entries.first?.entryIndex, 0)
        XCTAssertTrue(entries.dropFirst().allSatisfy { $0.entryIndex < 0 })
        XCTAssertTrue(entries.contains(where: { $0.text.contains("Search service refactor") }))
    }

    func testPlanViewerSearchResultCountsMatches() {
        let plan = PlanDocument(
            sessionID: "plan-1",
            sessionTitle: "Plan Search",
            source: .copilotCLI,
            rawPlanPath: "/tmp/plan.md",
            text: """
            Plan search should find the word search twice.
            Search wiring is important.
            """
        )

        let result = plan.viewerSearchResult(for: "search")

        XCTAssertEqual(result.totalMatchCount, 3)
        XCTAssertEqual(result.highlightQuery, "search")
    }

    func testMarkdownRenderingBuildsStructuredPlanBlocks() {
        let blocks = MarkdownRendering.blocks(from: """
        # Plan Title

        Intro paragraph with **bold** guidance.

        - First item
        - Second item

        1. Step one
        2. Step two

        > Keep the old button as an escape hatch.

        | Column | Value |
        | --- | --- |
        | Viewer | Built-in |

        ```swift
        let mode = "viewer"
        ```
        """)

        XCTAssertEqual(
            blocks,
            [
                .heading(level: 1, text: "Plan Title"),
                .paragraph(text: "Intro paragraph with **bold** guidance."),
                .bulletList(items: ["First item", "Second item"]),
                .numberedList(items: ["Step one", "Step two"]),
                .blockquote(text: "Keep the old button as an escape hatch."),
                .table(rows: ["| Column | Value |", "| Viewer | Built-in |"]),
                .codeBlock(text: #"let mode = "viewer""#)
            ]
        )
    }

    func testMarkdownRenderingPreservesVisibleTextAndHighlightsMatches() {
        let rendered = MarkdownRendering.inlineAttributedString(
            from: #"**Plan** uses [viewer](https://example.com/viewer) links and ~~fallback~~ actions."#,
            highlightQuery: "viewer"
        )

        XCTAssertEqual(String(rendered.characters), "Plan uses viewer links and fallback actions.")
        XCTAssertTrue(rendered.runs.contains(where: { $0.link?.absoluteString == "https://example.com/viewer" }))
    }

    func testCurrentMatchUsesDistinctHighlightColor() {
        let text = "Open the viewer."
        let query = "viewer"

        let plain = MarkdownRendering.inlineAttributedString(from: text, highlightQuery: nil)
        let normal = MarkdownRendering.inlineAttributedString(from: text, highlightQuery: query, isCurrent: false)
        let current = MarkdownRendering.inlineAttributedString(from: text, highlightQuery: query, isCurrent: true)

        // Same visible text throughout.
        XCTAssertEqual(String(normal.characters), text)
        XCTAssertEqual(String(current.characters), text)

        // Highlighting adds a background attribute, and the current match differs from a normal match.
        XCTAssertNotEqual(plain, normal)
        XCTAssertNotEqual(plain, current)
        XCTAssertNotEqual(normal, current)
    }

    func testBlockMatchDetectionMirrorsRenderedRuns() {
        let heading = MarkdownBlock.heading(level: 1, text: "**Viewer** overview")
        let paragraph = MarkdownBlock.paragraph(text: "Nothing relevant here.")
        let list = MarkdownBlock.bulletList(items: ["alpha", "the viewer item"])
        let code = MarkdownBlock.codeBlock(text: "let viewer = true")

        // runStrings strips inline markdown for inline blocks but keeps code raw.
        XCTAssertEqual(MarkdownRendering.runStrings(for: heading), ["Viewer overview"])
        XCTAssertEqual(MarkdownRendering.runStrings(for: list), ["alpha", "the viewer item"])
        XCTAssertEqual(MarkdownRendering.runStrings(for: code), ["let viewer = true"])

        XCTAssertTrue(MarkdownRendering.blockContainsMatch(heading, query: "viewer"))
        XCTAssertFalse(MarkdownRendering.blockContainsMatch(paragraph, query: "viewer"))
        XCTAssertTrue(MarkdownRendering.blockContainsMatch(list, query: "viewer"))
        XCTAssertTrue(MarkdownRendering.blockContainsMatch(code, query: "viewer"))
        XCTAssertFalse(MarkdownRendering.blockContainsMatch(heading, query: nil))
    }

    func testSearchableTranscriptEntriesIgnoreToolResultContent() throws {
        let longContent = String(repeating: "prefix ", count: 40) + "pickDefaultInferenceId" + String(repeating: " suffix", count: 40)
        let url = try temporaryFile(
            named: "tool-result.jsonl",
            contents: """
            {"type":"tool.execution_start","data":{"toolCallId":"call-1","toolName":"rg","arguments":{"pattern":"pickDefaultInferenceId"}},"id":"evt-1","timestamp":"2026-05-07T06:19:05.000Z"}
            {"type":"tool.execution_complete","data":{"toolCallId":"call-1","success":true,"result":{"content":"\(longContent)"}},"id":"evt-2","timestamp":"2026-05-07T06:19:06.000Z"}
            """
        )

        let record = makeRecord(
            sessionID: "tool-result",
            title: "Tool result transcript",
            summary: nil,
            rawTranscriptPath: url.path
        )

        let entries = try TranscriptPreviewExtractor.searchableEntries(for: record)

        XCTAssertTrue(entries.isEmpty)
    }

    func testTranscriptLoaderKeepsLongToolResultContentVisible() throws {
        let longContent = String(repeating: "prefix ", count: 20) + "memory" + String(repeating: " suffix", count: 20)
        let url = try temporaryFile(
            named: "tool-visible.jsonl",
            contents: """
            {"type":"tool.execution_start","data":{"toolCallId":"call-1","toolName":"view","arguments":{"path":"/tmp/file.swift"}},"id":"evt-1","timestamp":"2026-05-07T06:19:05.000Z"}
            {"type":"tool.execution_complete","data":{"toolCallId":"call-1","success":true,"result":{"content":"\(longContent)"}},"id":"evt-2","timestamp":"2026-05-07T06:19:06.000Z"}
            """
        )

        let record = makeRecord(
            sessionID: "tool-visible",
            title: "Visible tool content",
            summary: nil,
            rawTranscriptPath: url.path
        )

        let transcript = try TranscriptPreviewExtractor.loadTranscript(for: record)

        XCTAssertEqual(transcript.entries.count, 2)
        XCTAssertTrue(transcript.entries[1].body?.contains("memory") == true)
    }

    private func temporaryFile(named name: String, contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeRecord(
        sessionID: String,
        title: String,
        summary: String?,
        rawTranscriptPath: String = "/tmp/test.jsonl",
        relatedPlanPath: String? = nil
    ) -> SessionRecord {
        SessionRecord(
            source: .copilotCLI,
            sourceSessionId: sessionID,
            workspacePath: "/Users/pisoni/Development/LocalProjects/agent-session-manager",
            projectName: "agent-session-manager",
            branch: "main",
            conversationModel: "gpt-5.4",
            startedAt: ISO8601DateCoding.parse("2026-05-07T06:18:14.516Z"),
            updatedAt: ISO8601DateCoding.parse("2026-05-07T06:30:14.516Z"),
            title: title,
            summary: summary,
            firstUserPreview: "Prompt",
            firstAssistantPreview: "Response",
            rawTranscriptPath: rawTranscriptPath,
            rawMetadataPath: nil,
            relatedPlanPath: relatedPlanPath,
            fingerprint: "fingerprint-\(sessionID)",
            resumeKind: .copilotConnect,
            resumePayload: sessionID,
            isNewtonProject: false
        )
    }
}

private extension SessionRecord {
    func withProjectName(_ projectName: String) -> SessionRecord {
        SessionRecord(
            source: source,
            sourceSessionId: sourceSessionId,
            workspacePath: workspacePath,
            projectName: projectName,
            branch: branch,
            conversationModel: conversationModel,
            startedAt: startedAt,
            updatedAt: updatedAt,
            title: title,
            summary: summary,
            firstUserPreview: firstUserPreview,
            firstAssistantPreview: firstAssistantPreview,
            rawTranscriptPath: rawTranscriptPath,
            rawMetadataPath: rawMetadataPath,
            relatedPlanPath: relatedPlanPath,
            fingerprint: fingerprint,
            resumeKind: resumeKind,
            resumePayload: resumePayload,
            isNewtonProject: isNewtonProject
        )
    }
}
