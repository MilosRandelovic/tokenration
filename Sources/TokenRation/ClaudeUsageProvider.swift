import Foundation
import os

/// Where the Claude provider reads its OAuth token: the login Keychain in the app, a fixture in tests.
protocol ClaudeCredentials: Sendable {
  /// The token a request sends, or the `UsageError` that stops one.
  func token() throws -> String
  /// A value that changes when the credential does, so a sign-in can end an auth hold at once.
  func fingerprint() throws -> String
}

/// Claude Code's credential in the login Keychain, read through `tool`.
struct KeychainCredentials: ClaudeCredentials {
  let service: String
  /// What reads the Keychain: `KeychainToken.securityTool` in the app, a fixture in tests.
  let tool: URL
  /// Where a failed read is recorded: the app's log in the app. A failure is logged once, until a read
  /// succeeds or fails differently, since credentials are read on every attempt and every panel open.
  let log: @Sendable (_ message: String) -> Void
  private let lastFailure = OSAllocatedUnfairLock<String?>(initialState: nil)

  init(service: String = "Claude Code-credentials", tool: URL, log: @escaping @Sendable (_ message: String) -> Void) {
    self.service = service
    self.tool = tool
    self.log = log
  }

  func token() throws -> String {
    let token = try KeychainToken.read(service: service, tool: tool) { reason in
      let isNew = lastFailure.withLock { last in
        defer { last = reason }
        return last != reason
      }
      if isNew { log("[claude] Keychain read: \(reason)") }
    }
    lastFailure.withLock { $0 = nil }
    return token
  }

  func fingerprint() throws -> String { KeychainToken.fingerprint(of: try token()) }
}

/// Live usage from `GET https://api.anthropic.com/api/oauth/usage` — the same endpoint
/// Claude Code's `/usage` command uses — authenticated with the OAuth token from the
/// login Keychain. Empirically the only required header is `Authorization: Bearer`; the
/// `anthropic-beta` header is sent too, matching the CLI.
struct ClaudeUsageProvider: UsageProviding {
  let provider = Provider.claude
  var endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
  /// Asks the endpoint: `URLSession.shared` in the app, a stub in tests.
  let session: URLSession
  /// Where the token comes from: `KeychainCredentials` in the app, a fixture in tests.
  let credentials: any ClaudeCredentials

  /// Absent or unusable credentials get a marker rather than nil, so that signing back in reads
  /// as a change and clears the hold immediately instead of waiting out the auth interval.
  func credentialFingerprint() async -> String? { (try? credentials.fingerprint()) ?? "none" }

  /// Reads the credential the way a fetch would and reports what would refuse it. No request is
  /// made: an expired or missing token is visible in the Keychain itself.
  func credentialProblem() async -> UsageError? {
    do {
      _ = try credentials.token()
      return nil
    } catch let error as UsageError { return error } catch { return .notSignedIn }
  }

  func fetch() async throws -> UsageSnapshot {
    let token = try credentials.token()

    var request = URLRequest(url: endpoint)
    request.timeoutInterval = 10
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.setValue("TokenRation", forHTTPHeaderField: "User-Agent")

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw UsageError.badResponse }
    switch http.statusCode {
    case 200: break
    case 401, 403: throw UsageError.sessionExpired
    case 429: throw UsageError.rateLimited(retryAfter: Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
    default: throw UsageError.requestFailed(http.statusCode)
    }

    guard let payload = try? JSONDecoder().decode(UsageResponse.self, from: data) else { throw UsageError.badResponse }
    // Every field is optional and a limit of an unknown kind is skipped, so a body of another shape, such as one
    // whose limits or their kinds were renamed and that carries no spend either, still decodes, to a reading with
    // nothing in it. Taken as a reading, it would drop the last numbers and show the tab as loading, with nothing in
    // the log to say why.
    let snapshot = payload.snapshot(now: Date())
    guard !snapshot.metrics.isEmpty else { throw UsageError.badResponse }
    return snapshot
  }

  /// `Retry-After` is either a number of seconds or an HTTP-date; parsing only the former
  /// silently dropped the server's guidance and let us retry far too soon.
  private static func retryAfter(_ header: String?) -> TimeInterval? {
    guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
    if let seconds = TimeInterval(header) { return max(seconds, 0) }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    guard let date = formatter.date(from: header) else { return nil }
    return max(date.timeIntervalSinceNow, 0)
  }
}

// MARK: - Wire format

/// The subset of the `/api/oauth/usage` response we render. The endpoint returns more
/// (per-model duplicates, daily breakdowns); we read the normalised `limits[]` array plus
/// `spend`, which together cover session, weekly, per-model (incl. Fable) and dollars.
private struct UsageResponse: Decodable {
  let limits: [Limit]?
  let spend: Spend?

