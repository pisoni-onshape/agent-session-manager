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
}
