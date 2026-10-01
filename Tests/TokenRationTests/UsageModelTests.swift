import Foundation
import Network
import UsageState
import UserNotifications
import XCTest
import os

@testable import TokenRation

// MARK: - Log routing

@MainActor final class LogRoutingTests: XCTestCase {
  /// The model logs through the sink it was given, each line prefixed with its provider, which is how
  /// the suite stays out of the user's log.
  func testModelLogsThroughItsSink() async {
    let logged = Box<[String]>([])
    let model = UsageModel(
      provider: StubProvider(provider: .codex) { snapshot("codex:window") }, defaults: makeDefaults(), restoring: nil,
      network: StubNetwork(), log: { logged.value.append($0) })
    await model.refresh(trigger: "test")
    XCTAssertFalse(logged.value.isEmpty, "a refresh logs its attempt")
    XCTAssertTrue(logged.value.allSatisfy { $0.hasPrefix("[codex] ") }, "logged: \(logged.value)")
  }

  /// Preferences log through the sink they were given, which is how the suite stays out of the user's log.
  func testReconcileLogsThroughItsSink() {
    let defaults = makeDefaults()
    defaults.set(["codex:window", "codex:model:retired"], forKey: "shownMetricIDs")
    let logged = Box<[String]>([])
    let prefs = Preferences(available: [.codex], defaults: defaults, log: { logged.value.append($0) })

    prefs.reconcile(knownIDs: ["codex:window"], settled: [.codex])
    XCTAssertEqual(logged.value, ["dropped pins no longer present in a snapshot: [\"codex:model:retired\"]"])
  }
}

// MARK: - Network

@MainActor final class NetworkTests: XCTestCase {
  /// Losing the network publishes at once, as the state file is rewritten on a connectivity change. Offline, a
  /// refresh spends no attempt and says why; the reconnect that follows refreshes at once rather than waiting out
  /// the offline retry.
  func testOfflineSkipsAndReconnectingRefreshes() async {
    let network = StubNetwork()
    let fetches = Box(0)
    let logged = Box<[String]>([])
    let model = UsageModel(
      provider: StubProvider(provider: .codex) {
        fetches.value += 1
        return snapshot("codex:window")
      }, defaults: makeDefaults(), restoring: nil, network: network, log: { logged.value.append($0) })
    let changes = Box(0)
    model.onChange = { changes.value += 1 }

    await network.report(offline: true)
    XCTAssertTrue(model.isOffline)
    XCTAssertEqual(changes.value, 1, "losing the network publishes at once")
    let wait = await model.refresh(trigger: "test")
    XCTAssertEqual(fetches.value, 0, "an offline refresh makes no attempt")
    XCTAssertEqual(wait, 5 * 60, "it waits the offline retry")

    await network.report(offline: false)
    XCTAssertFalse(model.isOffline)
    XCTAssertEqual(fetches.value, 1, "reconnecting refreshes")
    XCTAssertEqual(
      logged.value,
      [
        "[codex] network lost", "[codex] skip (test): offline", "[codex] network available", "[codex] fetch (reconnect)",
        "[codex] ok: codex:window=1%",
      ])
  }

  /// A report that changes nothing does nothing. The first report on a Mac that is online is one, and acting on
  /// it would log a reconnect that never happened and ask for a refresh at every launch.
  func testAReportThatChangesNothingIsIgnored() async {
    let network = StubNetwork()
    let fetches = Box(0)
    let logged = Box<[String]>([])
    let model = UsageModel(
      provider: StubProvider(provider: .codex) {
        fetches.value += 1
        return snapshot("codex:window")
      }, defaults: makeDefaults(), restoring: nil, network: network, log: { logged.value.append($0) })

    await network.report(offline: false)
    XCTAssertFalse(model.isOffline)
    XCTAssertEqual(fetches.value, 0)
    XCTAssertEqual(logged.value, [])
  }

