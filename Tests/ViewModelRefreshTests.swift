import Foundation
import XCTest
@testable import AgentSessionManager
@testable import AgentSessionManagerCore

@MainActor
final class ViewModelRefreshTests: XCTestCase {
    func testRefreshPublishesProgressStateWhileCatalogWorkRuns() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("catalog.sqlite3")

        let refreshStarted = expectation(description: "Refresh started")
        let releaseRefresh = DispatchSemaphore(value: 0)
        let refreshedRecord = try makeRecord(
            sessionID: "blocking-refresh",
            title: "Blocking Refresh",
            fingerprint: "v1",
            directory: directory,
            transcriptText: "Transcript used for refresh-state testing."
        )
        let adapter = BlockingSessionAdapter(
            candidates: [
                SessionScanCandidate(
                    id: refreshedRecord.id,
                    fingerprint: refreshedRecord.fingerprint,
                    loadRecord: {
                        refreshStarted.fulfill()
                        XCTAssertEqual(releaseRefresh.wait(timeout: .now() + 5), .success)
                        return refreshedRecord
                    }
                )
            ]
        )
        let catalog = try SessionCatalog(storeURL: databaseURL, adaptersOverride: [adapter])
        let viewModel = SessionBrowserViewModel(catalog: catalog)

        let refreshTask = Task {
            await viewModel.refreshSessions()
        }

        await fulfillment(of: [refreshStarted], timeout: 1)
        XCTAssertTrue(viewModel.isRefreshing)
        XCTAssertEqual(viewModel.refreshStatusText, "Refreshing session index…")

        releaseRefresh.signal()
        await refreshTask.value

        XCTAssertFalse(viewModel.isRefreshing)
        XCTAssertNil(viewModel.refreshStatusText)
        XCTAssertEqual(viewModel.displayedSessions.map(\.id), [refreshedRecord.id])
        XCTAssertNotNil(viewModel.lastRefreshDisplayText)
    }

    private func makeRecord(
        sessionID: String,
        title: String,
        fingerprint: String,
        directory: URL,
        transcriptText: String
    ) throws -> SessionRecord {
        let transcriptURL = directory.appendingPathComponent("\(sessionID).jsonl")
        try """
        {"type":"user.message","data":{"content":"\(transcriptText)"},"id":"\(sessionID)-1","timestamp":"2026-05-07T06:19:00.000Z"}
        {"type":"assistant.message","data":{"content":"Assistant reply for \(sessionID)."},"id":"\(sessionID)-2","timestamp":"2026-05-07T06:19:10.000Z"}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        return SessionRecord(
            source: .copilotCLI,
            sourceSessionId: sessionID,
            workspacePath: "/Users/pisoni/repos/newton5",
            projectName: "newton5",
            branch: "main",
            conversationModel: "gpt-5.4",
            startedAt: ISO8601DateCoding.parse("2026-05-07T06:18:14.516Z"),
            updatedAt: ISO8601DateCoding.parse("2026-05-07T06:30:14.516Z"),
            title: title,
            summary: "Summary",
            firstUserPreview: "Prompt",
            firstAssistantPreview: "Response",
            rawTranscriptPath: transcriptURL.path,
            rawMetadataPath: "/tmp/\(sessionID).yaml",
            relatedPlanPath: nil,
            fingerprint: fingerprint,
            resumeKind: .copilotConnect,
            resumePayload: sessionID,
            isNewtonProject: true
        )
    }
}

private struct BlockingSessionAdapter: SessionSourceAdapter {
    let candidates: [SessionScanCandidate]

    func scanCandidates() throws -> [SessionScanCandidate] {
        candidates
    }
}
