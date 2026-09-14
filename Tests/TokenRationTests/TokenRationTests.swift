import Foundation
import UsageState
import XCTest

@testable import TokenRation

/// A provider stub that returns whatever the test asks for, and counts calls.
private struct StubProvider: UsageProviding {
  let provider: Provider
  let outcome: @Sendable () throws -> UsageSnapshot
  /// Stands in for credentials that are missing or expired without an attempt being made.
  var credentialFault: UsageError? = nil
  /// Stands in for the credentials on disk; read through a box so a test can swap them
  /// mid-flight the way the CLI rewriting the Keychain does.
  var credentials: Box<String>? = nil

  func fetch() async throws -> UsageSnapshot { try outcome() }
  func credentialFingerprint() async -> String? { credentials?.value }
  func credentialProblem() async -> UsageError? { credentialFault }
}

/// A value a `@Sendable` provider can read and a test can change.
private final class Box<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: T
  init(_ value: T) { stored = value }
  var value: T {
    get {
      lock.lock();
      defer { lock.unlock() };
      return stored
    }
    set {
      lock.lock();
      stored = newValue;
      lock.unlock()
    }
  }
}

/// Mutable flag usable from a `@Sendable` closure.
private final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  func set() {
    lock.lock();
    value = true;
    lock.unlock()
  }
  var isSet: Bool {
    lock.lock();
    defer { lock.unlock() };
    return value
  }
}

private func makeDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
  let defaults = UserDefaults(suiteName: name)!
  defaults.removePersistentDomain(forName: name)
  return defaults
}

private func snapshot(_ id: String) -> UsageSnapshot {
  UsageSnapshot(
    metrics: [
      DisplayMetric(
        id: id, provider: .codex, title: "T", symbolName: "clock", barText: "1%", valueText: "1% used", fraction: 0.01, severity: .normal,
        resetsAt: nil)
    ], updatedAt: Date())
}

// MARK: - 1. Codex-only installs / unavailable pins

@MainActor final class PreferencesTests: XCTestCase {
  func testCodexOnlyMachineDefaultsToACodexPin() {
    let prefs = Preferences(available: [.codex], defaults: makeDefaults())
    XCTAssertEqual(prefs.shownMetricIDs, ["codex:window"])
    XCTAssertFalse(
      prefs.shownMetricIDs.contains { $0.hasPrefix("claude:") }, "a Codex-only Mac must not pin an unpinnable Claude placeholder")
  }

  func testPinsForUndetectedProvidersArePruned() {
    let defaults = makeDefaults()
    defaults.set(["claude:session", "codex:window"], forKey: "shownMetricIDs")

    let prefs = Preferences(available: [.codex], defaults: defaults)
    XCTAssertEqual(prefs.shownMetricIDs, ["codex:window"])
    // The pruning is persisted, so it doesn't reappear next launch.
    XCTAssertEqual(defaults.stringArray(forKey: "shownMetricIDs"), ["codex:window"])
  }

  func testPruningNeverLeavesTheMenuBarEmpty() {
    let defaults = makeDefaults()
    defaults.set(["claude:session"], forKey: "shownMetricIDs")

    let prefs = Preferences(available: [.codex], defaults: defaults)
    XCTAssertEqual(prefs.shownMetricIDs, ["codex:window"])
  }

}

// MARK: - 5b. Pins for metrics that vanish from a snapshot

@MainActor final class PinReconciliationTests: XCTestCase {
  func testPinForVanishedPerModelMetricIsDropped() {
    let defaults = makeDefaults()
    defaults.set(["codex:window", "codex:model:retired"], forKey: "shownMetricIDs")
    let prefs = Preferences(available: [.codex], defaults: defaults)

    // Codex reported successfully, but the per-model limit is gone.
    prefs.reconcile(knownIDs: ["codex:window"], settled: [.codex])

    XCTAssertEqual(prefs.shownMetricIDs, ["codex:window"])
    XCTAssertEqual(defaults.stringArray(forKey: "shownMetricIDs"), ["codex:window"])
  }

  func testPinsAreKeptForProvidersThatHaveNotReportedYet() {
    let defaults = makeDefaults()
    defaults.set(["claude:session", "codex:window"], forKey: "shownMetricIDs")
    let prefs = Preferences(available: [.claude, .codex], defaults: defaults)

    // Only Codex has data; Claude's pin must survive until Claude actually reports.
    prefs.reconcile(knownIDs: ["codex:window"], settled: [.codex])
    XCTAssertEqual(prefs.shownMetricIDs, ["claude:session", "codex:window"])
  }

  func testReconcileKeepsAtLeastOnePin() {
    let defaults = makeDefaults()
    defaults.set(["codex:model:retired"], forKey: "shownMetricIDs")
    let prefs = Preferences(available: [.codex], defaults: defaults)

    prefs.reconcile(knownIDs: ["codex:window"], settled: [.codex])
    XCTAssertEqual(prefs.shownMetricIDs, ["codex:window"], "reconciling must never leave the menu bar with nothing pinned")
  }

  func testReconcileIsANoOpBeforeAnyProviderReports() {
    let defaults = makeDefaults()
    defaults.set(["codex:model:retired"], forKey: "shownMetricIDs")
    let prefs = Preferences(available: [.codex], defaults: defaults)

    prefs.reconcile(knownIDs: [], settled: [])
    XCTAssertEqual(prefs.shownMetricIDs, ["codex:model:retired"])
  }
}