  struct Limit: Decodable {
    let kind: String?
    let percent: Double?
    let severity: String?
    let resetsAt: String?
    let scope: Scope?

    enum CodingKeys: String, CodingKey {
      case kind
      case percent
      case severity
      case resetsAt = "resets_at"
      case scope
    }
    struct Scope: Decodable {
      let model: Model?
      struct Model: Decodable {
        let displayName: String?

        enum CodingKeys: String, CodingKey { case displayName = "display_name" }
      }
    }
  }

  struct Spend: Decodable {
    let used: Money?
    let limit: Money?
    let percent: Double?
    let severity: String?
    struct Money: Decodable {
      let amountMinor: Int?
      let currency: String?
      let exponent: Int?

      enum CodingKeys: String, CodingKey {
        case amountMinor = "amount_minor"
        case currency
        case exponent
      }
    }
  }

  func snapshot(now: Date) -> UsageSnapshot {
    var metrics = (limits ?? []).compactMap(Self.metric(from:))
    if let spend, let metric = Self.metric(from: spend) { metrics.append(metric) }
    return UsageSnapshot(metrics: metrics, updatedAt: now)
  }

  private static func metric(from limit: Limit) -> DisplayMetric? {
    let percent = Int((limit.percent ?? 0).rounded())
    let severity = Severity(apiValue: limit.severity)
    let resetsAt = parseDate(limit.resetsAt)
    let fraction = Double(percent) / 100
    switch limit.kind {
    case "session":
      return DisplayMetric(
        id: Provider.claude.metricID("session"), provider: .claude, title: "Session (5-hour)",
        symbolName: Provider.claude.symbol(for: .session), barText: "\(percent)%", valueText: "\(percent)% used", fraction: fraction,
        severity: severity, resetsAt: resetsAt)
    case "weekly_all":
      return DisplayMetric(
        id: Provider.claude.metricID("weekly"), provider: .claude, title: "Weekly (all models)",
        symbolName: Provider.claude.symbol(for: .window), barText: "\(percent)%", valueText: "\(percent)% used", fraction: fraction,
        severity: severity, resetsAt: resetsAt)
    case "weekly_scoped":
      let name = limit.scope?.model?.displayName ?? "Model"
      return DisplayMetric(
        id: Provider.claude.metricID("model:\(name)"), provider: .claude, title: "\(name) (weekly)",
        symbolName: Provider.claude.symbol(for: .model), barText: "\(percent)%", valueText: "\(percent)% used", fraction: fraction,
        severity: severity, resetsAt: resetsAt)
    default: return nil
    }
  }

  private static func metric(from spend: Spend) -> DisplayMetric? {
    guard let used = spend.used else { return nil }
    let currency = used.currency ?? "USD"
    let percent = Int((spend.percent ?? 0).rounded())
    let usedText = Money.string(amount(used), currency: currency, fractionDigits: used.exponent ?? 2)
    let barText = Money.string(amount(used), currency: currency, fractionDigits: 0)
    var valueText = usedText
    if let limitMoney = spend.limit {
      let limitText = Money.string(amount(limitMoney), currency: limitMoney.currency ?? currency, fractionDigits: limitMoney.exponent ?? 2)
      valueText = "\(usedText) / \(limitText) · \(percent)%"
    }
    return DisplayMetric(
      id: Provider.claude.metricID("spend"), provider: .claude, title: "Extra usage", symbolName: Provider.claude.symbol(for: .money),
      barText: barText, valueText: valueText, fraction: spend.percent.map { $0 / 100 }, severity: Severity(apiValue: spend.severity),
      resetsAt: nil)
  }

  private static func amount(_ money: Spend.Money) -> Double { Double(money.amountMinor ?? 0) / pow(10, Double(money.exponent ?? 2)) }

  /// The endpoint's timestamps carry fractional seconds (e.g. `...59.783216+00:00`);
  /// fall back to a non-fractional parse if that ever changes.
  private static func parseDate(_ string: String?) -> Date? {
    guard let string else { return nil }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: string) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: string)
  }
}

/// Formats a currency amount for both the compact menu-bar text and the detailed menu line.
enum Money {
  static func string(_ amount: Double, currency: String, fractionDigits: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = currency
    formatter.maximumFractionDigits = fractionDigits
    formatter.minimumFractionDigits = fractionDigits
    return formatter.string(from: NSNumber(value: amount)) ?? "\(currency) \(amount)"
  }
}
