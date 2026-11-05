import Foundation
import XCTest

@testable import TokenRation

// MARK: - The Grok provider

/// Each test works in a home of its own, with Grok Build's sign-in and, where a test needs one, a fixture `grok` in
/// its `.grok` or in a fixture Homebrew directory, so no test reads the user's sign-in or starts the user's Grok Build.
final class GrokUsageProviderTests: XCTestCase {
  private var home: URL!

  override func setUpWithError() throws {
    home = FileManager.default.temporaryDirectory.appendingPathComponent("tokenration-grok-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".grok/bin"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: homebrew, withIntermediateDirectories: true)
  }

  /// Stands in for Homebrew's bin directory.
  private var homebrew: URL { home.appendingPathComponent("homebrew/bin") }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

  /// A time `offset` from now as Grok writes it, with microseconds.
  private func stamp(_ offset: TimeInterval) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date().addingTimeInterval(offset)).replacingOccurrences(of: "Z", with: "123Z")
  }

  /// An xAI sign-in as `grok login` writes it, with its token expiring `expiresIn` from now.
  private func xai(_ key: String, expiresIn: TimeInterval) -> [String: String] {
    ["key": key, "auth_mode": "oidc", "oidc_issuer": "https://auth.x.ai", "user_id": "user-fixture", "expires_at": stamp(expiresIn)]
  }

  /// Grok Build's sign-in file, holding `entries` under scopes of their own.
  private func signIn(_ entries: [[String: String]]) throws {
    let file = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ("scope-\($0.offset)", $0.element) })
    try JSONSerialization.data(withJSONObject: file).write(to: GrokSignIn.file(home: home))
  }

  private func signIn(key: String = "grok-fixture", expiresIn: TimeInterval) throws { try signIn([xai(key, expiresIn: expiresIn)]) }

  /// The weekly allowance of a unified account that has used none of it, as the endpoint sends it: proto3 JSON leaves
  /// the zero percentage out.
  private let unusedWeek = #"""
    {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-11-01T00:00:00+00:00","end":"2026-11-08T00:00:00+00:00"},"onDemandCap":{"val":0},"onDemandUsed":{"val":0},"prepaidBalance":{"val":0},"isUnifiedBillingUser":true}}
    """#

  private func provider(answering answer: @escaping StubURLProtocol.Handler, logged: Box<[String]> = Box([])) -> GrokUsageProvider {
    GrokUsageProvider(
      home: home, session: StubURLProtocol.session(answering: answer), binDirectories: [homebrew], log: { logged.value.append($0) },
      timeout: 10)
  }

  /// An answer that fails the test: for a fetch that must not ask over HTTP.
  private let unasked: StubURLProtocol.Handler = { request in
    XCTFail("asked over HTTP: \(request.url?.absoluteString ?? "")")
    return .failure(URLError(.notConnectedToInternet))
  }

  /// A fixture `grok` at `binary`, where Grok Build installs it unless a test says otherwise, which records how it was
  /// started and answers `initialize` and then the query with `answer`. With `checkingOrder`, it notes whether the
  /// query arrived before it answered `initialize`, waiting a second for one that comes too early.
  @discardableResult private func grokBuild(answering answer: String, checkingOrder: Bool = false, at binary: URL? = nil) throws -> URL {
    let calls = home.appendingPathComponent("calls")
    let order = home.appendingPathComponent("order")
    let waitForEarlyQuery =
      checkingOrder
      ? """
      if read -t 1 early; then echo early > '\(order.path)'; else echo waited > '\(order.path)'; fi
      """ : ""
    let script = """
      #!/bin/bash
      echo "$* ${GROK_DISABLE_AUTOUPDATER:-unset}" >> '\(calls.path)'
      IFS= read -r initialize
      \(waitForEarlyQuery)
      printf '%s\\n' '{"jsonrpc":"2.0","method":"_x.ai/mcp/servers_updated","params":{}}'
      printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
      while IFS= read -r line; do
        case "$line" in *'"id":2'*) printf '%s\\n' '\(answer)' ;; esac
      done
      """
    let binary = binary ?? home.appendingPathComponent(".grok/bin/grok")
    try script.write(to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    return calls
  }

  private func reply(_ result: String) -> String { #"{"jsonrpc":"2.0","id":2,"result":"# + result + "}" }

  // MARK: Detection and sign-in

  /// Grok counts as set up once its sign-in file exists, and not before.
  func testSetUpOnceSignedIn() throws {
    XCTAssertFalse(GrokUsageProvider.isSetUp(home: home))
    try signIn(expiresIn: 3600)
    XCTAssertTrue(GrokUsageProvider.isSetUp(home: home))
  }

  /// Of several xAI sign-ins the one that lasts longest is used, and its expiry is read through Grok's microseconds.
  /// Only an xAI sign-in can read billing, so an API key, an enterprise identity provider's token and a legacy web
  /// login are passed over however long they last, as is an empty token.
  func testLongestLastingXAISignInIsUsed() throws {
    try signIn([
      xai("older", expiresIn: -3600), xai("current", expiresIn: 5 * 3600), xai("", expiresIn: 9 * 3600),
      ["key": "api-key", "auth_mode": "api_key"],
      ["key": "enterprise", "auth_mode": "oidc", "oidc_issuer": "https://idp.acme.example", "expires_at": stamp(9 * 3600)],
      ["key": "lookalike", "auth_mode": "oidc", "oidc_issuer": "https://login.x.ai", "expires_at": stamp(9 * 3600)],
      ["key": "legacy", "auth_mode": "web_login", "oidc_issuer": "https://auth.x.ai", "expires_at": stamp(9 * 3600)],
    ])
    let used = try GrokSignIn.read(home: home)
    XCTAssertEqual(used.key, "current")
    XCTAssertEqual(used.userID, "user-fixture")
    XCTAssertEqual(try XCTUnwrap(used.expiresAt).timeIntervalSinceNow, 5 * 3600, accuracy: 5)
    XCTAssertTrue(used.isCurrent(at: Date()))
    XCTAssertFalse(used.isCurrent(at: Date().addingTimeInterval(5 * 3600 - 30)), "a token about to expire is not sent")

    try signIn([["key": "issued", "auth_mode": "external", "oidc_issuer": "https://auth.x.ai", "create_time": stamp(-86400)]])
    let issued = try GrokSignIn.read(home: home)
    XCTAssertEqual(
      try XCTUnwrap(issued.expiresAt).timeIntervalSinceNow, 29 * 86400, accuracy: 5, "with no expiry, Grok's 30 days from issue")

    try signIn([["key": "api-key", "auth_mode": "api_key"]])
    XCTAssertThrowsError(try GrokSignIn.read(home: home), "no xAI sign-in is no sign-in")
  }

  /// No sign-in is a sign-in problem, reported before any fetch; an expired token is not one, since a fetch has Grok
  /// Build renew it. The fingerprint follows the token, so a renewal or a sign-in ends a sign-in hold.
  func testMissingSignInIsTheOnlyCredentialProblem() async throws {
    let grok = provider(answering: unasked)
    let missing = await grok.credentialProblem()
    XCTAssertEqual(missing?.errorDescription, "Not signed in to Grok Build.")
    let none = await grok.credentialFingerprint()
    do {
      _ = try await grok.fetch()
      XCTFail("no sign-in must not return a reading")
    } catch UsageError.grokNotSignedIn {} catch { XCTFail("expected grokNotSignedIn, got \(error)") }

    try signIn(key: "first", expiresIn: -60)
    let expired = await grok.credentialProblem()
    XCTAssertNil(expired)
    let first = await grok.credentialFingerprint()
    try signIn(key: "renewed", expiresIn: 3600)
    let renewed = await grok.credentialFingerprint()
    XCTAssertNotEqual(first, none)
    XCTAssertNotEqual(renewed, first)
  }

  // MARK: Over HTTP

  /// A current token is sent as Grok Build sends it, to the endpoint behind its `/usage` screen, and Grok Build is
  /// not started.
  func testCurrentTokenIsAskedOverHTTP() async throws {
    try signIn(expiresIn: 3600)
    let calls = try grokBuild(answering: reply(unusedWeek))
    let asked = Box<URLRequest?>(nil)
    let answer = StubURLProtocol.respond(200, body: unusedWeek)
    let reading = try await provider(answering: { request in
      asked.value = request
      return answer(request)
    }).fetch()

    let request = try XCTUnwrap(asked.value)
    XCTAssertEqual(request.url?.absoluteString, "https://cli-chat-proxy.grok.com/v1/billing?format=credits")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer grok-fixture")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-XAI-Token-Auth"), "xai-grok-cli")
    XCTAssertEqual(request.value(forHTTPHeaderField: "x-userid"), "user-fixture")
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "TokenRation")
    XCTAssertEqual(reading.metrics.map(\.id), ["grok:window"])
    XCTAssertEqual(reading.metrics.first?.title, "Weekly (all Grok)")
    XCTAssertEqual(reading.metrics.first?.barText, "0%", "a percentage left out is none used")
    XCTAssertEqual(reading.metrics.first?.resetsAt, Date(timeIntervalSince1970: 1_794_096_000))
    XCTAssertFalse(FileManager.default.fileExists(atPath: calls.path), "Grok Build must not be started")
  }

  /// A rate limit carries the server's `Retry-After`, which the backoff takes as a hard lower bound, and starts no
  /// Grok Build: only a refused token is one to renew.
  func testRateLimitCarriesRetryAfter() async throws {
    try signIn(expiresIn: 3600)
    let calls = try grokBuild(answering: reply(unusedWeek))
    do {
      _ = try await provider(answering: StubURLProtocol.respond(429, headers: ["Retry-After": "120"])).fetch()
      XCTFail("a rate limit must not return a reading")
    } catch UsageError.rateLimited(let retryAfter) { XCTAssertEqual(retryAfter, 120) } catch {
      XCTFail("expected rateLimited, got \(error)")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: calls.path))
  }

  // MARK: Through Grok Build

  /// An expired token is never sent: Grok Build is started instead, with its update check off and in a process of
  /// its own, and the reading comes from its answer.
  func testExpiredTokenAsksGrokBuild() async throws {
    try signIn(expiresIn: -60)
    let calls = try grokBuild(answering: reply(unusedWeek))
    let logged = Box<[String]>([])
    let reading = try await provider(answering: unasked, logged: logged).fetch()
    XCTAssertEqual(reading.metrics.map(\.title), ["Weekly (all Grok)"])
    XCTAssertEqual(try String(contentsOf: calls, encoding: .utf8), "agent --no-leader stdio 1\n")
    XCTAssertTrue(logged.value.contains("[grok] token expired; asking Grok Build, which renews it"), "logged: \(logged.value)")
  }

  /// A token the endpoint refuses before it is due to expire asks for a sign-in, and starts no Grok Build, which
  /// renews only a token that has run out and would send the refused one again.
  func testRefusedTokenAsksForASignIn() async throws {
    try signIn(expiresIn: 3600)
    let calls = try grokBuild(answering: reply(unusedWeek))
    for status in [401, 403] {
      do {
        _ = try await provider(answering: StubURLProtocol.respond(status)).fetch()
        XCTFail("\(status) must not return a reading")
      } catch UsageError.grokNotSignedIn {} catch { XCTFail("\(status): expected grokNotSignedIn, got \(error)") }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: calls.path), "Grok Build must not be started")
  }

  /// The query waits for Grok Build's reply to `initialize`, during which it renews its token: a query sent with
  /// `initialize` could be answered from the token that had just expired.
  func testQueryWaitsForInitialize() async throws {
    try signIn(expiresIn: -60)
    try grokBuild(answering: reply(unusedWeek), checkingOrder: true)
    _ = try await provider(answering: unasked).fetch()
    XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("order"), encoding: .utf8), "waited\n")
  }

  /// A Grok Build with no sign-in it can use, or whose renewal failed so the endpoint refused the token it sent, asks
  /// for a sign-in; a rate limit is one; any other refusal is a response that cannot be read.
  func testRefusalsAreSortedBySignIn() async throws {
    let refusals: [(data: String, expected: UsageError)] = [
      ("Billing data requires auth with grok.com. Run `grok login` to authenticate.", .grokNotSignedIn),
      ("Billing service error: HTTP 401", .grokNotSignedIn), ("Billing service error: HTTP 429", .rateLimited(retryAfter: nil)),
      ("Billing service error: Forbidden", .grokNotSignedIn), ("Billing service error: HTTP 500", .badResponse),
    ]
    try signIn(expiresIn: -60)
    for refusal in refusals {
      try grokBuild(answering: #"{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"Internal error","data":"\#(refusal.data)"}}"#)
      do {
        _ = try await provider(answering: unasked).fetch()
        XCTFail("a refusal must not return a reading")
      } catch let error as UsageError { XCTAssertEqual(error.errorDescription, refusal.expected.errorDescription, refusal.data) }
    }
  }

  /// ACP's auth-required code asks for a sign-in whatever the words beside it.
  func testAuthRequiredCodeAsksForASignIn() async throws {
    try signIn(expiresIn: -60)
    try grokBuild(answering: #"{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"Something else"}}"#)
    do {
      _ = try await provider(answering: unasked).fetch()
      XCTFail("a refusal must not return a reading")
    } catch UsageError.grokNotSignedIn {} catch { XCTFail("expected grokNotSignedIn, got \(error)") }
  }

  /// Grok Build is started once for a token it could not renew: until `auth.json` holds another, a fetch reports the
  /// sign-in without starting it again, and the sign-in shows as a problem before any fetch.
  func testUnrenewableTokenStartsGrokBuildOnce() async throws {
    try signIn(key: "stale", expiresIn: -60)
    let calls = try grokBuild(answering: #"{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"Billing service error: HTTP 401"}}"#)
    let grok = provider(answering: unasked)
    for _ in 0..<2 {
      do {
        _ = try await grok.fetch()
        XCTFail("an unrenewable token must not return a reading")
      } catch UsageError.grokNotSignedIn {} catch { XCTFail("expected grokNotSignedIn, got \(error)") }
    }
    XCTAssertEqual(try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").count, 1, "started once")
    let problem = await grok.credentialProblem()
    XCTAssertEqual(problem?.errorDescription, "Not signed in to Grok Build.")

    // The same token issued again with a later expiry is a new issue, as Grok itself tells them apart.
    try signIn(key: "stale", expiresIn: -30)
    _ = try? await grok.fetch()
    XCTAssertEqual(try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").count, 2, "a new issue is tried")
  }

  /// A start that fails for any other reason, in words this provider does not recognise, is not repeated every poll
  /// either: Grok Build is started again for the same token no sooner than an hour later.
  func testOtherFailuresRestartGrokBuildAtMostHourly() async throws {
    try signIn(expiresIn: -60)
    let calls = try grokBuild(
      answering: #"{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"Billing service error: upstream unavailable"}}"#)
    let grok = provider(answering: unasked)
    for _ in 0..<3 {
      do {
        _ = try await grok.fetch()
        XCTFail("a failed start must not return a reading")
      } catch UsageError.badResponse {} catch { XCTFail("expected badResponse, got \(error)") }
    }
    XCTAssertEqual(try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").count, 1, "started once")
    let problem = await grok.credentialProblem()
    XCTAssertNil(problem, "a failure that is not the sign-in's is no sign-in problem")
  }

  /// A `grok` Homebrew installed renews an expired token as one Grok Build's installer put in `~/.grok/bin` does.
  func testHomebrewGrokBuildIsUsed() async throws {
    try signIn(expiresIn: -60)
    let calls = try grokBuild(answering: reply(unusedWeek), at: homebrew.appendingPathComponent("grok"))
    let reading = try await provider(answering: unasked).fetch()
    XCTAssertEqual(reading.metrics.map(\.title), ["Weekly (all Grok)"])
    XCTAssertEqual(try String(contentsOf: calls, encoding: .utf8), "agent --no-leader stdio 1\n")
  }

  /// With no `grok` where Grok Build installs it or in Homebrew's directories, an expired token cannot be renewed,
  /// which no sign-in fixes, and the log names every place looked in.
  func testMissingGrokBuildIsUnavailable() async throws {
    try signIn(expiresIn: -60)
    let logged = Box<[String]>([])
    do {
      _ = try await provider(answering: unasked, logged: logged).fetch()
      XCTFail("an expired token with no Grok Build must not return a reading")
    } catch UsageError.grokUnavailable {} catch { XCTFail("expected grokUnavailable, got \(error)") }
    let looked = "[grok] no grok at \(home.appendingPathComponent(".grok/bin/grok").path), \(homebrew.appendingPathComponent("grok").path)"
    XCTAssertTrue(logged.value.contains(looked), "logged: \(logged.value)")
    XCTAssertFalse(UsageError.grokUnavailable.isMissingSignIn)
    XCTAssertTrue(UsageError.grokNotSignedIn.isMissingSignIn)
  }

  // MARK: Mapping

  private func metrics(_ config: String) throws -> [DisplayMetric] {
    let response = try JSONDecoder().decode(GrokUsageProvider.BillingResponse.self, from: Data(#"{"config":\#(config)}"#.utf8))
    return GrokUsageProvider.metrics(from: response)
  }

  /// A monthly allowance that is Grok Build's own is named for both, and its severity follows how much is used.
  func testMonthlyAllowanceOfGrokBuildAlone() throws {
    let allowance = try XCTUnwrap(
      try metrics(#"{"creditUsagePercent":82.4,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_MONTHLY","end":"2026-12-01T00:00:00+00:00"}}"#)
        .first)
    XCTAssertEqual(allowance.title, "Monthly (Grok Build)")
    XCTAssertEqual(allowance.barText, "82%")
    XCTAssertEqual(allowance.severity, .critical)
  }

  /// The older shape, with a limit and its use and no percentage, still gives the proportion, and its period end
  /// the reset.
  func testOlderShapeGivesTheProportion() throws {
    let allowance = try XCTUnwrap(
      try metrics(#"{"monthlyLimit":{"val":10000},"used":{"val":2500},"billingPeriodEnd":"2026-12-01T00:00:00+00:00"}"#).first)
    XCTAssertEqual(allowance.barText, "25%")
    XCTAssertNotNil(allowance.resetsAt)
  }

  /// On-demand spend shows against its cap once one is set, and prepaid credit while any remains; at zero, as an
  /// account without either sends them, neither shows.
  func testSpendShowsOnlyWhereThereIsSome() throws {
    let spending = try metrics(
      #"{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY"},"onDemandCap":{"val":5000},"onDemandUsed":{"val":1840},"prepaidBalance":{"val":2500}}"#
    )
    XCTAssertEqual(spending.map(\.id), ["grok:window", "grok:on-demand", "grok:credits"])
    // In this Mac's locale, as the app shows it: `$` here, `US$` where the local dollar is another.
    func usd(_ amount: Double, _ digits: Int = 2) -> String { Money.string(amount, currency: "USD", fractionDigits: digits) }
    XCTAssertEqual(spending[1].valueText, "\(usd(18.40)) / \(usd(50)) · 37%")
    XCTAssertEqual(spending[1].barText, usd(18, 0))
    XCTAssertEqual(spending[2].valueText, "\(usd(25)) remaining")
    XCTAssertNil(spending[2].fraction, "a balance has no denominator")

    let none = try metrics(#"{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY"},"onDemandCap":{},"prepaidBalance":{}}"#)
    XCTAssertEqual(none.map(\.id), ["grok:window"], "an empty amount is zero")
  }

  /// An answer with nothing to show is a response that cannot be read, so the last numbers stay.
  func testEmptyAnswerIsABadResponse() async throws {
    XCTAssertEqual(try metrics("{}").count, 0)
    try signIn(expiresIn: 3600)
    do {
      _ = try await provider(answering: StubURLProtocol.respond(200, body: #"{"config":{}}"#)).fetch()
      XCTFail("an empty answer must not return a reading")
    } catch UsageError.badResponse {} catch { XCTFail("expected badResponse, got \(error)") }
  }
}
