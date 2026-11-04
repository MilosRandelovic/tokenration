import Foundation
import os

/// Grok Build's sign-in, as `grok login` leaves it in `~/.grok/auth.json`: an access token that lasts six hours, which
/// Grok renews itself, with the refresh token beside it, whenever it runs. TokenRation only reads the file.
struct GrokSignIn: Sendable, Equatable {
  /// The access token.
  let key: String
  /// Sent with the token, as Grok Build sends it.
  let userID: String?
  let expiresAt: Date?
  /// Tells one issue of the token from the next. The token alone does not, since an issuer may issue the same token
  /// again with a later expiry; Grok tells them apart by the token, its expiry and when it was issued, and so does this.
  let issue: String

  /// Where Grok Build keeps its sign-in under `home`.
  static func file(home: URL) -> URL { home.appendingPathComponent(".grok/auth.json") }

  /// How long Grok takes a token with no `expires_at` to last, from when it was made.
  static let defaultLifetime: TimeInterval = 30 * 86400

  /// The file's first-party xAI sign-in that lasts longest. The file holds one sign-in per scope Grok has been signed in
  /// through, and only an xAI one, made by `grok login` or an xAI auth provider, can read billing, as Grok's own
  /// `x.ai/billing` requires: an API key, an enterprise identity provider's token or a legacy web login is passed
  /// over, as is an empty token. Throws `grokNotSignedIn` when the file is missing or unreadable or holds no such
  /// sign-in.
  static func read(home: URL) throws -> GrokSignIn {
    guard let data = try? Data(contentsOf: file(home: home)), let entries = try? JSONDecoder().decode([String: Entry].self, from: data)
    else { throw UsageError.grokNotSignedIn }
    let signIns = entries.values.compactMap { entry -> GrokSignIn? in
      guard let key = entry.key, !key.isEmpty, entry.isXAI else { return nil }
      let expiry = entry.expiresAt.flatMap(parseDate) ?? entry.createTime.flatMap(parseDate).map { $0 + defaultLifetime }
      let issue = KeychainToken.fingerprint(of: [key, entry.expiresAt ?? "", entry.createTime ?? ""].joined(separator: "\n"))
      return GrokSignIn(key: key, userID: entry.userID, expiresAt: expiry, issue: issue)
    }
    guard let latest = signIns.max(by: { ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast) }) else {
      throw UsageError.grokNotSignedIn
    }
    return latest
  }

  /// Whether the token is still good at `now`, with a minute to spare for the request it is sent with. One whose
  /// expiry cannot be told is taken as run out, so Grok Build, which knows, is asked instead.
  func isCurrent(at now: Date) -> Bool { expiresAt.map { $0.timeIntervalSince(now) > 60 } ?? false }

  /// The expiry carries microseconds (`2026-11-03T06:15:52.369025Z`), more digits than `ISO8601DateFormatter` reads,
  /// so the fraction is dropped: a second either way changes nothing here.
  private static func parseDate(_ string: String) -> Date? {
    let whole = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: whole)
  }

  private struct Entry: Decodable {
    let key: String?
    let authMode: String?
    let oidcIssuer: String?
    let userID: String?
    let createTime: String?
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
      case key
      case authMode = "auth_mode"
      case oidcIssuer = "oidc_issuer"
      case userID = "user_id"
      case createTime = "create_time"
      case expiresAt = "expires_at"
    }

    /// An OIDC or auth-provider sign-in issued by xAI's own issuer, as Grok's `is_xai_auth` judges it.
    var isXAI: Bool {
      guard authMode == "oidc" || authMode == "external", var issuer = oidcIssuer else { return false }
      while issuer.hasSuffix("/") { issuer.removeLast() }
      return issuer == "https://auth.x.ai"
    }
  }
}

