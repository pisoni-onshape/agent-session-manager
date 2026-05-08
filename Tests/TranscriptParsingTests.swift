import Foundation
import XCTest
@testable import AgentSessionManager

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
            transcriptSessionIDsByQuery: ["drag": [record.id]]
        )

        XCTAssertTrue(matches)
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
                TranscriptEntry(id: "t1", role: .tool, title: "Started view", body: "quads.swift", timestamp: nil),
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
        XCTAssertEqual(matches.first?.matchCount, 2)
        XCTAssertEqual(matches.first?.snippets.count, 2)
    }

    func testSearchableTranscriptEntriesIncludeToolBodies() throws {
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

        XCTAssertEqual(entries.map(\.entryIndex), [0, 1, 2])
        XCTAssertEqual(
            entries.map(\.text),
            [
                "Find the terminal drag bug.",
                "view\n/tmp/file.swift",
                "I’ll inspect the drag target next."
            ]
        )
    }

    func testSearchableTranscriptEntriesKeepLongToolResultContent() throws {
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

        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries[1].text.contains("pickDefaultInferenceId"))
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
        rawTranscriptPath: String = "/tmp/test.jsonl"
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
            relatedPlanPath: nil,
            fingerprint: "fingerprint-\(sessionID)",
            resumeKind: .copilotConnect,
            resumePayload: sessionID,
            isNewtonProject: false
        )
    }
}