  /// Only a satisfied path is online: an unsatisfied one, or one that needs a connection made first, is offline.
  func testOnlyASatisfiedPathIsOnline() {
    let cases: [(status: NWPath.Status, offline: Bool)] = [(.satisfied, false), (.unsatisfied, true), (.requiresConnection, true)]
    for testCase in cases { XCTAssertEqual(SystemNetworkMonitor.isOffline(testCase.status), testCase.offline, "\(testCase.status)") }
  }
}

// MARK: - Holds

@MainActor final class HeldUntilTests: XCTestCase {
  /// The UI needs the effective deadline, not just the 429 one: a hold after an auth failure
  /// refuses a manual refresh exactly the same way.
  func testAuthHoldIsReported() async {
    let model = UsageModel(
      provider: StubProvider(provider: .codex) { throw UsageError.sessionExpired }, defaults: makeDefaults(), restoring: nil,
      network: StubNetwork(), log: discardLog)
    XCTAssertNil(model.heldUntil, "nothing has failed yet")

    await model.refresh(trigger: "test")
    XCTAssertNotNil(model.heldUntil, "an auth hold refuses a refresh, so it must be visible to the UI")
    XCTAssertNil(model.rateLimitedUntil, "and it is not a throttle")
  }

  func testRateLimitHoldIsReported() async {
    let model = UsageModel(
      provider: StubProvider(provider: .codex) { throw UsageError.rateLimited(retryAfter: 600) }, defaults: makeDefaults(), restoring: nil,
      network: StubNetwork(), log: discardLog)
    await model.refresh(trigger: "test")
    XCTAssertNotNil(model.heldUntil)
  }

  /// A deadline in the past is not a hold: the button must come back when the wait is over.
  func testExpiredDeadlineIsNotAHold() {
    let defaults = makeDefaults()
    defaults.set(Date(timeIntervalSinceNow: -60), forKey: "nextAttemptAt.codex")
    let model = UsageModel(
      provider: StubProvider(provider: .codex) { snapshot("codex:window") }, defaults: defaults, restoring: nil, network: StubNetwork(),
      log: discardLog)
    XCTAssertNil(model.heldUntil)
  }

  /// The minimum gap refuses a manual refresh just as a backoff does — including right after a
  /// successful poll — so the button must be disabled then too.
  func testMinimumGapCountsAsAHold() async {
    let model = UsageModel(
      provider: StubProvider(provider: .codex) { snapshot("codex:window") }, defaults: makeDefaults(), restoring: nil,
      network: StubNetwork(), log: discardLog)
    await model.refresh(trigger: "test")
    XCTAssertNil(model.rateLimitedUntil, "nothing failed")
    XCTAssertNotNil(model.heldUntil, "a refresh inside the gap is refused, so it is a hold")
  }

  /// The wiring, not just the formatter: the tooltip has to ask for the wait form, or a correct
  /// `ResetText.wait` never reaches the button and the hold still reads "in 0m".
  func testTooltipReportsASubMinuteHoldInSeconds() {
    let now = Date()
    XCTAssertEqual(
      UsagePanelView.refreshHelp(refreshing: false, offline: false, heldUntil: now.addingTimeInterval(45), now: now), "Next attempt in 45s")
  }

  func testTooltipWordsTheOtherStates() {
    let now = Date()
    XCTAssertEqual(UsagePanelView.refreshHelp(refreshing: false, offline: false, heldUntil: nil, now: now), "Refresh now")
    XCTAssertEqual(UsagePanelView.refreshHelp(refreshing: true, offline: false, heldUntil: nil, now: now), "Refreshing…")
  }

  /// Offline, `refresh` refuses a click, so the button is unavailable and says why. Being offline wins over a
  /// hold: the wait is for the network, and a reconnect refreshes by itself.
  func testTooltipSaysOffline() {
    let now = Date()
    XCTAssertEqual(UsagePanelView.refreshHelp(refreshing: false, offline: true, heldUntil: nil, now: now), "Offline")
    XCTAssertEqual(UsagePanelView.refreshHelp(refreshing: false, offline: true, heldUntil: now.addingTimeInterval(45), now: now), "Offline")
  }

