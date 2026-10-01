import Foundation
import Network
import UsageState
import UserNotifications
import XCTest
import os

@testable import TokenRation

/// Stands in for the notification center: answers `status`, which a request for authorization turns into
/// `statusOnceAsked` when one is given; counts those requests and records the options each asked for; and
/// records each request posted, as the center would have received it, each post failing with `postFailure`
/// while one is set.
private final class StubNotifier: UpdateNotifying {
  struct Message: Equatable, Sendable {
    let title: String
    let body: String
  }

  /// What the center would have received of a request: what it shows, under which identifier, and whether at once.
  struct Delivery: Sendable {
    let identifier: String
    let message: Message
    let isImmediate: Bool
  }

  let status: Box<UNAuthorizationStatus>
  let statusOnceAsked: UNAuthorizationStatus?
  let requests = Box(0)
  let requestedOptions = Box<[UNAuthorizationOptions]>([])
  let delivered = Box<[Delivery]>([])
  let postFailure = Box<(any Error)?>(nil)

  /// The identifier of each request posted.
  var posted: [String] { delivered.value.map(\.identifier) }
  /// What each request posted puts in front of the user.
  var messages: [Message] { delivered.value.map(\.message) }

  init(status: UNAuthorizationStatus, statusOnceAsked: UNAuthorizationStatus? = nil) {
    self.status = Box(status)
    self.statusOnceAsked = statusOnceAsked
  }

  func requestAuthorization(options: UNAuthorizationOptions) async {
    // Recorded before the count, so a test that waits for the count finds the options already there.
    requestedOptions.value.append(options)
    requests.value += 1
    if let statusOnceAsked { status.value = statusOnceAsked }
  }

  func authorizationStatus() async -> UNAuthorizationStatus { status.value }

  func post(_ request: UNNotificationRequest) async throws {
    if let failure = postFailure.value { throw failure }
    delivered.value.append(
      Delivery(
        identifier: request.identifier, message: Message(title: request.content.title, body: request.content.body),
        isImmediate: request.trigger == nil))
  }
}

