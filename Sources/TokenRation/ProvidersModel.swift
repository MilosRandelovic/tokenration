import Foundation
import Observation
import UsageState

/// Coordinates the detected providers: one `UsageModel` each, polling independently with its
/// own persisted backoff, plus the panel's selected tab and a lookup across all of them for
/// the menu bar.
///
/// Independence matters: Claude and Codex have separate budgets and separate failure modes, so
/// one being throttled or signed out must not stall the other.
@Observable @MainActor final class ProvidersModel {
  /// Providers set up on this Mac, in stable order. Empty if neither is.
  let available: [Provider]
  /// Which provider's tab the panel is showing.
  var selected: Provider

  @ObservationIgnored private var models: [Provider: UsageModel] = [:]
  @ObservationIgnored var onChange: (@MainActor () -> Void)?
  /// Fired with every known metric id and the providers that have produced a reading, so
  /// preferences can drop pins for metrics that no longer exist.
  @ObservationIgnored var onMetricsSettled: (@MainActor (Set<String>, Set<Provider>) -> Void)?

  init(providers: [Provider] = Provider.detected) {
    // Always keep at least one so the UI has something coherent to show; an undetected
    // provider simply reports "not signed in" when it tries to fetch.
    let resolved = providers.isEmpty ? [Provider.claude] : providers
    available = resolved
    selected = resolved[0]
    Log.write("providers detected: \(resolved.map(\.rawValue).joined(separator: ", "))")

    for provider in resolved {
      let model = UsageModel(provider: Self.makeProvider(provider))
      model.onChange = { [weak self] in
        self?.publishState()
        self?.onChange?()
      }
      models[provider] = model
    }
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
    do { try UsageStateStore.write(state) } catch { Log.write("failed to publish usage state: \(error.localizedDescription)") }
  }

  private static func makeProvider(_ provider: Provider) -> any UsageProviding {
    switch provider {
    case .claude: ClaudeUsageProvider()
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
