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

    func testScheduledRefreshDefersWhileAppIsActiveUntilAppBecomesInactive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("catalog.sqlite3")

        let refreshedRecord = try makeRecord(
            sessionID: "deferred-refresh",
            title: "Deferred Refresh",
            fingerprint: "v1",
            directory: directory,
            transcriptText: "Transcript used for deferred scheduled refresh testing."
        )
        let refreshExecuted = expectation(description: "Deferred scheduled refresh ran")
        let loadCallCounter = LoadCallCounter()
        let adapter = BlockingSessionAdapter(
            candidates: [
                SessionScanCandidate(
                    id: refreshedRecord.id,
                    fingerprint: refreshedRecord.fingerprint,
                    loadRecord: {
                        loadCallCounter.increment()
                        refreshExecuted.fulfill()
                        return refreshedRecord
                    }
                )
            ]
        )
        let catalog = try SessionCatalog(storeURL: databaseURL, adaptersOverride: [adapter])
        let settings = makeSettingsStore(cadence: .every15Minutes, deferWhileActive: true)
        let viewModel = SessionBrowserViewModel(catalog: catalog, settings: settings)

        await viewModel.loadInitialData()
        viewModel.setAppIsActive(true)

        await viewModel.handleScheduledRefreshTrigger()

        XCTAssertTrue(viewModel.hasPendingScheduledRefresh)
        XCTAssertFalse(viewModel.isRefreshing)

        viewModel.setAppIsActive(false)

        await fulfillment(of: [refreshExecuted], timeout: 1)
        await waitForCondition { !viewModel.isRefreshing && !viewModel.hasPendingScheduledRefresh }

        XCTAssertEqual(loadCallCounter.value, 1)
        XCTAssertEqual(viewModel.displayedSessions.map(\.id), [refreshedRecord.id])
    }

    func testScheduledRefreshCoalescesMultipleActiveTicksIntoOnePendingRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("catalog.sqlite3")

        let refreshedRecord = try makeRecord(
            sessionID: "coalesced-refresh",
            title: "Coalesced Refresh",
            fingerprint: "v1",
            directory: directory,
            transcriptText: "Transcript used for coalesced scheduled refresh testing."
        )
        let refreshExecuted = expectation(description: "Coalesced scheduled refresh ran")
        let loadCallCounter = LoadCallCounter()
        let adapter = BlockingSessionAdapter(
            candidates: [
                SessionScanCandidate(
                    id: refreshedRecord.id,
                    fingerprint: refreshedRecord.fingerprint,
                    loadRecord: {
                        loadCallCounter.increment()
                        refreshExecuted.fulfill()
                        return refreshedRecord
                    }
                )
            ]
        )
        let catalog = try SessionCatalog(storeURL: databaseURL, adaptersOverride: [adapter])
        let settings = makeSettingsStore(cadence: .every15Minutes, deferWhileActive: true)
        let viewModel = SessionBrowserViewModel(catalog: catalog, settings: settings)

        await viewModel.loadInitialData()
        viewModel.setAppIsActive(true)

        await viewModel.handleScheduledRefreshTrigger()
        await viewModel.handleScheduledRefreshTrigger()

        XCTAssertTrue(viewModel.hasPendingScheduledRefresh)
        XCTAssertFalse(viewModel.isRefreshing)

        viewModel.setAppIsActive(false)

        await fulfillment(of: [refreshExecuted], timeout: 1)
        await waitForCondition { !viewModel.isRefreshing && !viewModel.hasPendingScheduledRefresh }

        XCTAssertEqual(loadCallCounter.value, 1)
        XCTAssertEqual(viewModel.displayedSessions.map(\.id), [refreshedRecord.id])
    }

    func testLoadPresentedPlanReturnsPresentedPlanForInAppViewer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let planURL = directory.appendingPathComponent("plan.md")
        try """
        # Plan

        Keep the **viewer** flow consistent.
        """.write(to: planURL, atomically: true, encoding: .utf8)

        let record = try makeRecord(
            sessionID: "plan-viewer",
            title: "Plan Viewer",
            fingerprint: "plan-v1",
            directory: directory,
            transcriptText: "Transcript text",
            relatedPlanPath: planURL.path
        )
        let viewModel = SessionBrowserViewModel(catalog: nil)

        let presentedPlan = await viewModel.loadPresentedPlan(for: record, initialSearchText: "viewer")

        XCTAssertEqual(presentedPlan?.initialSearchText, "viewer")
        XCTAssertEqual(presentedPlan?.plan.rawPlanPath, planURL.path)
        XCTAssertEqual(presentedPlan?.plan.sessionTitle, "Plan Viewer")
        XCTAssertTrue(presentedPlan?.plan.text.contains("**viewer**") == true)
        XCTAssertNil(viewModel.errorMessage)
    }

    private func makeRecord(
        sessionID: String,
        title: String,
        fingerprint: String,
        directory: URL,
        transcriptText: String,
        relatedPlanPath: String? = nil
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
            relatedPlanPath: relatedPlanPath,
            fingerprint: fingerprint,
            resumeKind: .copilotConnect,
            resumePayload: sessionID,
            isNewtonProject: true
        )
    }

    private func makeSettingsStore(
        cadence: AutoRefreshCadence,
        deferWhileActive: Bool
    ) -> AppSettingsStore {
        let suiteName = "ViewModelRefreshTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store = AppSettingsStore(
            userDefaults: defaults,
            launchAtLoginController: MockLaunchAtLoginController(status: .notRegistered),
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        )
        store.setAutoRefreshCadence(cadence)
        store.setDeferRefreshWhileAppIsActive(deferWhileActive)
        store.setRefreshOnFirstLaunchAfterBoot(false)
        store.setRefreshOnSubsequentLaunches(false)
        return store
    }

    private func waitForCondition(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTFail("Timed out waiting for condition.")
    }
}

private struct BlockingSessionAdapter: SessionSourceAdapter {
    let candidates: [SessionScanCandidate]

    func scanCandidates() throws -> [SessionScanCandidate] {
        candidates
    }
}

private final class LoadCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock {
            count += 1
        }
    }
}

private final class MockLaunchAtLoginController: LaunchAtLoginControlling {
    var status: LaunchAtLoginStatus

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func setEnabled(_ enabled: Bool) throws {
        status = enabled ? .enabled : .notRegistered
    }
}
