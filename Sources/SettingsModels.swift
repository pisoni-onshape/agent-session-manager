import Foundation

public enum AutoRefreshCadence: String, CaseIterable, Identifiable, Sendable {
    case off
    case every15Minutes
    case every30Minutes
    case every1Hour
    case every4Hours
    case everyDay
    case every7Days

    public var id: String { rawValue }

    public var displayName: String {
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

    public var timeInterval: TimeInterval? {
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

    public var intervalNanoseconds: UInt64? {
        guard let timeInterval else { return nil }
        return UInt64(timeInterval * 1_000_000_000)
    }
}

public struct AutoSessionRefreshSettings: Equatable, Sendable {
    public let cadence: AutoRefreshCadence
    public let deferWhileAppIsActive: Bool
    public let refreshOnFirstLaunchAfterBoot: Bool
    public let refreshOnSubsequentLaunches: Bool

    public init(
        cadence: AutoRefreshCadence,
        deferWhileAppIsActive: Bool,
        refreshOnFirstLaunchAfterBoot: Bool,
        refreshOnSubsequentLaunches: Bool
    ) {
        self.cadence = cadence
        self.deferWhileAppIsActive = deferWhileAppIsActive
        self.refreshOnFirstLaunchAfterBoot = refreshOnFirstLaunchAfterBoot
        self.refreshOnSubsequentLaunches = refreshOnSubsequentLaunches
    }

    public static let standard = AutoSessionRefreshSettings(
        cadence: .every15Minutes,
        deferWhileAppIsActive: true,
        refreshOnFirstLaunchAfterBoot: true,
        refreshOnSubsequentLaunches: false
    )
}

public enum LaunchRefreshKind: Equatable, Sendable {
    case firstLaunchAfterBoot
    case subsequentLaunch
}

public struct LaunchRefreshDecision: Equatable, Sendable {
    public let kind: LaunchRefreshKind
    public let shouldRefresh: Bool

    public init(kind: LaunchRefreshKind, shouldRefresh: Bool) {
        self.kind = kind
        self.shouldRefresh = shouldRefresh
    }
}

public struct AppSettingsSnapshot: Equatable, Sendable {
    public let newtonReposRootPath: String
    public let autoSessionRefresh: AutoSessionRefreshSettings

    public init(newtonReposRootPath: String, autoSessionRefresh: AutoSessionRefreshSettings) {
        self.newtonReposRootPath = newtonReposRootPath
        self.autoSessionRefresh = autoSessionRefresh
    }

    public static func defaultNewtonReposRootPath(homeDirectory: URL = AppPaths.homeDirectory) -> String {
        homeDirectory.appendingPathComponent("repos", isDirectory: true).path
    }

    public static func normalizedNewtonReposRootPath(
        _ rawValue: String,
        homeDirectoryPath: String = AppPaths.homeDirectory.path
    ) -> String {
        PathUtilities.normalizedDirectoryPath(rawValue, homeDirectoryPath: homeDirectoryPath)
            ?? defaultNewtonReposRootPath(homeDirectory: URL(fileURLWithPath: homeDirectoryPath, isDirectory: true))
    }

    public static func standard(homeDirectory: URL = AppPaths.homeDirectory) -> AppSettingsSnapshot {
        AppSettingsSnapshot(
            newtonReposRootPath: defaultNewtonReposRootPath(homeDirectory: homeDirectory),
            autoSessionRefresh: .standard
        )
    }
}

public enum AppSettingsPersistence {
    public static let newtonReposRootPathKey = "settings.newtonReposRootPath"
    public static let autoRefreshCadenceKey = "settings.autoRefreshCadence"
    public static let deferRefreshWhileAppIsActiveKey = "settings.deferRefreshWhileAppIsActive"
    public static let refreshOnFirstLaunchAfterBootKey = "settings.refreshOnFirstLaunchAfterBoot"
    public static let refreshOnSubsequentLaunchesKey = "settings.refreshOnSubsequentLaunches"
    public static let lastSeenBootIdentifierKey = "settings.lastSeenBootIdentifier"
    public static let lastSuccessfulRefreshDateKey = "settings.lastSuccessfulRefreshDate"

    public static func currentBootIdentifier(
        referenceDate: Date = Date(),
        systemUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> String {
        String(Int((referenceDate.timeIntervalSince1970 - systemUptime).rounded(.down)))
    }

    public static func loadSnapshot(
        userDefaults: UserDefaults = .standard,
        homeDirectoryURL: URL = AppPaths.homeDirectory
    ) -> AppSettingsSnapshot {
        let homeDirectoryPath = homeDirectoryURL.path
        let defaultRootPath = AppSettingsSnapshot.defaultNewtonReposRootPath(homeDirectory: homeDirectoryURL)
        let storedRootPath = userDefaults.string(forKey: newtonReposRootPathKey) ?? defaultRootPath
        let storedAutoRefreshCadence = userDefaults.string(forKey: autoRefreshCadenceKey)
        let deferWhileAppIsActive = userDefaults.object(forKey: deferRefreshWhileAppIsActiveKey) as? Bool
            ?? AutoSessionRefreshSettings.standard.deferWhileAppIsActive
        let refreshOnFirstLaunchAfterBoot = userDefaults.object(forKey: refreshOnFirstLaunchAfterBootKey) as? Bool
            ?? AutoSessionRefreshSettings.standard.refreshOnFirstLaunchAfterBoot
        let refreshOnSubsequentLaunches = userDefaults.object(forKey: refreshOnSubsequentLaunchesKey) as? Bool
            ?? AutoSessionRefreshSettings.standard.refreshOnSubsequentLaunches

        return AppSettingsSnapshot(
            newtonReposRootPath: AppSettingsSnapshot.normalizedNewtonReposRootPath(
                storedRootPath,
                homeDirectoryPath: homeDirectoryPath
            ),
            autoSessionRefresh: AutoSessionRefreshSettings(
                cadence: storedAutoRefreshCadence.flatMap(AutoRefreshCadence.init(rawValue:))
                    ?? AutoSessionRefreshSettings.standard.cadence,
                deferWhileAppIsActive: deferWhileAppIsActive,
                refreshOnFirstLaunchAfterBoot: refreshOnFirstLaunchAfterBoot,
                refreshOnSubsequentLaunches: refreshOnSubsequentLaunches
            )
        )
    }

    public static func consumeLaunchRefreshDecision(
        settings: AutoSessionRefreshSettings,
        userDefaults: UserDefaults = .standard,
        referenceDate: Date = Date(),
        systemUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> LaunchRefreshDecision {
        let bootIdentifier = currentBootIdentifier(referenceDate: referenceDate, systemUptime: systemUptime)
        let lastSeenBootIdentifier = userDefaults.string(forKey: lastSeenBootIdentifierKey)
        let kind: LaunchRefreshKind = lastSeenBootIdentifier == bootIdentifier ? .subsequentLaunch : .firstLaunchAfterBoot

        userDefaults.set(bootIdentifier, forKey: lastSeenBootIdentifierKey)

        let shouldRefresh: Bool
        switch kind {
        case .firstLaunchAfterBoot:
            shouldRefresh = settings.refreshOnFirstLaunchAfterBoot
        case .subsequentLaunch:
            shouldRefresh = settings.refreshOnSubsequentLaunches
        }

        return LaunchRefreshDecision(kind: kind, shouldRefresh: shouldRefresh)
    }

    public static func loadLastSuccessfulRefreshDate(
        userDefaults: UserDefaults = .standard
    ) -> Date? {
        userDefaults.object(forKey: lastSuccessfulRefreshDateKey) as? Date
    }

    public static func recordLastSuccessfulRefreshDate(
        _ date: Date,
        userDefaults: UserDefaults = .standard
    ) {
        userDefaults.set(date, forKey: lastSuccessfulRefreshDateKey)
    }
}
