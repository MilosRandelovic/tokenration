import CryptoKit
import Foundation
import os

/// Reads the Claude Code OAuth access token from the login Keychain by invoking
/// `/usr/bin/security`, the same way the Claude Code CLI does.
///
/// Why shell out instead of calling `SecItemCopyMatching` directly: the item
/// "Claude Code-credentials" is owned by Claude Code, so any *other* binary reading it
/// triggers a one-time macOS "allow access" prompt. When the accessor is `/usr/bin/security`
/// (Apple-signed and stable), clicking "Always Allow" once grants access that persists —
/// even across rebuilds of this app, whose own signature would otherwise change. That is
/// what makes it keep "just working" without re-prompting.
///
/// We only read the current token; we never write or refresh it, so we ride Claude Code's
/// own refresh cycle.
enum KeychainToken {
  /// The tool the app reads the Keychain through.
  static let securityTool = URL(fileURLWithPath: "/usr/bin/security")

  /// Reads the token stored for `service` through `tool`: `securityTool` in the app, a fixture in tests. A
  /// read the tool fails is described to `onFailure`, with the tool's exit and what it wrote to stderr, before
  /// it throws `notSignedIn`, so a missing item, refused access and a locked Keychain can be told apart. No
  /// deadline: what holds a read up is usually macOS's access or unlock prompt, waiting for the user.
  static func read(service: String, tool: URL, onFailure: (_ reason: String) -> Void) throws -> String {
    let process = Process()
    process.executableURL = tool
    process.arguments = ["find-generic-password", "-s", service, "-w"]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    do { try process.run() } catch {
      onFailure("could not start \(tool.path): \(error.localizedDescription)")
      throw UsageError.notSignedIn
    }
    // Both streams are read while the tool runs, so neither can fill its pipe and stall it.
    let errorOutput = OSAllocatedUnfairLock(initialState: Data())
    let errorsRead = DispatchGroup()
    errorsRead.enter()
    DispatchQueue.global(qos: .utility).async {
      let written = stderr.fileHandleForReading.readDataToEndOfFile()
      errorOutput.withLock { $0 = written }
      errorsRead.leave()
    }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    errorsRead.wait()
    guard process.terminationStatus == 0 else {
      let message = String(decoding: errorOutput.withLock { $0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      // After an uncaught signal `terminationStatus` holds the signal's number, not an exit status.
      let ending = process.terminationReason == .uncaughtSignal ? "was ended by signal" : "exited with status"
      onFailure("\(tool.lastPathComponent) \(ending) \(process.terminationStatus)" + (message.isEmpty ? "" : ": \(message)"))
      throw UsageError.notSignedIn
    }

    // `security -w` prints the secret plus a trailing newline; trim before parsing.
    guard let text = String(data: data, encoding: .utf8) else {
      onFailure("the stored credential is not text")
      throw UsageError.notSignedIn
    }
    return try token(fromSecret: text, onFailure: onFailure)
  }

  /// Interprets the stored expiry, which the CLI writes in epoch milliseconds. Seconds are
  /// accepted too, so a change of unit degrades to "no expiry known" rather than treating a
  /// valid token as expired.
  static func expiryDate(_ value: Double?) -> Date? {
    guard let value, value > 0 else { return nil }
    return Date(timeIntervalSince1970: value > 1_000_000_000_000 ? value / 1000 : value)
  }

  /// A short digest of `token`: enough to tell that it changed, not enough to use.
  static func fingerprint(of token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  /// Pulls the access token out of the stored blob.
  ///
  /// An empty token counts as signed out. The CLI writes the credential back with empty strings
  /// when its refresh token has expired and the refresh fails, and sending `Bearer ` with nothing
  /// after it earns an HTTP 429 rather than a 401 — so without this check the app reads a
  /// throttle where the real answer is "sign in again", and backs off for hours over it.
  ///
  /// A credential that cannot be used is described to `onFailure` before the throw, as a failed read is.
  static func token(fromSecret text: String, onFailure: (_ reason: String) -> Void = { _ in }) throws -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let jsonData = trimmed.data(using: .utf8), let blob = try? JSONDecoder().decode(CredentialsBlob.self, from: jsonData) else {
      onFailure("the stored credential is not one TokenRation can read")
      throw UsageError.notSignedIn
    }
    guard !blob.claudeAiOauth.accessToken.isEmpty else {
      onFailure("the stored credential holds no token, as Claude Code leaves it when a refresh fails")
      throw UsageError.notSignedIn
    }
    // An expired token is still a token: the endpoint answers 429 rather than 401, so
    // sending one anyway reads as a rate limit and buries a sign-in problem under hours of
    // backoff. The expiry sits beside the token, so there is no reason to find out the hard
    // way. The CLI refreshes it; this app never does.
    if let expiry = expiryDate(blob.claudeAiOauth.expiresAt), expiry <= Date() {
      onFailure("the stored token has expired")
      throw UsageError.sessionExpired
    }
    return blob.claudeAiOauth.accessToken
  }

  /// The stored secret is a JSON blob: { "claudeAiOauth": { "accessToken": ..., "expiresAt": ... } }
  private struct CredentialsBlob: Decodable {
    let claudeAiOauth: OAuth
    struct OAuth: Decodable {
      let accessToken: String
      /// Epoch milliseconds, as the CLI writes them.
      let expiresAt: Double?
    }
  }
}