  func testNoHoldWhenNothingHasFailed() {
    let model = UsageModel(
      provider: StubProvider(provider: .codex) { snapshot("codex:window") }, defaults: makeDefaults(), restoring: nil,
      network: StubNetwork(), log: discardLog)
    XCTAssertNil(model.heldUntil)
  }

  /// An auth hold waits for exactly one thing: different credentials. Once they are on disk
  /// `refresh` clears the backoff and attempts, so the button has to be offered again — the
  /// regression here left it dead for the rest of a quarter-hour interval after a sign-in.
  func testSpentAuthHoldStopsBeingAHold() async {
    let credentials = Box("rejected-token")
    let defaults = makeDefaults()
    let model = UsageModel(
      provider: StubProvider(provider: .codex, outcome: { throw UsageError.sessionExpired }, credentials: credentials), defaults: defaults,
      restoring: nil, network: StubNetwork(), log: discardLog)

    await model.refresh(trigger: "test")
    await model.refreshCredentialState()
    XCTAssertNotNil(model.heldUntil, "the credentials that were rejected are still the ones on disk")

    // By the time an auth hold matters the minimum gap is long past; only the hold is in force.
    defaults.set(Date(timeIntervalSinceNow: -300), forKey: "lastAttemptAt.codex")
    credentials.value = "signed-in-again"
    await model.refreshCredentialState()

    XCTAssertNil(model.heldUntil, "a refresh now would clear the backoff and attempt, so it must be offered")
  }

  /// A 429 is the server asking for quiet, and signing in again does not change that.
  func testRateLimitHoldSurvivesACredentialChange() async {
    let credentials = Box("first")
    let defaults = makeDefaults()
    let model = UsageModel(
      provider: StubProvider(provider: .codex, outcome: { throw UsageError.rateLimited(retryAfter: 600) }, credentials: credentials),
      defaults: defaults, restoring: nil, network: StubNetwork(), log: discardLog)

    await model.refresh(trigger: "test")
    defaults.set(Date(timeIntervalSinceNow: -300), forKey: "lastAttemptAt.codex")
    credentials.value = "second"
    await model.refreshCredentialState()

    XCTAssertNotNil(model.heldUntil, "a throttle is not escaped by signing in again")
  }

  /// Only the auth paths record a fingerprint. A backoff from an ordinary failure records none,
  /// so signing in again must not shorten it — whatever failed had nothing to do with
  /// credentials, and unlike a 429 there is no separate deadline to fall back on.
  func testErrorBackoffSurvivesACredentialChange() async {
    struct Unreachable: Error {}
    let credentials = Box("first")
    let defaults = makeDefaults()
    let model = UsageModel(
      provider: StubProvider(provider: .codex, outcome: { throw Unreachable() }, credentials: credentials), defaults: defaults,
      restoring: nil, network: StubNetwork(), log: discardLog)

    await model.refresh(trigger: "test")
    XCTAssertNil(model.rateLimitedUntil, "a plain failure is not a throttle, so only the backoff holds")
    defaults.set(Date(timeIntervalSinceNow: -300), forKey: "lastAttemptAt.codex")
    credentials.value = "second"
    await model.refreshCredentialState()

    XCTAssertNotNil(model.heldUntil, "an error backoff is not escaped by signing in again")
  }

  /// The comparison needs both fingerprints. Until the credentials have been read the hold
  /// stands, or a launch would offer a click that `refresh` still refuses.
  func testAuthHoldStandsUntilCredentialsHaveBeenRead() async {
    let defaults = makeDefaults()
    let model = UsageModel(
      provider: StubProvider(provider: .codex, outcome: { throw UsageError.sessionExpired }, credentials: Box("token")), defaults: defaults,
      restoring: nil, network: StubNetwork(), log: discardLog)

    await model.refresh(trigger: "test")
    defaults.set(Date(timeIntervalSinceNow: -300), forKey: "lastAttemptAt.codex")

    XCTAssertNotNil(model.heldUntil, "no reading of the credentials has happened yet")
  }
}

