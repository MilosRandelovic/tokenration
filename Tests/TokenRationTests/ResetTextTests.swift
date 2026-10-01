import Foundation
import Network
import UsageState
import UserNotifications
import XCTest
import os

@testable import TokenRation

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
