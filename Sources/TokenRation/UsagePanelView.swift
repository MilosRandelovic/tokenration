import AppKit
import Combine
import SwiftUI

/// A metric's usage bar.
///
/// Hand-rolled rather than SwiftUI's `Gauge(.accessoryLinearCapacity)`: that style draws its
/// fill with rounded end caps, so an unused metric still showed a sliver of colour at 0%.
/// Here the fill simply isn't drawn until it's at least a pixel wide.
private struct MeterBar: View {
  let fraction: Double
  let color: Color

  var body: some View {
    GeometryReader { geometry in
      let fillWidth = geometry.size.width * min(max(fraction, 0), 1)
      ZStack(alignment: .leading) {
        Capsule().fill(.quaternary)
        if fillWidth >= 1 { Capsule().fill(color).frame(width: fillWidth) }
      }
    }.frame(height: 5)
  }
}

/// The dropdown shown from the menu bar: a tab per detected provider, a meter per metric, a pin
/// toggle to choose which metrics ride in the menu bar, and refresh/quit. Updates live because
/// the models and `Preferences` are `@Observable`.
struct UsagePanelView: View {
  let providers: ProvidersModel
  let prefs: Preferences
  let updates: UpdateChecker
  @State private var showingAbout = false
  /// Drives the relative times below. SwiftUI only redraws when state changes, and a provider
  /// that is held off produces none for hours — so "resets in 2h" would sit frozen at whatever
  /// it read when the panel last drew, disagreeing with the menu bar beside it.
  @State private var now = Date()
  /// Accumulated rotation of the refresh glyph — one turn added per fetch.
  @State private var spin = 0.0
  private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

  var body: some View {
    Group { if showingAbout { aboutView } else { mainView } }.padding(14).frame(width: 300).onReceive(clock) { now = $0 }
  }

  /// The model whose metrics are on screen.
  private var model: UsageModel? { providers.selectedModel }

