import Foundation
import XCTest
@testable import AgentSessionManager

final class SQLiteStoreTests: XCTestCase {
    func testReplaceAllPersistsAndReadsBackSessions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("catalog.sqlite3")

        let store = try SQLiteSessionStore(databaseURL: databaseURL)
        let record = SessionRecord(
            source: .copilotCLI,
            sourceSessionId: "session-1",
            workspacePath: "/Users/pisoni/repos/newton5",
            projectName: "newton5",
            branch: "main",
            conversationModel: "gpt-5.4",
            startedAt: ISO8601DateCoding.parse("2026-05-07T06:18:14.516Z"),
            updatedAt: ISO8601DateCoding.parse("2026-05-07T06:30:14.516Z"),
            title: "Resume local session browser work",
            summary: "Refresh the local session index and show previews.",
            firstUserPreview: "Resume local session browser work",
            firstAssistantPreview: "I’ll refresh the catalog and inspect the previews.",
            rawTranscriptPath: "/tmp/events.jsonl",
            rawMetadataPath: "/tmp/workspace.yaml",
            relatedPlanPath: "/tmp/plan.md",
            resumeKind: .copilotConnect,
            resumePayload: "session-1",
            isNewtonProject: true
        )

        try store.replaceAll(records: [record])
        let loaded = try store.fetchAll()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.source, .copilotCLI)
        XCTAssertEqual(loaded.first?.sourceSessionId, "session-1")
        XCTAssertEqual(loaded.first?.title, "Resume local session browser work")
        XCTAssertEqual(loaded.first?.resumeKind, .copilotConnect)
        XCTAssertEqual(loaded.first?.conversationModel, "gpt-5.4")
        XCTAssertEqual(loaded.first?.relatedPlanPath, "/tmp/plan.md")
        XCTAssertTrue(loaded.first?.isNewtonProject == true)
    }
}
