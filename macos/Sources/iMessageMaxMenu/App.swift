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

/// AppKit owns the status item, its menu and the Settings window. The public
/// MenuBarExtra and Settings scenes cannot open a window on launch or reopen,
/// and a new user needs both to find the app. The window's content and its
/// state use SwiftUI and Observation.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let design: DesignOptions
  private let milestones: Milestones
  private let model: AppModel
  private var statusItem: NSStatusItem?
  private var statusMenu: StatusMenuController?
  private var settings: SettingsWindowController?
  private var designMenu: NSWindow?

  init(design: DesignOptions) {
    self.design = design
    if let fixture = design.fixture {
      milestones = Milestones(defaults: nil)
      model = .designFixture(fixture, milestones: milestones, clientRoot: design.clientRoot)
    } else {
      milestones = Milestones(defaults: .standard)
      model = .live(milestones: milestones, clientRoot: design.clientRoot)
    }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.mainMenu = makeMainMenu(settings: #selector(showSettings))
    let settings = SettingsWindowController(
      model: model, motion: design.motion,
      focus: design.capture ? .none : .app)
    self.settings = settings
    let menu = StatusMenuController(model: model) { page in settings.show(page) }
    statusMenu = menu
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.menu = menu.menu
    statusItem = item
    updateStatusItem()
    if design.isActive {
      design.prepare(model)
      if design.capture {
        designMenu = design.show(settings: settings, model: model)
        return
      }
    }
    // `make install` and uninstall scripts pass these. Launch arguments
    // reach only a new launch of the app.
    let arguments = CommandLine.arguments
    let scripted = arguments.contains("--register-helper") || arguments.contains("--unregister-helper")
    if !design.isActive {
      model.startMonitoring()
      if arguments.contains("--register-helper") { model.registerHelper() }
      if arguments.contains("--unregister-helper") { model.unregisterHelperAndQuit() }
    }
    // A person who opens the app sees Settings, on Permissions. A launch at
    // login stays quiet in the menu bar.
    if design.isActive || !(scripted || Self.launchedAtLogin) { settings.show(.permissions) }
  }

  private static var launchedAtLogin: Bool {
    let event = NSAppleEventManager.shared().currentAppleEvent
    return event?.eventID == kAEOpenApplication
      && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        == keyAELaunchedAsLogInItem
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    settings?.show(nil)
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

  @objc private func showSettings() { settings?.show(nil) }

  private func updateStatusItem() {
    withObservationTracking {
      let state = model.state
      let title = "iMessage Max, \(state.status.word)"
      statusItem?.button?.image = MenuBarArtwork.image(for: state.mood)
      statusItem?.button?.image?.isTemplate = true
      statusItem?.button?.toolTip = title
      statusItem?.button?.setAccessibilityLabel(title)
    } onChange: { [weak self] in
      Task { @MainActor in self?.updateStatusItem() }
    }
  }
}