  private var mainView: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      if providers.showsTabs { providerTabs }
      Divider()
      content
      if updates.updateAvailable {
        Divider()
        updateBanner
      }
      Divider()
      footer
    }
  }

  /// One tab per detected provider. Only shown when both are set up.
  ///
  /// The system segmented control, deliberately: it is the standard way to switch between a few
  /// mutually exclusive views, and it picks up whatever the current OS does with selection and
  /// material. Earlier hand-drawn versions matched one macOS release and looked dated on the
  /// next. The selection is accent-coloured because that is how the system shows selection, and
  /// the accent is the user's own choice in System Settings.
  private var providerTabs: some View {
    Picker("", selection: Binding(get: { providers.selected }, set: { providers.selected = $0 })) {
      ForEach(providers.available, id: \.self) { provider in Text(provider.displayName).tag(provider) }
    }.pickerStyle(.segmented).labelsHidden()
  }

  @ViewBuilder private var content: some View {
    if let model {
      if model.snapshot.hasData {
        ForEach(model.snapshot.metrics) { metric in row(metric) }
        // Data is still shown above; flag when it's no longer current.
        if model.rateLimitedUntil != nil {
          footnote("Rate limited — showing last update\(retryText)", systemImage: "hourglass")
        } else if let error = model.lastError {
          footnote(error, systemImage: "exclamationmark.triangle.fill")
        }
      } else if model.rateLimitedUntil != nil {
        statusCard(
          symbol: "hourglass", title: "Rate limited",
          message: "\(providers.selected.displayName)'s usage endpoint is " + "throttling requests. TokenRation will refresh "
            + "automatically\(retryText).")
      } else if let error = model.lastError {
        statusCard(symbol: "exclamationmark.triangle.fill", title: "Unavailable", message: error)
      } else {
        loadingState
      }
    }
  }

  private var header: some View {
    HStack(spacing: 6) {
      appIcon(size: 16)
      Text("TokenRation").font(.headline)
      Spacer()
      if model?.isRefreshing == true { ProgressView().controlSize(.small) }
      Button {
        showingAbout = true
      } label: {
        Image(systemName: "info.circle")
      }.buttonStyle(.borderless).help("About TokenRation")
    }
  }

  /// The app's own icon. An unbundled build (`swift run`) has none, so a glyph stands in there.
  @ViewBuilder private func appIcon(size: CGFloat) -> some View {
    if let icon = NSApp.applicationIconImage {
      Image(nsImage: icon).resizable().frame(width: size, height: size)
    } else {
      Image(systemName: "gauge.with.dots.needle.bottom.50percent")
    }
  }

  /// Shown only when a newer release exists — most users won't run `brew upgrade` unprompted.
  private var updateBanner: some View {
    HStack(spacing: 6) {
      Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
      VStack(alignment: .leading, spacing: 1) {
        Text("Version \(updates.latestVersion ?? "") available").font(.caption.weight(.medium))
        Text("brew upgrade tokenration").font(.caption2).monospaced().foregroundStyle(.secondary).textSelection(.enabled)
      }
      Spacer()
      Link(destination: updates.releasesURL) { Image(systemName: "arrow.up.right.square") }.help("View release on GitHub")
    }
  }

  private func row(_ metric: DisplayMetric) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Image(systemName: metric.symbolName).foregroundStyle(.secondary).frame(width: 16)
        Text(metric.title).font(.subheadline.weight(.medium))
        Spacer()
        Text(metric.barText).font(.subheadline).monospacedDigit()
        pin(metric.id)
      }
      if let fraction = metric.fraction { MeterBar(fraction: fraction, color: tint(metric.severity)) }
      Text(caption(metric)).font(.caption).foregroundStyle(.secondary)
    }
  }

  private func pin(_ id: String) -> some View {
    Button {
      prefs.toggle(id)
    } label: {
      Image(systemName: prefs.isShown(id) ? "pin.fill" : "pin")
    }.buttonStyle(.borderless).help(prefs.isShown(id) ? "Hide from menu bar" : "Show in menu bar")
  }

  private var footer: some View {
    HStack {
      if let model, model.snapshot.hasData {
        Text("Updated \(model.snapshot.updatedAt, format: .dateTime.hour().minute())").font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      let refreshing = model?.isRefreshing == true
      // A refresh asked for during a hold is refused by the guards in `refresh`, so offering it
      // would be a button that accepts the click and does nothing — which reads as a broken
      // control rather than as a deliberate wait. The panel already gives the reason above; the
      // tooltip gives the timing. Offline is refused the same way, with no deadline to give.
      let heldUntil = model?.heldUntil
      let offline = model?.isOffline == true
      Button {
        Task { await model?.refresh(trigger: "manual") }
      } label: {
        Image(systemName: "arrow.clockwise").rotationEffect(.degrees(spin))
      }.buttonStyle(.borderless)
        // One finite turn each time a fetch begins. A repeating animation has to be cancelled
        // when the fetch ends, and one that fails to cancel spins forever; accumulating the angle
        // leaves no animation running and needs no snap back to zero.
        .onChange(of: refreshing) { _, started in if started { withAnimation(.easeInOut(duration: 0.6)) { spin += 360 } } }.disabled(
          refreshing || offline || heldUntil != nil
        ).help(Self.refreshHelp(refreshing: refreshing, offline: offline, heldUntil: heldUntil, now: now))
      Button("Quit") { NSApplication.shared.terminate(nil) }
    }
  }

  private func caption(_ metric: DisplayMetric) -> String {
    // Measured against `now` rather than the wall clock, so the text refreshes with the tick.
    if let resetsAt = metric.resetsAt, resetsAt > now { return "resets in \(ResetText.short(until: resetsAt, from: now))" }
    return metric.valueText  // e.g. spend's "$246.40 / $1,000.00 · 25%"
  }

  private func tint(_ severity: Severity) -> Color {
    switch severity {
    case .normal: .green
    case .warning: .orange
    case .critical: .red
    }
  }

  private var loadingState: some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text("Loading usage…").foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity).padding(.vertical, 10)
  }

  private func statusCard(symbol: String, title: String, message: String) -> some View {
    VStack(spacing: 6) {
      Image(systemName: symbol).font(.title2).foregroundStyle(.orange)
      Text(title).font(.subheadline.weight(.semibold))
      Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }.frame(maxWidth: .infinity).padding(.vertical, 8)
  }

  private func footnote(_ text: String, systemImage: String) -> some View {
    Label(text, systemImage: systemImage).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
  }

  /// Says why the refresh button is unavailable, since a disabled control explains nothing on
  /// its own. Takes the moment to measure against rather than reading the ticking clock itself,
  /// so a hover shows the time left now and the wording can be asserted without a view.
  static func refreshHelp(refreshing: Bool, offline: Bool, heldUntil: Date?, now: Date) -> String {
    if refreshing { return "Refreshing…" }
    // A reconnect refreshes by itself, so the wait offline is for the network, not for a deadline.
    if offline { return "Offline" }
    guard let heldUntil else { return "Refresh now" }
    return "Next attempt in \(ResetText.wait(until: heldUntil, from: now))"
  }

  /// " · retry in 12m" while rate-limited, else "".
  private var retryText: String {
    guard let until = model?.rateLimitedUntil, until.timeIntervalSinceNow > 0 else { return "" }
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.hour, .minute]
    formatter.unitsStyle = .abbreviated
    formatter.maximumUnitCount = 1
    return " · retry in \(formatter.string(from: until.timeIntervalSinceNow) ?? "")"
  }

  // MARK: - About

  private var aboutView: some View {
    VStack(spacing: 10) {
      appIcon(size: 48)
      Text("TokenRation").font(.headline)
      Text("Version \(Self.appVersion)").font(.caption).foregroundStyle(.secondary)
      if updates.updateAvailable {
        Link(destination: updates.releasesURL) {
          Label("Version \(updates.latestVersion ?? "") available", systemImage: "arrow.down.circle.fill").font(.caption)
        }
      } else if updates.latestVersion != nil {
        Label("Up to date", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
      }
      Text(
        "Your Claude and Codex usage in the menu bar.\n\n" + "No separate sign-in: it reuses the credentials the Claude Code and Codex "
          + "CLIs already store, and never changes them."
      ).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
      Link("github.com/MilosRandelovic/tokenration", destination: URL(string: "https://github.com/MilosRandelovic/tokenration")!).font(
        .caption)
      Divider()
      HStack {
        Button("Back") { showingAbout = false }
        Spacer()
        Button("Quit") { NSApplication.shared.terminate(nil) }
      }
    }
  }

  private static var appVersion: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev" }
}
