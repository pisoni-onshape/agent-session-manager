import Combine
import Foundation
import ServiceManagement
import AgentSessionManagerCore

enum LaunchAtLoginStatus: Equatable, Sendable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound

    var detailText: String? {
        switch self {
        case .enabled, .notRegistered:
            return nil
        case .requiresApproval:
            return "Approval is required in System Settings > General > Login Items."
        case .notFound:
            return "Launch at Login is unavailable for this build."
        }
    }
}

protocol LaunchAtLoginControlling {
    var status: LaunchAtLoginStatus { get }
    func setEnabled(_ enabled: Bool) throws
}

struct SystemLaunchAtLoginController: LaunchAtLoginControlling {
    var status: LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .notFound
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

@MainActor
final class AppSettingsStore: ObservableObject {
    @Published private(set) var launchAtLoginEnabled: Bool = false
    @Published private(set) var launchAtLoginStatusDetail: String?
    @Published private(set) var launchAtLoginErrorMessage: String?
    @Published private(set) var newtonReposRootPath: String
    @Published private(set) var autoRefreshCadence: AutoRefreshCadence
    @Published private(set) var refreshOnFirstLaunchAfterBoot: Bool
    @Published private(set) var refreshOnSubsequentLaunches: Bool

    private let userDefaults: UserDefaults
    private let launchAtLoginController: any LaunchAtLoginControlling
    private let homeDirectoryURL: URL

    init(
        userDefaults: UserDefaults = .standard,
        launchAtLoginController: any LaunchAtLoginControlling = SystemLaunchAtLoginController(),
        homeDirectoryURL: URL = AppPaths.homeDirectory
    ) {
        self.userDefaults = userDefaults
        self.launchAtLoginController = launchAtLoginController
        self.homeDirectoryURL = homeDirectoryURL

        let snapshot = AppSettingsPersistence.loadSnapshot(
            userDefaults: userDefaults,
            homeDirectoryURL: homeDirectoryURL
        )

        self.newtonReposRootPath = snapshot.newtonReposRootPath
        self.autoRefreshCadence = snapshot.autoSessionRefresh.cadence
        self.refreshOnFirstLaunchAfterBoot = snapshot.autoSessionRefresh.refreshOnFirstLaunchAfterBoot
        self.refreshOnSubsequentLaunches = snapshot.autoSessionRefresh.refreshOnSubsequentLaunches

        userDefaults.set(self.newtonReposRootPath, forKey: AppSettingsPersistence.newtonReposRootPathKey)
        userDefaults.set(self.autoRefreshCadence.rawValue, forKey: AppSettingsPersistence.autoRefreshCadenceKey)
        userDefaults.set(
            self.refreshOnFirstLaunchAfterBoot,
            forKey: AppSettingsPersistence.refreshOnFirstLaunchAfterBootKey
        )
        userDefaults.set(
            self.refreshOnSubsequentLaunches,
            forKey: AppSettingsPersistence.refreshOnSubsequentLaunchesKey
        )

        refreshLaunchAtLoginStatus()
    }

    var snapshot: AppSettingsSnapshot {
        AppSettingsSnapshot(
            newtonReposRootPath: newtonReposRootPath,
            autoSessionRefresh: autoSessionRefreshSettings
        )
    }

    var autoSessionRefreshSettings: AutoSessionRefreshSettings {
        AutoSessionRefreshSettings(
            cadence: autoRefreshCadence,
            refreshOnFirstLaunchAfterBoot: refreshOnFirstLaunchAfterBoot,
            refreshOnSubsequentLaunches: refreshOnSubsequentLaunches
        )
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            try launchAtLoginController.setEnabled(enabled)
            launchAtLoginErrorMessage = nil
        } catch {
            launchAtLoginErrorMessage = error.localizedDescription
        }

        refreshLaunchAtLoginStatus()
    }

    func refreshLaunchAtLoginStatus() {
        let status = launchAtLoginController.status
        launchAtLoginEnabled = status == .enabled
        launchAtLoginStatusDetail = status.detailText
    }

    func setNewtonReposRootPath(_ rawValue: String) {
        let normalizedPath = AppSettingsSnapshot.normalizedNewtonReposRootPath(
            rawValue,
            homeDirectoryPath: homeDirectoryURL.path
        )
        guard normalizedPath != newtonReposRootPath else { return }

        newtonReposRootPath = normalizedPath
        userDefaults.set(normalizedPath, forKey: AppSettingsPersistence.newtonReposRootPathKey)
    }

    func setAutoRefreshCadence(_ cadence: AutoRefreshCadence) {
        guard cadence != autoRefreshCadence else { return }

        autoRefreshCadence = cadence
        userDefaults.set(cadence.rawValue, forKey: AppSettingsPersistence.autoRefreshCadenceKey)
    }

    func setRefreshOnFirstLaunchAfterBoot(_ enabled: Bool) {
        guard enabled != refreshOnFirstLaunchAfterBoot else { return }

        refreshOnFirstLaunchAfterBoot = enabled
        userDefaults.set(enabled, forKey: AppSettingsPersistence.refreshOnFirstLaunchAfterBootKey)
    }

    func setRefreshOnSubsequentLaunches(_ enabled: Bool) {
        guard enabled != refreshOnSubsequentLaunches else { return }

        refreshOnSubsequentLaunches = enabled
        userDefaults.set(enabled, forKey: AppSettingsPersistence.refreshOnSubsequentLaunchesKey)
    }

    func consumeLaunchRefreshDecision(
        referenceDate: Date = Date(),
        systemUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> LaunchRefreshDecision {
        AppSettingsPersistence.consumeLaunchRefreshDecision(
            settings: autoSessionRefreshSettings,
            userDefaults: userDefaults,
            referenceDate: referenceDate,
            systemUptime: systemUptime
        )
    }
}
