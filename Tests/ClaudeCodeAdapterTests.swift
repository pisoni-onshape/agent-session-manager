import Foundation
import XCTest
@testable import AgentSessionManagerCore

final class ClaudeCodeAdapterTests: XCTestCase {
    // MARK: - Fixture helpers

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func jsonLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        // Real Claude Code JSONL (written by Node's JSON.stringify) does not escape forward
        // slashes; JSONSerialization does. Unescape so fixtures match on-disk files.
        return String(data: data, encoding: .utf8)!.replacingOccurrences(of: "\\/", with: "/")
    }

    @discardableResult
    private func writeSession(
        root: URL,
        projectFolder: String,
        sessionId: String,
        records: [[String: Any]]
    ) throws -> URL {
        let projectDir = root.appendingPathComponent(projectFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let fileURL = projectDir.appendingPathComponent("\(sessionId).jsonl")
        let contents = records.map(jsonLine).joined(separator: "\n")
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private func userRecord(
        entrypoint: String? = nil,
        text: Any,
        cwd: String = "/Users/pisoni/repos/newton3",
        branch: String = "main",
        timestamp: String = "2026-07-01T10:00:00.000Z",
        isMeta: Bool = false
    ) -> [String: Any] {
        var object: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": text],
            "cwd": cwd,
            "gitBranch": branch,
            "timestamp": timestamp,
            "uuid": UUID().uuidString
        ]
        if let entrypoint { object["entrypoint"] = entrypoint }
        if isMeta { object["isMeta"] = true }
        return object
    }

    private func assistantRecord(
        entrypoint: String? = nil,
        content: Any,
        model: String = "claude-opus-4-8",
        cwd: String = "/Users/pisoni/repos/newton3",
        branch: String = "main",
        timestamp: String = "2026-07-01T10:05:00.000Z"
    ) -> [String: Any] {
        var object: [String: Any] = [
            "type": "assistant",
            "message": ["role": "assistant", "model": model, "content": content],
            "cwd": cwd,
            "gitBranch": branch,
            "timestamp": timestamp,
            "uuid": UUID().uuidString
        ]
        if let entrypoint { object["entrypoint"] = entrypoint }
        return object
    }

    // MARK: - Classification

    func testClassifiesCLISessionWithResumeAction() throws {
        let root = try makeRoot()
        let sessionId = "11111111-1111-1111-1111-111111111111"
        try writeSession(
            root: root,
            projectFolder: "-Users-pisoni-repos-newton3",
            sessionId: sessionId,
            records: [
                ["type": "mode", "mode": "normal", "sessionId": sessionId],
                userRecord(entrypoint: "cli", text: "Fix the failing sketch test."),
                assistantRecord(content: [["type": "text", "text": "On it."]])
            ]
        )

        let records = try ClaudeCodeAdapter(root: root).discover()

        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.source, .claudeCodeCLI)
        XCTAssertEqual(record.sourceSessionId, sessionId)
        XCTAssertEqual(record.workspacePath, "/Users/pisoni/repos/newton3")
        XCTAssertEqual(record.projectName, "newton3")
        XCTAssertEqual(record.branch, "main")
        XCTAssertEqual(record.conversationModel, "claude-opus-4-8")
        XCTAssertEqual(record.title, "Fix the failing sketch test.")
        XCTAssertEqual(record.firstUserPreview, "Fix the failing sketch test.")
        XCTAssertEqual(record.resumeKind, .claudeResume)
        XCTAssertEqual(record.resumePayload, sessionId)
    }

    func testClassifiesVSCodeSessionOpensWorkspace() throws {
        let root = try makeRoot()
        let sessionId = "22222222-2222-2222-2222-222222222222"
        try writeSession(
            root: root,
            projectFolder: "-Users-pisoni-repos-newton2",
            sessionId: sessionId,
            records: [
                userRecord(entrypoint: "claude-vscode", text: "Explain this module.", cwd: "/Users/pisoni/repos/newton2"),
                assistantRecord(content: [["type": "text", "text": "Sure."]], cwd: "/Users/pisoni/repos/newton2")
            ]
        )

        let record = try XCTUnwrap(try ClaudeCodeAdapter(root: root).discover().first)
        XCTAssertEqual(record.source, .claudeCodeVSCode)
        XCTAssertEqual(record.resumeKind, .openInVSCode)
        XCTAssertEqual(record.resumePayload, "/Users/pisoni/repos/newton2")
    }

    func testClassifiesDesktopSessionResumesInClaudeDesktop() throws {
        let root = try makeRoot()
        let sessionId = "33333333-3333-3333-3333-333333333333"
        try writeSession(
            root: root,
            projectFolder: "-Users-pisoni-repos-newton3",
            sessionId: sessionId,
            records: [
                userRecord(entrypoint: "claude-desktop", text: "How do skills load?"),
                assistantRecord(content: [["type": "text", "text": "Skills load from ~/.agents."]])
            ]
        )

        let record = try XCTUnwrap(try ClaudeCodeAdapter(root: root).discover().first)
        XCTAssertEqual(record.source, .claudeDesktop)
        XCTAssertEqual(record.resumeKind, .resumeInClaudeDesktop)
        XCTAssertEqual(record.resumePayload, sessionId)
    }

    func testDesktopSessionPrefersDesktopMetadataTitleAndRenameRoundTrips() throws {
        let root = try makeRoot()
        let sessionId = "ffffffff-ffff-ffff-ffff-ffffffffffff"
        try writeSession(
            root: root,
            projectFolder: "-Users-pisoni-repos-newton3",
            sessionId: sessionId,
            records: [
                userRecord(entrypoint: "claude-desktop", text: "Pre-allow safe tools."),
                assistantRecord(content: [["type": "text", "text": "Here is a list."]]),
                ["type": "ai-title", "aiTitle": "Configure safe tools and terminal commands", "sessionId": sessionId]
            ]
        )

        // Desktop metadata store: title differs from the JSONL ai-title (as the real app behaves).
        let desktopRoot = root.deletingLastPathComponent().appendingPathComponent("claude-code-sessions", isDirectory: true)
        let metaDir = desktopRoot.appendingPathComponent("acct/workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)
        let metaURL = metaDir.appendingPathComponent("local_abc.json")
        try jsonLine([
            "sessionId": "local_abc",
            "cliSessionId": sessionId,
            "title": "Safe tools and commands allowlist",
            "titleSource": "auto"
        ]).write(to: metaURL, atomically: true, encoding: .utf8)

        let adapter = ClaudeCodeAdapter(root: root, desktopSessionsRoot: desktopRoot)
        let record = try XCTUnwrap(try adapter.discover().first)
        XCTAssertEqual(record.title, "Safe tools and commands allowlist")
        XCTAssertEqual(
            record.rawMetadataPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            metaURL.standardizedFileURL.path
        )

        // Rename writes back to the Desktop metadata JSON (title + titleSource=user) and is re-read.
        XCTAssertTrue(ClaudeCodeAdapter.updateDesktopTitle(atMetadataPath: metaURL.path, title: "My Desktop rename"))
        let renamed = try XCTUnwrap(try adapter.discover().first)
        XCTAssertEqual(renamed.title, "My Desktop rename")

        let reloaded = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as? [String: Any])
        XCTAssertEqual(reloaded["title"] as? String, "My Desktop rename")
        XCTAssertEqual(reloaded["titleSource"] as? String, "user")
        XCTAssertEqual(reloaded["cliSessionId"] as? String, sessionId, "other fields preserved")
    }

    func testSkipsSDKAndUnknownEntrypoints() throws {
        let root = try makeRoot()
        try writeSession(
            root: root,
            projectFolder: "-Users-pisoni-repos-newton3",
            sessionId: "44444444-4444-4444-4444-444444444444",
            records: [
                userRecord(entrypoint: "sdk-ts", text: "Automated agent run."),
                assistantRecord(content: [["type": "text", "text": "Done."]])
            ]
        )
        try writeSession(
            root: root,
            projectFolder: "-Users-pisoni-repos-newton3",
            sessionId: "55555555-5555-5555-5555-555555555555",
            records: [
                userRecord(entrypoint: "future-surface", text: "Unknown surface."),
                assistantRecord(content: [["type": "text", "text": "Done."]])
            ]
        )

        XCTAssertTrue(try ClaudeCodeAdapter(root: root).discover().isEmpty)
    }

    // MARK: - Guards

    func testIgnoresSubagentSubdirectories() throws {
        let root = try makeRoot()
        let sessionId = "66666666-6666-6666-6666-666666666666"
        try writeSession(
            root: root,
            projectFolder: "-Users-pisoni-repos-newton3",
            sessionId: sessionId,
            records: [
                userRecord(entrypoint: "cli", text: "Main session prompt."),
                assistantRecord(content: [["type": "text", "text": "Reply."]])
            ]
        )

        // A `<uuid>/subagents/*.jsonl` sidecar must never be treated as a session.
        let subagentDir = root
            .appendingPathComponent("-Users-pisoni-repos-newton3", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagentDir, withIntermediateDirectories: true)
        try jsonLine(userRecord(entrypoint: "cli", text: "Subagent prompt."))
            .write(to: subagentDir.appendingPathComponent("agent-abc.jsonl"), atomically: true, encoding: .utf8)

        let records = try ClaudeCodeAdapter(root: root).discover()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.sourceSessionId, sessionId)
    }

    func testDropsSessionsWithoutUserOrAssistantMessage() throws {
        let root = try makeRoot()
        try writeSession(
            root: root,
            projectFolder: "-Users-pisoni-repos-newton3",
            sessionId: "77777777-7777-7777-7777-777777777777",
            records: [
                ["type": "system", "entrypoint": "cli", "content": "session bootstrap", "timestamp": "2026-07-01T10:00:00.000Z"]
            ]
        )

        XCTAssertTrue(try ClaudeCodeAdapter(root: root).discover().isEmpty)
    }

    // MARK: - Titles

    func testTitleSkipsInjectedWrapperTurns() throws {
        let root = try makeRoot()
        try writeSession(
            root: root,
            projectFolder: "-Users-pisoni-repos-newton3",
            sessionId: "88888888-8888-8888-8888-888888888888",
            records: [
                userRecord(entrypoint: "cli", text: "<command-name>/model</command-name>", isMeta: false),
                userRecord(text: "<local-command-stdout>Set model to Fable 5</local-command-stdout>"),
                userRecord(text: "Refactor the transcript parser, please."),
                assistantRecord(content: [["type": "text", "text": "Sure."]])
            ]
        )

        let record = try XCTUnwrap(try ClaudeCodeAdapter(root: root).discover().first)
        XCTAssertEqual(record.title, "Refactor the transcript parser, please.")
        XCTAssertEqual(record.firstUserPreview, "Refactor the transcript parser, please.")
    }

    func testPrefersStoredSessionTitlesOverFirstPrompt() throws {
        let root = try makeRoot()

        // ai-title present, no custom-title -> uses the AI title.
        try writeSession(
            root: root,
            projectFolder: "-Users-pisoni-repos-newton3",
            sessionId: "cccccccc-cccc-cccc-cccc-cccccccccccc",
            records: [
                userRecord(entrypoint: "cli", text: "Please add a force-move for incomplete Excel tasks."),
                assistantRecord(content: [["type": "text", "text": "Sure."]]),
                ["type": "ai-title", "aiTitle": "Add force move for incomplete Excel tasks", "sessionId": "cccccccc-cccc-cccc-cccc-cccccccccccc"]
            ]
        )

        // custom-title outranks ai-title.
        try writeSession(
            root: root,
            projectFolder: "-Users-pisoni-repos-newton3",
            sessionId: "dddddddd-dddd-dddd-dddd-dddddddddddd",
            records: [
                userRecord(entrypoint: "cli", text: "How do I find out which skills are loaded?"),
                assistantRecord(content: [["type": "text", "text": "Run /status."]]),
                ["type": "ai-title", "aiTitle": "Listing loaded skills", "sessionId": "dddddddd-dddd-dddd-dddd-dddddddddddd"],
                ["type": "custom-title", "customTitle": "Loaded Skills test", "sessionId": "dddddddd-dddd-dddd-dddd-dddddddddddd"]
            ]
        )

        let records = try ClaudeCodeAdapter(root: root).discover()
        let byId = Dictionary(uniqueKeysWithValues: records.map { ($0.sourceSessionId, $0) })
        XCTAssertEqual(byId["cccccccc-cccc-cccc-cccc-cccccccccccc"]?.title, "Add force move for incomplete Excel tasks")
        XCTAssertEqual(byId["dddddddd-dddd-dddd-dddd-dddddddddddd"]?.title, "Loaded Skills test")
    }

    func testRenameAppendsCustomTitleAndIsPickedUp() throws {
        let root = try makeRoot()
        let sessionId = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
        let fileURL = try writeSession(
            root: root,
            projectFolder: "-Users-pisoni-repos-newton3",
            sessionId: sessionId,
            records: [
                userRecord(entrypoint: "cli", text: "Original prompt."),
                assistantRecord(content: [["type": "text", "text": "ok"]]),
                ["type": "ai-title", "aiTitle": "Original AI title", "sessionId": sessionId]
            ]
        )

        let before = try XCTUnwrap(try ClaudeCodeAdapter(root: root).discover().first)
        XCTAssertEqual(before.title, "Original AI title")

        XCTAssertTrue(ClaudeCodeAdapter.appendClaudeCustomTitle(at: fileURL.path, sessionId: sessionId, title: "My renamed session"))

        let after = try XCTUnwrap(try ClaudeCodeAdapter(root: root).discover().first)
        XCTAssertEqual(after.title, "My renamed session")
        XCTAssertEqual(after.sourceSessionId, sessionId)
    }

    func testRenameSupportedForClaudeAndCopilotOnly() {
        XCTAssertTrue(SessionSource.claudeCodeCLI.supportsRename)
        XCTAssertTrue(SessionSource.claudeCodeVSCode.supportsRename)
        XCTAssertTrue(SessionSource.claudeDesktop.supportsRename)
        XCTAssertTrue(SessionSource.copilotCLI.supportsRename)
        XCTAssertFalse(SessionSource.cursor.supportsRename)
        XCTAssertFalse(SessionSource.vscodeCopilot.supportsRename)
    }

    // MARK: - Plan derivation

    func testDerivesPlanPathFromTranscriptWhenFileExists() throws {
        let root = try makeRoot()
        let plansDir = root.deletingLastPathComponent().appendingPathComponent(".claude/plans", isDirectory: true)
        try FileManager.default.createDirectory(at: plansDir, withIntermediateDirectories: true)
        let planURL = plansDir.appendingPathComponent("cool-plan-happy-turing.md")
        try "# Plan\n\nDo the thing.".write(to: planURL, atomically: true, encoding: .utf8)

        try writeSession(
            root: root,
            projectFolder: "-Users-pisoni-repos-newton3",
            sessionId: "99999999-9999-9999-9999-999999999999",
            records: [
                userRecord(entrypoint: "cli", text: "Please plan this out."),
                assistantRecord(content: [["type": "text", "text": "You should create your plan at \(planURL.path)"]])
            ]
        )

        let record = try XCTUnwrap(try ClaudeCodeAdapter(root: root).discover().first)
        XCTAssertEqual(
            record.relatedPlanPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            planURL.standardizedFileURL.path
        )
    }

    func testPlanPathNilWhenReferencedFileMissing() throws {
        let root = try makeRoot()
        let missingPlan = root.deletingLastPathComponent().appendingPathComponent(".claude/plans/absent.md")

        try writeSession(
            root: root,
            projectFolder: "-Users-pisoni-repos-newton3",
            sessionId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            records: [
                userRecord(entrypoint: "cli", text: "Plan referencing \(missingPlan.path)"),
                assistantRecord(content: [["type": "text", "text": "Okay."]])
            ]
        )

        let record = try XCTUnwrap(try ClaudeCodeAdapter(root: root).discover().first)
        XCTAssertNil(record.relatedPlanPath)
    }

    func testPlanPathPrefersMostRecentExistingReferenceOverLaterMissingOne() throws {
        let root = try makeRoot()
        let plansDir = root.deletingLastPathComponent().appendingPathComponent(".claude/plans", isDirectory: true)
        try FileManager.default.createDirectory(at: plansDir, withIntermediateDirectories: true)
        let realPlan = plansDir.appendingPathComponent("real-plan.md")
        try "# Plan".write(to: realPlan, atomically: true, encoding: .utf8)
        let missingPlan = plansDir.appendingPathComponent("example-only.md")

        try writeSession(
            root: root,
            projectFolder: "-Users-pisoni-repos-newton3",
            sessionId: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            records: [
                userRecord(entrypoint: "cli", text: "Create your plan at \(realPlan.path)"),
                // A later record mentions an example path that was never written.
                assistantRecord(content: [["type": "text", "text": "For example a plan could live at \(missingPlan.path)"]])
            ]
        )

        let record = try XCTUnwrap(try ClaudeCodeAdapter(root: root).discover().first)
        XCTAssertEqual(
            record.relatedPlanPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            realPlan.standardizedFileURL.path
        )
    }
}
