import Foundation
import Network
import UsageState
import UserNotifications
import XCTest
import os

@testable import TokenRation

// MARK: - Providers model

@MainActor final class ProvidersModelTests: XCTestCase {
  /// With nothing detected the panel falls back to Claude, and the launch log says nothing was detected
  /// rather than logging "providers detected: claude" for a Claude detection never found, or ending at
  /// "providers detected: " with nothing after it.
  func testResolveNamesTheDetectedProvidersOrTheFallback() {
    let fallback = ProvidersModel.resolve(detected: [])
    XCTAssertEqual(fallback.available, [.claude])
    XCTAssertEqual(fallback.summary, "providers detected: none, showing claude")

    let detected = ProvidersModel.resolve(detected: [.claude, .codex])
    XCTAssertEqual(detected.available, [.claude, .codex])
    XCTAssertEqual(detected.summary, "providers detected: claude, codex")
  }

  private func reading(of provider: String, metric id: String) -> ProviderUsage {
    ProviderUsage(
      provider: provider, displayName: provider, status: "ok", error: nil, updatedAt: Date(timeIntervalSinceNow: -60),
      rateLimitedUntil: nil,
      metrics: [MetricUsage(id: id, title: id, usedPercent: 30, value: "30%", detail: "30% used", severity: "normal", resetsAt: nil)])
  }

  /// A cold start hands each model the published reading, so the panel shows the last numbers before any
  /// fetch rather than a spinner, and the providers model logs its detection summary before any line from
  /// the models it builds.
  func testEachModelRestoresThePublishedReading() {
    let logged = Box<[String]>([])
    let published = UsageState(
      writtenAt: Date(), pollIntervalSeconds: 300,
      providers: [reading(of: "claude", metric: "claude:session"), reading(of: "codex", metric: "codex:window")])
    let model = ProvidersModel(
      providers: [.claude, .codex], published: published,
      makeProvider: { provider in StubProvider(provider: provider) { snapshot("\(provider.rawValue):fetched") } },
      makeNetworkMonitor: { StubNetwork() }, defaults: makeDefaults(), log: { logged.value.append($0) }, publish: { _ in })
    XCTAssertEqual(model.model(for: .claude)?.snapshot.metrics.map(\.id), ["claude:session"])
    XCTAssertEqual(model.model(for: .codex)?.snapshot.metrics.map(\.id), ["codex:window"])
    XCTAssertEqual(logged.value.first, "providers detected: claude, codex", "logged: \(logged.value)")
  }

  /// Every change is published to the state file the MCP server reads, each provider with its status and
  /// its numbers, a metric's fraction as a percentage. Each model keeps its persisted state in the defaults
  /// the providers model was given.
  func testEveryChangeIsPublished() async throws {
    let written = Box<[UsageState]>([])
    let defaults = makeDefaults()
    let model = ProvidersModel(
      providers: [.claude, .codex], published: nil,
      makeProvider: { provider in StubProvider(provider: provider) { snapshot("\(provider.rawValue):fetched") } },
      makeNetworkMonitor: { StubNetwork() }, defaults: defaults, log: discardLog, publish: { written.value.append($0) })
    await model.refreshAll(trigger: "test")
    let last = try XCTUnwrap(written.value.last, "a refresh publishes")
    XCTAssertEqual(last.providers.map(\.provider), ["claude", "codex"])
    XCTAssertEqual(last.providers.map(\.status), ["ok", "ok"])
    XCTAssertEqual(last.providers.flatMap { $0.metrics.map(\.id) }, ["claude:fetched", "codex:fetched"])
    XCTAssertEqual(last.providers.flatMap { $0.metrics.map(\.usedPercent) }, [1, 1], "a fraction of 0.01 is published as 1%")
    for provider in ["claude", "codex"] {
      XCTAssertNotNil(defaults.object(forKey: "lastAttemptAt.\(provider)"), "\(provider)'s attempt is recorded in the defaults given")
    }
  }

  /// A publish that fails is logged rather than lost: the MCP server would otherwise serve an old reading
  /// with nothing to say why. The models log to the same place, each line prefixed with its provider.
  func testFailedPublishIsLogged() async {
    struct WriteFailed: LocalizedError { var errorDescription: String? { "disk full" } }
    let logged = Box<[String]>([])
    let model = ProvidersModel(
      providers: [.claude], published: nil, makeProvider: { StubProvider(provider: $0) { snapshot("claude:fetched") } },
      makeNetworkMonitor: { StubNetwork() }, defaults: makeDefaults(), log: { logged.value.append($0) },
      publish: { _ in throw WriteFailed() })
    await model.refreshAll(trigger: "test")
    XCTAssertTrue(logged.value.contains("failed to publish usage state: disk full"), "logged: \(logged.value)")
    XCTAssertTrue(logged.value.contains { $0.hasPrefix("[claude] ") }, "the model logs where the providers model does: \(logged.value)")
  }

