import AppKit
import Observation
import SwiftUI

@main
struct iMessageMaxMenuApp {
  @MainActor static func main() {
    let app = NSApplication.shared
    let design = DesignOptions()
    if let appearance = design.appearance { app.appearance = NSAppearance(named: appearance) }
    if let sheet = design.artworkSheet {
      writeArtworkSheet(to: sheet)
      return
    }
    let delegate = AppDelegate(design: design)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
      app.run()
    }
  }
}

/// AppKit owns only the status item and popover lifecycle. The public
/// MenuBarExtra API cannot show the panel on app launch or reopen, and a new
/// user needs both to find the app. The panel and its state use SwiftUI and
/// Observation.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
  private let design: DesignOptions
  private let milestones: Milestones
  private let model: AppModel
  private var designWindow: NSWindow?
  private var statusItem: NSStatusItem?
  private let popover = NSPopover()
  private var keyMonitor: Any?

  init(design: DesignOptions) {
    self.design = design
    if let fixture = design.fixture {
      milestones = Milestones(defaults: nil)
      model = .designFixture(fixture, milestones: milestones)
    } else {
      milestones = Milestones(defaults: .standard)
      model = .live(milestones: milestones)
    }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem = item
    item.button?.target = self
    item.button?.action = #selector(togglePanel)
    popover.behavior = .transient
    popover.delegate = self
    popover.appearance = NSApp.appearance
    popover.animates =
      !(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || design.motion.reduce)
    let hosting = NSHostingController(
      rootView: PanelView(model: model).environment(\.motionSettings, design.motion))
    hosting.sizingOptions = [.preferredContentSize]
    updateStatusItem()
    if design.isActive {
      design.prepare(model)
      if design.window {
        designWindow = design.showWindow(hosting, model: model)
        return
      }
    } else {
      model.startMonitoring()
      // `make install` and uninstall scripts pass these. Launch arguments
      // reach only a new launch of the app.
      let arguments = CommandLine.arguments
      if arguments.contains("--register-helper") { model.registerHelper() }
      if arguments.contains("--unregister-helper") { model.unregisterHelperAndQuit() }
    }
    popover.contentViewController = hosting
    if !milestones.reached(.introducedMenuBar) {
      milestones.mark(.introducedMenuBar)
      showPanel()
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    showPanel()
    return false
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard model.busy != nil, design.fixture == nil else { return .terminateNow }
    Task {
      await model.prepareToQuit()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  @objc private func togglePanel() {
    if popover.isShown { popover.performClose(nil) } else { showPanel() }
  }

  private func showPanel() {
    guard let button = statusItem?.button else { return }
    let screenHeight = button.window?.screen?.visibleFrame.height ?? .greatestFiniteMagnitude
    model.maximumPanelHeight = min(Design.maximumPanelHeight, screenHeight - 12)
    model.panelOpen = true
    NSApp.activate(ignoringOtherApps: true)
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    popover.contentViewController?.view.window?.makeKey()
    if keyMonitor == nil {
      // Local monitors run on NSApplication's main event-dispatch thread. This
      // monitor takes only the Escape key, and only in the shown panel.
      // Escape goes back to the home page first, then closes the panel.
      keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        let handled = MainActor.assumeIsolated {
          guard let self, self.popover.isShown, event.keyCode == 53,
            event.window === self.popover.contentViewController?.view.window
          else { return false }
          if self.model.section != nil {
            self.model.section = nil
          } else {
            self.popover.performClose(nil)
          }
          return true
        }
        return handled ? nil : event
      }
    }
    Task { await model.refresh() }
  }

  func popoverDidClose(_ notification: Notification) {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
    model.section = nil
    model.panelOpen = false
    model.clearNotice()
  }

  private func updateStatusItem() {
    withObservationTracking {
      let state = model.state
      let title = "iMessage Max, \(state.title)"
      statusItem?.button?.image = MenuBarArtwork.image(for: state.mood)
      statusItem?.button?.image?.isTemplate = true
      statusItem?.button?.toolTip = title
      statusItem?.button?.setAccessibilityLabel(title)
    } onChange: { [weak self] in
      Task { @MainActor in self?.updateStatusItem() }
    }
  }
}
