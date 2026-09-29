import Sparkle
import XCTest
@testable import PenguinNotch

/// "Checking…" is a state the settings sheet must always leave: a check that
/// ends any other way, or never reports back, still lands somewhere.
@MainActor
final class UpdaterOutcomeTests: XCTestCase {
    func testACycleThatEndsSilentlyClearsChecking() {
        XCTAssertEqual(Updater.outcome(afterCycleFrom: .checking, errorCode: nil), .idle)
    }

    func testACycleThatCouldNotReachTheFeedSaysSo() {
        let code = Int(SUError.appcastError.rawValue)
        XCTAssertEqual(Updater.outcome(afterCycleFrom: .checking, errorCode: code), .unreachable)
    }

    func testAnAnswerAlreadyGivenIsKept() {
        XCTAssertEqual(Updater.outcome(afterCycleFrom: .found("1.14.0"), errorCode: nil), .found("1.14.0"))
        let upToDate = Updater.Outcome.upToDate(Date(timeIntervalSince1970: 1))
        XCTAssertEqual(Updater.outcome(afterCycleFrom: upToDate, errorCode: nil), upToDate)
    }

    func testACheckThatNeverAnswersStopsSayingChecking() {
        guard case .failed(let why) = Updater.outcome(afterTimeoutFrom: .checking) else {
            return XCTFail("a stalled check must not stay on Checking…")
        }
        XCTAssertTrue(why.contains("GitHub"), why)
        XCTAssertEqual(Updater.outcome(afterTimeoutFrom: .upToDate(Date(timeIntervalSince1970: 1))),
                       .upToDate(Date(timeIntervalSince1970: 1)))
    }

    /// The line under an update offered in the notch is the appcast's HTML
    /// release notes read as plain text.
    func testReleaseNotesAreReadAsOnePlainLine() {
        let html = "<h2>New</h2>\n<ul>\n  <li>Carry the notch by its dots &amp; drop it anywhere.</li>\n</ul>"
        XCTAssertEqual(UpdatePrompt.summary(of: html), "New Carry the notch by its dots & drop it anywhere.")
        XCTAssertEqual(UpdatePrompt.summary(of: ""), "")
    }

    func testThePreviewNamesTheNextVersion() {
        XCTAssertEqual(Updater.nextVersion(after: "1.18.0"), "1.19.0")
        XCTAssertEqual(Updater.nextVersion(after: "1.18.3"), "1.19.0")
        XCTAssertEqual(Updater.nextVersion(after: "2"), "2.1.0")
    }

    func testTheCustomDriverKeepsTheUsefulErrorAfterClosingTheCard() {
        let updater = Updater()
        updater.preview()
        let driver = NotchUpdateDriver(updater: updater)
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                            userInfo: [NSLocalizedDescriptionKey: "The update download timed out."])
        var acknowledged = false

        driver.showUpdaterError(error) { acknowledged = true }

        XCTAssertTrue(acknowledged)
        XCTAssertNil(updater.prompt)
        XCTAssertEqual(updater.outcome, .failed(error.localizedDescription))
        XCTAssertEqual(Updater.outcome(afterCycleFrom: updater.outcome, errorCode: nil), updater.outcome)
    }

    func testTheCustomDriverExplainsAnUnavailableFeed() throws {
        let updater = Updater()
        let driver = NotchUpdateDriver(updater: updater)
        let error = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.appcastError.rawValue))

        driver.showUpdaterError(error, acknowledgement: {})

        XCTAssertEqual(updater.outcome, .unreachable)
        let message = try XCTUnwrap(updater.outcome.message)
        XCTAssertTrue(message.contains("GitHub Releases"), message)
    }

    func testAPreviewCanBeDeferredAndReofferedWithoutARealCheck() throws {
        let updater = Updater()
        updater.preview()
        let offered = try XCTUnwrap(updater.prompt)
        updater.respond(.later)
        XCTAssertNil(updater.prompt)
        XCTAssertEqual(updater.pending, offered.version)
        updater.reoffer()
        XCTAssertEqual(updater.prompt, offered)
        XCTAssertEqual(updater.outcome, .idle)
        updater.respond(.close)
    }
}
