import Foundation
import Network
import UsageState
import UserNotifications
import XCTest
import os

@testable import TokenRation

// MARK: - Test hygiene

final class DefaultsSuiteTests: XCTestCase {
  /// A defaults suite `makeDefaults` makes is stored in the run's own directory, at its path with `.plist`
  /// appended, never in the user's `~/Library/Preferences`.
  func testDefaultsSuitesStayOutOfTheUsersPreferences() {
    let name = UUID().uuidString
    let defaults = makeDefaults(name)
    defaults.set(1, forKey: "consecutiveFailures.claude")
    XCTAssertTrue(defaults.synchronize())
    let preferences = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: defaultsSuitesDirectory.appendingPathComponent("\(name).plist").path),
      "the defaults suite is in the run's directory")
    XCTAssertFalse(FileManager.default.fileExists(atPath: preferences.appendingPathComponent("\(name).plist").path))
    XCTAssertEqual(
      makeDefaults(name).integer(forKey: "consecutiveFailures.claude"), 0, "a new defaults suite of the same name starts empty")
  }

  /// The observer removes the directory it was given, files and all, when the run ends, so a run leaves no
  /// directory of defaults suites in the temporary directory. It is built here on a scratch directory, never
  /// the run's own.
  func testCleanupRemovesItsDirectoryWhenTheRunEnds() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tokenration-test-cleanup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data().write(to: directory.appendingPathComponent("suite.plist"))
    DefaultsSuitesCleanup(directory: directory).testBundleDidFinish(Bundle.main)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "the directory is gone")
  }
}
