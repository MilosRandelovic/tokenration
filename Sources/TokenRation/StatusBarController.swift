import AppKit
import SwiftUI

/// Borderless panel that can still become key, so its SwiftUI buttons receive clicks.
private final class PanelWindow: NSPanel { override var canBecomeKey: Bool { true } }

/// Dropdown content with a rounded material background, so the borderless panel reads as a
/// native dropdown.
private struct PanelRoot: View {
  let providers: ProvidersModel
  let prefs: Preferences
  let updates: UpdateChecker
  var body: some View {
    UsagePanelView(providers: providers, prefs: prefs, updates: updates).background(.regularMaterial).clipShape(
      RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}

/// Manages a SINGLE menu-bar item (all pinned metrics side by side) plus a custom dropdown
/// panel. An owned `NSPanel` rather than `NSPopover` is deliberate: `NSPopover` cannot
/// reposition while open, so it drifts off-centre as the item resizes, and its transient
/// dismissal conflicts with the status-item click. A panel can be moved smoothly with
/// `setFrame` (no close/reopen, so no flicker) and dismissed explicitly via an event monitor.
///
/// Menu-bar icons are template images, so macOS tints them to the bar's colour (light/dark).
@MainActor final class StatusBarController: NSObject {
  private let providers: ProvidersModel
  private let prefs: Preferences
  private let updates: UpdateChecker
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let hostingView: NSHostingView<PanelRoot>
  private let panel: PanelWindow
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var trackTimer: Timer?
  private var countdownTimer: Timer?
  private var animationDeadline = Date.distantPast
  private var spinnerTimer: Timer?
  private var spinnerIndex = 0
  private static let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

  init(providers: ProvidersModel, prefs: Preferences, updates: UpdateChecker) {
    self.providers = providers
    self.prefs = prefs
    self.updates = updates
    self.hostingView = NSHostingView(rootView: PanelRoot(providers: providers, prefs: prefs, updates: updates))
    self.panel = PanelWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 220), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: true)
    super.init()

    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .popUpMenu
    panel.hidesOnDeactivate = false
    panel.contentView = hostingView

    statusItem.button?.target = self
    statusItem.button?.action = #selector(togglePanel(_:))
    statusItem.button?.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(statusButtonFrameChanged), name: NSView.frameDidChangeNotification, object: statusItem.button)