// MARK: - Attention state

@MainActor final class NeedsSignInTests: XCTestCase {
  /// Only a sign-in fixes an expired or missing credential, so that state is tracked separately
  /// from a throttle — the menu bar asks for attention in one case and stays quiet in the other.
  func testAuthFailureAsksForAttention() async {
    let model = UsageModel(
      provider: StubProvider(provider: .codex) { throw UsageError.sessionExpired }, defaults: makeDefaults(), restoring: nil,
      network: StubNetwork(), log: discardLog)
    await model.refresh(trigger: "test")
    XCTAssertTrue(model.needsSignIn)
  }

  /// The control for `testMissingCodexBinaryIsNotASignInProblem`: `notSignedIn` asks for a sign-in whichever
  /// provider throws it, so in `testMissingCodexBinaryIsNotASignInProblem` it is the error, not the provider,
  /// that keeps the warning away.
  func testMissingCredentialsAlsoAskForAttention() async {
    let model = UsageModel(
      provider: StubProvider(provider: .codex) { throw UsageError.notSignedIn }, defaults: makeDefaults(), restoring: nil,
      network: StubNetwork(), log: discardLog)
    await model.refresh(trigger: "test")
    XCTAssertTrue(model.needsSignIn)
  }

  /// The model routes `codexUnavailable` to the ordinary backoff, growing with each failure, without asking
  /// for a sign-in: no sign-in fixes a `codex` that is missing or will not start, and the auth interval would
  /// hold it for a quarter of an hour. The sites that throw it are pinned by
  /// `CodexBinaryTests.testBinaryThatCannotStartIsReportedAsCodexUnavailable` and
  /// `testNoBinaryFoundIsReportedAsCodexUnavailable`.
  func testMissingCodexBinaryIsNotASignInProblem() async throws {
    let defaults = makeDefaults()
    let model = UsageModel(
      provider: StubProvider(provider: .codex) { throw UsageError.codexUnavailable }, defaults: defaults, restoring: nil,
      network: StubNetwork(), log: discardLog)
    await model.refresh(trigger: "test")

    XCTAssertFalse(model.needsSignIn, "no sign-in fixes a missing binary, so the menu bar must not ask for one")
    let message = model.lastError ?? ""
    XCTAssertTrue(message.contains("Codex"), "the Codex tab must name Codex: \(message)")
    XCTAssertFalse(message.contains("Claude"), "the Codex tab must not name Claude: \(message)")
    XCTAssertEqual(message, "Couldn't find or start the Codex CLI.", "the CHANGELOG quotes it")

    // Only the backoff holds once the minimum gap is spent: a minute ±10%, with a second of slack as it counts down.
    defaults.set(Date(timeIntervalSinceNow: -300), forKey: "lastAttemptAt.codex")
    let hold = try XCTUnwrap(model.heldUntil, "the backoff must be persisted like any other failure's").timeIntervalSinceNow
    XCTAssertEqual(hold, 60, accuracy: 7, "a first failure backs off about a minute, not the auth interval")

    // Once it lapses, the next failure waits twice as long, ±10%: the backoff grows rather than repeating.
    defaults.set(Date(timeIntervalSinceNow: -1), forKey: "nextAttemptAt.codex")
    defaults.set(Date(timeIntervalSinceNow: -300), forKey: "lastAttemptAt.codex")
    let second = await model.refresh(trigger: "retry")
    XCTAssertEqual(second, 120, accuracy: 12, "a second failure backs off about two minutes, not a constant interval")
  }

