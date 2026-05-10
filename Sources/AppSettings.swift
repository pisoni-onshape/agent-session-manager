import Combine
import Foundation
import ServiceManagement

enum AutoRefreshCadence: String, CaseIterable, Identifiable, Sendable {
    case off
    case every15Minutes
    case every30Minutes
    case every1Hour
    case every4Hours
    case everyDay
    case every7Days

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .every15Minutes:
            return "Every 15 minutes"
        case .every30Minutes:
            return "Every 30 minutes"
        case .every1Hour:
            return "Every 1 hour"
        case .every4Hours:
            return "Every 4 hours"
        case .everyDay:
            return "Every day"
        case .every7Days:
            return "Every 7 days"
        }
    }

    var timeInterval: TimeInterval? {
        switch self {
        case .off:
            return nil
        case .every15Minutes:
            return 15 * 60
        case .every30Minutes:
            return 30 * 60
        case .every1Hour:
            return 60 * 60
        case .every4Hours:
            return 4 * 60 * 60
        case .everyDay:
            return 24 * 60 * 60
        case .every7Days:
            return 7 * 24 * 60 * 60
        }
    }

    var intervalNanoseconds: UInt64? {
        guard let timeInterval else { return nil }
        return UInt64(timeInterval * 1_000_000_000)
    }
}

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

struct AppSettingsSnapshot: Equatable, Sendable {
    let newtonReposRootPath: String
    let autoRefreshCadence: AutoRefreshCadence

    static func defaultNewtonReposRootPath(homeDirectory: URL = AppPaths.homeDirectory) -> String {
        homeDirectory.appendingPathComponent("repos", isDirectory: true).path
    }

    static func normalizedNewtonReposRootPath(
        _ rawValue: String,
        homeDirectoryPath: String = AppPaths.homeDirectory.path
    ) -> String {
        PathUtilities.normalizedDirectoryPath(rawValue, homeDirectoryPath: homeDirectoryPath)
            ?? defaultNewtonReposRootPath(homeDirectory: URL(fileURLWithPath: homeDirectoryPath, isDirectory: true))
    }

    static func standard(homeDirectory: URL = AppPaths.homeDirectory) -> AppSettingsSnapshot {
        AppSettingsSnapshot(
            newtonReposRootPath: defaultNewtonReposRootPath(homeDirectory: homeDirectory),
            autoRefreshCadence: .off
        )
    }
}

@MainActor
final class AppSettingsStore: ObservableObject {
    private static let newtonReposRootPathKey = "settings.newtonReposRootPath"
    private static let autoRefreshCadenceKey = "settings.autoRefreshCadence"

    @Published private(set) var launchAtLoginEnabled: Bool = false
    @Published private(set) var launchAtLoginStatusDetail: String?
    @Published private(set) var launchAtLoginErrorMessage: String?
    @Published private(set) var newtonReposRootPath: String
    @Published private(set) var autoRefreshCadence: AutoRefreshCadence

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

        let homeDirectoryPath = homeDirectoryURL.path
        let defaultRootPath = AppSettingsSnapshot.defaultNewtonReposRootPath(homeDirectory: homeDirectoryURL)
        let storedRootPath = userDefaults.string(forKey: Self.newtonReposRootPathKey) ?? defaultRootPath
        let storedAutoRefreshCadence = userDefaults.string(forKey: Self.autoRefreshCadenceKey)

        self.newtonReposRootPath = AppSettingsSnapshot.normalizedNewtonReposRootPath(
            storedRootPath,
            homeDirectoryPath: homeDirectoryPath
        )
        self.autoRefreshCadence = AutoRefreshCadence(rawValue: storedAutoRefreshCadence ?? "") ?? .off

        userDefaults.set(self.newtonReposRootPath, forKey: Self.newtonReposRootPathKey)
        userDefaults.set(self.autoRefreshCadence.rawValue, forKey: Self.autoRefreshCadenceKey)

        refreshLaunchAtLoginStatus()
    }

    var snapshot: AppSettingsSnapshot {
        AppSettingsSnapshot(
            newtonReposRootPath: newtonReposRootPath,
            autoRefreshCadence: autoRefreshCadence
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
        userDefaults.set(normalizedPath, forKey: Self.newtonReposRootPathKey)
    }

    func setAutoRefreshCadence(_ cadence: AutoRefreshCadence) {
        guard cadence != autoRefreshCadence else { return }

        autoRefreshCadence = cadence
        userDefaults.set(cadence.rawValue, forKey: Self.autoRefreshCadenceKey)
    }
}
