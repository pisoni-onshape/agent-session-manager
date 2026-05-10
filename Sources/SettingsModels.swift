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

public struct AppSettingsSnapshot: Equatable, Sendable {
    public let newtonReposRootPath: String
    public let autoRefreshCadence: AutoRefreshCadence

    public init(newtonReposRootPath: String, autoRefreshCadence: AutoRefreshCadence) {
        self.newtonReposRootPath = newtonReposRootPath
        self.autoRefreshCadence = autoRefreshCadence
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
            autoRefreshCadence: .off
        )
    }
}