  /// A relaunch restores the backoff but not the reason for it, so the state is asked of the
  /// credentials rather than waited for — otherwise stale numbers sit under a normal glyph until
  /// the next attempt, up to a quarter of an hour later.
  func testCredentialStateIsAskedForNotWaitedFor() async {
    let model = UsageModel(
      provider: StubProvider(provider: .codex, outcome: { snapshot("codex:window") }, credentialFault: UsageError.sessionExpired),
      defaults: makeDefaults(), restoring: nil, network: StubNetwork(), log: discardLog)
    XCTAssertFalse(model.needsSignIn, "nothing has been asked yet")

    await model.refreshCredentialState()
    XCTAssertTrue(model.needsSignIn, "the credentials answer without an attempt being made")
    XCTAssertEqual(model.lastError, UsageError.sessionExpired.errorDescription, "the panel needs the reason, not just the menu bar's glyph")
  }

  /// And usable credentials clear it, so signing in while held off drops the warning.
  func testUsableCredentialsClearTheWarning() async {
    let model = UsageModel(
      provider: StubProvider(provider: .codex) { throw UsageError.sessionExpired }, defaults: makeDefaults(), restoring: nil,
      network: StubNetwork(), log: discardLog)
    await model.refresh(trigger: "test")
    XCTAssertTrue(model.needsSignIn)

    await model.refreshCredentialState()
    XCTAssertFalse(model.needsSignIn, "the stub's credentials are usable, so the warning goes")
  }

  /// Being throttled is not something the user can act on, so it must not raise the warning.
  func testRateLimitDoesNotAskForAttention() async {
    let model = UsageModel(
      provider: StubProvider(provider: .codex) { throw UsageError.rateLimited(retryAfter: 60) }, defaults: makeDefaults(), restoring: nil,
      network: StubNetwork(), log: discardLog)
    await model.refresh(trigger: "test")
    XCTAssertFalse(model.needsSignIn, "a throttle is waited out, not signed into")
  }

  /// And it clears once a reading succeeds, so the warning cannot outlive its cause.
  func testSuccessClearsTheWarning() async {
    let defaults = makeDefaults()
    let failing = Box(true)
    let model = UsageModel(
      provider: StubProvider(
        provider: .codex, outcome: { if failing.value { throw UsageError.sessionExpired } else { return snapshot("codex:window") } }),
      defaults: defaults, restoring: nil, network: StubNetwork(), log: discardLog)
    await model.refresh(trigger: "test")
    XCTAssertTrue(model.needsSignIn)

    failing.value = false
    defaults.set(Date(timeIntervalSinceNow: -1), forKey: "nextAttemptAt.codex")
    defaults.set(Date(timeIntervalSinceNow: -600), forKey: "lastAttemptAt.codex")
    let resumed = UsageModel(
      provider: StubProvider(provider: .codex) { snapshot("codex:window") }, defaults: defaults, restoring: nil, network: StubNetwork(),
      log: discardLog)
    await resumed.refresh(trigger: "retry")
    XCTAssertFalse(resumed.needsSignIn)
  }
}

// MARK: - Backoff persistence · Retry-After as a strict lower bound

@MainActor final class BackoffTests: XCTestCase {
  /// An auth failure must survive stop/start. A backoff held only in the polling task's sleep
  /// is lost when the loop restarts, falling back to the 120s minimum gap.
  func testAuthBackoffSurvivesStopStart() async {
    let defaults = makeDefaults()
    let provider = StubProvider(provider: .codex) { throw UsageError.notSignedIn }
    let model = UsageModel(provider: provider, defaults: defaults, restoring: nil, network: StubNetwork(), log: discardLog)

    let first = await model.refresh(trigger: "test")
    XCTAssertGreaterThan(first, 10 * 60, "missing credentials should hold off ~15 minutes")

    // Simulate stop/start: the very next attempt must be refused, not retried.
    model.stop()
    model.start()
    let second = await model.refresh(trigger: "after-restart")
    XCTAssertGreaterThan(second, 10 * 60, "restarting the loop must not discard the auth backoff")
  }

