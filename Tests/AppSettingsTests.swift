import Foundation
import XCTest
@testable import AgentSessionManager
@testable import AgentSessionManagerCore

@MainActor
final class AppSettingsTests: XCTestCase {
    func testDefaultNewtonReposRootExpandsHomeDirectory() {
        let homeDirectory = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        XCTAssertEqual(
            AppSettingsSnapshot.defaultNewtonReposRootPath(homeDirectory: homeDirectory),
            "/Users/tester/repos"
        )
    }

    func testNormalizedNewtonReposRootPathExpandsHomeAndTrimsTrailingSlash() {
        XCTAssertEqual(
            AppSettingsSnapshot.normalizedNewtonReposRootPath(
                "$HOME/repos/",
                homeDirectoryPath: "/Users/tester"
            ),
            "/Users/tester/repos"
        )
    }

    func testSettingsStorePersistsNormalizedPathAndCadence() {
        let suiteName = "AppSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let controller = MockLaunchAtLoginController(status: .notRegistered)
        let homeDirectory = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        let store = AppSettingsStore(
            userDefaults: defaults,
            launchAtLoginController: controller,
            homeDirectoryURL: homeDirectory
        )
        store.setNewtonReposRootPath("/Users/tester/repos/")
        store.setAutoRefreshCadence(.every4Hours)
        store.setDeferRefreshWhileAppIsActive(true)
        store.setRefreshOnFirstLaunchAfterBoot(false)
        store.setRefreshOnSubsequentLaunches(false)

        let reopenedStore = AppSettingsStore(
            userDefaults: defaults,
            launchAtLoginController: controller,
            homeDirectoryURL: homeDirectory
        )

        XCTAssertEqual(reopenedStore.newtonReposRootPath, "/Users/tester/repos")
        XCTAssertEqual(reopenedStore.autoRefreshCadence, .every4Hours)
        XCTAssertTrue(reopenedStore.deferRefreshWhileAppIsActive)
        XCTAssertFalse(reopenedStore.refreshOnFirstLaunchAfterBoot)
        XCTAssertFalse(reopenedStore.refreshOnSubsequentLaunches)
    }

    func testLaunchAtLoginFailureSurfacesErrorAndKeepsDisabledState() {
        let suiteName = "AppSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let controller = MockLaunchAtLoginController(
            status: .notRegistered,
            nextError: MockLaunchAtLoginError.enableFailed
        )
        let store = AppSettingsStore(
            userDefaults: defaults,
            launchAtLoginController: controller,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        )

        store.setLaunchAtLoginEnabled(true)

        XCTAssertFalse(store.launchAtLoginEnabled)
        XCTAssertEqual(store.launchAtLoginErrorMessage, MockLaunchAtLoginError.enableFailed.localizedDescription)
    }

    func testAutoRefreshCadenceIntervalsMatchExpectedDurations() {
        XCTAssertNil(AutoRefreshCadence.off.timeInterval)
        XCTAssertEqual(AutoRefreshCadence.every15Minutes.timeInterval, 900)
        XCTAssertEqual(AutoRefreshCadence.every30Minutes.timeInterval, 1_800)
        XCTAssertEqual(AutoRefreshCadence.every1Hour.timeInterval, 3_600)
        XCTAssertEqual(AutoRefreshCadence.every4Hours.timeInterval, 14_400)
        XCTAssertEqual(AutoRefreshCadence.everyDay.timeInterval, 86_400)
        XCTAssertEqual(AutoRefreshCadence.every7Days.timeInterval, 604_800)
    }

    func testLaunchRefreshDecisionUsesFirstAndSubsequentLaunchSettings() {
        let suiteName = "AppSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let settings = AutoSessionRefreshSettings(
            cadence: .off,
            deferWhileAppIsActive: false,
            refreshOnFirstLaunchAfterBoot: false,
            refreshOnSubsequentLaunches: true
        )

        let firstDecision = AppSettingsPersistence.consumeLaunchRefreshDecision(
            settings: settings,
            userDefaults: defaults,
            referenceDate: Date(timeIntervalSince1970: 1_000),
            systemUptime: 100
        )
        let subsequentDecision = AppSettingsPersistence.consumeLaunchRefreshDecision(
            settings: settings,
            userDefaults: defaults,
            referenceDate: Date(timeIntervalSince1970: 2_000),
            systemUptime: 1_100
        )

        XCTAssertEqual(firstDecision, LaunchRefreshDecision(kind: .firstLaunchAfterBoot, shouldRefresh: false))
        XCTAssertEqual(subsequentDecision, LaunchRefreshDecision(kind: .subsequentLaunch, shouldRefresh: true))
    }

    func testDefaultAutoSessionRefreshSettingsPreserveLaunchRefreshBehavior() {
        XCTAssertEqual(
            AutoSessionRefreshSettings.standard,
            AutoSessionRefreshSettings(
                cadence: .everyDay,
                deferWhileAppIsActive: false,
                refreshOnFirstLaunchAfterBoot: true,
                refreshOnSubsequentLaunches: false
            )
        )
    }

    func testLastSuccessfulRefreshDatePersistsAcrossSettingsStoreReload() {
        let suiteName = "AppSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let controller = MockLaunchAtLoginController(status: .notRegistered)
        let homeDirectory = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let refreshDate = Date(timeIntervalSince1970: 1_715_370_200)

        let store = AppSettingsStore(
            userDefaults: defaults,
            launchAtLoginController: controller,
            homeDirectoryURL: homeDirectory
        )
        store.recordLastSuccessfulRefreshDate(refreshDate)

        let reopenedStore = AppSettingsStore(
            userDefaults: defaults,
            launchAtLoginController: controller,
            homeDirectoryURL: homeDirectory
        )

        XCTAssertEqual(reopenedStore.lastSuccessfulRefreshDate(), refreshDate)
    }
}

private final class MockLaunchAtLoginController: LaunchAtLoginControlling {
    var status: LaunchAtLoginStatus
    var nextError: Error?

    init(status: LaunchAtLoginStatus, nextError: Error? = nil) {
        self.status = status
        self.nextError = nextError
    }

    func setEnabled(_ enabled: Bool) throws {
        if let nextError {
            throw nextError
        }
        status = enabled ? .enabled : .notRegistered
    }
}

private enum MockLaunchAtLoginError: LocalizedError {
    case enableFailed

    var errorDescription: String? {
        switch self {
        case .enableFailed:
            return "Enable failed."
        }
    }
}
