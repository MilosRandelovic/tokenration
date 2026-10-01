import Foundation
import Network
import UsageState
import UserNotifications
import XCTest
import os

@testable import TokenRation

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
      restoring: published(updatedAt: updatedAt), network: StubNetwork(), log: discardLog)

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
      provider: StubProvider(provider: .codex) { snapshot("codex:window") }, defaults: makeDefaults(), restoring: published(updatedAt: nil),
      network: StubNetwork(), log: discardLog)
    XCTAssertFalse(model.snapshot.hasData)
  }

  /// Another provider's reading must not be adopted.
  func testOnlyTheMatchingProviderIsRestored() {
    let model = UsageModel(
      provider: StubProvider(provider: .claude) { snapshot("claude:session") }, defaults: makeDefaults(),
      restoring: published(updatedAt: Date()), network: StubNetwork(), log: discardLog)
    XCTAssertFalse(model.snapshot.hasData, "a Codex reading must not appear under Claude")
  }
}
