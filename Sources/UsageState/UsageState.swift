import Foundation

/// The snapshot TokenRation publishes to disk after each poll, and the bundled MCP server
/// reads back.
///
/// This exists so nothing except the app ever talks to a usage API. MCP servers are spawned
/// per client session, so a server that fetched for itself would multiply request load across
/// every concurrent agent — exactly the pattern that gets an account rate-limited. Readers get
/// the app's cached reading plus enough metadata (`writtenAt`, `pollIntervalSeconds`) to judge
/// for themselves whether it's fresh enough.
public struct UsageState: Codable, Sendable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  /// When the app last wrote this file.
  public var writtenAt: Date
  /// How often the app polls, so a reader can reason about staleness.
  public var pollIntervalSeconds: Int
  public var providers: [ProviderUsage]

  public init(writtenAt: Date, pollIntervalSeconds: Int, providers: [ProviderUsage]) {
    self.schemaVersion = Self.currentSchemaVersion
    self.writtenAt = writtenAt
    self.pollIntervalSeconds = pollIntervalSeconds
    self.providers = providers
  }
}

public struct ProviderUsage: Codable, Sendable {
  /// "claude" or "codex".
  public var provider: String
  public var displayName: String
  /// "ok", "loading", "rate_limited", or "error".
  public var status: String
  public var error: String?
  /// When this provider's reading was fetched (nil if it has never succeeded).
  public var updatedAt: Date?
  /// While throttled, when the app will try again.
  public var rateLimitedUntil: Date?
  public var metrics: [MetricUsage]

  public init(
    provider: String, displayName: String, status: String, error: String?, updatedAt: Date?, rateLimitedUntil: Date?, metrics: [MetricUsage]
  ) {
    self.provider = provider
    self.displayName = displayName
    self.status = status
    self.error = error
    self.updatedAt = updatedAt
    self.rateLimitedUntil = rateLimitedUntil
    self.metrics = metrics
  }
}

public struct MetricUsage: Codable, Sendable {
  /// Provider-namespaced id, e.g. `claude:session`.
  public var id: String
  public var title: String
  /// 0–100 for windowed limits; nil for things without a percentage (e.g. credits).
  public var usedPercent: Double?
  /// Compact value as shown in the menu bar, e.g. "4%" or "$246".
  public var value: String
  /// Fuller description, e.g. "$246.40 / $1,000.00 · 25%".
  public var detail: String
  /// "normal", "warning", or "critical".
  public var severity: String
  public var resetsAt: Date?

  public init(id: String, title: String, usedPercent: Double?, value: String, detail: String, severity: String, resetsAt: Date?) {
    self.id = id
    self.title = title
    self.usedPercent = usedPercent
    self.value = value
    self.detail = detail
    self.severity = severity
    self.resetsAt = resetsAt
  }
}

public extension ProviderUsage {
  /// Age of **this provider's reading**, which is what callers actually care about.
  ///
  /// Not the same as the file's `writtenAt`: the app rewrites the file whenever anything
  /// observable changes — a refresh starting, an error, a connectivity change — so file age
  /// can look fresh while the underlying quota numbers are old. Returns nil when the provider
  /// has never produced a reading.
  func readingAge(now: Date) -> TimeInterval? { updatedAt.map { now.timeIntervalSince($0) } }

  /// Whether this provider's reading is older than roughly two poll intervals — by which
  /// point the app probably isn't running. Unknown readings count as stale.
  func isStale(pollIntervalSeconds: Int, now: Date) -> Bool {
    guard let age = readingAge(now: now) else { return true }
    return age > Double(pollIntervalSeconds * 2)
  }
}

/// Reads and writes the state file at
/// `~/Library/Application Support/TokenRation/usage.json`.
public enum UsageStateStore {
  public static var fileURL: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TokenRation/usage.json")
  }

  public static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  public static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  /// Write atomically, so a reader never sees a half-written file.
  public static func write(_ state: UsageState) throws {
    let url = fileURL
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try makeEncoder().encode(state)
    try data.write(to: url, options: .atomic)
  }

  /// Returns nil when the app has never run (or the file is unreadable/incompatible).
  public static func read() -> UsageState? {
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    return try? makeDecoder().decode(UsageState.self, from: data)
  }
}
