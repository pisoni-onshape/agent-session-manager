import XCTest
@testable import AgentSessionManagerCore

final class WorkspaceLauncherTests: XCTestCase {
    func testCopilotNewConversationCommandUsesWorkspaceDirectory() {
        XCTAssertEqual(
            WorkspaceLauncher.copilotNewConversationCommand(workingDirectory: "/tmp/Project's Folder"),
            "cd '/tmp/Project'\\''s Folder' && copilot"
        )
    }

    func testCopilotResumeCommandIncludesWorkspaceDirectory() {
        let record = SessionRecord(
            source: .copilotCLI,
            sourceSessionId: "session-123",
            workspacePath: "/tmp/My Project",
            projectName: "My Project",
            branch: "main",
            conversationModel: "gpt-5.4",
            startedAt: nil,
            updatedAt: nil,
            title: "Resume command",
            summary: nil,
            firstUserPreview: nil,
            firstAssistantPreview: nil,
            rawTranscriptPath: nil,
            rawMetadataPath: nil,
            relatedPlanPath: nil,
            fingerprint: "fingerprint",
            resumeKind: .copilotConnect,
            resumePayload: "session-123",
            isNewtonProject: false
        )

        XCTAssertEqual(
            WorkspaceLauncher.copilotResumeCommand(for: record),
            "cd '/tmp/My Project' && copilot --resume 'session-123'"
        )
    }

    func testClaudeResumeCommandIncludesWorkspaceDirectory() {
        let record = SessionRecord(
            source: .claudeCodeCLI,
            sourceSessionId: "session-abc",
            workspacePath: "/tmp/My Project",
            projectName: "My Project",
            branch: "main",
            conversationModel: "claude-opus-4-8",
            startedAt: nil,
            updatedAt: nil,
            title: "Resume command",
            summary: nil,
            firstUserPreview: nil,
            firstAssistantPreview: nil,
            rawTranscriptPath: nil,
            rawMetadataPath: nil,
            relatedPlanPath: nil,
            fingerprint: "fingerprint",
            resumeKind: .claudeResume,
            resumePayload: "session-abc",
            isNewtonProject: false
        )

        XCTAssertEqual(
            WorkspaceLauncher.claudeResumeCommand(for: record),
            "cd '/tmp/My Project' && claude --resume 'session-abc'"
        )
    }

    func testClaudeNewConversationCommandUsesWorkspaceDirectory() {
        XCTAssertEqual(
            WorkspaceLauncher.claudeNewConversationCommand(workingDirectory: "/tmp/My Project"),
            "cd '/tmp/My Project' && claude"
        )
    }
}
