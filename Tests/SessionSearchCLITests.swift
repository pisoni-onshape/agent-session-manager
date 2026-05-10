import Foundation
import XCTest
@testable import AgentSessionManagerCore

final class SessionSearchCLITests: XCTestCase {
    func testTopLevelHelpShowsSearchUsage() {
        let result = SessionSearchCLI.execute(arguments: ["agent-session-manager", "--help"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardOutput.contains("Usage:"))
        XCTAssertTrue(result.standardOutput.contains("search --query <text>"))
        XCTAssertTrue(result.standardError.isEmpty)
    }

    func testJSONSearchSupportsTopLevelSearchAliasAndFilters() {
        let snapshot = SessionCatalogSnapshot(
            sessions: [makeRecord(sessionID: "drag-session", title: "Find drag bug", branch: "main")],
            starredSessionIDs: ["copilot-cli::drag-session"]
        )

        let result = SessionSearchCLI.execute(
            arguments: [
                "agent-session-manager",
                "--search", "project:agent drag",
                "--source", "copilot",
                "--branch", "main",
                "--starred",
                "--newton-only",
                "--limit", "5",
                "--within", "1w",
                "--json"
            ],
            snapshot: snapshot,
            referenceDate: ISO8601DateCoding.parse("2026-05-08T06:30:14.516Z") ?? Date()
        ) { sessionIDs, query in
            XCTAssertEqual(sessionIDs, ["copilot-cli::drag-session"])
            XCTAssertEqual(query, "drag")
            return [
                TranscriptIndexSearchHit(
                    sessionRecordID: "copilot-cli::drag-session",
                    entryIndex: 0,
                    text: "Find the terminal drag bug."
                )
            ]
        }

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardOutput.contains("\"resultCount\" : 1"))
        XCTAssertTrue(result.standardOutput.contains("\"query\" : \"project:agent drag\""))
        XCTAssertTrue(result.standardOutput.contains("\"starred\" : true"))
        XCTAssertTrue(result.standardOutput.contains("\"transcriptMatchCount\" : 1"))
    }

    func testInvalidWithinValueReturnsUsageError() {
        let result = SessionSearchCLI.execute(arguments: [
            "agent-session-manager",
            "search",
            "--query", "drag",
            "--within", "yesterday"
        ])

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.standardError.contains("Expected --within"))
        XCTAssertTrue(result.standardError.contains("Usage:"))
    }

    private func makeRecord(sessionID: String, title: String, branch: String?) -> SessionRecord {
        SessionRecord(
            source: .copilotCLI,
            sourceSessionId: sessionID,
            workspacePath: "/Users/pisoni/Development/LocalProjects/agent-session-manager",
            projectName: "agent-session-manager",
            branch: branch,
            conversationModel: "gpt-5.4",
            startedAt: ISO8601DateCoding.parse("2026-05-07T06:18:14.516Z"),
            updatedAt: ISO8601DateCoding.parse("2026-05-08T06:30:14.516Z"),
            title: title,
            summary: "Investigate drag behavior.",
            firstUserPreview: "Find the drag bug.",
            firstAssistantPreview: "I’ll inspect the drag path next.",
            rawTranscriptPath: "/tmp/\(sessionID).jsonl",
            rawMetadataPath: "/tmp/\(sessionID).yaml",
            relatedPlanPath: "/tmp/\(sessionID)-plan.md",
            fingerprint: "fingerprint-\(sessionID)",
            resumeKind: .copilotConnect,
            resumePayload: sessionID,
            isNewtonProject: true
        )
    }
}
