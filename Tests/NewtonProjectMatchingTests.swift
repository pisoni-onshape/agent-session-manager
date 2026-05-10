import XCTest
@testable import AgentSessionManager

final class NewtonProjectMatchingTests: XCTestCase {
    func testMatcherAcceptsNewtonRepoDirectlyUnderConfiguredRoot() {
        let matcher = NewtonProjectMatcher(reposRootPath: "/Users/tester/repos")

        XCTAssertTrue(matcher.matches(workspacePath: "/Users/tester/repos/newton5"))
        XCTAssertTrue(matcher.matches(workspacePath: "/Users/tester/repos/newton5/workspace.code-workspace"))
    }

    func testMatcherRejectsProjectOutsideConfiguredRoot() {
        let matcher = NewtonProjectMatcher(reposRootPath: "/Users/tester/repos")

        XCTAssertFalse(matcher.matches(workspacePath: "/Users/tester/Development/LocalProjects/newton-env-manager"))
        XCTAssertFalse(matcher.matches(workspacePath: "/Users/tester/repos2/newton5"))
    }

    func testMatcherNormalizesTrailingSlashInConfiguredRoot() {
        let matcher = NewtonProjectMatcher(reposRootPath: "/Users/tester/repos/")

        XCTAssertTrue(matcher.matches(workspacePath: "/Users/tester/repos/newton-main"))
    }

    func testMatcherRejectsNonNewtonRepoNamesWithinConfiguredRoot() {
        let matcher = NewtonProjectMatcher(reposRootPath: "/Users/tester/repos")

        XCTAssertFalse(matcher.matches(workspacePath: "/Users/tester/repos/agent-session-manager"))
    }
}
