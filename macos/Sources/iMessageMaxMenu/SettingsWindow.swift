import AppKit
import SwiftUI

/// Owns the one Settings window: an AppKit split view with a native sidebar
/// and toolbar, and SwiftUI in each pane. The app is a menu bar app, so it
/// shows in the Dock and the app switcher only while this window is open.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
  private static let navigation = NSToolbarItem.Identifier("navigation")
  private let model: AppModel
  private let motion: MotionSettings
  private let focus: Focus
  private(set) var window: NSWindow?
  private let back = NSToolbarItem(itemIdentifier: .init("back"))
  private let forward = NSToolbarItem(itemIdentifier: .init("forward"))

  enum Focus {
    /// The app comes forward, with a Dock icon while the window is open.
    case app
    /// The design harness: the window shows without taking focus.
    case none
  }

  init(model: AppModel, motion: MotionSettings, focus: Focus) {
    self.model = model
    self.motion = motion
    self.focus = focus
  }

  /// Shows the window, on `page` if given, else where it was.
  func show(_ page: SettingsPage?) {
    if let page { model.show(page) }
    let window = window ?? makeWindow()
    self.window = window
    model.windowOpen = true
    switch focus {
    case .app:
      NSApp.setActivationPolicy(.regular)
      NSApp.activate()
      window.makeKeyAndOrderFront(nil)
    case .none:
      window.orderFrontRegardless()
    }
  }

  private func makeWindow() -> NSWindow {
    let split = NSSplitViewController()
    let sidebar = NSSplitViewItem(
      sidebarWithViewController: NSHostingController(
        rootView: SettingsSidebar(model: model).environment(\.motionSettings, motion)))
    sidebar.minimumThickness = 215
    sidebar.maximumThickness = 280
    sidebar.canCollapse = false
    let detail = NSSplitViewItem(
      viewController: NSHostingController(
        rootView: SettingsDetail(model: model).environment(\.motionSettings, motion)))
    detail.minimumThickness = 460
    detail.titlebarSeparatorStyle = .none
    split.addSplitViewItem(sidebar)
    split.addSplitViewItem(detail)
    let window = NSWindow(contentViewController: split)
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    let toolbar = NSToolbar(identifier: "Settings")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    window.toolbar = toolbar
    window.toolbarStyle = .unified
    window.titlebarSeparatorStyle = .none
    window.isReleasedWhenClosed = false
    window.appearance = NSApp.appearance
    window.setContentSize(NSSize(width: 760, height: 580))
    window.contentMinSize = NSSize(width: 680, height: 440)
    window.center()
    window.setFrameAutosaveName("Settings")
    window.delegate = self
    self.window = window
    followPage()
    return window
  }

  /// Keeps the title and the back and forward buttons on the current page.
  private func followPage() {
    let history = withObservationTracking { model.history } onChange: { [weak self] in
      Task { @MainActor in self?.followPage() }
    }
    window?.title = history.current.title
    back.isEnabled = history.canGoBack
    forward.isEnabled = history.canGoForward
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.sidebarTrackingSeparator, Self.navigation]
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    guard identifier == Self.navigation else { return nil }
    for (item, symbol, label, help, action) in [
      (back, "chevron.left", "Back", "Go to the previous page", #selector(goBack)),
      (forward, "chevron.right", "Forward", "Go to the next page", #selector(goForward)),
    ] {
      item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
      item.label = label
      item.toolTip = help
      item.isBordered = true
      item.autovalidates = false
      item.target = self
      item.action = action
    }
    let group = NSToolbarItemGroup(itemIdentifier: identifier)
    group.subitems = [back, forward]
    group.label = "Back/Forward"
    group.isNavigational = true
    followPage()
    return group
  }

  @objc private func goBack() { model.history.back() }
  @objc private func goForward() { model.history.forward() }

  /// Coming back from System Settings checks again, so a switch turned on
  /// there shows here without a click.
  func windowDidBecomeKey(_ notification: Notification) {
    Task { await model.opened() }
  }

  func windowWillClose(_ notification: Notification) {
    model.windowOpen = false
    model.clearNotice()
    model.newsSeen()
    if focus == .app { NSApp.setActivationPolicy(.accessory) }
  }
}

