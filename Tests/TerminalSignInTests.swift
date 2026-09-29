import XCTest
@testable import PenguinNotch

/// A CLI-backed account signs in from its own login command, so the Accounts
/// row can offer a button rather than a sentence to copy into a terminal.
final class TerminalSignInTests: XCTestCase {
    func testTheButtonIsNamedAfterTheTool() {
        let route = SignInRoute.command("gh auth login", name: "GitHub")
        XCTAssertEqual(route.actionTitle, "Sign in to GitHub")
    }

    /// `true` is on every Mac, in /usr/bin; the made-up tool is on none.
    func testExplanationSaysWhatTheButtonRuns() {
        let route = SignInRoute.command("true login", name: "Example")
        XCTAssertTrue(route.explanation.contains("true login"), route.explanation)
        XCTAssertTrue(route.explanation.contains("browser"), route.explanation)
    }

    /// A tool signed in with a slash command inside it has no `login` to run:
    /// the row has to say to sign in there.
    func testExplanationSaysToUseSlashLoginWhenTheCommandIsTheToolItself() {
        let route = SignInRoute.command("true", name: "Example")
        XCTAssertTrue(route.explanation.contains("/login"), route.explanation)
    }

    func testExplanationPointsAtTheInstallPageWhenTheToolIsMissing() {
        let route = SignInRoute.command("codenotch-no-such-tool login", name: "Example",
                                        install: URL(string: "https://example.com"))
        XCTAssertFalse(TerminalCommand.isInstalled(command: "codenotch-no-such-tool login"))
        XCTAssertTrue(route.explanation.contains("Install"), route.explanation)
    }

    /// The first word that is not an environment assignment is the program.
    func testAnEnvironmentPrefixDoesNotHideTheProgram() {
        XCTAssertTrue(TerminalCommand.isInstalled(command: "CLAUDE_CONFIG_DIR=/tmp/x true login"))
        XCTAssertFalse(TerminalCommand.isInstalled(command: "ONLY=assignments"))
    }

    func testQuotedProfilePathsDoNotBecomeTheProgram() {
        XCTAssertTrue(TerminalCommand.isInstalled(command: "CLAUDE_CONFIG_DIR='/tmp/Work Space/.claude-team' true login"))
        XCTAssertTrue(TerminalCommand.isInstalled(command: "CODEX_HOME='/tmp/O'\"'\"'Brien Team' true login"))
        XCTAssertTrue(TerminalCommand.isInstalled(command: "EMPTY= PROFILE=\"/tmp/Work Team\"\ttrue login"))
    }

    func testExecutableLookupDoesNotTreatShellSyntaxAsAProgram() {
        XCTAssertNil(TerminalCommand.executable(in: "PROFILE='/tmp/incomplete true"))
        XCTAssertNil(TerminalCommand.executable(in: "$(touch /tmp/should-not-exist) login"))
        XCTAssertNil(TerminalCommand.executable(in: "true;anything"))
        XCTAssertEqual(TerminalCommand.executable(in: "true login; ignored"), "true")
        XCTAssertTrue(TerminalCommand.isInstalled(command: "/usr/bin/true login"))
    }

    func testTheRouteStillSaysWhereToSwitchAndWhatSignOutLeaves() {
        let route = SignInRoute.command("true login", name: "Example")
        XCTAssertFalse(route.switchHint.isEmpty)
        XCTAssertFalse(route.signOutCaveat.isEmpty)
    }
}
