import Foundation

/// The human-readable rendering of a published reading, so the text a caller quotes and the JSON
/// it can parse describe the same state.
public enum UsageSummary {
  /// One line per provider: `Claude: [⚠ stale] Session (5-hour) 46% (resets in 3h 29m) · read 1h 0m ago`.
  ///
  /// Any warning is bracketed at the front, ahead of the numbers it qualifies. Callers are told to
  /// report this summary rather than the payload beside it, so a status placed after the
  /// percentages is a status that gets dropped — which is how an expired session came to be
  /// reported as hours-old numbers that read as current. The brackets earn their place: an error
  /// message carries its own punctuation, so the warning needs an extent that does not depend on
  /// what is inside it.
  public static func text(for state: UsageState, now: Date) -> String {
    state.providers.map { line(for: $0, pollIntervalSeconds: state.pollIntervalSeconds, now: now) }.joined(separator: "\n")
  }

  private static func line(for provider: ProviderUsage, pollIntervalSeconds: Int, now: Date) -> String {
    let age = provider.readingAge(now: now)
    var warnings: [String] = []
    if let problem = problem(for: provider) { warnings.append(problem) }
    // Never both: a provider that has no reading at all is starting up, not holding a stale one.
    if age == nil {
      warnings.append("no reading yet")
    } else if provider.isStale(pollIntervalSeconds: pollIntervalSeconds, now: now) {
      warnings.append("stale")
    }

    var line = "\(provider.displayName):"
    if !warnings.isEmpty { line += " [⚠ \(warnings.joined(separator: "; "))]" }
    let metrics = provider.metrics.map { metric -> String in
      let reset = metric.resetsAt.map { " (resets in \(shortDuration($0.timeIntervalSince(now))))" } ?? ""
      return "\(metric.title) \(metric.value)\(reset)"
    }
    if !metrics.isEmpty {
      line += " \(metrics.joined(separator: ", "))"
    } else if warnings.isEmpty {
      // Nothing to show and nothing wrong still has to say something.
      line += " \(provider.status)"
    }
    // Age is reported per provider — one can be hours old while the other just refreshed.
    if let age { line += " · read \(ageText(age)) ago" }
    return line
  }

  /// What is wrong, in words. The status is a wire token (`rate_limited`), so it is never printed
  /// as-is; an error's own message says more than the token it arrived with.
  private static func problem(for provider: ProviderUsage) -> String? {
    let message = provider.error.flatMap { $0.isEmpty ? nil : $0 }
    switch provider.status {
    case "ok": return message
    case "loading": return nil
    case "error": return message ?? "unavailable"
    case "rate_limited": return "rate limited"
    default: return provider.status.replacingOccurrences(of: "_", with: " ")
    }
  }

  /// Seconds while a reading is fresh enough to think of in seconds, coarser once it is not.
  private static func ageText(_ seconds: TimeInterval) -> String { seconds < 120 ? "\(Int(seconds))s" : shortDuration(seconds) }

  static func shortDuration(_ seconds: TimeInterval) -> String {
    let total = max(Int(seconds), 0)
    let days = total / 86400, hours = (total % 86400) / 3600, minutes = (total % 3600) / 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
  }
}
