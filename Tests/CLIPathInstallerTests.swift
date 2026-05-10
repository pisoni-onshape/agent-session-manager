import Foundation
import XCTest
@testable import AgentSessionManager

final class CLIPathInstallerTests: XCTestCase {
    func testInstallerFallsBackToUserLocalBinAndUpdatesZProfile() throws {
        let homeDirectory = temporaryDirectory()
        let appBundleURL = try makeAppBundle(in: homeDirectory)

        let result = try CLIPathInstaller.installForCurrentUser(
            environment: ["PATH": "/usr/bin:/bin"],
            homeDirectoryURL: homeDirectory,
            appBundleURL: appBundleURL
        )

        XCTAssertEqual(result.installedCommandURL.path, homeDirectory.appendingPathComponent(".local/bin/agent-session-manager").path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: result.installedCommandURL.path), result.bundledBinaryURL.path)
        XCTAssertEqual(result.updatedShellProfileURL?.path, homeDirectory.appendingPathComponent(".zprofile").path)
        XCTAssertTrue((try String(contentsOf: result.updatedShellProfileURL!, encoding: .utf8)).contains(#"export PATH="$HOME/.local/bin:$PATH""#))
    }

    func testInstallerUsesWritablePathDirectoryWithoutTouchingShellProfile() throws {
        let homeDirectory = temporaryDirectory()
        let writableBinURL = homeDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: writableBinURL, withIntermediateDirectories: true)
        let appBundleURL = try makeAppBundle(in: homeDirectory)

        let result = try CLIPathInstaller.installForCurrentUser(
            environment: ["PATH": writableBinURL.path],
            homeDirectoryURL: homeDirectory,
            appBundleURL: appBundleURL
        )

        XCTAssertEqual(result.installedCommandURL.path, writableBinURL.appendingPathComponent("agent-session-manager").path)
        XCTAssertNil(result.updatedShellProfileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: homeDirectory.appendingPathComponent(".zprofile").path))
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeAppBundle(in homeDirectory: URL) throws -> URL {
        let bundleURL = homeDirectory.appendingPathComponent("AgentSessionManager.app", isDirectory: true)
        let helperURL = bundleURL.appendingPathComponent("Contents/Helpers/AgentSessionManagerCLI")
        try FileManager.default.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
        return bundleURL
    }
}
