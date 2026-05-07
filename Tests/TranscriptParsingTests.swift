import Foundation
import XCTest
@testable import AgentSessionManager

final class TranscriptParsingTests: XCTestCase {
    func testEventTranscriptExtractionFindsSessionAndPreview() throws {
        let url = try temporaryFile(
            named: "event.jsonl",
            contents: """
            {"type":"session.start","data":{"sessionId":"abc-123","startTime":"2026-05-07T06:18:14.516Z"}}
            {"type":"user.message","data":{"content":"<user_query>Find the terminal drag/drop bug.</user_query>"}}
            {"type":"assistant.message","data":{"content":"I’ll trace the terminal initialization path first."}}
            """
        )

        let preview = try TranscriptPreviewExtractor.extractEventTranscript(from: url)
        XCTAssertEqual(preview.sessionId, "abc-123")
        XCTAssertEqual(preview.firstUser, "Find the terminal drag/drop bug.")
        XCTAssertEqual(preview.firstAssistant, "I’ll trace the terminal initialization path first.")
        XCTAssertNotNil(preview.startedAt)
    }

    func testCursorTranscriptExtractionFindsFirstTurns() throws {
        let url = try temporaryFile(
            named: "cursor.jsonl",
            contents: """
            {"role":"user","message":{"content":[{"type":"text","text":"Please explain how body edges become quads."}]}}
            {"role":"assistant","message":{"content":[{"type":"text","text":"I’ll inspect the edge rendering pipeline first."}]}}
            """
        )

        let preview = try TranscriptPreviewExtractor.extractCursorTranscript(from: url)
        XCTAssertEqual(preview.firstUser, "Please explain how body edges become quads.")
        XCTAssertEqual(preview.firstAssistant, "I’ll inspect the edge rendering pipeline first.")
    }

    private func temporaryFile(named name: String, contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
