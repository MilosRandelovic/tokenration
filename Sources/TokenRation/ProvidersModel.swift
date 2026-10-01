import Foundation
import Observation
import UsageState

/// Coordinates the providers the panel shows: one `UsageModel` each, polling independently with its
/// own persisted backoff, plus the panel's selected tab and a lookup across all of them for
/// the menu bar.
///
/// Independence matters: Claude and Codex have separate budgets and separate failure modes, so
/// one being throttled or signed out must not stall the other.
@Observable @MainActor final class ProvidersModel {
  /// The providers the panel shows, in stable order: those set up on this Mac, or Claude alone when
  /// neither is.
  let available: [Provider]
  /// Which provider's tab the panel is showing.
  var selected: Provider

  @ObservationIgnored private var models: [Provider: UsageModel] = [:]
  @ObservationIgnored var onChange: (@MainActor () -> Void)?
  /// Fired with every known metric id and the providers that have produced a reading, so
  /// preferences can drop pins for metrics that no longer exist.
  @ObservationIgnored var onMetricsSettled: (@MainActor (_ knownIDs: Set<String>, _ settled: Set<Provider>) -> Void)?
  @ObservationIgnored private let log: @Sendable (_ message: String) -> Void
  @ObservationIgnored private let publish: (_ state: UsageState) throws -> Void

  /// Stand-ins in tests for each of these:
  /// - Parameters:
  ///   - providers: What detection found: `Provider.detectAll(home:codex:)` in the app.
  ///   - published: The reading each model restores: `UsageStateStore.read()` in the app.
  ///   - makeProvider: Builds each provider: `makeProvider(_:)` in the app.
  ///   - makeNetworkMonitor: Makes each model's network monitor: a new `SystemNetworkMonitor` in the app.
  ///   - defaults: Holds the models' persisted state: `.standard` in the app.
  ///   - log: Records decisions: the app's log.
  ///   - publish: Writes the state file the MCP server reads: `UsageStateStore.write(_:)` in the app.
  init(
    providers: [Provider], published: UsageState?, makeProvider: (_ provider: Provider) -> any UsageProviding,
    makeNetworkMonitor: () -> any NetworkMonitoring, defaults: UserDefaults, log: @escaping @Sendable (_ message: String) -> Void,
    publish: @escaping (_ state: UsageState) throws -> Void
  ) {
    let (resolved, summary) = Self.resolve(detected: providers)
    available = resolved
    selected = resolved[0]
    self.log = log
    self.publish = publish
    log(summary)

    for provider in resolved {
      let model = UsageModel(
        provider: makeProvider(provider), defaults: defaults, restoring: published, network: makeNetworkMonitor(), log: log)
      model.onChange = { [weak self] in
        self?.publishState()
        self?.onChange?()
      }
      models[provider] = model
    }
  }

  /// The providers the panel shows for what detection found, and the launch log's line for them. Always
  /// at least one, so the UI has something coherent to show; Claude, the fallback, simply reports "not
  /// signed in" when it tries to fetch, and the line says nothing was detected rather than naming it as
  /// detected. `init` takes both from this one result, so it has no second list to log and cannot log the
  /// Claude fallback as if detection had found it. Internal so a test can pin both, empty case included.
  static func resolve(detected: [Provider]) -> (available: [Provider], summary: String) {
    guard !detected.isEmpty else { return ([.claude], "providers detected: none, showing claude") }
    return (detected, "providers detected: " + detected.map(\.rawValue).joined(separator: ", "))
  }

  // MARK: - Published state (for the bundled MCP server)

  /// Mirror the current readings to `usage.json` so the MCP server — and anything else that
  /// wants them — can read the app's cached data instead of calling a usage API itself.
  private func publishState() {
    let providerStates = available.compactMap { provider -> ProviderUsage? in
      guard let model = models[provider] else { return nil }
      let status: String
      if model.rateLimitedUntil != nil {
        status = "rate_limited"
      } else if model.lastError != nil {
        status = "error"
      } else if model.snapshot.hasData {
        status = "ok"
      } else {
        status = "loading"
      }
      return ProviderUsage(
        provider: provider.rawValue, displayName: provider.displayName, status: status, error: model.lastError,
        updatedAt: model.snapshot.hasData ? model.snapshot.updatedAt : nil, rateLimitedUntil: model.rateLimitedUntil,
        metrics: model.snapshot.metrics.map { metric in
          MetricUsage(
            id: metric.id, title: metric.title, usedPercent: metric.fraction.map { ($0 * 100).rounded() }, value: metric.barText,
            detail: metric.valueText, severity: metric.severity.name, resetsAt: metric.resetsAt)
        })
    }
    let settled = Set(available.filter { models[$0]?.snapshot.hasData == true })
    onMetricsSettled?(Set(allMetrics.map(\.id)), settled)

    let state = UsageState(writtenAt: Date(), pollIntervalSeconds: Int(UsageModel.defaultInterval), providers: providerStates)
    do { try publish(state) } catch { log("failed to publish usage state: \(error.localizedDescription)") }
  }

  /// The app's providers: Claude's on the network and the login Keychain, Codex's on the shared resolver.
  /// Internal so a test can inspect what it builds, and only inspect: running either provider reaches the
  /// network, the Keychain or this Mac's codex.
  nonisolated static func makeProvider(_ provider: Provider) -> any UsageProviding {
    switch provider {
    case .claude:
      ClaudeUsageProvider(session: .shared, credentials: KeychainCredentials(tool: KeychainToken.securityTool, log: { Log.write($0) }))
    // The shared resolver, as detection used: see `CodexBinary.Resolver`.
    case .codex: CodexUsageProvider()
    }
  }

  var showsTabs: Bool { available.count > 1 }

  func model(for provider: Provider) -> UsageModel? { models[provider] }

  var selectedModel: UsageModel? { models[selected] }

  /// Every metric from every provider, in provider order — the pool the menu bar pins from.
  var allMetrics: [DisplayMetric] { available.compactMap { models[$0] }.flatMap(\.snapshot.metrics) }

  /// Find a pinned metric by id across providers.
  func metric(id: String) -> DisplayMetric? { allMetrics.first { $0.id == id } }

  /// True when any provider is currently failing, so the menu bar can hint at staleness.
  var hasError: Bool { models.values.contains { $0.lastError != nil } }

  // MARK: - Lifecycle

  func startAll() { for model in models.values { model.start() } }

  func stopAll() { for model in models.values { model.stop() } }

  /// Refresh every provider (each still subject to its own guards).
  func refreshAll(trigger: String) async { for model in models.values { await model.refresh(trigger: trigger) } }

  /// Re-read every provider's credentials. Cheap — a Keychain read, no request — so it can run
  /// on a panel open, where a sign-in made since the last attempt should already be visible.
  func refreshCredentialStates() async { for model in models.values { await model.refreshCredentialState() } }
}
