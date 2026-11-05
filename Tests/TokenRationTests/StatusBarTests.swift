import AppKit
import XCTest

@testable import TokenRation

// MARK: - Status item placement

@MainActor final class StatusBarTests: XCTestCase {
  /// The panel opens under the item on the display that was clicked even when the item's one window has moved to
  /// another display's menu bar: the item keeps its distance from that display's right edge and top.
  func testStatusItemIsCarriedToTheDisplayThatWasClicked() {
    let builtIn = NSRect(x: 0, y: 0, width: 1728, height: 1117)
    let external = NSRect(x: 1728, y: -964, width: 1440, height: 2560)
    let onBuiltIn = NSRect(x: 1400, y: 1085, width: 120, height: 32)
    let carried = StatusBarController.statusItemRect(onBuiltIn, movedFrom: builtIn, to: external)
    XCTAssertEqual(carried, NSRect(x: 1728 + 1440 - 328, y: -964 + 2560 - 32, width: 120, height: 32))
    XCTAssertEqual(StatusBarController.statusItemRect(carried, movedFrom: external, to: builtIn), onBuiltIn, "and back again")
  }

  /// A metric names its provider only when the pins span more than one: a bar of one provider's metrics needs no name.
  func testProviderIsNamedOnlyWhenPinsSpanProviders() {
    XCTAssertFalse(StatusBarController.namesProviders(pinned: ["claude:session", "claude:weekly", "claude:model:opus"]))
    XCTAssertFalse(StatusBarController.namesProviders(pinned: ["codex:window"]))
    XCTAssertTrue(StatusBarController.namesProviders(pinned: ["claude:session", "codex:window"]))
    XCTAssertTrue(StatusBarController.namesProviders(pinned: ["claude:session", "claude:weekly", "grok:window"]))
  }

  /// A glyph means one kind of limit whichever provider reports it, so the same kind looks the same across tabs.
  func testEveryProviderUsesTheSameGlyphForTheSameKind() {
    for provider in Provider.allCases {
      XCTAssertEqual(DisplayMetric.symbolName(for: provider.metricID("session")), MetricKind.session.symbolName)
      XCTAssertEqual(DisplayMetric.symbolName(for: provider.metricID("window")), MetricKind.window.symbolName)
      XCTAssertEqual(DisplayMetric.symbolName(for: provider.metricID("model:fixture")), MetricKind.model.symbolName)
      XCTAssertEqual(DisplayMetric.symbolName(for: provider.metricID("credits")), MetricKind.money.symbolName)
    }
    XCTAssertEqual(Set([MetricKind.session, .window, .model, .money].map(\.symbolName)).count, 4, "each kind has a glyph of its own")
  }
}
