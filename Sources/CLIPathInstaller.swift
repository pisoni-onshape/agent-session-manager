import AppKit
import Foundation
import AgentSessionManagerCore

struct CLIPathInstallResult {
    let installedCommandURL: URL
    let bundledBinaryURL: URL
    let updatedShellProfileURL: URL?

    var successMessage: String {
        var lines = [
            "Installed `agent-session-manager` at \(installedCommandURL.path).",
            "It points to \(bundledBinaryURL.path)."
        ]
        if let updatedShellProfileURL {
            lines.append("Updated \(updatedShellProfileURL.path) to include $HOME/.local/bin on PATH. Open a new Terminal window or run `source \(updatedShellProfileURL.path)`.")
        }
        return lines.joined(separator: "\n")
    }
}

enum CLIPathInstallError: LocalizedError {
    case bundledCLIUnavailable(String)
    case destinationOccupied(String)

    var errorDescription: String? {
        switch self {
        case let .bundledCLIUnavailable(path):
            return "The bundled CLI helper is unavailable at \(path). Build the app again so the helper is copied into the app bundle."
        case let .destinationOccupied(path):
            return "Cannot install the CLI because \(path) already exists and is not a symlink managed by Agent Session Manager."
        }
    }
}

enum CLIPathInstaller {
    private static let commandName = "agent-session-manager"
    private static let helperRelativePath = "Contents/Helpers/AgentSessionManagerCLI"
    private static let managedPATHEntry = #"export PATH="$HOME/.local/bin:$PATH""#
    private static let managedProfileComment = "# Added by Agent Session Manager"

    static func installForCurrentUser(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectoryURL: URL = AppPaths.homeDirectory,
        appBundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) throws -> CLIPathInstallResult {
        let bundledBinaryURL = try bundledCLIExecutableURL(appBundleURL: appBundleURL, fileManager: fileManager)
        let installDirectoryURL = preferredInstallDirectory(
            environment: environment,
            homeDirectoryURL: homeDirectoryURL,
            fileManager: fileManager
        )

        try fileManager.createDirectory(at: installDirectoryURL, withIntermediateDirectories: true)
        let commandURL = installDirectoryURL.appendingPathComponent(commandName)
        try installSymlink(at: commandURL, target: bundledBinaryURL, fileManager: fileManager)

        var updatedShellProfileURL: URL?
        let userLocalBinURL = defaultUserInstallDirectory(homeDirectoryURL: homeDirectoryURL)
        if installDirectoryURL.standardizedFileURL == userLocalBinURL.standardizedFileURL,
           !pathContains(url: userLocalBinURL, environment: environment) {
            let profileURL = shellProfileURL(homeDirectoryURL: homeDirectoryURL)
            let didUpdateProfile = try ensureUserLocalBinOnPATH(
                profileURL: profileURL,
                fileManager: fileManager
            )
            if didUpdateProfile {
                updatedShellProfileURL = profileURL
            }
        }

        return CLIPathInstallResult(
            installedCommandURL: commandURL,
            bundledBinaryURL: bundledBinaryURL,
            updatedShellProfileURL: updatedShellProfileURL
        )
    }

    static func bundledCLIExecutableURL(
        appBundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let helperURL = appBundleURL.appendingPathComponent(helperRelativePath)
        guard fileManager.isExecutableFile(atPath: helperURL.path) else {
            throw CLIPathInstallError.bundledCLIUnavailable(helperURL.path)
        }
        return helperURL
    }

    private static func preferredInstallDirectory(
        environment: [String: String],
        homeDirectoryURL: URL,
        fileManager: FileManager
    ) -> URL {
        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) }

        for entry in pathEntries where entry.hasPrefix("/") {
            let url = URL(fileURLWithPath: entry, isDirectory: true)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            if fileManager.isWritableFile(atPath: url.path) {
                return url
            }
        }

        return defaultUserInstallDirectory(homeDirectoryURL: homeDirectoryURL)
    }

    private static func defaultUserInstallDirectory(homeDirectoryURL: URL) -> URL {
        homeDirectoryURL.appendingPathComponent(".local/bin", isDirectory: true)
    }

    private static func shellProfileURL(homeDirectoryURL: URL) -> URL {
        homeDirectoryURL.appendingPathComponent(".zprofile")
    }

    private static func pathContains(url: URL, environment: [String: String]) -> Bool {
        let normalizedTarget = url.standardizedFileURL.path
        return (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true).standardizedFileURL.path }
            .contains(normalizedTarget)
    }

    private static func ensureUserLocalBinOnPATH(
        profileURL: URL,
        fileManager: FileManager
    ) throws -> Bool {
        let existingContents: String
        if fileManager.fileExists(atPath: profileURL.path) {
            existingContents = try String(contentsOf: profileURL, encoding: .utf8)
            if existingContents.contains(managedPATHEntry) {
                return false
            }
        } else {
            existingContents = ""
        }

        var updatedContents = existingContents
        if !updatedContents.isEmpty, !updatedContents.hasSuffix("\n") {
            updatedContents += "\n"
        }
        updatedContents += "\(managedProfileComment)\n\(managedPATHEntry)\n"
        try updatedContents.write(to: profileURL, atomically: true, encoding: .utf8)
        return true
    }

    private static func installSymlink(
        at commandURL: URL,
        target bundledBinaryURL: URL,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: commandURL.path) {
            let resourceValues = try commandURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard resourceValues.isSymbolicLink == true else {
                throw CLIPathInstallError.destinationOccupied(commandURL.path)
            }

            let currentDestination = try fileManager.destinationOfSymbolicLink(atPath: commandURL.path)
            let currentDestinationURL = URL(
                fileURLWithPath: currentDestination,
                relativeTo: commandURL.deletingLastPathComponent()
            ).standardizedFileURL
            if currentDestinationURL == bundledBinaryURL.standardizedFileURL {
                return
            }
            try fileManager.removeItem(at: commandURL)
        }

        try fileManager.createSymbolicLink(at: commandURL, withDestinationURL: bundledBinaryURL)
    }
}
