import Foundation
import Network
import UsageState
import UserNotifications
import XCTest
import os

@testable import TokenRation

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
