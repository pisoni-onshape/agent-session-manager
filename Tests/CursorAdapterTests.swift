import Foundation
import XCTest
@testable import AgentSessionManager

final class CursorAdapterTests: XCTestCase {
    func testCursorAdapterUsesWorkspaceStorageMetadataForCanonicalWorkspaceName() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let projectsRoot = directory.appendingPathComponent(".cursor/projects", isDirectory: true)
        let workspaceStorageRoot = directory.appendingPathComponent("Cursor/User/workspaceStorage", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceStorageRoot, withIntermediateDirectories: true)

        let workspacePath = "/Users/pisoni/Library/CloudStorage/OneDrive-PTC/Projects/newton-env-manager"
        let projectDirectory = projectsRoot.appendingPathComponent(
            "Users-pisoni-Library-CloudStorage-OneDrive-PTC-Projects-newton-env-manager",
            isDirectory: true
        )
        let sessionDirectory = projectDirectory.appendingPathComponent("agent-transcripts/session-1", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try """
        {"role":"user","message":{"content":[{"type":"text","text":"Explain the terminal behavior."}]}}
        {"role":"assistant","message":{"content":[{"type":"text","text":"I’ll inspect the workspace metadata path."}]}}
        """.write(
            to: sessionDirectory.appendingPathComponent("session-1.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let workspaceDirectory = workspaceStorageRoot.appendingPathComponent("3303167c120fc2f8eb2bf262a31d5cc4", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        try """
        {
          "folder": "file:///Users/pisoni/Library/CloudStorage/OneDrive-PTC/Projects/newton-env-manager"
        }
        """.write(
            to: workspaceDirectory.appendingPathComponent("workspace.json"),
            atomically: true,
            encoding: .utf8
        )

        let records = try CursorAdapter(root: projectsRoot, workspaceStorageRoot: workspaceStorageRoot).discover()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].workspacePath, workspacePath)
        XCTAssertEqual(records[0].projectName, "newton-env-manager")
        XCTAssertEqual(records[0].resumeKind, .openInCursor)
        XCTAssertEqual(records[0].resumePayload, workspacePath)
    }

    func testCursorAdapterFallsBackToProjectSlugWithoutWorkspaceMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let projectsRoot = directory.appendingPathComponent(".cursor/projects", isDirectory: true)
        let workspaceStorageRoot = directory.appendingPathComponent("Cursor/User/workspaceStorage", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceStorageRoot, withIntermediateDirectories: true)

        let projectDirectory = projectsRoot.appendingPathComponent(
            "Users-pisoni-Development-LocalProjects-nonexistent-demo-app",
            isDirectory: true
        )
        let sessionDirectory = projectDirectory.appendingPathComponent("agent-transcripts/session-2", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try """
        {"role":"user","message":{"content":[{"type":"text","text":"Summarize the filters."}]}}
        {"role":"assistant","message":{"content":[{"type":"text","text":"I’ll review the filter UI next."}]}}
        """.write(
            to: sessionDirectory.appendingPathComponent("session-2.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let records = try CursorAdapter(root: projectsRoot, workspaceStorageRoot: workspaceStorageRoot).discover()

        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records[0].workspacePath)
        XCTAssertEqual(records[0].projectName, "nonexistent-demo-app")
        XCTAssertEqual(records[0].resumeKind, .revealPath)
    }
}