/// Reads Grok usage from the billing summary Grok Build's own `/usage` screen shows: the allowance used this period,
/// when the period ends, and any on-demand spend or prepaid credit.
///
/// Asked over HTTP with Grok Build's token while that token is current, and through Grok Build itself once it has
/// run out. Starting `grok agent` renews the token, so its sign-in never lapses for want of TokenRation renewing it,
/// but each start runs Grok's whole start-up — fetching its configuration, models and plugins, and rewriting its
/// `config.toml` — which a request every poll should not cost. Asking over HTTP while the token lasts leaves Grok
/// to start at most once every six hours while it is not otherwise in use. TokenRation never writes `auth.json`:
/// Grok renews its own sign-in.
struct GrokUsageProvider: UsageProviding {
  let provider = Provider.grok
  /// The user's home in the app, a fixture in tests: where `~/.grok` is.
  let home: URL
  /// Asks the billing endpoint: `URLSession.uncached` in the app, a stub in tests.
  let session: URLSession
  /// Where `grok` is looked for after Grok Build's own `~/.grok/bin`: Homebrew's in the app, a fixture in tests.
  let binDirectories: [URL]
  /// Where a start of Grok Build, and why, is recorded: the app's log in the app.
  let log: @Sendable (_ message: String) -> Void
  var endpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
  /// Hard ceiling for an exchange with Grok Build — spawn, initialize, query, parse.
  var timeout: TimeInterval = 20
  /// Grok Build's last failed start, for the issue of the token it was started for. While it holds, Grok Build is not
  /// started again for that issue, which would most likely fail the same way after the whole start-up each retry costs:
  /// a failed renewal holds until `auth.json` holds another issue, and any other failure for `restartAfterFailure`,
  /// whatever its wording, so no refusal Grok words in a way this provider does not recognise starts it every poll.
  private let failedStart = OSAllocatedUnfairLock<FailedStart?>(initialState: nil)
  /// How long a start of Grok Build that failed for any reason but its sign-in holds off the next.
  static let restartAfterFailure: TimeInterval = 3600

  private struct FailedStart: Sendable {
    let issue: String
    let missingSignIn: Bool
    let at: Date
  }

  init(
    home: URL, session: URLSession, binDirectories: [URL], log: @escaping @Sendable (_ message: String) -> Void, timeout: TimeInterval = 20
  ) {
    self.home = home
    self.session = session
    self.binDirectories = binDirectories
    self.log = log
    self.timeout = timeout
  }

  /// Whether Grok Build is signed in on this Mac: its sign-in file exists, which `grok login` leaves. No process is
  /// started and the file is not read, so detection costs nothing a Mac without Grok would notice.
  static func isSetUp(home: URL) -> Bool { FileManager.default.fileExists(atPath: GrokSignIn.file(home: home).path) }

  /// Where `grok` may be, in the order they are tried: where Grok Build's installer puts it and its updates keep it,
  /// then each of `binDirectories`, where Homebrew's `grok-build` cask links it.
  static func binaries(home: URL, binDirectories: [URL]) -> [URL] {
    [home.appendingPathComponent(".grok/bin/grok")] + binDirectories.map { $0.appendingPathComponent("grok") }
  }

  /// Changes with every issue of the token, which is every renewal as well as every sign-in.
  func credentialFingerprint() async -> String? { (try? GrokSignIn.read(home: home))?.issue ?? "none" }

  /// A missing sign-in is a problem, and so is an expired token Grok Build has already failed to renew; one it has
  /// not yet tried is not, since a fetch has Grok Build renew it.
  func credentialProblem() async -> UsageError? {
    do {
      let signIn = try GrokSignIn.read(home: home)
      return !signIn.isCurrent(at: Date()) && heldStart(for: signIn)?.isMissingSignIn == true ? .grokNotSignedIn : nil
    } catch let error as UsageError { return error } catch { return .grokNotSignedIn }
  }

  /// A token the endpoint refuses before it expires is not renewed by starting Grok Build, which renews only one that
  /// has run out, so it is a sign-in to report; the next renewal or sign-in changes the fingerprint and ends the hold.
  func fetch() async throws -> UsageSnapshot {
    let signIn = try GrokSignIn.read(home: home)
    let billing: BillingResponse
    if signIn.isCurrent(at: Date()) {
      billing = try await askOverHTTP(with: signIn)
    } else if let held = heldStart(for: signIn) {
      throw held
    } else {
      log("[grok] token expired; asking Grok Build, which renews it")
      do {
        billing = try await askGrokBuild()
        failedStart.withLock { $0 = nil }
      } catch let error as UsageError {
        // A Grok Build that never started, or a rate limit, which holds off by its own floor, leaves nothing to hold.
        switch error {
        case .grokUnavailable, .rateLimited: break
        default:
          failedStart.withLock { $0 = FailedStart(issue: signIn.issue, missingSignIn: error.isMissingSignIn, at: Date()) }
          log(
            error.isMissingSignIn
              ? "[grok] Grok Build could not renew its sign-in; not starting it again until the sign-in changes"
              : "[grok] Grok Build failed; not starting it again for this sign-in for \(Int(Self.restartAfterFailure / 60)) minutes")
        }
        throw error
      }
    }
    let metrics = Self.metrics(from: billing)
    guard !metrics.isEmpty else { throw UsageError.badResponse }
    return UsageSnapshot(metrics: metrics, updatedAt: Date())
  }

