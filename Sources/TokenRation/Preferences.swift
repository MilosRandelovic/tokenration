import Foundation
import Observation

/// User choices persisted in UserDefaults: which metrics are pinned to the menu bar.
/// Pin one metric → a single icon; pin several → several side by side.
/// `@Observable` so the panel's pin toggles reflect changes live.
@Observable @MainActor final class Preferences {
  private(set) var shownMetricIDs: [String]

  @ObservationIgnored var onChange: (@MainActor () -> Void)?
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let log: @Sendable (_ message: String) -> Void
  @ObservationIgnored private static let key = "shownMetricIDs"

  /// - Parameters:
  ///   - available: the providers the panel shows: those set up on this Mac, or Claude alone when
  ///     neither is. Pins are constrained to these, so a Codex-only machine never ends up with an
  ///     unpinnable Claude placeholder in the menu bar (there'd be no Claude tab to unpin it from).
  ///     The empty-list fallback below is a defence: `ProvidersModel.resolve` never hands over none.
  ///   - defaults: storage for the pin list; injectable for tests.
  ///   - log: where pin decisions are recorded: the app's log, or a sink in tests.
  init(available: [Provider], defaults: UserDefaults, log: @escaping @Sendable (_ message: String) -> Void) {
    self.defaults = defaults
    self.log = log
    let providers = available.isEmpty ? [Provider.claude] : available
    let stored = defaults.stringArray(forKey: Self.key) ?? []
    shownMetricIDs = Self.sanitise(stored, available: providers)
    // Persist the sanitised list so a pruned pin doesn't come back on the next launch.
    if shownMetricIDs != stored { defaults.set(shownMetricIDs, forKey: Self.key) }
  }

  /// Drop pins belonging to providers that aren't set up, and guarantee at least one pin.
  /// Pins are filtered by *provider*, not by which metrics currently have data — metrics only
  /// appear after a fetch, so filtering on those would wrongly discard valid pins at launch.
  private static func sanitise(_ ids: [String], available: [Provider]) -> [String] {
    let kept = ids.filter { id in
      guard let owner = Provider.owning(metricID: id) else { return false }
      return available.contains(owner)
    }
    return kept.isEmpty ? [available[0].defaultMetricID] : kept
  }

  /// Drop pins that a provider's *successful* snapshot no longer contains — a per-model limit
  /// that was renamed or retired, say. Provider-level sanitising can't catch those: the metric
  /// vanishes while its provider stays available, so the menu bar kept rendering a placeholder
  /// with no panel row to unpin it from.
  ///
  /// Only providers that have actually produced a reading are reconciled (`settled`);
  /// otherwise a provider that hasn't fetched yet would have all of its pins discarded at
  /// launch. At least one pin is always preserved.
  func reconcile(knownIDs: Set<String>, settled: Set<Provider>) {
    guard !settled.isEmpty else { return }
    let kept = shownMetricIDs.filter { id in
      guard let owner = Provider.owning(metricID: id) else { return false }
      guard settled.contains(owner) else { return true }  // no reading yet — leave alone
      return knownIDs.contains(id)
    }
    guard kept != shownMetricIDs else { return }
    let resolved = kept.isEmpty ? [knownIDs.sorted().first].compactMap { $0 } : kept
    guard !resolved.isEmpty else { return }  // nothing valid to fall back to; keep as-is
    log("dropped pins no longer present in a snapshot: " + "\(Set(shownMetricIDs).subtracting(resolved).sorted())")
    shownMetricIDs = resolved
    defaults.set(resolved, forKey: Self.key)
    onChange?()
  }

  func isShown(_ id: String) -> Bool { shownMetricIDs.contains(id) }

  /// Toggle a metric on/off, always keeping at least one pinned (never zero icons).
  func toggle(_ id: String) {
    var ids = shownMetricIDs
    if let index = ids.firstIndex(of: id) { if ids.count > 1 { ids.remove(at: index) } } else { ids.append(id) }
    shownMetricIDs = ids
    defaults.set(ids, forKey: Self.key)
    onChange?()
  }
}