  /// A rejected token is usually one the CLI has just rotated, so the first rejection must come
  /// back quickly rather than parking the provider for a quarter of an hour. A rejection that
  /// repeats does need a sign-in, so it must then settle onto the long interval.
  func testRejectedTokenRetriesSoonThenSettles() async {
    let defaults = makeDefaults()
    let provider = StubProvider(provider: .codex) { throw UsageError.sessionExpired }

    let first = await UsageModel(provider: provider, defaults: defaults, restoring: nil, network: StubNetwork(), log: discardLog).refresh(
      trigger: "test")
    XCTAssertGreaterThan(first, 120, "must exceed the minimum gap, or the retry is skipped instead of attempted")
    XCTAssertLessThan(first, 5 * 60, "a rotated token should be picked up within minutes")

    // Let the first deadline lapse. A fresh model is what a relaunch looks like, and it restores
    // the stored failure count, so this stands in for the second consecutive rejection.
    defaults.set(Date().addingTimeInterval(-1), forKey: "nextAttemptAt.codex")
    defaults.set(Date().addingTimeInterval(-10 * 60), forKey: "lastAttemptAt.codex")
    let second = await UsageModel(provider: provider, defaults: defaults, restoring: nil, network: StubNetwork(), log: discardLog).refresh(
      trigger: "retry")
    XCTAssertGreaterThan(second, 10 * 60, "a token that stays rejected needs a sign-in, so stop retrying quickly")
  }

  /// The same, across a relaunch: a fresh model reading the same defaults must still hold off.
  func testBackoffSurvivesRelaunch() async {
    let defaults = makeDefaults()
    let failing = StubProvider(provider: .codex) { throw UsageError.badResponse }
    let first = UsageModel(provider: failing, defaults: defaults, restoring: nil, network: StubNetwork(), log: discardLog)
    let wait = await first.refresh(trigger: "test")
    XCTAssertGreaterThan(wait, 30, "a general failure should back off at least a minute-ish")

    // A brand-new model is what a relaunch looks like. It must honour the stored deadline
    // even though the 120s minimum gap alone would have allowed a retry much sooner.
    let relaunched = UsageModel(provider: failing, defaults: defaults, restoring: nil, network: StubNetwork(), log: discardLog)
    let afterRelaunch = await relaunched.refresh(trigger: "relaunch")
    XCTAssertGreaterThan(afterRelaunch, 30, "a relaunch must not discard a backoff that is still in force")
  }

  /// Upgrading mid-throttle: an older build persisted only `rateLimitedUntil.<provider>`.
  /// That deadline must still be honoured, not bypassed after the 120s minimum gap.
  func testLegacyRateLimitDeadlineIsHonouredAfterUpgrade() async {
    let defaults = makeDefaults()
    let future = Date().addingTimeInterval(45 * 60)
    defaults.set(future, forKey: "rateLimitedUntil.codex")  // only the legacy key

    let fetched = Flag()
    let provider = StubProvider(provider: .codex) {
      fetched.set()
      return snapshot("codex:window")
    }
    let model = UsageModel(provider: provider, defaults: defaults, restoring: nil, network: StubNetwork(), log: discardLog)
    let wait = await model.refresh(trigger: "after-upgrade")

    XCTAssertFalse(fetched.isSet, "must not fetch while a legacy 429 deadline is still in force")
    XCTAssertGreaterThan(wait, 30 * 60, "should wait out the stored deadline")
    XCTAssertNotNil(defaults.object(forKey: "nextAttemptAt.codex"), "the legacy deadline should be migrated forward")
  }

