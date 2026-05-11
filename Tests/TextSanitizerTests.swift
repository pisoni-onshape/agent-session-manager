import XCTest
@testable import AgentSessionManagerCore

final class TextSanitizerTests: XCTestCase {
    func testInferTitleRemovesSystemWrappers() {
        let raw = """
        <current_datetime>2026-05-07T13:43:11.463+05:30</current_datetime>

        <user_query>
        Build the local session browser for Copilot CLI.
        </user_query>

        <reminder>
        <sql_tables>No tables currently exist.</sql_tables>
        </reminder>
        """

        XCTAssertEqual(
            TextSanitizer.inferTitle(from: raw, fallback: "Fallback"),
            "Build the local session browser for Copilot CLI."
        )
    }

    func testCleanPreservesParagraphBreaksForDisplayText() {
        let raw = """
        <current_datetime>2026-05-07T13:43:11.463+05:30</current_datetime>

        Here's my analysis:

        Root cause
        \tIndented detail


        1. First item
        2. Second item
        """

        XCTAssertEqual(
            TextSanitizer.clean(raw),
            """
            Here's my analysis:

            Root cause
                Indented detail

            1. First item
            2. Second item
            """
        )
    }

    func testCompactCollapsesParagraphBreaksForSummariesAndSearch() {
        let raw = """
        Here's my analysis:

        Root cause
        \tIndented detail
        """

        XCTAssertEqual(
            TextSanitizer.compact(raw),
            "Here's my analysis: Root cause Indented detail"
        )
    }

    func testCursorProjectDecodingHandlesNewtonRepoPaths() {
        XCTAssertEqual(
            PathUtilities.decodeCursorWorkspacePath(from: "Users-pisoni-repos-newton4"),
            "/Users/pisoni/repos/newton4"
        )
    }

    func testCursorProjectDirectoryNameMatchesCursorWorkspaceSlug() {
        XCTAssertEqual(
            PathUtilities.cursorProjectDirectoryName(forWorkspacePath: "/Users/pisoni/Library/CloudStorage/OneDrive-PTC/Projects/newton-env-manager"),
            "Users-pisoni-Library-CloudStorage-OneDrive-PTC-Projects-newton-env-manager"
        )
        XCTAssertEqual(
            PathUtilities.cursorProjectDirectoryName(forWorkspacePath: "/Users/pisoni/Downloads/Interns 2026-27"),
            "Users-pisoni-Downloads-Interns-2026-27"
        )
    }

    func testDisplayProjectNameUsesWorkspaceFileNameWithoutExtension() {
        XCTAssertEqual(
            PathUtilities.displayProjectName(
                workspacePath: "/Users/pisoni/workspaces/Agent Session Manager.code-workspace",
                fallback: "fallback"
            ),
            "Agent Session Manager"
        )
    }

    func testBase64EncodedASCIIMatchesVSCodeMemoryFolderFormat() {
        XCTAssertEqual(
            PathUtilities.base64EncodedASCII("094573f8-522c-43d7-8198-139fcd09e04d"),
            "MDk0NTczZjgtNTIyYy00M2Q3LTgxOTgtMTM5ZmNkMDllMDRk"
        )
    }
}