// MARK: - Holds

@MainActor final class HeldUntilTests: XCTestCase {
  /// The UI needs the effective deadline, not just the 429 one: a hold after an auth failure
  /// refuses a manual refresh exactly the same way.
  func testAuthHoldIsReported() async {
    let model = UsageModel(
      provider: StubProvider(provider: .codex) { throw UsageError.sessionExpired }, defaults: makeDefaults(), restoring: nil)
    XCTAssertNil(model.heldUntil, "nothing has failed yet")

    await model.refresh(trigger: "test")
    XCTAssertNotNil(model.heldUntil, "an auth hold refuses a refresh, so it must be visible to the UI")
    XCTAssertNil(model.rateLimitedUntil, "and it is not a throttle")
  }

  func testRateLimitHoldIsReported() async {
    let model = UsageModel(
      provider: StubProvider(provider: .codex) { throw UsageError.rateLimited(retryAfter: 600) }, defaults: makeDefaults(), restoring: nil)
    await model.refresh(trigger: "test")
    XCTAssertNotNil(model.heldUntil)
  }

  /// A deadline in the past is not a hold: the button must come back when the wait is over.
  func testExpiredDeadlineIsNotAHold() {
    let defaults = makeDefaults()
    defaults.set(Date(timeIntervalSinceNow: -60), forKey: "nextAttemptAt.codex")
    let model = UsageModel(provider: StubProvider(provider: .codex) { snapshot("codex:window") }, defaults: defaults, restoring: nil)
    XCTAssertNil(model.heldUntil)
  }

  /// The minimum gap refuses a manual refresh just as a backoff does — including right after a
  /// successful poll — so the button must be disabled then too.
  func testMinimumGapCountsAsAHold() async {
    let model = UsageModel(provider: StubProvider(provider: .codex) { snapshot("codex:window") }, defaults: makeDefaults(), restoring: nil)
    await model.refresh(trigger: "test")
    XCTAssertNil(model.rateLimitedUntil, "nothing failed")
    XCTAssertNotNil(model.heldUntil, "a refresh inside the gap is refused, so it is a hold")
  }

  /// The wiring, not just the formatter: the tooltip has to ask for the wait form, or a correct
  /// `ResetText.wait` never reaches the button and the hold still reads "in 0m".
  func testTooltipReportsASubMinuteHoldInSeconds() {
    let now = Date()
    XCTAssertEqual(UsagePanelView.refreshHelp(refreshing: false, heldUntil: now.addingTimeInterval(45), now: now), "Next attempt in 45s")
  }

  func testTooltipWordsTheOtherTwoStates() {
    let now = Date()
    XCTAssertEqual(UsagePanelView.refreshHelp(refreshing: false, heldUntil: nil, now: now), "Refresh now")
    XCTAssertEqual(UsagePanelView.refreshHelp(refreshing: true, heldUntil: nil, now: now), "Refreshing…")
  }

  func testNoHoldWhenNothingHasFailed() {
    let model = UsageModel(provider: StubProvider(provider: .codex) { snapshot("codex:window") }, defaults: makeDefaults(), restoring: nil)
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
      restoring: nil)

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
      defaults: defaults, restoring: nil)

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
      restoring: nil)

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
      restoring: nil)

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
      provider: StubProvider(provider: .codex) { throw UsageError.sessionExpired }, defaults: makeDefaults(), restoring: nil)
    await model.refresh(trigger: "test")
    XCTAssertTrue(model.needsSignIn)
  }

  func testMissingCredentialsAlsoAskForAttention() async {
    let model = UsageModel(
      provider: StubProvider(provider: .codex) { throw UsageError.notSignedIn }, defaults: makeDefaults(), restoring: nil)
    await model.refresh(trigger: "test")
    XCTAssertTrue(model.needsSignIn)
  }

  /// A relaunch restores the backoff but not the reason for it, so the state is asked of the
  /// credentials rather than waited for — otherwise stale numbers sit under a normal glyph until
  /// the next attempt, up to a quarter of an hour later.
  func testCredentialStateIsAskedForNotWaitedFor() async {
    let model = UsageModel(
      provider: StubProvider(provider: .codex, outcome: { snapshot("codex:window") }, credentialFault: UsageError.sessionExpired),
      defaults: makeDefaults(), restoring: nil)
    XCTAssertFalse(model.needsSignIn, "nothing has been asked yet")

    await model.refreshCredentialState()
    XCTAssertTrue(model.needsSignIn, "the credentials answer without an attempt being made")
    XCTAssertEqual(model.lastError, UsageError.sessionExpired.errorDescription, "the panel needs the reason, not just the menu bar's glyph")
  }

  /// And usable credentials clear it, so signing in while held off drops the warning.
  func testUsableCredentialsClearTheWarning() async {
    let model = UsageModel(
      provider: StubProvider(provider: .codex) { throw UsageError.sessionExpired }, defaults: makeDefaults(), restoring: nil)
    await model.refresh(trigger: "test")
    XCTAssertTrue(model.needsSignIn)

    await model.refreshCredentialState()
    XCTAssertFalse(model.needsSignIn, "the stub's credentials are usable, so the warning goes")
  }

  /// Being throttled is not something the user can act on, so it must not raise the warning.
  func testRateLimitDoesNotAskForAttention() async {
    let model = UsageModel(
      provider: StubProvider(provider: .codex) { throw UsageError.rateLimited(retryAfter: 60) }, defaults: makeDefaults(), restoring: nil)
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
      defaults: defaults, restoring: nil)
    await model.refresh(trigger: "test")
    XCTAssertTrue(model.needsSignIn)

    failing.value = false
    defaults.set(Date(timeIntervalSinceNow: -1), forKey: "nextAttemptAt.codex")
    defaults.set(Date(timeIntervalSinceNow: -600), forKey: "lastAttemptAt.codex")
    let resumed = UsageModel(provider: StubProvider(provider: .codex) { snapshot("codex:window") }, defaults: defaults, restoring: nil)
    await resumed.refresh(trigger: "retry")
    XCTAssertFalse(resumed.needsSignIn)
  }
}