    providers.onChange = { [weak self] in self?.render() }
    // The secondary line counts down, so it drifts between readings — a poll is five minutes
    // apart, and a held-off provider can go hours without one. Redraw on its own cadence.
    countdownTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.render() } }
    prefs.onChange = { [weak self] in self?.render() }
    render()
  }

  private func render() {
    guard let button = statusItem.button else { return }
    let ids = prefs.shownMetricIDs.isEmpty ? [Provider.claude.metricID("session")] : prefs.shownMetricIDs
    button.imagePosition = .imageOnly
    button.toolTip = tooltip(ids: ids)

    if providers.allMetrics.isEmpty && !providers.hasError {
      startSpinner()  // loading: animated menu-bar spinner
      button.appearsDisabled = false
      return
    }
    stopSpinner()

    if !providers.allMetrics.isEmpty {
      button.image = compositeImage(ids: ids)
      // Always render crisp (matching native icons). Dimming for staleness read as a
      // rendering defect; staleness is surfaced in the panel instead.
      button.appearsDisabled = false
    } else {
      // No data + a failure: a single status glyph — "waiting" vs. "error".
      button.image = iconImage(providers.hasError ? "exclamationmark.triangle" : "hourglass")
      button.appearsDisabled = false
    }
    // Re-centering on resize is driven by the button's frame-change notification
    // (statusButtonFrameChanged), which fires once the new geometry has settled.
  }

  // MARK: - Loading / status icons

  private func startSpinner() {
    guard spinnerTimer == nil else { return }
    spinnerIndex = 0
    statusItem.button?.image = spinnerImage()
    spinnerTimer = Timer.scheduledTimer(timeInterval: 0.08, target: self, selector: #selector(spinnerTick), userInfo: nil, repeats: true)
  }

  private func stopSpinner() {
    spinnerTimer?.invalidate()
    spinnerTimer = nil
  }

  @objc private func spinnerTick() {
    spinnerIndex += 1
    statusItem.button?.image = spinnerImage()
  }

  /// A braille spinner frame at a FIXED width, so animating it doesn't resize the item
  /// (which would re-center the panel every tick).
  private func spinnerImage() -> NSImage {
    let height = max(NSStatusBar.system.thickness, 22)
    let width: CGFloat = 22
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let text = NSAttributedString(
      string: Self.spinnerFrames[spinnerIndex % Self.spinnerFrames.count],
      attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black, .paragraphStyle: paragraph])
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    text.draw(in: NSRect(x: 0, y: ((height - text.size().height) / 2).rounded(), width: width, height: text.size().height))
    image.unlockFocus()
    image.isTemplate = true
    return image
  }

  /// A single centered SF Symbol as a template image (rate-limited / error, no data yet).
  private func iconImage(_ symbolName: String) -> NSImage {
    let height = max(NSStatusBar.system.thickness, 22)
    let width: CGFloat = 26
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    if let symbol = symbolImage(symbolName) {
      symbol.draw(
        in: NSRect(
          x: ((width - symbol.size.width) / 2).rounded(), y: ((height - symbol.size.height) / 2).rounded(), width: symbol.size.width,
          height: symbol.size.height))
    }
    image.unlockFocus()
    image.isTemplate = true
    return image
  }

  /// The item resized (pin/unpin) or moved; re-center the open panel with the settled
  /// geometry so it tracks the item in the same layout pass — no stale-then-correct hop.
  @objc private func statusButtonFrameChanged() { if panel.isVisible { layoutPanel(animated: true) } }

  // MARK: - Panel show / hide / position

  @objc private func togglePanel(_ sender: Any?) { if panel.isVisible { hidePanel() } else { showPanel() } }

  private func showPanel() {
    layoutPanel()
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    // Credentials can have been replaced since the last attempt, which may be a quarter of an
    // hour ago; re-reading them here is what clears the warning glyph and re-enables refresh.
    Task { await providers.refreshCredentialStates() }
    // Background polling is slow by design; top up when the panel is opened — but only if
    // the reading is stale, so opening it repeatedly can't spam the endpoint.
    if let model = providers.selectedModel, model.isStale() { Task { await model.refresh(trigger: "panel opened") } }
    // Opening the panel is when the update banner is actually read; the checker's own gap keeps
    // this from turning into a request per click.
    Task { await updates.check() }
    startMonitors()
    trackTimer = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(trackTick), userInfo: nil, repeats: true)
  }

  private func hidePanel() {
    trackTimer?.invalidate()
    trackTimer = nil
    stopMonitors()
    panel.orderOut(nil)
  }

  /// Size the panel to its content and center it under the item, just below the menu bar.
  /// Only writes when the frame actually changes, so a stable item causes no churn; when
  /// the item drifts/resizes, `setFrame` slides the panel smoothly (no close/reopen).
  private func layoutPanel(animated: Bool = false) {
    guard let button = statusItem.button, let window = button.window else { return }
    let fitting = hostingView.fittingSize
    let size = NSSize(width: fitting.width > 10 ? fitting.width : 300, height: fitting.height > 10 ? fitting.height : 220)
    let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
    let origin = NSPoint(x: (buttonRect.midX - size.width / 2).rounded(), y: (buttonRect.minY - size.height - 5).rounded())
    let target = NSRect(origin: origin, size: size)

    let current = panel.frame
    let moved = abs(current.minX - target.minX) > 0.5 || abs(current.minY - target.minY) > 0.5
    let resized = abs(current.width - target.width) > 0.5 || abs(current.height - target.height) > 0.5
    guard moved || resized else { return }

    if animated {
      animationDeadline = Date().addingTimeInterval(panel.animationResizeTime(target))
      panel.setFrame(target, display: true, animate: true)
    } else {
      panel.setFrame(target, display: true)
    }
  }

  @objc private func trackTick() {
    guard panel.isVisible else {
      hidePanel()
      return
    }
    guard Date() >= animationDeadline else { return }  // let an in-progress glide finish
    layoutPanel(animated: true)
  }

  private func startMonitors() {
    // Click outside → dismiss, but never for a click on our own status item: this monitor
    // runs *before* the button's action, so hiding here would let the action see a hidden
    // panel and immediately re-show it — the panel would never close. The panel's own
    // frame is excluded too, so interacting with it can't dismiss it.
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
      guard let self, !self.clickIsOnOurUI() else { return }
      self.hidePanel()
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
      if event.keyCode == 53 {  // Esc
        self?.hidePanel()
        return nil
      }
      return event
    }
  }

  /// Whether the pointer is over our status item or the open panel. Global monitor events
  /// carry no window, so compare against screen coordinates.
  private func clickIsOnOurUI() -> Bool {
    let location = NSEvent.mouseLocation
    if panel.isVisible, panel.frame.contains(location) { return true }
    guard let button = statusItem.button, let window = button.window else { return false }
    return window.convertToScreen(button.convert(button.bounds, to: nil)).contains(location)
  }

  private func stopMonitors() {
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    globalMonitor = nil
    localMonitor = nil
  }

  // MARK: - Rendering

  /// All pinned metrics laid out left-to-right into one template image.
  private func compositeImage(ids: [String]) -> NSImage {
    let height = max(NSStatusBar.system.thickness, 22)
    let segments = ids.map { segment(id: $0) }
    let segmentGap: CGFloat = 10
    let sidePad: CGFloat = 4
    let width = sidePad * 2 + segments.reduce(0) { $0 + $1.size.width } + segmentGap * CGFloat(max(segments.count - 1, 0))

    let image = NSImage(size: NSSize(width: max(width, 12), height: height))
    image.lockFocus()
    var x = sidePad
    for seg in segments {
      seg.draw(in: NSRect(x: x, y: 0, width: seg.size.width, height: height))
      x += seg.size.width + segmentGap
    }
    image.unlockFocus()
    image.isTemplate = true  // macOS tints to the menu-bar foreground colour
    return image
  }

  /// One metric: SF Symbol on the left, then two rows (big value over small secondary).
  private func segment(id: String) -> NSImage {
    let metric = providers.metric(id: id)
    // A provider whose credentials have lapsed shows a warning in place of its own glyph:
    // every one of its rows is stale for the same reason, and unlike a throttle it is
    // something only you can clear.
    let provider = metric?.provider ?? Provider.owning(metricID: id)
    let needsSignIn = provider.map { providers.model(for: $0)?.needsSignIn == true } ?? false
    let glyph = needsSignIn ? "exclamationmark.triangle.fill" : (metric?.symbolName ?? DisplayMetric.symbolName(for: id))
    let symbol = symbolImage(glyph)
    let primary = line(metric?.barText ?? "—", size: 11, weight: .semibold, lineHeight: 12)
    let secondary = line(menuSecondary(for: metric), size: 8, weight: .regular, lineHeight: 9)

    let pSize = primary.size()
    let sSize = secondary.size()
    // The second line's height is reserved whether or not it has text. A window whose reset has
    // passed has nothing to say there, and without the reservation that segment's percentage
    // would centre itself while its neighbours sat on the two-line baseline.
    let secondaryHeight: CGFloat = 9
    let textWidth = max(pSize.width, sSize.width)
    let symbolWidth = symbol?.size.width ?? 0
    let symbolGap: CGFloat = symbol == nil ? 0 : 3
    let height = max(NSStatusBar.system.thickness, 22)

    let image = NSImage(size: NSSize(width: max(symbolWidth + symbolGap + textWidth, 1), height: height))
    image.lockFocus()
    var x: CGFloat = 0
    if let symbol {
      let y = ((height - symbol.size.height) / 2).rounded()
      symbol.draw(in: NSRect(x: x, y: y, width: symbol.size.width, height: symbol.size.height))
      x += symbolWidth + symbolGap
    }
    let bottom = ((height - (pSize.height + secondaryHeight)) / 2).rounded()
    secondary.draw(in: NSRect(x: x, y: bottom, width: textWidth, height: secondaryHeight))
    primary.draw(in: NSRect(x: x, y: bottom + secondaryHeight, width: textWidth, height: pSize.height))
    image.unlockFocus()
    return image
  }

  private func symbolImage(_ name: String) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    image?.isTemplate = true
    return image
  }

  private func line(_ string: String, size: CGFloat, weight: NSFont.Weight, lineHeight: CGFloat) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.maximumLineHeight = lineHeight
    paragraph.minimumLineHeight = lineHeight
    return NSAttributedString(
      string: string,
      attributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight), .foregroundColor: NSColor.black, .paragraphStyle: paragraph,
      ])
  }

  /// Secondary line: reset countdown for windows, or the percentage for metrics that have no
  /// reset at all, such as spend.
  ///
  /// Once a reset has passed there is no live countdown left, so the line holds the time that was
  /// remaining when the reading was taken. That is frozen rather than wrong: it sits beside a
  /// percentage from the same stale reading, and both describe that moment. Falling back to the
  /// percentage instead would print the line above it twice.
  private func menuSecondary(for metric: DisplayMetric?) -> String {
    guard let metric else { return "" }
    if let resetsAt = metric.resetsAt {
      if resetsAt.timeIntervalSinceNow > 0 { return ResetText.short(until: resetsAt) }
      guard let taken = providers.model(for: metric.provider)?.snapshot.updatedAt, resetsAt > taken else { return "" }
      return ResetText.short(until: resetsAt, from: taken)
    }
    if let fraction = metric.fraction { return "\(Int((fraction * 100).rounded()))%" }
    return ""
  }

  private func tooltip(ids: [String]) -> String {
    let lines = ids.compactMap { providers.metric(id: $0) }.map { "\($0.provider.displayName) \($0.title): \($0.valueText)" }
    return lines.isEmpty ? "TokenRation" : lines.joined(separator: "\n")
  }
}
