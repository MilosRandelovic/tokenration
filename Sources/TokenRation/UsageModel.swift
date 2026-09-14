import Foundation
import Network
import Observation
import UsageState

/// Owns the current reading and the polling loop. `@Observable` so the SwiftUI panel
/// re-renders on change; also fires `onChange` so the AppKit status-bar buttons refresh.
///
/// Request discipline is the point of this class. The usage endpoint is shared with Claude
/// Code and throttles hard, so **every** path to a request funnels through `refresh(trigger:)`,
/// which enforces, in order: an active rate-limit deadline, a minimum gap since the last
/// attempt, and network availability. The deadline, failure count and last-attempt time are
/// persisted, so relaunches and repeated system wakes can't bypass a backoff that's in force.
/// Every decision is logged (see `Log`).
@Observable @MainActor final class UsageModel {
  private(set) var snapshot: UsageSnapshot = .placeholder
  private(set) var lastError: String?
  /// True when the last attempt failed for a reason only a sign-in can fix. Distinct from
  /// being throttled or offline, where waiting is the whole remedy — so the menu bar can ask
  /// for attention in one case and stay quiet in the other.
  private(set) var needsSignIn = false
  /// The credentials on disk as last read by `refreshCredentialState()`, against which a hold's
  /// recorded fingerprint is compared.
  private var currentCredentialFingerprint: String?
  private(set) var isRefreshing = false
  /// Set while the usage endpoint is throttling us; the date is when we'll next retry.
  private(set) var rateLimitedUntil: Date?
  private(set) var isOffline = false

  @ObservationIgnored var onChange: (@MainActor () -> Void)?
  @ObservationIgnored private let provider: any UsageProviding
  @ObservationIgnored private let baseInterval: TimeInterval
  @ObservationIgnored private var loopTask: Task<Void, Never>?
  @ObservationIgnored private let pathMonitor = NWPathMonitor()
  @ObservationIgnored private let defaults: UserDefaults

  /// No two attempts within this window, whatever triggered them (launch, wake, reconnect,
  /// panel open, loop). This is the backstop that makes wake storms harmless.
  private static let minimumGap: TimeInterval = 120
  /// Wait after a failure: 1m, 2m, 4m … capped at 30m.
  private static let firstBackoff: TimeInterval = 60
  private static let maxBackoff: TimeInterval = 30 * 60
  /// Minimum wait after a 429, even if the server suggests sooner: 15m, 30m … capped at 2h.
  private static let rateLimitFloor: TimeInterval = 15 * 60
  private static let maxRateLimitWait: TimeInterval = 2 * 60 * 60
  /// No stored credentials needs user action, so check back rarely.
  private static let authRetryInterval: TimeInterval = 15 * 60
  /// A rejected token is usually one the CLI has just rotated, with the replacement already in
  /// the Keychain — so the first rejection is retried soon after. Kept above `minimumGap`, or the
  /// retry would be skipped rather than attempted.
  private static let rejectedTokenRetry: TimeInterval = 150
  /// While offline we don't attempt at all; reconnecting triggers a refresh.
  private static let offlineRetryInterval: TimeInterval = 5 * 60
  /// Default cadence between successful polls; published in the state file so readers can
  /// judge staleness.
  static let defaultInterval: TimeInterval = 5 * 60

  /// Persisted keys are per-provider: Claude and Codex have independent budgets, so one
  /// being throttled must never stall or reset the other.
  @ObservationIgnored private let deadlineKey: String
  /// Deadline covering **every** kind of failure, not just 429s. Without this, an auth or
  /// network backoff lived only as a sleep in the polling task, so a sleep/wake cycle or a
  /// relaunch discarded a 15–30 minute hold-off and fell back to the 120s minimum gap.
  @ObservationIgnored private let nextAttemptKey: String
  @ObservationIgnored private let failuresKey: String
  @ObservationIgnored private let lastAttemptKey: String
  @ObservationIgnored private let heldCredentialKey: String

  /// Which source this model polls.
  let source: Provider