  /// What a fetch reports instead of starting Grok Build again for `signIn`, while its last failed start holds.
  private func heldStart(for signIn: GrokSignIn) -> UsageError? {
    guard let failed = failedStart.withLock({ $0 }), failed.issue == signIn.issue else { return nil }
    if failed.missingSignIn { return .grokNotSignedIn }
    return Date() < failed.at.addingTimeInterval(Self.restartAfterFailure) ? .badResponse : nil
  }

  // MARK: - Asking

  /// The request Grok Build itself makes for `/usage`.
  private func askOverHTTP(with signIn: GrokSignIn) async throws -> BillingResponse {
    var request = URLRequest(url: endpoint)
    request.timeoutInterval = 15
    request.setValue("Bearer \(signIn.key)", forHTTPHeaderField: "Authorization")
    request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
    if let userID = signIn.userID { request.setValue(userID, forHTTPHeaderField: "x-userid") }
    request.setValue("TokenRation", forHTTPHeaderField: "User-Agent")

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw UsageError.badResponse }
    switch http.statusCode {
    case 200: break
    case 401, 403: throw UsageError.grokNotSignedIn
    case 429: throw UsageError.rateLimited(retryAfter: RetryAfter.seconds(http.value(forHTTPHeaderField: "Retry-After")))
    default: throw UsageError.requestFailed(http.statusCode)
    }
    guard let billing = try? JSONDecoder().decode(BillingResponse.self, from: data) else { throw UsageError.badResponse }
    return billing
  }

  /// Starts `grok agent` and calls its `x.ai/billing` method, which answers from the same endpoint after Grok has
  /// renewed its token. Its update check is switched off, so this never updates Grok behind the user's back.
  private func askGrokBuild() async throws -> BillingResponse {
    let candidates = Self.binaries(home: home, binDirectories: binDirectories)
    guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
      log("[grok] no grok at \(candidates.map(\.path).joined(separator: ", "))")
      throw UsageError.grokUnavailable
    }
    let exchange = RPCExchange<BillingResponse>(
      binary: binary.path, request: Self.billingRequest, searchPath: nil, log: log, beforeLaunch: nil)
    return try await exchange.run(timeout: timeout)
  }

  /// `grok agent` sets up its sign-in while it initializes, so the query waits for that reply. `--no-leader` keeps the
  /// exchange to a process of its own rather than one shared with a running Grok.
  static let billingRequest = RPCRequest(
    label: "grok", arguments: ["agent", "--no-leader", "stdio"], environment: ["GROK_DISABLE_AUTOUPDATER": "1"],
    initialize:
      #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{},"clientInfo":{"name":"TokenRation","version":"1"}}}"#,
    query: #"{"jsonrpc":"2.0","id":2,"method":"_x.ai/billing","params":{}}"#, queryAfterInitialize: true, unavailable: .grokUnavailable,
    rejection: rejection(_:))

  /// What Grok Build's refusal of `x.ai/billing` means. It asks for a sign-in, with ACP's auth-required code, when it
  /// has none it can use, and passes the endpoint's refusal on as `Billing service error: HTTP <status>` or in the
  /// endpoint's own words; a refused token there is one Grok could not renew. A rate limit carries no `Retry-After`
  /// through Grok, so the local floor holds. Words this does not recognise are a response that cannot be read, which
  /// `failedStart` still keeps from starting Grok Build every poll.
  static func rejection(_ error: RPCError) -> UsageError {
    if error.code == authRequired { return .grokNotSignedIn }
    let text = error.summary.lowercased()
    if text.contains("http 429") || text.contains("rate limit") { return .rateLimited(retryAfter: nil) }
    let signInWords = ["http 401", "http 403", "auth", "login", "unauthori", "forbidden", "credential", "expired", "token"]
    return signInWords.contains { text.contains($0) } ? .grokNotSignedIn : .badResponse
  }

  /// ACP's error code for a request that needs authentication first.
  static let authRequired = -32000

  // MARK: - Wire format

  /// The billing summary, as the endpoint and `x.ai/billing` both return it. Amounts are in US cents, and proto3 JSON
  /// leaves out any field whose value is zero, so an absent amount or percentage is zero.
  struct BillingResponse: Decodable, Sendable {
    let config: Config?

    struct Config: Decodable, Sendable {
      /// The allowance used this period, 0 to 100.
      let creditUsagePercent: Double?
      let currentPeriod: Period?
      let onDemandCap: Cents?
      let onDemandUsed: Cents?
      let prepaidBalance: Cents?
      /// Whether the allowance is the pool every Grok product draws from, rather than Grok Build's own.
      let isUnifiedBillingUser: Bool?
      /// The older shape's period end, for a server that sends no `currentPeriod`.
      let billingPeriodEnd: String?
      /// The older shape's allowance and use, for a server that sends no percentage.
      let monthlyLimit: Cents?
      let used: Cents?
    }

    struct Period: Decodable, Sendable {
      /// `USAGE_PERIOD_TYPE_WEEKLY` or `USAGE_PERIOD_TYPE_MONTHLY`.
      let type: String?
      let end: String?
    }

    struct Cents: Decodable, Sendable {
      let val: Int?
      var cents: Int { val ?? 0 }
    }
  }

  // MARK: - Mapping

  static func metrics(from response: BillingResponse) -> [DisplayMetric] {
    guard let config = response.config else { return [] }
    var metrics: [DisplayMetric] = []
    let provider = Provider.grok

    // A config with neither a period nor any measure of the allowance has none to show.
    if config.currentPeriod != nil || config.creditUsagePercent != nil || config.monthlyLimit != nil {
      let percent = Int(min(max(allowanceUsed(config), 0), 100).rounded())
      let period =
        switch config.currentPeriod?.type {
        case "USAGE_PERIOD_TYPE_WEEKLY": "Weekly"
        case "USAGE_PERIOD_TYPE_MONTHLY": "Monthly"
        default: "Usage"
        }
      let scope = config.isUnifiedBillingUser == true ? "all Grok" : "Grok Build"
      metrics.append(
        DisplayMetric(
          id: provider.metricID("window"), provider: provider, title: "\(period) (\(scope))", symbolName: provider.symbol(for: .window),
          barText: "\(percent)%", valueText: "\(percent)% used", fraction: Double(percent) / 100, severity: severity(percent: percent),
          resetsAt: (config.currentPeriod?.end ?? config.billingPeriodEnd).flatMap(parseDate)))
    }

    // On-demand spend exists only once a cap is set, and its proportion is of that cap.
    if let cap = config.onDemandCap?.cents, cap > 0 {
      let used = config.onDemandUsed?.cents ?? 0
      let percent = Int((Double(used) / Double(cap) * 100).rounded())
      metrics.append(
        DisplayMetric(
          id: provider.metricID("on-demand"), provider: provider, title: "On-demand", symbolName: provider.symbol(for: .money),
          barText: dollars(used, fractionDigits: 0), valueText: "\(dollars(used)) / \(dollars(cap)) · \(percent)%",
          fraction: Double(used) / Double(cap), severity: severity(percent: percent), resetsAt: nil))
    }

    // A prepaid balance carries no denominator, so it is shown only while there is one.
    if let balance = config.prepaidBalance?.cents, balance > 0 {
      metrics.append(
        DisplayMetric(
          id: provider.metricID("credits"), provider: provider, title: "Prepaid credits", symbolName: provider.symbol(for: .money),
          barText: dollars(balance, fractionDigits: 0), valueText: "\(dollars(balance)) remaining", fraction: nil, severity: .normal,
          resetsAt: nil))
    }
    return metrics
  }

  /// The percentage the server gives, else the older shape's use over its limit, else none used.
  private static func allowanceUsed(_ config: BillingResponse.Config) -> Double {
    if let percent = config.creditUsagePercent { return percent }
    if let limit = config.monthlyLimit?.cents, limit > 0 { return Double(config.used?.cents ?? 0) / Double(limit) * 100 }
    return 0
  }

  private static func dollars(_ cents: Int, fractionDigits: Int = 2) -> String {
    Money.string(Double(cents) / 100, currency: "USD", fractionDigits: fractionDigits)
  }

  /// Grok reports no severity, so it is derived from how much is consumed, as for Codex.
  private static func severity(percent: Int) -> Severity {
    switch percent {
    case ..<50: .normal
    case ..<80: .warning
    default: .critical
    }
  }

  /// Periods are RFC 3339 with an offset and no fraction (`2026-11-08T00:00:00+00:00`).
  private static func parseDate(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
  }
}
