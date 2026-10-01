import Foundation
import Network
import UsageState
import UserNotifications
import XCTest
import os

@testable import TokenRation

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

  /// A fixture standing in for `/usr/bin/security`, named as it is, running `script`.
  private func makeTool(_ script: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tokenration-keychain-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let tool = directory.appendingPathComponent("security")
    try ("#!/bin/sh\n" + script).write(to: tool, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    return tool
  }

  /// The token is read through the tool, asked for the service's password alone, and a read that works
  /// logs nothing.
  func testTokenIsReadThroughTheTool() throws {
    let arguments = FileManager.default.temporaryDirectory.appendingPathComponent("tokenration-keychain-args-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: arguments) }
    let tool = try makeTool("printf '%s ' \"$@\" > '\(arguments.path)'\necho '{\"claudeAiOauth\":{\"accessToken\":\"sk-fixture\"}}'\n")
    let logged = Box<[String]>([])
    let credentials = KeychainCredentials(service: "fixture-service", tool: tool, log: { logged.value.append($0) })
    XCTAssertEqual(try credentials.token(), "sk-fixture")
    XCTAssertEqual(try String(contentsOf: arguments, encoding: .utf8), "find-generic-password -s fixture-service -w ")
    XCTAssertEqual(logged.value, [])
  }

  /// A read the tool fails says why in the log, with the tool's exit and what it wrote to stderr: without it a
  /// missing item, refused access and a locked Keychain all read as "Not signed in to Claude Code." with
  /// nothing more. The same failure is logged once, since credentials are read on every attempt and panel
  /// open; a different one is news, and so is the same one again once a read has worked in between.
  func testFailedReadIsLoggedOnce() throws {
    let unique = UUID().uuidString
    let works = FileManager.default.temporaryDirectory.appendingPathComponent("tokenration-keychain-ok-\(unique)")
    let denies = FileManager.default.temporaryDirectory.appendingPathComponent("tokenration-keychain-denied-\(unique)")
    addTeardownBlock {
      try? FileManager.default.removeItem(at: works)
      try? FileManager.default.removeItem(at: denies)
    }
    let tool = try makeTool(
      "if [ -e '\(works.path)' ]; then echo '{\"claudeAiOauth\":{\"accessToken\":\"sk-fixture\"}}'; exit 0; fi\n"
        + "if [ -e '\(denies.path)' ]; then echo 'security: User interaction is not allowed.' >&2; exit 36; fi\n"
        + "echo 'security: The specified item could not be found in the keychain.' >&2\nexit 44\n")
    let logged = Box<[String]>([])
    let credentials = KeychainCredentials(tool: tool, log: { logged.value.append($0) })
    for _ in 0..<2 {
      XCTAssertThrowsError(try credentials.token()) { error in
        guard case UsageError.notSignedIn = error else { return XCTFail("expected notSignedIn, got \(error)") }
      }
    }
    let missing = "[claude] Keychain read: security exited with status 44: security: The specified item could not be found in the keychain."
    XCTAssertEqual(logged.value, [missing], "the same failure, once")

    FileManager.default.createFile(atPath: denies.path, contents: nil)
    XCTAssertThrowsError(try credentials.token())
    let denied = "[claude] Keychain read: security exited with status 36: security: User interaction is not allowed."
    XCTAssertEqual(logged.value, [missing, denied], "a different failure is news")

    try FileManager.default.removeItem(at: denies)
    FileManager.default.createFile(atPath: works.path, contents: nil)
    XCTAssertEqual(try credentials.token(), "sk-fixture")
    try FileManager.default.removeItem(at: works)
    XCTAssertThrowsError(try credentials.token())
    XCTAssertEqual(logged.value, [missing, denied, missing], "after a read that worked, a failure is news again")
  }

  /// A credential the tool reads but TokenRation cannot use is described too, each in its own words, so the log
  /// tells an unreadable blob from the empty one Claude Code leaves after a failed refresh, or an expired token.
  func testUnusableCredentialIsDescribed() {
    let past = (Date().timeIntervalSince1970 - 3600) * 1000
    let cases = [
      ("not json", "the stored credential is not one TokenRation can read"),
      (#"{"claudeAiOauth":{"accessToken":""}}"#, "the stored credential holds no token, as Claude Code leaves it when a refresh fails"),
      (#"{"claudeAiOauth":{"accessToken":"sk-test","expiresAt":"# + String(past) + "}}", "the stored token has expired"),
    ]
    for (secret, expected) in cases {
      let reasons = Box<[String]>([])
      XCTAssertThrowsError(try KeychainToken.token(fromSecret: secret) { reasons.value.append($0) })
      XCTAssertEqual(reasons.value, [expected], secret)
    }
  }

  /// A tool that cannot be started, or that a signal ends, is described too.
  func testEachToolFailureIsDescribed() throws {
    let missingTool = FileManager.default.temporaryDirectory.appendingPathComponent("tokenration-no-such-tool-\(UUID().uuidString)")
    let killed = try makeTool("kill -KILL $$\n")
    for (tool, expected) in [(missingTool, "could not start \(missingTool.path)"), (killed, "security was ended by signal 9")] {
      let reasons = Box<[String]>([])
      XCTAssertThrowsError(try KeychainToken.read(service: "fixture", tool: tool) { reasons.value.append($0) })
      XCTAssertEqual(reasons.value.count, 1, "\(tool.path): \(reasons.value)")
      XCTAssertTrue(reasons.value.first?.hasPrefix(expected) == true, "\(reasons.value)")
    }
  }
}