/// The menu bar while the Settings window is open, so ⌘W, ⌘Q, ⌘, and Copy
/// work as in any Mac app.
@MainActor
func makeMainMenu(settings: Selector) -> NSMenu {
  let main = NSMenu()
  func submenu(_ title: String, _ items: [NSMenuItem]) {
    let menu = NSMenu(title: title)
    items.forEach(menu.addItem)
    let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    holder.submenu = menu
    main.addItem(holder)
  }
  func item(_ title: String, _ action: Selector?, _ key: String = "") -> NSMenuItem {
    NSMenuItem(title: title, action: action, keyEquivalent: key)
  }
  let hideOthers = item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h")
  hideOthers.keyEquivalentModifierMask = [.command, .option]
  submenu(
    "iMessage Max",
    [
      item("About iMessage Max", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
      .separator(), item("Settings…", settings, ","), .separator(),
      item("Hide iMessage Max", #selector(NSApplication.hide(_:)), "h"), hideOthers,
      .separator(), item(MenuEntry.quitTitle, #selector(NSApplication.terminate(_:)), "q"),
    ])
  submenu(
    "Edit",
    [
      item("Copy", #selector(NSText.copy(_:)), "c"),
      item("Select All", #selector(NSText.selectAll(_:)), "a"),
    ])
  submenu(
    "Window",
    [
      item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
      item("Close", #selector(NSWindow.performClose(_:)), "w"),
    ])
  return main
}

struct SettingsSidebar: View {
  let model: AppModel

  var body: some View {
    List(
      selection: Binding(
        get: { model.history.current },
        set: { if let page = $0 { model.show(page) } })
    ) {
      IdentityRow(model: model)
      Section {
        SidebarRow(page: .general, symbol: "gearshape.fill", color: .gray)
        SidebarRow(page: .permissions, symbol: "hand.raised.fill", color: Design.blue)
        SidebarRow(page: .connections, symbol: "link", color: .green)
      }
      Section {
        SidebarRow(page: .about, symbol: "questionmark", color: .gray)
      }
    }
    .listStyle(.sidebar)
    .tint(Design.blue)
  }
}

struct SettingsDetail: View {
  let model: AppModel

  var body: some View {
    Group {
      switch model.history.current {
      case .general: GeneralPage(model: model)
      case .permissions: PermissionsPage(model: model)
      case .connections: ConnectionsPage(model: model)
      case .about: AboutPage(model: model)
      }
    }
    .formStyle(.grouped)
    .tint(Design.blue)
  }
}

/// The top of the sidebar: who this is and how it is doing, like the account
/// row in System Settings. It is not a page of its own: clicking it opens the
/// page that needs the user, or General.
struct IdentityRow: View {
  let model: AppModel

  var body: some View {
    let state = model.state
    HStack(spacing: 10) {
      MaxFaceView(
        mood: state.mood, celebration: model.celebration, size: 30, awake: model.windowOpen)
      VStack(alignment: .leading, spacing: 1) {
        Text("iMessage Max").font(.system(size: 13, weight: .semibold))
        Text(state.status.word).font(.system(size: 11)).foregroundStyle(.secondary)
          .contentTransition(.interpolate)
      }
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
    .onTapGesture { model.show(state.attention?.page ?? .general) }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("iMessage Max, \(state.status.word)")
    .accessibilityAddTraits(.isButton)
  }
}

struct SidebarRow: View {
  let page: SettingsPage
  let symbol: String
  let color: Color

  var body: some View {
    Label {
      Text(page.title)
    } icon: {
      Image(systemName: symbol)
        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
        .frame(width: 20, height: 20)
        .background(color.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
    .tag(page)
  }
}