/// GitHub's answer naming `tag` the latest release.
private func releaseAnswer(_ tag: String) -> StubURLProtocol.Handler { StubURLProtocol.respond(200, body: #"{"tag_name":"\#(tag)"}"#) }

// MARK: - Update checking

@MainActor final class UpdateCheckerTests: XCTestCase {
  /// Defaults recording a check that has just succeeded, so a started checker's loop makes no request.
  private func checkedJustNow() -> UserDefaults {
    let defaults = makeDefaults()
    defaults.set(Date(), forKey: UpdateChecker.lastCheckKey)
    return defaults
  }

  /// A checker running `currentVersion`, whose requests `answer` serves and whose announcements `notifier`
  /// takes, logging to `logged`.
  private func makeChecker(
    defaults: UserDefaults = makeDefaults(), answering answer: @escaping StubURLProtocol.Handler = StubURLProtocol.respond(500),
    notifier: StubNotifier = StubNotifier(status: .authorized), currentVersion: String? = "1.0.5", logged: Box<[String]> = Box([])
  ) -> UpdateChecker {
    UpdateChecker(
      defaults: defaults, session: StubURLProtocol.session(answering: answer), notifier: notifier, currentVersion: currentVersion,
      log: { logged.value.append($0) })
  }

  /// Three-part versions must order numerically, not lexically: the whole point of the check is
  /// noticing 0.1.2 while running 0.1.1, and "0.1.10" must beat "0.1.9" rather than lose to it.
  func testVersionOrdering() {
    XCTAssertTrue(UpdateChecker.isNewer("0.1.2", than: "0.1.1"))
    XCTAssertTrue(UpdateChecker.isNewer("0.1.10", than: "0.1.9"))
    XCTAssertTrue(UpdateChecker.isNewer("0.2.0", than: "0.1.99"))
    XCTAssertTrue(UpdateChecker.isNewer("1.0.0", than: "0.9.9"))
    XCTAssertFalse(UpdateChecker.isNewer("0.1.1", than: "0.1.1"))
    XCTAssertFalse(UpdateChecker.isNewer("0.1.1", than: "0.1.2"))
    // A shorter version is the same as one zero-padded, so neither direction is "newer".
    XCTAssertFalse(UpdateChecker.isNewer("0.1", than: "0.1.0"))
    XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.1"))
  }

  /// A recorded check must suppress the next request for the whole gap; without this the panel
  /// trigger would fire a request on every click.
  func testRecentCheckIsSkipped() async {
    let defaults = makeDefaults()
    defaults.set(Date(), forKey: UpdateChecker.lastCheckKey)
    defaults.set("0.9.9", forKey: "latestKnownVersion")
    let asked = Box(0)
    let checker = makeChecker(
      defaults: defaults,
      answering: { request in
        asked.value += 1
        return releaseAnswer("v2.0.0")(request)
      })

    await checker.check()
    XCTAssertEqual(asked.value, 0, "a recent check must not ask GitHub again")
    XCTAssertEqual(checker.latestVersion, "0.9.9", "a skipped check must not disturb the cached answer")
  }

  /// With no record of a previous check, the first one has to run.
  func testFirstCheckIsDue() { XCTAssertTrue(makeChecker().isDue) }

  /// A check that just happened must suppress the next one, or the panel trigger would fire a
  /// request on every click.
  func testRecentCheckIsNotDue() {
    let defaults = makeDefaults()
    defaults.set(Date(), forKey: UpdateChecker.lastCheckKey)
    XCTAssertFalse(makeChecker(defaults: defaults).isDue)
  }

  /// The cached answer has to be readable before any network call completes, or the panel shows
  /// nothing on launch even when an update is already known.
  func testCachedVersionIsRestoredAtInit() {
    let defaults = makeDefaults()
    defaults.set("1.2.3", forKey: "latestKnownVersion")
    XCTAssertEqual(makeChecker(defaults: defaults).latestVersion, "1.2.3")
  }

  /// A check asks GitHub's API for the repository's latest release, as JSON, naming itself.
  func testCheckAsksGitHubForTheLatestRelease() async throws {
    let asked = Box<URLRequest?>(nil)
    let checker = makeChecker(answering: { request in
      asked.value = request
      return releaseAnswer("v1.0.5")(request)
    })
    await checker.check()
    let request = try XCTUnwrap(asked.value, "a due check asks")
    XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/MilosRandelovic/tokenration/releases/latest")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "TokenRation")
  }

  /// A check that gets no answer, offline or timed out, says so and stays due, so the next opportunity
  /// asks again.
  func testUnansweredCheckIsLoggedAndStaysDue() async {
    let logged = Box<[String]>([])
    let checker = makeChecker(answering: { _ in .failure(URLError(.notConnectedToInternet)) }, logged: logged)
    await checker.check()
    XCTAssertEqual(logged.value, ["[update] check failed: no response"])
    XCTAssertTrue(checker.isDue)
  }

  /// A refusal, a rate limit or no release yet, says so with its status and stays due.
  func testRefusedCheckIsLoggedAndStaysDue() async {
    let logged = Box<[String]>([])
    let checker = makeChecker(answering: StubURLProtocol.respond(403), logged: logged)
    await checker.check()
    XCTAssertEqual(logged.value, ["[update] check failed: HTTP 403"])
    XCTAssertTrue(checker.isDue)
  }

  /// A 200 whose body is not a release says it could not read one rather than naming the status as the
  /// failure, and stays due, with no version recorded and nothing announced.
  func testUnreadableReleaseIsLoggedAndStaysDue() async {
    let logged = Box<[String]>([])
    let notifier = StubNotifier(status: .authorized)
    let checker = makeChecker(answering: StubURLProtocol.respond(200, body: "{}"), notifier: notifier, logged: logged)
    await checker.check()
    XCTAssertEqual(logged.value, ["[update] check failed: unreadable release"])
    XCTAssertTrue(checker.isDue)
    XCTAssertNil(checker.latestVersion)
    XCTAssertEqual(notifier.posted, [])
  }

  /// The running version being the latest is recorded and spaces the next check, and the user is told
  /// nothing.
  func testCurrentReleaseIsRecordedQuietly() async {
    let logged = Box<[String]>([])
    let notifier = StubNotifier(status: .authorized)
    let checker = makeChecker(answering: releaseAnswer("v1.0.5"), notifier: notifier, logged: logged)
    await checker.check()
    XCTAssertEqual(logged.value, ["[update] 1.0.5 is current (latest 1.0.5)"])
    XCTAssertEqual(checker.latestVersion, "1.0.5", "the tag's v is dropped")
    XCTAssertFalse(checker.isDue, "a successful check spaces the next one")
    XCTAssertFalse(checker.updateAvailable)
    XCTAssertEqual(notifier.posted, [])
  }

  /// A newer release is announced once per version, naming it and the command that installs it:
  /// announcing it on every check would train the user to ignore it, so the announcement is remembered
  /// across checks.
  func testNewerReleaseIsAnnouncedOncePerVersion() async {
    let defaults = makeDefaults()
    let logged = Box<[String]>([])
    let notifier = StubNotifier(status: .authorized)
    let checker = makeChecker(defaults: defaults, answering: releaseAnswer("v1.0.6"), notifier: notifier, logged: logged)
    await checker.check()
    defaults.removeObject(forKey: UpdateChecker.lastCheckKey)
    await checker.check()
    XCTAssertEqual(notifier.posted, ["update-1.0.6"])
    XCTAssertEqual(
      notifier.messages, [StubNotifier.Message(title: "TokenRation 1.0.6 is available", body: "Run brew upgrade tokenration to update.")])
    XCTAssertEqual(notifier.delivered.value.map(\.isImmediate), [true], "shown at once")
    XCTAssertTrue(checker.updateAvailable)
    XCTAssertEqual(logged.value, ["[update] 1.0.6 available (running 1.0.5)", "[update] 1.0.6 available (running 1.0.5)"])
  }

  /// With notifications not permitted the panel still shows the update, and the log says so once per
  /// run rather than on every check.
  func testRefusedNotificationsAreLoggedOncePerRun() async {
    let defaults = makeDefaults()
    let logged = Box<[String]>([])
    let notifier = StubNotifier(status: .denied)
    let checker = makeChecker(defaults: defaults, answering: releaseAnswer("v1.0.6"), notifier: notifier, logged: logged)
    await checker.check()
    defaults.removeObject(forKey: UpdateChecker.lastCheckKey)
    await checker.check()
    XCTAssertEqual(notifier.posted, [])
    XCTAssertEqual(logged.value.filter { $0.contains("notifications not permitted") }.count, 1, "logged: \(logged.value)")
  }

  /// Provisional permission, which delivers quietly, is permission: the release is announced.
  func testProvisionalPermissionAnnounces() async {
    let notifier = StubNotifier(status: .provisional)
    await makeChecker(answering: releaseAnswer("v1.0.6"), notifier: notifier).check()
    XCTAssertEqual(notifier.posted, ["update-1.0.6"])
  }

  /// Permission not yet decided is asked for at the announcement and read again, so the first
  /// announcement on a fresh install is not dropped while the launch prompt is still unanswered.
  func testUndecidedPermissionIsAskedForBeforeAnnouncing() async {
    let notifier = StubNotifier(status: .notDetermined, statusOnceAsked: .authorized)
    await makeChecker(answering: releaseAnswer("v1.0.6"), notifier: notifier).check()
    XCTAssertEqual(notifier.requests.value, 1)
    XCTAssertEqual(notifier.requestedOptions.value, [[.alert, .sound]], "the alert an announcement is shown in, with its sound")
    XCTAssertEqual(notifier.posted, ["update-1.0.6"], "permission granted when asked is used at once")
  }

  /// A post that fails is logged and not remembered, so the next check announces the version again.
  func testFailedAnnouncementIsLoggedAndRetried() async {
    struct PostFailed: LocalizedError { var errorDescription: String? { "center unavailable" } }
    let defaults = makeDefaults()
    let logged = Box<[String]>([])
    let notifier = StubNotifier(status: .authorized)
    notifier.postFailure.value = PostFailed()
    let checker = makeChecker(defaults: defaults, answering: releaseAnswer("v1.0.6"), notifier: notifier, logged: logged)
    await checker.check()
    XCTAssertEqual(notifier.posted, [])
    XCTAssertTrue(logged.value.contains("[update] could not post notification: center unavailable"), "logged: \(logged.value)")
    notifier.postFailure.value = nil
    defaults.removeObject(forKey: UpdateChecker.lastCheckKey)
    await checker.check()
    XCTAssertEqual(notifier.posted, ["update-1.0.6"], "a failed announcement is made again at the next check")
  }

  /// Launch asks for notification permission, so the prompt is answered before a release lands.
  func testStartAsksForNotificationPermission() async throws {
    let notifier = StubNotifier(status: .notDetermined)
    let checker = makeChecker(defaults: checkedJustNow(), notifier: notifier)
    checker.start()
    defer { checker.stop() }
    for _ in 0..<500 where notifier.requests.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(notifier.requests.value, 1)
    XCTAssertEqual(notifier.requestedOptions.value, [[.alert, .sound]], "the alert an announcement is shown in, with its sound")
  }

  /// A second start before a stop asks for permission once: while the checker is running, `start` does nothing.
  func testSecondStartAsksForPermissionOnce() async throws {
    let notifier = StubNotifier(status: .notDetermined)
    let checker = makeChecker(defaults: checkedJustNow(), notifier: notifier)
    checker.start()
    checker.start()
    defer { checker.stop() }
    for _ in 0..<500 where notifier.requests.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
    // A second request would be made alongside the first; this is its bounded chance to land.
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(notifier.requests.value, 1)
  }

  /// Asking for notification permission is what made `swift run` crash at launch, so an unbundled build never
  /// asks: with no version to compare it never announces anything, and the real notification center crashes a
  /// process without a bundle.
  func testUnbundledStartNeverAsksForPermission() async throws {
    let notifier = StubNotifier(status: .notDetermined)
    let checker = makeChecker(notifier: notifier, currentVersion: nil)
    checker.start()
    defer { checker.stop() }
    // A request would be made at once; this is its bounded chance to land.
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(notifier.requests.value, 0)
  }

  /// A relaunch on the same defaults restores the latest version before any check and does not announce
  /// a version already announced.
  func testRelaunchKeepsTheLatestVersionAndTheAnnouncement() async {
    let defaults = makeDefaults()
    let notifier = StubNotifier(status: .authorized)
    await makeChecker(defaults: defaults, answering: releaseAnswer("v1.0.6"), notifier: notifier).check()
    defaults.removeObject(forKey: UpdateChecker.lastCheckKey)
    let relaunched = makeChecker(defaults: defaults, answering: releaseAnswer("v1.0.6"), notifier: notifier)
    XCTAssertEqual(relaunched.latestVersion, "1.0.6")
    XCTAssertTrue(relaunched.updateAvailable)
    await relaunched.check()
    XCTAssertEqual(notifier.posted, ["update-1.0.6"], "a version announced before the relaunch is not announced again")
  }

  /// An unbundled build has no version to compare, so it never asks.
  func testUnbundledBuildNeverAsks() async {
    let asked = Box(0)
    let checker = makeChecker(
      answering: { request in
        asked.value += 1
        return releaseAnswer("v1.0.6")(request)
      }, currentVersion: nil)
    await checker.check()
    XCTAssertEqual(asked.value, 0)
  }
}
