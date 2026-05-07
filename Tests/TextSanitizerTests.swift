import XCTest
@testable import AgentSessionManager

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

    func testCursorProjectDecodingHandlesNewtonRepoPaths() {
        XCTAssertEqual(
            PathUtilities.decodeCursorWorkspacePath(from: "Users-pisoni-repos-newton4"),
            "/Users/pisoni/repos/newton4"
        )
    }

    func testBase64EncodedASCIIMatchesVSCodeMemoryFolderFormat() {
        XCTAssertEqual(
            PathUtilities.base64EncodedASCII("094573f8-522c-43d7-8198-139fcd09e04d"),
            "MDk0NTczZjgtNTIyYy00M2Q3LTgxOTgtMTM5ZmNkMDllMDRk"
        )
    }
}