// MARK: - Token expiry

final class TokenExpiryTests: XCTestCase {
  private func secret(expiresAt: String) -> String {
    #"{"claudeAiOauth":{"accessToken":"sk-test","refreshToken":"r","expiresAt":"# + expiresAt + #"}}"#
  }

  /// An expired token is still a token, and the endpoint answers 429 rather than 401 — so sending
  /// one reads as a rate limit and buries a sign-in problem under hours of backoff.
  func testExpiredTokenIsRejectedBeforeUse() {
    let past = (Date().timeIntervalSince1970 - 3600) * 1000
    XCTAssertThrowsError(try KeychainToken.token(fromSecret: secret(expiresAt: String(past)))) { error in
      guard case UsageError.sessionExpired = error else { return XCTFail("expected sessionExpired, got \(error)") }
    }
  }

  func testUnexpiredTokenIsReturned() throws {
    let future = (Date().timeIntervalSince1970 + 3600) * 1000
    XCTAssertEqual(try KeychainToken.token(fromSecret: secret(expiresAt: String(future))), "sk-test")
  }

  /// No expiry recorded means the token is used: refusing it would be worse than trying it.
  func testMissingExpiryIsNotTreatedAsExpired() throws {
    let secret = #"{"claudeAiOauth":{"accessToken":"sk-test","refreshToken":"r"}}"#
    XCTAssertEqual(try KeychainToken.token(fromSecret: secret), "sk-test")
  }

  /// The CLI writes milliseconds. Seconds are read too, so a change of unit cannot make a valid
  /// token look decades expired.
  func testSecondsAndMillisecondsBothParse() {
    let seconds = Date().timeIntervalSince1970 + 3600
    XCTAssertEqual(KeychainToken.expiryDate(seconds)?.timeIntervalSince1970 ?? 0, seconds, accuracy: 1)
    XCTAssertEqual(KeychainToken.expiryDate(seconds * 1000)?.timeIntervalSince1970 ?? 0, seconds, accuracy: 1)
    XCTAssertNil(KeychainToken.expiryDate(0), "a zero expiry is the CLI's signed-out blob, not 1970")
    XCTAssertNil(KeychainToken.expiryDate(nil))
  }
}

// MARK: - Relative times

final class ResetTextTests: XCTestCase {
  /// Measured against a passed-in moment, so a ticking view refreshes without new data.
  func testCountdownFollowsTheReferenceDate() {
    let resets = Date(timeIntervalSince1970: 10_000)
    let early = ResetText.short(until: resets, from: Date(timeIntervalSince1970: 10_000 - 7200))
    let later = ResetText.short(until: resets, from: Date(timeIntervalSince1970: 10_000 - 600))
    XCTAssertEqual(early, "2h")
    XCTAssertEqual(later, "10m")
    XCTAssertNotEqual(early, later, "the same reset must read differently as time passes")
  }

  /// A reset already in the past reads as nothing, never as a negative or a wrapped duration.
  func testPastResetIsEmpty() {
    let resets = Date(timeIntervalSince1970: 10_000)
    XCTAssertEqual(ResetText.short(until: resets, from: Date(timeIntervalSince1970: 20_000)), "0m", "clamped, never negative")
  }

  /// The regression: `short` allows no unit below a minute, so the refresh button spent the last
  /// minute of every hold telling the user the next attempt was "in 0m".
  func testSubMinuteWaitIsReportedInSeconds() {
    let now = Date()
    XCTAssertEqual(ResetText.wait(until: now.addingTimeInterval(45), from: now), "45s")
    XCTAssertEqual(ResetText.wait(until: now.addingTimeInterval(1), from: now), "1s")
  }

  /// Rounding up, because a wait still in force must never render as no wait at all.
  func testAPartialSecondStillCountsAsASecond() {
    let now = Date()
    XCTAssertEqual(ResetText.wait(until: now.addingTimeInterval(0.2), from: now), "1s")
  }

  /// A minute or more keeps the coarse wording, so the button and the reset countdowns beside it
  /// do not disagree about how a duration is written.
  func testAMinuteOrMoreKeepsTheCoarseWording() {
    let now = Date()
    XCTAssertEqual(ResetText.wait(until: now.addingTimeInterval(120), from: now), "2m")
    XCTAssertEqual(
      ResetText.wait(until: now.addingTimeInterval(3600), from: now), ResetText.short(until: now.addingTimeInterval(3600), from: now))
  }

