import Foundation

/// A usage source TokenRation can read. Deliberately a closed set — the app is not a
/// general multi-provider framework.
enum Provider: String, CaseIterable, Sendable {
  case claude
  case codex
  case grok

  var displayName: String {
    switch self {
    case .claude: "Claude"
    case .codex: "Codex"
    case .grok: "Grok"
    }
  }

  /// The launch's one detection: the providers set up on this Mac, in a stable order, Codex counting as set up
  /// whenever its credentials exist (see `CodexUsageProvider.detectSetUp()`). Filesystem checks: when Codex's
  /// credentials exist, Codex's check also starts a search for codex in the background, which may ask the login
  /// shell, within the bound that `CodexBinary.loginShellDeadline` documents, because codex on a `PATH` only a
  /// shell profile sets is findable no other way. Asking runs the user's login profile, so this runs once,
  /// where the app is wired together. Never itself prompts for Keychain access. `home` is where the Claude
  /// check looks for Claude Code's `.claude` directory and the Grok check for Grok Build's sign-in, and `codex` runs
  /// Codex's check, `detectSetUp()`. The app passes the user's home and a provider on `CodexBinary.Resolver.shared`,
  /// the resolver every fetch uses; a test passes a fixture home and its own.
  static func detectAll(home: URL, codex: CodexUsageProvider) -> [Provider] {
    allCases.filter { provider in
      switch provider {
      case .claude:
        // Claude Code's config directory; the token itself lives in the Keychain, which we
        // deliberately don't touch until an actual fetch.
        FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path)
      case .codex: codex.detectSetUp()
      case .grok: GrokUsageProvider.isSetUp(home: home)
      }
    }
  }

  /// Menu-bar/panel glyphs. Each provider uses a **distinct symbol family** for the same
  /// concepts, which is how the menu bar tells them apart: template images are monochrome
  /// (so colour is unavailable), and adding letters or dividers would cost width.
  ///
  ///   Claude — clock · calendar · cpu · dollarsign.circle
  ///   Codex  — hourglass.bottomhalf.filled · hourglass · cpu.fill · creditcard
  ///   Grok   — bolt · bolt.circle · bolt.square · banknote
  func symbol(for kind: MetricKind) -> String {
    switch (self, kind) {
    case (.claude, .session): "clock"
    case (.claude, .window): "calendar"
    case (.claude, .model): "cpu"
    case (.claude, .money): "dollarsign.circle"
    case (.codex, .session): "hourglass.bottomhalf.filled"
    case (.codex, .window): "hourglass"
    case (.codex, .model): "cpu.fill"
    case (.codex, .money): "creditcard"
    case (.grok, .session): "bolt"
    case (.grok, .window): "bolt.circle"
    case (.grok, .model): "bolt.square"
    case (.grok, .money): "banknote"
    }
  }

  /// Namespaced metric id, e.g. `claude:session`, `codex:model:bengalfox`.
  func metricID(_ suffix: String) -> String { "\(rawValue):\(suffix)" }

  /// The metric pinned by default for this provider: Claude's session, and Codex's and Grok's long window, which every
  /// plan has.
  var defaultMetricID: String {
    switch self {
    case .claude: metricID("session")
    case .codex, .grok: metricID("window")
    }
  }

  /// The provider a namespaced metric id belongs to, or nil if it isn't one of ours.
  static func owning(metricID: String) -> Provider? {
    guard let prefix = metricID.split(separator: ":").first else { return nil }
    return Provider(rawValue: String(prefix))
  }
}

/// What a metric measures, independent of provider — used to pick the provider's glyph.
enum MetricKind: Sendable {
  /// A window shorter than a day: Claude's 5-hour, and Codex's by its duration, whichever slot it arrives in.
  case session
  /// A longer window (weekly).
  case window
  /// A per-model limit.
  case model
  /// Spend or credits.
  case money
}
