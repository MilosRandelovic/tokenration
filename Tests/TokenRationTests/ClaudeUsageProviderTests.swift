import Foundation
import Network
import UsageState
import UserNotifications
import XCTest
import os

@testable import TokenRation

// MARK: - The Claude provider's request and responses

final class ClaudeUsageProviderTests: XCTestCase {
  /// Credentials a test chooses: a token, or the error that stops one.
  private struct FixtureCredentials: ClaudeCredentials {
    var outcome: Result<String, UsageError> = .success("sk-fixture")

    func token() throws -> String { try outcome.get() }
    func fingerprint() throws -> String { try outcome.get() + "-fingerprint" }
  }

  private func provider(answering answer: @escaping StubURLProtocol.Handler, credentials: FixtureCredentials = FixtureCredentials())
    -> ClaudeUsageProvider
  { ClaudeUsageProvider(session: StubURLProtocol.session(answering: answer), credentials: credentials) }

  /// A reading is built from the response's `limits`.
  func testReadingComesFromTheLimits() async throws {
    let reading = try await provider(
      answering: StubURLProtocol.respond(200, body: #"{"limits":[{"kind":"session","percent":42,"severity":"normal"}]}"#)
    ).fetch()
    XCTAssertEqual(reading.metrics.map(\.id), ["claude:session"])
    XCTAssertEqual(reading.metrics.first?.barText, "42%")
  }

  /// An answer whose only limit is of an unknown kind but which carries extra usage is still a reading, of the
  /// spend alone: the empty-reading guard refuses only an answer with nothing to show.
  func testSpendAloneIsAReading() async throws {
    let body = #"{"limits":[{"kind":"renamed","percent":42}],"spend":{"used":{"amount_minor":1250,"currency":"USD","exponent":2}}}"#
    let reading = try await provider(answering: StubURLProtocol.respond(200, body: body)).fetch()
    XCTAssertEqual(reading.metrics.map(\.id), ["claude:spend"])
  }

  /// The request carries the OAuth token, the `anthropic-beta` header Claude Code sends, and TokenRation's
  /// `User-Agent`.
  func testRequestCarriesTheTokenAndHeaders() async throws {
    let asked = Box<URLRequest?>(nil)
    _ = try await provider(answering: { request in
      asked.value = request
      return StubURLProtocol.respond(200, body: #"{"limits":[{"kind":"session","percent":42,"severity":"normal"}]}"#)(request)
    }).fetch()
    let request = try XCTUnwrap(asked.value)
    XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-fixture")
    XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "TokenRation")
  }

  /// A rejected token, 401 or 403, is an expired session, which asks the user to sign in again.
  func testRejectedTokenIsAnExpiredSession() async {
    for status in [401, 403] {
      do {
        _ = try await provider(answering: StubURLProtocol.respond(status)).fetch()
        XCTFail("\(status) must not return a reading")
      } catch UsageError.sessionExpired {} catch { XCTFail("\(status): expected sessionExpired, got \(error)") }
    }
  }

  /// A rate limit carries the server's `Retry-After`, in seconds or as an HTTP date, which the backoff
  /// then treats as a hard lower bound; without one, or with one that is neither, it carries none.
  func testRateLimitCarriesRetryAfter() async {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    let inNinetySeconds = formatter.string(from: Date().addingTimeInterval(90))
    let cases: [(name: String, headers: [String: String], expected: ClosedRange<TimeInterval>?)] = [
      ("in seconds", ["Retry-After": "120"], 120...120), ("as an HTTP date", ["Retry-After": inNinetySeconds], 85...90),
      ("absent", [:], nil), ("neither seconds nor a date", ["Retry-After": "soon"], nil),
    ]
    for testCase in cases {
      do {
        _ = try await provider(answering: StubURLProtocol.respond(429, headers: testCase.headers)).fetch()
        XCTFail("\(testCase.name): a rate limit must not return a reading")
      } catch UsageError.rateLimited(let retryAfter) {
        if let expected = testCase.expected {
          XCTAssertTrue(retryAfter.map(expected.contains) == true, "\(testCase.name): \(String(describing: retryAfter))")
        } else {
          XCTAssertNil(retryAfter, testCase.name)
        }
      } catch { XCTFail("\(testCase.name): expected rateLimited, got \(error)") }
    }
  }

  /// Any other status is a failed request, which takes the ordinary backoff.
  func testOtherStatusesAreFailedRequests() async {
    do {
      _ = try await provider(answering: StubURLProtocol.respond(500)).fetch()
      XCTFail("500 must not return a reading")
    } catch UsageError.requestFailed(let status) { XCTAssertEqual(status, 500) } catch { XCTFail("expected requestFailed, got \(error)") }
  }

  /// A 200 with nothing TokenRation can show is a bad response rather than an empty reading, whether its body
  /// is not JSON, is JSON of another shape or holds only limits of kinds this build does not know: an empty
  /// reading would drop the last numbers and show the tab as loading, with nothing in the log to say why.
  func testUnreadableBodyIsABadResponse() async {
    let cases = [
      ("not JSON", "<html>blocked</html>"), ("JSON of another shape", "{}"),
      ("only unknown kinds", #"{"limits":[{"kind":"renamed","percent":42,"severity":"normal"}]}"#),
    ]
    for (name, body) in cases {
      do {
        _ = try await provider(answering: StubURLProtocol.respond(200, body: body)).fetch()
        XCTFail("\(name): must not return a reading")
      } catch UsageError.badResponse {} catch { XCTFail("\(name): expected badResponse, got \(error)") }
    }
  }

  /// A token the credentials refuse stops the fetch before any request is made.
  func testMissingTokenStopsTheRequest() async {
    let asked = Box(0)
    let refused = provider(
      answering: { request in
        asked.value += 1
        return StubURLProtocol.respond(200)(request)
      }, credentials: FixtureCredentials(outcome: .failure(.notSignedIn)))
    do {
      _ = try await refused.fetch()
      XCTFail("no token, no reading")
    } catch UsageError.notSignedIn {} catch { XCTFail("expected notSignedIn, got \(error)") }
    XCTAssertEqual(asked.value, 0, "no request without a token")
  }

  /// The credential checks read the credentials and never the network: a problem is the one the token
  /// read raises, and a fingerprint that cannot be read is a marker, so signing back in reads as a change.
  func testCredentialChecksReadOnlyTheCredentials() async {
    let asked = Box(0)
    let counting: StubURLProtocol.Handler = { request in
      asked.value += 1
      return StubURLProtocol.respond(200)(request)
    }
    let expired = provider(answering: counting, credentials: FixtureCredentials(outcome: .failure(.sessionExpired)))
    let problem = await expired.credentialProblem()
    if case .sessionExpired? = problem {} else { XCTFail("expected sessionExpired, got \(String(describing: problem))") }
    let unreadable = await expired.credentialFingerprint()
    XCTAssertEqual(unreadable, "none")
    let signedIn = provider(answering: counting)
    let noProblem = await signedIn.credentialProblem()
    XCTAssertNil(noProblem)
    let fingerprint = await signedIn.credentialFingerprint()
    XCTAssertEqual(fingerprint, "sk-fixture-fingerprint")
    XCTAssertEqual(asked.value, 0, "the checks make no request")
  }
}
