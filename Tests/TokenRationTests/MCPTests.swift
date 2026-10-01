import Foundation
import Network
import UsageState
import UserNotifications
import XCTest
import os

@testable import TokenRation

// MARK: - MCP freshness reflects the provider reading, not the file

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

// MARK: - The MCP summary line carries the state, not just the numbers

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
