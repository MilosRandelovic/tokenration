import AppKit

/// Process entry point — starts the AppKit menu-bar app as an accessory
/// (no Dock icon, no main window).
@main enum EntryPoint {
  static func main() {
    MainActor.assumeIsolated {
      // Written before the delegate is built: building it runs detection, whose decisions belong to this launch.
      Log.write("app launched (version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"))")
      let app = NSApplication.shared
      let delegate = AppDelegate()
      app.delegate = delegate
      app.setActivationPolicy(.accessory)
      app.run()
    }
  }
}