  init(
    provider: any UsageProviding = ClaudeUsageProvider(), baseInterval: TimeInterval = UsageModel.defaultInterval,
    defaults: UserDefaults = .standard, restoring: UsageState? = UsageStateStore.read()
  ) {
    self.provider = provider
    self.baseInterval = baseInterval
    self.defaults = defaults
    self.source = provider.provider
    let suffix = provider.provider.rawValue
    self.deadlineKey = "rateLimitedUntil.\(suffix)"
    self.nextAttemptKey = "nextAttemptAt.\(suffix)"
    self.failuresKey = "consecutiveFailures.\(suffix)"
    self.lastAttemptKey = "lastAttemptAt.\(suffix)"
    self.heldCredentialKey = "rejectedCredential.\(suffix)"
    // Restore any backoff that was in force when we last ran.
    let legacyDeadline = defaults.object(forKey: deadlineKey) as? Date
    if let legacyDeadline, legacyDeadline > Date() { rateLimitedUntil = legacyDeadline }
    // Builds before `nextAttemptAt` existed persisted only `rateLimitedUntil`. Carry such a
    // deadline forward, otherwise upgrading mid-throttle would drop the hold-off to the
    // 120s minimum gap and fetch early against an endpoint that is still rate-limiting us.
    let storedNext = defaults.object(forKey: nextAttemptKey) as? Date
    if let legacyDeadline, legacyDeadline > (storedNext ?? .distantPast) { defaults.set(legacyDeadline, forKey: nextAttemptKey) }
    if let next = defaults.object(forKey: nextAttemptKey) as? Date, next > Date() {
      log("launch: backoff restored, \(Int(next.timeIntervalSinceNow))s remaining")
    }
    // Show the last known numbers straight away; the fetch that follows replaces them.
    if let stored = restoring?.providers.first(where: { $0.provider == source.rawValue }), let restored = UsageSnapshot(restoring: stored) {
      snapshot = restored
      log("restored last reading (\(Int(Date().timeIntervalSince(restored.updatedAt)))s old)")
    }
    startNetworkMonitor()
  }

  /// Ask the provider whether its credentials are usable, and reflect that immediately.
  ///
  /// Called at start-up because a restored backoff carries the wait but not the reason: without
  /// this the menu bar would show stale numbers under a normal glyph until the next attempt
  /// failed, which can be a quarter of an hour away.
  func refreshCredentialState() async {
    let problem = await provider.credentialProblem()
    let fingerprint = await provider.credentialFingerprint()
    // Only set the message, never clear one: an unrelated failure — a throttle, a bad response
    // — is still the last thing that actually happened, and a successful fetch clears it anyway.
    if let problem { lastError = problem.errorDescription }
    let signInChanged = (problem != nil) != needsSignIn
    let credentialChanged = fingerprint != currentCredentialFingerprint
    guard signInChanged || credentialChanged else { return }
    needsSignIn = problem != nil
    currentCredentialFingerprint = fingerprint
    onChange?()
  }

  /// Log with the provider name, so a two-provider log stays readable.
  private func log(_ message: String) { Log.write("[\(source.rawValue)] \(message)") }

  // MARK: - Persisted state

  private var consecutiveFailures: Int {
    get { defaults.integer(forKey: failuresKey) }
    set { defaults.set(newValue, forKey: failuresKey) }
  }

  private var lastAttemptAt: Date? {
    get { defaults.object(forKey: lastAttemptKey) as? Date }
    set { defaults.set(newValue, forKey: lastAttemptKey) }
  }

  /// When the next attempt is allowed, for any reason. This is the guard; `rateLimitedUntil`
  /// only records that the cause was a 429, so the UI can say so.
  private var nextAttemptAt: Date? {
    get { defaults.object(forKey: nextAttemptKey) as? Date }
    set { if let newValue { defaults.set(newValue, forKey: nextAttemptKey) } else { defaults.removeObject(forKey: nextAttemptKey) } }
  }

  private func setRateLimited(until date: Date?) {
    rateLimitedUntil = date
    if let date { defaults.set(date, forKey: deadlineKey) } else { defaults.removeObject(forKey: deadlineKey) }
  }

  /// Record a backoff that survives stop/start and relaunch.
  private func holdOff(_ seconds: TimeInterval) { nextAttemptAt = Date().addingTimeInterval(seconds) }

  /// The credential fingerprint that was rejected, when the current hold is an auth hold.
  /// Set only by the auth paths, so a 429 hold never carries one and is never cut short.
  private var heldCredentialFingerprint: String? {
    get { defaults.string(forKey: heldCredentialKey) }
    set { if let newValue { defaults.set(newValue, forKey: heldCredentialKey) } else { defaults.removeObject(forKey: heldCredentialKey) } }
  }