  /// Replacing rejected credentials must end the hold they caused. Without this the panel tells
  /// you to refresh the CLI and then ignores the result for the rest of the interval.
  func testReplacedCredentialsEndTheAuthHold() async {
    let defaults = makeDefaults()
    let credentials = Box("token-a")
    let reject = Box(true)
    let provider = StubProvider(
      provider: .codex, outcome: { if reject.value { throw UsageError.sessionExpired } else { return snapshot("codex:window") } },
      credentials: credentials)
    let model = UsageModel(provider: provider, defaults: defaults, restoring: nil, network: StubNetwork(), log: discardLog)

    let held = await model.refresh(trigger: "test")
    XCTAssertGreaterThan(held, 120, "a rejection should hold off")

    // Same credentials: the hold must stand.
    let stillHeld = await model.refresh(trigger: "unchanged")
    XCTAssertGreaterThan(stillHeld, 0)
    XCTAssertNotNil(defaults.object(forKey: "nextAttemptAt.codex"), "an unchanged token must not clear the hold")

    // The CLI writes a new token: the next attempt must go through and succeed.
    credentials.value = "token-b"
    reject.value = false
    let afterRefresh = await model.refresh(trigger: "after-cli-refresh")
    XCTAssertGreaterThan(afterRefresh, 60, "a success returns the normal poll interval")
    XCTAssertNil(defaults.object(forKey: "nextAttemptAt.codex"), "replaced credentials should have cleared the hold")
  }

  /// A 429 is the server asking for quiet, not a credential problem, so new credentials must
  /// not be treated as licence to retry early.
  func testReplacedCredentialsDoNotCutShortARateLimitHold() async {
    let defaults = makeDefaults()
    let credentials = Box("token-a")
    let provider = StubProvider(provider: .codex, outcome: { throw UsageError.rateLimited(retryAfter: 3600) }, credentials: credentials)
    let model = UsageModel(provider: provider, defaults: defaults, restoring: nil, network: StubNetwork(), log: discardLog)

    let held = await model.refresh(trigger: "test")
    XCTAssertGreaterThan(held, 30 * 60, "a 429 with retry-after should hold for the hour")

    credentials.value = "token-b"
    let afterRefresh = await model.refresh(trigger: "after-cli-refresh")
    XCTAssertGreaterThan(afterRefresh, 30 * 60, "new credentials must not shorten a rate-limit hold")
  }

  func testSuccessClearsBackoff() async {
    let defaults = makeDefaults()
    let model = UsageModel(
      provider: StubProvider(provider: .codex) { snapshot("codex:window") }, defaults: defaults, restoring: nil, network: StubNetwork(),
      log: discardLog)
    let wait = await model.refresh(trigger: "test")
    XCTAssertGreaterThan(wait, 60, "a success returns the normal poll interval")
    XCTAssertNil(defaults.object(forKey: "nextAttemptAt.codex"))
    XCTAssertNil(model.rateLimitedUntil)
  }

  /// Retry-After is a hard floor: jitter must never schedule earlier than the server asked.
  func testRetryAfterIsAStrictLowerBound() async {
    let retryAfter: TimeInterval = 3600  // above the local floor, so jitter is the only risk
    for _ in 0..<200 {
      let defaults = makeDefaults()
      let provider = StubProvider(provider: .codex) { throw UsageError.rateLimited(retryAfter: retryAfter) }
      let model = UsageModel(provider: provider, defaults: defaults, restoring: nil, network: StubNetwork(), log: discardLog)
      let wait = await model.refresh(trigger: "test")
      XCTAssertGreaterThanOrEqual(wait, retryAfter, "never retry before the server's Retry-After")
    }
  }

  func testRateLimitUsesLocalFloorWhenServerAsksForLess() async {
    let defaults = makeDefaults()
    let provider = StubProvider(provider: .codex) { throw UsageError.rateLimited(retryAfter: 1) }
    let model = UsageModel(provider: provider, defaults: defaults, restoring: nil, network: StubNetwork(), log: discardLog)
    let wait = await model.refresh(trigger: "test")
    XCTAssertGreaterThan(wait, 10 * 60, "a tiny Retry-After must not defeat the local floor")
    XCTAssertNotNil(model.rateLimitedUntil)
  }
}
