import Foundation
import Network
import UsageState
import UserNotifications
import XCTest
import os

@testable import TokenRation

// MARK: - Codex-only installs / unavailable pins

@MainActor final class PreferencesTests: XCTestCase {
  func testCodexOnlyMachineDefaultsToACodexPin() {
    let prefs = Preferences(available: [.codex], defaults: makeDefaults(), log: discardLog)
    XCTAssertEqual(prefs.shownMetricIDs, ["codex:window"])
    XCTAssertFalse(
      prefs.shownMetricIDs.contains { $0.hasPrefix("claude:") }, "a Codex-only Mac must not pin an unpinnable Claude placeholder")
  }

  func testPinsForUndetectedProvidersArePruned() {
    let defaults = makeDefaults()
    defaults.set(["claude:session", "codex:window"], forKey: "shownMetricIDs")

    let prefs = Preferences(available: [.codex], defaults: defaults, log: discardLog)
    XCTAssertEqual(prefs.shownMetricIDs, ["codex:window"])
    // The pruning is persisted, so it doesn't reappear next launch.
    XCTAssertEqual(defaults.stringArray(forKey: "shownMetricIDs"), ["codex:window"])
  }

  func testPruningNeverLeavesTheMenuBarEmpty() {
    let defaults = makeDefaults()
    defaults.set(["claude:session"], forKey: "shownMetricIDs")

    let prefs = Preferences(available: [.codex], defaults: defaults, log: discardLog)
    XCTAssertEqual(prefs.shownMetricIDs, ["codex:window"])
  }

}

// MARK: - Pins for metrics that vanish from a snapshot

@MainActor final class PinReconciliationTests: XCTestCase {
  func testPinForVanishedPerModelMetricIsDropped() {
    let defaults = makeDefaults()
    defaults.set(["codex:window", "codex:model:retired"], forKey: "shownMetricIDs")
    let prefs = Preferences(available: [.codex], defaults: defaults, log: discardLog)

    // Codex reported successfully, but the per-model limit is gone.
    prefs.reconcile(knownIDs: ["codex:window"], settled: [.codex])

    XCTAssertEqual(prefs.shownMetricIDs, ["codex:window"])
    XCTAssertEqual(defaults.stringArray(forKey: "shownMetricIDs"), ["codex:window"])
  }

  func testPinsAreKeptForProvidersThatHaveNotReportedYet() {
    let defaults = makeDefaults()
    defaults.set(["claude:session", "codex:window"], forKey: "shownMetricIDs")
    let prefs = Preferences(available: [.claude, .codex], defaults: defaults, log: discardLog)

    // Only Codex has data; Claude's pin must survive until Claude actually reports.
    prefs.reconcile(knownIDs: ["codex:window"], settled: [.codex])
    XCTAssertEqual(prefs.shownMetricIDs, ["claude:session", "codex:window"])
  }

  func testReconcileKeepsAtLeastOnePin() {
    let defaults = makeDefaults()
    defaults.set(["codex:model:retired"], forKey: "shownMetricIDs")
    let prefs = Preferences(available: [.codex], defaults: defaults, log: discardLog)

    prefs.reconcile(knownIDs: ["codex:window"], settled: [.codex])
    XCTAssertEqual(prefs.shownMetricIDs, ["codex:window"], "reconciling must never leave the menu bar with nothing pinned")
  }

  func testReconcileIsANoOpBeforeAnyProviderReports() {
    let defaults = makeDefaults()
    defaults.set(["codex:model:retired"], forKey: "shownMetricIDs")
    let prefs = Preferences(available: [.codex], defaults: defaults, log: discardLog)

    prefs.reconcile(knownIDs: [], settled: [])
    XCTAssertEqual(prefs.shownMetricIDs, ["codex:model:retired"])
  }
}