  private func clearBackoff() {
    setRateLimited(until: nil)
    nextAttemptAt = nil
    heldCredentialFingerprint = nil
  }

  // MARK: - Loop

  func start() {
    guard loopTask == nil else { return }
    log("poll loop started")
    // Independent of the poll loop, which may be held off for a long time before it runs.
    Task { await refreshCredentialState() }
    loopTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        let wait = await self.refresh(trigger: "loop")
        self.log("next attempt in \(Int(wait))s")
        try? await Task.sleep(for: .seconds(wait))
      }
    }
  }

  func stop() {
    guard loopTask != nil else { return }
    log("poll loop stopped")
    loopTask?.cancel()
    loopTask = nil
  }

  /// True when the last reading is old enough to be worth refreshing on demand.
  /// When the next attempt is allowed, or nil when one may be made now.
  ///
  /// `rateLimitedUntil` covers only the 429 case; a hold after an auth failure or a general
  /// error is just as binding, and a refresh asked for during either is refused. The UI needs
  /// the effective deadline so it can stop offering an action that cannot happen.
  var heldUntil: Date? {
    // All three refusal paths in `refresh`, not just the throttle: an auth or error backoff
    // binds the same way, and so does the minimum gap since the last attempt — including one
    // that succeeded. Miss any of them and the button takes a click it cannot act on.
    //
    // The exception is a spent auth hold. It exists to wait for exactly one thing — different
    // credentials — and `refresh` cuts it short the moment they arrive, so reporting it here
    // would refuse a click that would have worked, for the rest of an interval measured in
    // quarter-hours. The 429 and minimum-gap deadlines are unaffected; neither is escapable.
    let backoffEnds = authHoldIsSpent ? nil : nextAttemptAt
    let gapEnds = lastAttemptAt.map { $0.addingTimeInterval(Self.minimumGap) }
    let deadline = [backoffEnds, rateLimitedUntil, gapEnds].compactMap { $0 }.max()
    guard let deadline, deadline > Date() else { return nil }
    return deadline
  }

  /// Whether the hold in force is an auth hold whose credentials have since been replaced — the
  /// synchronous twin of `credentialsReplaced()`, reading the fingerprint cached by
  /// `refreshCredentialState()` because the UI reads this during layout and cannot await.
  /// False until that cache is populated, so a launch never enables the button on a guess.
  private var authHoldIsSpent: Bool {
    guard let rejected = heldCredentialFingerprint, let current = currentCredentialFingerprint else { return false }
    return rejected != current
  }

  func isStale(olderThan age: TimeInterval = 60) -> Bool { Date().timeIntervalSince(snapshot.updatedAt) > age }

  /// Attempt one fetch. Returns how many seconds to wait before the next attempt.
  /// `trigger` is recorded in the log so bursts can be traced to their source.
  @discardableResult func refresh(trigger: String) async -> TimeInterval {
    guard !isRefreshing else {
      log("skip (\(trigger)): a fetch is already in flight")
      return baseInterval
    }

    // 1. An active backoff deadline wins over everything — poking a throttled endpoint
    //    extends the penalty, and re-hammering a failing one is pointless. This is
    //    persisted, so a relaunch or sleep/wake cycle can't shorten it.
    // The later of the two deadlines wins: `rateLimitedUntil` is also what older builds
    // persisted, so this is belt-and-braces alongside the migration above.
    let effectiveDeadline = [nextAttemptAt, rateLimitedUntil].compactMap { $0 }.max()
    if let until = effectiveDeadline {
      if until > Date() {
        // Credentials replaced since they were rejected: the hold exists to wait for exactly
        // this, so attempt now rather than sitting out the rest of it. Only the auth paths
        // record a fingerprint, so a 429 — the server asking for quiet — still holds.
        if await credentialsReplaced() {
          log("credentials replaced since they were rejected — attempting now")
          clearBackoff()
          consecutiveFailures = 0
        } else {
          let remaining = until.timeIntervalSinceNow
          let reason = rateLimitedUntil != nil ? "rate-limited" : "backing off"
          log("skip (\(trigger)): \(reason), \(Int(remaining))s remaining")
          return remaining
        }
      } else {
        clearBackoff()
      }
    }

    // 2. Never two attempts inside the minimum gap, however they were triggered. This is
    //    what stops repeated wakes or relaunches from turning into a burst.
    if let last = lastAttemptAt {
      let elapsed = Date().timeIntervalSince(last)
      if elapsed >= 0, elapsed < Self.minimumGap {
        let remaining = Self.minimumGap - elapsed
        log("skip (\(trigger)): only \(Int(elapsed))s since last attempt")
        return remaining
      }
    }

    // 3. No network path: don't spend an attempt. Reconnecting triggers a refresh.
    if isOffline {
      log("skip (\(trigger)): offline")
      return Self.offlineRetryInterval
    }

    isRefreshing = true
    lastAttemptAt = Date()
    onChange?()
    defer {
      isRefreshing = false
      onChange?()
    }

    log("fetch (\(trigger))")
    do {
      snapshot = try await provider.fetch()
      lastError = nil
      needsSignIn = false
      clearBackoff()
      consecutiveFailures = 0
      let summary = snapshot.metrics.map { "\($0.id)=\($0.barText)" }.joined(separator: " ")
      log("ok: \(summary)")
      return jittered(baseInterval)
    } catch let UsageError.rateLimited(retryAfter) {
      consecutiveFailures += 1
      let floor = min(Self.rateLimitFloor * pow(2, Double(consecutiveFailures - 1)), Self.maxRateLimitWait)
      // Retry-After is a hard lower bound: jitter only the local floor, so a negative
      // jitter can never schedule us earlier than the server asked.
      let wait = max(retryAfter ?? 0, jittered(floor))
      setRateLimited(until: Date().addingTimeInterval(wait))
      holdOff(wait)
      lastError = "Rate limited"
      needsSignIn = false
      log(
        "HTTP 429 (retry-after \(retryAfter.map { String(Int($0)) } ?? "none"), "
          + "failures \(consecutiveFailures)) — holding off \(Int(wait))s")
      return wait
    } catch UsageError.sessionExpired {
      consecutiveFailures += 1
      setRateLimited(until: nil)
      lastError = UsageError.sessionExpired.errorDescription
      needsSignIn = true
      // A first rejection is treated as a token the CLI has just rotated, so it is retried soon.
      // One that repeats means the credentials really are stale and only a sign-in fixes it.
      let wait = jittered(consecutiveFailures == 1 ? Self.rejectedTokenRetry : Self.authRetryInterval)
      holdOff(wait)
      heldCredentialFingerprint = await provider.credentialFingerprint()
      log("token rejected (failures \(consecutiveFailures)) — retrying in \(Int(wait))s")
      return wait
    } catch UsageError.notSignedIn {
      consecutiveFailures += 1
      setRateLimited(until: nil)
      lastError = UsageError.notSignedIn.errorDescription
      needsSignIn = true
      let wait = jittered(Self.authRetryInterval)
      holdOff(wait)
      heldCredentialFingerprint = await provider.credentialFingerprint()
      log("no stored credentials — retrying in \(Int(wait))s")
      return wait
    } catch {
      consecutiveFailures += 1
      setRateLimited(until: nil)
      lastError = error.localizedDescription
      needsSignIn = false
      let wait = jittered(min(Self.firstBackoff * pow(2, Double(consecutiveFailures - 1)), Self.maxBackoff))
      holdOff(wait)
      log("error (failures \(consecutiveFailures)): \(error.localizedDescription) " + "— backing off \(Int(wait))s")
      return wait
    }
  }

  // MARK: - Network

  /// Track connectivity so offline stretches cost nothing, and so regaining a connection
  /// refreshes promptly (still subject to the guards in `refresh`).
  private func startNetworkMonitor() {
    pathMonitor.pathUpdateHandler = { [weak self] path in
      let offline = path.status != .satisfied
      Task { @MainActor [weak self] in
        guard let self, offline != self.isOffline else { return }
        self.isOffline = offline
        self.log("network \(offline ? "lost" : "available")")
        self.onChange?()
        if !offline { await self.refresh(trigger: "reconnect") }
      }
    }
    pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
  }

  /// Whether the credentials on disk differ from the ones whose rejection caused the hold.
  /// False whenever the hold has no fingerprint, so non-auth holds are left alone.
  private func credentialsReplaced() async -> Bool {
    guard let rejected = heldCredentialFingerprint, let current = await provider.credentialFingerprint() else { return false }
    return current != rejected
  }

  /// ±10%, so several machines (or a restart storm) don't line up on the same tick.
  private func jittered(_ interval: TimeInterval) -> TimeInterval { interval * Double.random(in: 0.9...1.1) }
}