  /// Each provider is published with its model's status: `loading` before any reading, then `ok`, `error`
  /// with the error's text, or `rate_limited`; and with a reading time only once it has a reading.
  func testEachStatusIsPublished() async throws {
    let written = Box<[UsageState]>([])
    let model = ProvidersModel(
      providers: [.claude, .codex], published: nil,
      makeProvider: { provider in
        StubProvider(provider: provider) {
          guard provider == .claude else { throw UsageError.badResponse }
          return snapshot("claude:fetched")
        }
      }, makeNetworkMonitor: { StubNetwork() }, defaults: makeDefaults(), log: discardLog, publish: { written.value.append($0) })
    await model.refreshAll(trigger: "test")
    let first = try XCTUnwrap(written.value.first, "a refresh publishes")
    XCTAssertEqual(first.providers.map(\.status), ["loading", "loading"], "nothing has a reading when the first refresh starts")
    XCTAssertEqual(first.providers.map(\.updatedAt), [nil, nil], "no reading, no reading time")
    let last = try XCTUnwrap(written.value.last)
    XCTAssertEqual(last.providers.map(\.status), ["ok", "error"])
    XCTAssertNotNil(last.providers[0].updatedAt, "a reading has its time")
    XCTAssertNil(last.providers[1].updatedAt, "a provider that has only failed has no reading time")
    XCTAssertNotNil(last.providers[1].error)
    XCTAssertEqual(last.providers[1].error, model.model(for: .codex)?.lastError, "an error is published with its text")

    let throttled = Box<[UsageState]>([])
    let limited = ProvidersModel(
      providers: [.claude], published: nil, makeProvider: { StubProvider(provider: $0) { throw UsageError.rateLimited(retryAfter: 600) } },
      makeNetworkMonitor: { StubNetwork() }, defaults: makeDefaults(), log: discardLog, publish: { throttled.value.append($0) })
    await limited.refreshAll(trigger: "test")
    XCTAssertEqual(throttled.value.last?.providers.map(\.status), ["rate_limited"])
  }

  /// Preferences are told which providers have a reading, and only those: pins are dropped only for a
  /// provider that has reported, so one without a reading, whether still loading or failing, must not count
  /// as settled, while one with a reading counts even while it fails.
  func testOnlyProvidersWithAReadingAreSettled() async {
    let settled = Box<[Set<Provider>]>([])
    let model = ProvidersModel(
      providers: [.claude, .codex], published: nil,
      makeProvider: { provider in
        StubProvider(provider: provider) {
          guard provider == .claude else { throw UsageError.badResponse }
          return snapshot("claude:fetched")
        }
      }, makeNetworkMonitor: { StubNetwork() }, defaults: makeDefaults(), log: discardLog, publish: { _ in })
    model.onMetricsSettled = { _, providers in settled.value.append(providers) }
    await model.refreshAll(trigger: "test")
    XCTAssertEqual(settled.value.first, Set<Provider>(), "nothing has a reading when the first refresh starts: \(settled.value)")
    XCTAssertFalse(settled.value.contains { $0.contains(.codex) }, "Codex has only failed: \(settled.value)")
    XCTAssertEqual(settled.value.last, Set([Provider.claude]), "settled: \(settled.value)")

    let restoredSettled = Box<[Set<Provider>]>([])
    let restoring = ProvidersModel(
      providers: [.codex],
      published: UsageState(writtenAt: Date(), pollIntervalSeconds: 300, providers: [reading(of: "codex", metric: "codex:window")]),
      makeProvider: { StubProvider(provider: $0) { throw UsageError.badResponse } }, makeNetworkMonitor: { StubNetwork() },
      defaults: makeDefaults(), log: discardLog, publish: { _ in })
    restoring.onMetricsSettled = { _, providers in restoredSettled.value.append(providers) }
    await restoring.refreshAll(trigger: "test")
    XCTAssertNotNil(restoring.model(for: .codex)?.lastError, "Codex's provider failed")
    XCTAssertEqual(
      restoredSettled.value.last, Set([Provider.codex]), "a provider with a reading counts even while failing: \(restoredSettled.value)")
  }

  /// Each model is given a network monitor of its own: a monitor reports to the one model that started it, so a
  /// monitor shared between models would leave every model but the last blind to the network.
  func testEachModelIsGivenItsOwnNetworkMonitor() async {
    let made = Box<[StubNetwork]>([])
    let model = ProvidersModel(
      providers: [.claude, .codex], published: nil,
      makeProvider: { provider in StubProvider(provider: provider) { snapshot("\(provider.rawValue):fetched") } },
      makeNetworkMonitor: {
        let network = StubNetwork()
        made.value.append(network)
        return network
      }, defaults: makeDefaults(), log: discardLog, publish: { _ in })
    XCTAssertEqual(made.value.count, 2, "one monitor per model")
    await made.value.last?.report(offline: true)
    XCTAssertEqual(model.model(for: .codex)?.isOffline, true)
    XCTAssertEqual(model.model(for: .claude)?.isOffline, false)
  }

  /// The app's Claude provider asks the network through the shared session and reads the login Keychain.
  func testProvidersModelBuildsClaudeOnTheNetworkAndTheKeychain() throws {
    let claude = try XCTUnwrap(ProvidersModel.makeProvider(.claude) as? ClaudeUsageProvider)
    XCTAssertTrue(claude.session === URLSession.shared)
    let credentials = try XCTUnwrap(claude.credentials as? KeychainCredentials)
    XCTAssertEqual(credentials.service, "Claude Code-credentials")
    XCTAssertEqual(credentials.tool, KeychainToken.securityTool)
  }
}