  /// Reset countdowns are unchanged: they are measured in hours and the menu bar redraws every
  /// half-minute, so seconds there would be both pointless and stale.
  func testResetCountdownsAreUnaffected() {
    let now = Date()
    XCTAssertEqual(ResetText.short(until: now.addingTimeInterval(45), from: now), "0m")
  }
}

// MARK: - Codex plan shapes

/// Codex plans differ in which rate-limit windows exist and which slot each arrives in. These
/// decode the wire payload the way the provider does, so plans nobody here can sign in to are
/// still covered.
final class CodexWindowTests: XCTestCase {
  private func metrics(_ json: String) throws -> [DisplayMetric] {
    let envelope = try JSONDecoder().decode(CodexUsageProvider.Envelope.self, from: Data(json.utf8))
    return CodexUsageProvider.metrics(from: try XCTUnwrap(envelope.result))
  }

  private func payload(_ limits: String) -> String { #"{"id":2,"result":{"rateLimits":{"# + limits + #"}}}"# }

  /// A weekly-only plan: one window, named and glyphed as the long one.
  func testWeeklyOnlyPlan() throws {
    let result = try metrics(payload(#""primary":{"usedPercent":41,"windowDurationMins":10080,"resetsAt":2000000}"#))
    XCTAssertEqual(result.map(\.title), ["Weekly (7-day)"])
    XCTAssertEqual(result.map(\.id), ["codex:window"], "the id names the role, not the slot it arrived in")
  }

  /// A plan with both windows, short one in `secondary`.
  func testShortWindowInSecondary() throws {
    let result = try metrics(
      payload(#""primary":{"usedPercent":41,"windowDurationMins":10080},"secondary":{"usedPercent":12,"windowDurationMins":300}"#))
    XCTAssertEqual(result.map(\.title), ["Session (5-hour)", "Weekly (7-day)"], "shortest window first")
  }

  /// The same plan shape with the slots swapped. Titles, order and glyphs must not change, because
  /// the slot carries no meaning — this is the case a weekly-only account cannot exercise.
  func testShortWindowInPrimary() throws {
    let result = try metrics(
      payload(#""primary":{"usedPercent":12,"windowDurationMins":300},"secondary":{"usedPercent":41,"windowDurationMins":10080}"#))
    XCTAssertEqual(result.map(\.title), ["Session (5-hour)", "Weekly (7-day)"], "order follows duration, not slot")
    // Paired with the title rather than checked by position: a positional check passes if order
    // and glyph are both wrong in the same direction.
    let glyphs = Dictionary(uniqueKeysWithValues: result.map { ($0.title, $0.symbolName) })
    XCTAssertEqual(glyphs["Session (5-hour)"], Provider.codex.symbol(for: .session), "a 5-hour limit must not wear the weekly glyph")
    XCTAssertEqual(glyphs["Weekly (7-day)"], Provider.codex.symbol(for: .window))
  }

  /// A monthly credit cap is the Codex analogue of Claude's extra usage: it has a total, so it
  /// gets a proportion, a reset and a severity rather than a bare number.
  func testMonthlyCreditCap() throws {
    let result = try metrics(
      payload(
        #""primary":{"usedPercent":10,"windowDurationMins":10080},"#
          + #""individualLimit":{"limit":"1000","used":"920","remainingPercent":8,"resetsAt":2000000}"#))
    let cap = try XCTUnwrap(result.first { $0.id == "codex:spend" })
    XCTAssertEqual(cap.title, "Monthly credits")
    XCTAssertEqual(cap.barText, "92%", "used is the complement of remaining")
    XCTAssertEqual(cap.valueText, "920 / 1000 · 92%")
    XCTAssertEqual(cap.fraction, 0.92)
    XCTAssertEqual(cap.severity, .critical, "92% used must not read as normal")
    XCTAssertNotNil(cap.resetsAt, "a monthly cap resets, unlike a credit balance")
  }

  /// The documented types say string; a projection sending numbers must not break the payload.
  func testCapAcceptsNumbersOrStrings() throws {
    let asNumbers = try metrics(payload(#""individualLimit":{"limit":1000,"used":920,"remainingPercent":8}"#))
    XCTAssertEqual(asNumbers.first?.valueText, "920 / 1000 · 92%", "numeric fields render the same as strings")
    let asStrings = try metrics(payload(#""individualLimit":{"limit":"1000","used":"920","remainingPercent":"8"}"#))
    XCTAssertEqual(asStrings.first?.valueText, "920 / 1000 · 92%")
  }

  /// A cap with no percentage cannot be drawn as a proportion, so it is not shown at all.
  func testCapWithoutAPercentIsSkipped() throws {
    let result = try metrics(payload(#""individualLimit":{"limit":"1000","used":"920"}"#))
    XCTAssertFalse(result.contains { $0.id == "codex:spend" })
  }

  /// A window payload with a cap present must still decode the windows — the reason both scalar
  /// forms are accepted is that a mismatch here would take the working rows down too.
  func testWindowsSurviveAnUnexpectedCapShape() throws {
    let result = try metrics(
      payload(#""primary":{"usedPercent":10,"windowDurationMins":10080},"individualLimit":{"limit":{"nested":true}}"#))
    XCTAssertEqual(result.map(\.title), ["Weekly (7-day)"], "the weekly window still reports")
  }

  /// Credits carry approximate message counts, which mean more than an opaque credit figure.
  func testCreditsShowApproximateMessages() throws {
    let result = try metrics(payload(#""credits":{"hasCredits":true,"balance":"420","approxLocalMessages":80,"approxCloudMessages":12}"#))
    let credits = try XCTUnwrap(result.first { $0.id == "codex:credits" })
    XCTAssertEqual(credits.valueText, "420 remaining · ~80 local, ~12 cloud msgs")
    XCTAssertNil(credits.fraction, "a balance has no denominator, so no bar")
  }

  /// A balance cannot signal exhaustion by itself; the spend-control flag is the only signal.
  func testSpendControlReachedMakesCreditsCritical() throws {
    let result = try metrics(payload(#""credits":{"hasCredits":true,"balance":"0"},"spendControlReached":true"#))
    XCTAssertEqual(result.first { $0.id == "codex:credits" }?.severity, .critical)
  }

  /// An account without credits shows no credits row at all.
  func testNoCreditsMeansNoRow() throws {
    let result = try metrics(payload(#""credits":{"hasCredits":false,"balance":"0"}"#))
    XCTAssertFalse(result.contains { $0.id == "codex:credits" })
  }

  /// A window with no stated duration must not be guessed at.
  func testWindowWithoutADurationIsUnnamed() throws {
    let result = try metrics(payload(#""primary":{"usedPercent":5}"#))
    XCTAssertEqual(result.map(\.title), ["Usage limit"])
    XCTAssertEqual(result.map(\.symbolName), [Provider.codex.symbol(for: .window)], "an unknown window is the long one")
  }
}

// MARK: - Credentials

final class KeychainTokenTests: XCTestCase {
  /// The CLI writes the credential back with empty strings when its refresh token has expired
  /// and the refresh fails. Sending that as a bearer token earns an HTTP 429, so treating it as
  /// a real token makes the app report a throttle and back off for hours over a sign-in problem.
  func testEmptyAccessTokenIsSignedOut() {
    let secret = #"{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}"#
    XCTAssertThrowsError(try KeychainToken.token(fromSecret: secret)) { error in
      guard case UsageError.notSignedIn = error else { return XCTFail("expected notSignedIn, got \(error)") }
    }
  }

  func testTokenIsReadFromTheBlob() throws {
    let secret = #"{"claudeAiOauth":{"accessToken":"sk-test-value","refreshToken":"r"}}"# + "\n"
    XCTAssertEqual(try KeychainToken.token(fromSecret: secret), "sk-test-value")
  }

  func testGarbageIsSignedOut() {
    XCTAssertThrowsError(try KeychainToken.token(fromSecret: "not json")) { error in
      guard case UsageError.notSignedIn = error else { return XCTFail("expected notSignedIn, got \(error)") }
    }
  }
}

// MARK: - Cold start

@MainActor final class RestoredReadingTests: XCTestCase {
  private func published(updatedAt: Date?) -> UsageState {
    UsageState(
      writtenAt: Date(), pollIntervalSeconds: 300,
      providers: [
        ProviderUsage(
          provider: "codex", displayName: "Codex", status: "ok", error: nil, updatedAt: updatedAt, rateLimitedUntil: nil,
          metrics: [
            MetricUsage(
              id: "codex:window", title: "Weekly (7-day)", usedPercent: 41, value: "41%", detail: "41% used", severity: "warning",
              resetsAt: Date(timeIntervalSince1970: 2_000_000))
          ])
      ])
  }

  /// A cold start must show the last known numbers, not a spinner: the guards can defer the
  /// first fetch for minutes, and the reading is already on disk.
  func testLastReadingIsShownBeforeAnyFetch() {
    let updatedAt = Date(timeIntervalSinceNow: -600)
    let model = UsageModel(
      provider: StubProvider(provider: .codex) { snapshot("codex:window") }, defaults: makeDefaults(),
      restoring: published(updatedAt: updatedAt))

    XCTAssertTrue(model.snapshot.hasData, "the stored reading should be on screen immediately")
    XCTAssertEqual(model.snapshot.metrics.first?.barText, "41%")
    XCTAssertEqual(model.snapshot.metrics.first?.fraction, 0.41, "percent is stored 0-100 and displayed 0-1")
    XCTAssertEqual(model.snapshot.metrics.first?.severity, .warning, "severity must survive the round trip")
    XCTAssertEqual(model.snapshot.metrics.first?.provider, .codex, "the provider comes back from the namespaced id")
    XCTAssertFalse(model.snapshot.metrics.first?.symbolName.isEmpty ?? true, "a glyph is rebuilt from the id")
    XCTAssertEqual(model.snapshot.updatedAt, updatedAt, "age must be the reading's own, so the footer isn't misleading")
    XCTAssertTrue(model.isStale(), "a ten-minute-old reading should still trigger a top-up")
  }

  /// A reading with no timestamp is not worth showing: the panel would claim data of unknown age.
  func testReadingWithoutATimestampIsIgnored() {
    let model = UsageModel(
      provider: StubProvider(provider: .codex) { snapshot("codex:window") }, defaults: makeDefaults(), restoring: published(updatedAt: nil))
    XCTAssertFalse(model.snapshot.hasData)
  }

  /// Another provider's reading must not be adopted.
  func testOnlyTheMatchingProviderIsRestored() {
    let model = UsageModel(
      provider: StubProvider(provider: .claude) { snapshot("claude:session") }, defaults: makeDefaults(),
      restoring: published(updatedAt: Date()))
    XCTAssertFalse(model.snapshot.hasData, "a Codex reading must not appear under Claude")
  }
}

// MARK: - Update checking

@MainActor final class UpdateCheckerTests: XCTestCase {
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
    defaults.set(Date(), forKey: "lastUpdateCheck")
    defaults.set("0.9.9", forKey: "latestKnownVersion")
    let checker = UpdateChecker(defaults: defaults)

    await checker.check()
    XCTAssertEqual(checker.latestVersion, "0.9.9", "a skipped check must not disturb the cached answer")
  }

  /// With no record of a previous check, the first one has to run.
  func testFirstCheckIsDue() { XCTAssertTrue(UpdateChecker(defaults: makeDefaults()).isDue) }

  /// A check that just happened must suppress the next one, or the panel trigger would fire a
  /// request on every click.
  func testRecentCheckIsNotDue() {
    let defaults = makeDefaults()
    defaults.set(Date(), forKey: "lastUpdateCheck")
    XCTAssertFalse(UpdateChecker(defaults: defaults).isDue)
  }

  /// The cached answer has to be readable before any network call completes, or the panel shows
  /// nothing on launch even when an update is already known.
  func testCachedVersionIsRestoredAtInit() {
    let defaults = makeDefaults()
    defaults.set("1.2.3", forKey: "latestKnownVersion")
    XCTAssertEqual(UpdateChecker(defaults: defaults).latestVersion, "1.2.3")
  }
}

// MARK: - 2. Backoff persistence · 4. Retry-After as a strict lower bound

@MainActor final class BackoffTests: XCTestCase {
  /// An auth failure must survive stop/start. A backoff held only in the polling task's sleep
  /// is lost when the loop restarts, falling back to the 120s minimum gap.
  func testAuthBackoffSurvivesStopStart() async {
    let defaults = makeDefaults()
    let provider = StubProvider(provider: .codex) { throw UsageError.notSignedIn }
    let model = UsageModel(provider: provider, defaults: defaults)

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

    let first = await UsageModel(provider: provider, defaults: defaults).refresh(trigger: "test")
    XCTAssertGreaterThan(first, 120, "must exceed the minimum gap, or the retry is skipped instead of attempted")
    XCTAssertLessThan(first, 5 * 60, "a rotated token should be picked up within minutes")

    // Let the first deadline lapse. A fresh model is what a relaunch looks like, and it restores
    // the stored failure count, so this stands in for the second consecutive rejection.
    defaults.set(Date().addingTimeInterval(-1), forKey: "nextAttemptAt.codex")
    defaults.set(Date().addingTimeInterval(-10 * 60), forKey: "lastAttemptAt.codex")
    let second = await UsageModel(provider: provider, defaults: defaults).refresh(trigger: "retry")
    XCTAssertGreaterThan(second, 10 * 60, "a token that stays rejected needs a sign-in, so stop retrying quickly")
  }

  /// The same, across a relaunch: a fresh model reading the same defaults must still hold off.
  func testBackoffSurvivesRelaunch() async {
    let defaults = makeDefaults()
    let failing = StubProvider(provider: .codex) { throw UsageError.badResponse }
    let first = UsageModel(provider: failing, defaults: defaults)
    let wait = await first.refresh(trigger: "test")
    XCTAssertGreaterThan(wait, 30, "a general failure should back off at least a minute-ish")

    // A brand-new model is what a relaunch looks like. It must honour the stored deadline
    // even though the 120s minimum gap alone would have allowed a retry much sooner.
    let relaunched = UsageModel(provider: failing, defaults: defaults)
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
    let model = UsageModel(provider: provider, defaults: defaults)
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
    let model = UsageModel(provider: provider, defaults: defaults)

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
    let model = UsageModel(provider: provider, defaults: defaults)

    let held = await model.refresh(trigger: "test")
    XCTAssertGreaterThan(held, 30 * 60, "a 429 with retry-after should hold for the hour")

    credentials.value = "token-b"
    let afterRefresh = await model.refresh(trigger: "after-cli-refresh")
    XCTAssertGreaterThan(afterRefresh, 30 * 60, "new credentials must not shorten a rate-limit hold")
  }

  func testSuccessClearsBackoff() async {
    let defaults = makeDefaults()
    let model = UsageModel(provider: StubProvider(provider: .codex) { snapshot("codex:window") }, defaults: defaults)
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
      let model = UsageModel(provider: provider, defaults: defaults)
      let wait = await model.refresh(trigger: "test")
      XCTAssertGreaterThanOrEqual(wait, retryAfter, "never retry before the server's Retry-After")
    }
  }

  func testRateLimitUsesLocalFloorWhenServerAsksForLess() async {
    let defaults = makeDefaults()
    let provider = StubProvider(provider: .codex) { throw UsageError.rateLimited(retryAfter: 1) }
    let model = UsageModel(provider: provider, defaults: defaults)
    let wait = await model.refresh(trigger: "test")
    XCTAssertGreaterThan(wait, 10 * 60, "a tiny Retry-After must not defeat the local floor")
    XCTAssertNotNil(model.rateLimitedUntil)
  }
}

// MARK: - 3. Codex subprocess timeout and cancellation

/// A real hanging child. `/bin/sleep` was useless here: `CodexExchange` always appends
/// `app-server`, so `sleep app-server` died instantly with "invalid time interval" and the
/// tests passed without ever reaching the watchdog or the cancellation path.
private struct HangingFixture {
  let url: URL
  /// Unique, so `pgrep -f` can prove the child is gone afterwards.
  var marker: String { url.lastPathComponent }

  init() throws {
    url = FileManager.default.temporaryDirectory.appendingPathComponent("tokenration-hang-\(UUID().uuidString).sh")
    // Ignores its arguments and stdin, and stays alive until signalled.
    try "#!/bin/sh\nwhile :; do sleep 0.2; done\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }

  func cleanUp() { try? FileManager.default.removeItem(at: url) }

  /// How many live processes still match this fixture.
  func liveProcessCount() -> Int {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", marker]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return -1 }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    return text.split(separator: "\n").filter { !$0.isEmpty }.count
  }

  /// pgrep also matches this test process's own argv in some setups; poll for it to settle.
  func waitForExit(timeout: TimeInterval = 5) -> Int {
    let deadline = Date().addingTimeInterval(timeout)
    var count = liveProcessCount()
    while count > 0, Date() < deadline {
      usleep(100_000)
      count = liveProcessCount()
    }
    return count
  }
}

final class CodexTimeoutTests: XCTestCase {
  /// A child that never writes must hit the watchdog — and be terminated by it.
  func testHangingSubprocessTimesOutAndIsTerminated() async throws {
    let fixture = try HangingFixture()
    defer { fixture.cleanUp() }
    let timeout: TimeInterval = 2

    let started = Date()
    do {
      _ = try await CodexUsageProvider.readRateLimits(binary: fixture.url.path, timeout: timeout)
      XCTFail("a hanging child must not return a result")
    } catch {
      let elapsed = Date().timeIntervalSince(started)
      // Proves the watchdog fired rather than the child dying on its own.
      XCTAssertGreaterThanOrEqual(elapsed, timeout - 0.5, "should have waited for the watchdog")
      XCTAssertLessThan(elapsed, timeout + 8, "must not block indefinitely")
      if case UsageError.badResponse = error {} else { XCTFail("expected a badResponse timeout, got \(error)") }
    }
    XCTAssertEqual(fixture.waitForExit(), 0, "the child must be terminated on timeout")
  }

  /// Cancelling must unblock immediately and tear the child down.
  func testCancellationTerminatesTheChild() async throws {
    let fixture = try HangingFixture()
    defer { fixture.cleanUp() }

    let task = Task { try await CodexUsageProvider.readRateLimits(binary: fixture.url.path, timeout: 120) }
    // Let it actually launch, so cancellation races a live process.
    try await Task.sleep(for: .milliseconds(400))
    let started = Date()
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("cancellation should surface an error")
    } catch { XCTAssertLessThan(Date().timeIntervalSince(started), 10, "cancellation must not wait out the 120s timeout") }
    XCTAssertEqual(fixture.waitForExit(), 0, "the child must be terminated on cancellation")
  }

  /// Cancelling during launch must not leak an unmonitored child.
  func testCancellationDuringLaunchDoesNotLeak() async throws {
    let fixture = try HangingFixture()
    defer { fixture.cleanUp() }

    let task = Task { try await CodexUsageProvider.readRateLimits(binary: fixture.url.path, timeout: 120) }
    // Cancel immediately, so it lands while `process.run()` is in flight.
    task.cancel()
    _ = try? await task.value
    XCTAssertEqual(fixture.waitForExit(), 0, "a child launched as cancellation landed must still be reaped")
  }

  /// A child that exits without answering resolves via EOF, not the watchdog.
  func testProcessExitingWithoutAnswerFailsPromptly() async {
    let started = Date()
    _ = try? await CodexUsageProvider.readRateLimits(binary: "/usr/bin/true", timeout: 30)
    XCTAssertLessThan(Date().timeIntervalSince(started), 10, "EOF should resolve the exchange without waiting for the timeout")
  }
}

// MARK: - 5. MCP freshness reflects the provider reading, not the file

final class FreshnessTests: XCTestCase {
  private func provider(updatedAt: Date?) -> ProviderUsage {
    ProviderUsage(
      provider: "claude", displayName: "Claude", status: "ok", error: nil, updatedAt: updatedAt, rateLimitedUntil: nil, metrics: [])
  }

  /// The app rewrites the file on refresh starts, errors and connectivity changes, so a
  /// just-written file can still hold an old reading. Age must come from `updatedAt`.
  func testAgeComesFromTheProviderReadingNotTheFile() {
    let now = Date()
    let old = provider(updatedAt: now.addingTimeInterval(-3600))
    let state = UsageState(writtenAt: now, pollIntervalSeconds: 300, providers: [old])

    XCTAssertEqual(old.readingAge(now: now) ?? 0, 3600, accuracy: 2)
    XCTAssertTrue(
      old.isStale(pollIntervalSeconds: state.pollIntervalSeconds, now: now),
      "an hour-old reading is stale even though the file was just written")
  }

  func testFreshReadingIsNotStale() {
    let now = Date()
    let fresh = provider(updatedAt: now.addingTimeInterval(-30))
    XCTAssertFalse(fresh.isStale(pollIntervalSeconds: 300, now: now))
  }

  func testProviderWithNoReadingCountsAsStale() {
    let never = provider(updatedAt: nil)
    XCTAssertNil(never.readingAge())
    XCTAssertTrue(never.isStale(pollIntervalSeconds: 300), "a provider that has never produced a reading must not look fresh")
  }

  func testStateRoundTripsThroughJSON() throws {
    let now = Date()
    let state = UsageState(writtenAt: now, pollIntervalSeconds: 300, providers: [provider(updatedAt: now)])
    let data = try UsageStateStore.makeEncoder().encode(state)
    let decoded = try UsageStateStore.makeDecoder().decode(UsageState.self, from: data)
    XCTAssertEqual(decoded.providers.count, 1)
    XCTAssertEqual(decoded.pollIntervalSeconds, 300)
    XCTAssertEqual(decoded.providers[0].updatedAt?.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970, accuracy: 1)
  }
}

// MARK: - 6. The MCP summary line carries the state, not just the numbers

final class UsageSummaryTests: XCTestCase {
  private func state(status: String, error: String?, ageSeconds: TimeInterval, now: Date) -> UsageState {
    let metric = MetricUsage(
      id: "claude:session", title: "Session (5-hour)", usedPercent: 46, value: "46%", detail: "46% used", severity: "normal",
      resetsAt: now.addingTimeInterval(3600))
    let provider = ProviderUsage(
      provider: "claude", displayName: "Claude", status: status, error: error, updatedAt: now.addingTimeInterval(-ageSeconds),
      rateLimitedUntil: nil, metrics: [metric])
    return UsageState(writtenAt: now, pollIntervalSeconds: 300, providers: [provider])
  }

  func testHealthyProviderCarriesNoWarning() {
    let now = Date()
    let line = UsageSummary.text(for: state(status: "ok", error: nil, ageSeconds: 30, now: now), now: now)

    XCTAssertEqual(line, "Claude: Session (5-hour) 46% (resets in 1h 0m) · read 30s ago")
  }

  /// The defect this guards: the status used to be rendered only when a provider had no metrics,
  /// so an expired session holding its last reading was reported as bare percentages.
  func testErrorLeadsTheLineAheadOfTheNumbers() {
    let now = Date()
    let message = "Session expired — open Claude Code to refresh"
    let line = UsageSummary.text(for: state(status: "error", error: message, ageSeconds: 14400, now: now), now: now)

    XCTAssertTrue(line.contains(message), "the summary must name the problem, not just the numbers: \(line)")
    guard let warning = line.range(of: "⚠"), let numbers = line.range(of: "46%") else {
      return XCTFail("expected both a warning and the metrics in: \(line)")
    }
    XCTAssertLessThan(warning.lowerBound, numbers.lowerBound, "the warning must come before the numbers it qualifies: \(line)")
  }

  func testStaleReadingIsFlaggedAndItsAgeIsLegible() {
    let now = Date()
    let line = UsageSummary.text(for: state(status: "ok", error: nil, ageSeconds: 3600, now: now), now: now)

    XCTAssertTrue(line.contains("[⚠ stale]"), "an hour-old reading under a 5-minute poll is stale: \(line)")
    XCTAssertTrue(line.contains("read 1h 0m ago"), "a stale age reported in seconds is unreadable: \(line)")
  }

  /// The status is a wire token. It has to reach the line as words, not as `rate_limited`.
  func testWireStatusIsNamedInWordsWithoutAnErrorMessage() {
    let now = Date()
    let line = UsageSummary.text(for: state(status: "rate_limited", error: nil, ageSeconds: 30, now: now), now: now)

    XCTAssertTrue(line.contains("[⚠ rate limited]"), "a status with no message still has to appear: \(line)")
    XCTAssertFalse(line.contains("rate_limited"), "the wire token must not be printed as-is: \(line)")
  }

  /// `error` names no fault on its own, so the message it arrived with is what gets printed.
  func testErrorStatusIsNotPrintedAlongsideItsOwnMessage() {
    let now = Date()
    let line = UsageSummary.text(for: state(status: "error", error: "Not signed in", ageSeconds: 30, now: now), now: now)

    XCTAssertTrue(line.contains("[⚠ Not signed in]"), "the message alone should fill the warning: \(line)")
  }

  func testProviderWithNoReadingSaysSo() {
    let now = Date()
    let provider = ProviderUsage(
      provider: "codex", displayName: "Codex", status: "loading", error: nil, updatedAt: nil, rateLimitedUntil: nil, metrics: [])
    let line = UsageSummary.text(for: UsageState(writtenAt: now, pollIntervalSeconds: 300, providers: [provider]), now: now)

    XCTAssertEqual(line, "Codex: [⚠ no reading yet]", "a provider that has never read is starting up, not stale")
  }
}
