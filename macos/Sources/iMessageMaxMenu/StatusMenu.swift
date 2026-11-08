import AppKit
import SwiftUI

/// One line of the status menu, derived from the state alone, so the menu,
/// its design preview and the tests read the same list.
enum MenuEntry: Equatable {
  case header(Status)
  case attention(Attention)
  case connections(String)
  case separator
  case settings
  case quit
}

extension PanelState {
  var menu: [MenuEntry] {
    var entries: [MenuEntry] = [.header(status)]
    if let attention { entries.append(.attention(attention)) }
    entries += [
      .separator, .connections("Connections: \(connections ?? "Checking…")"),
      .separator, .settings, .separator, .quit,
    ]
    return entries
  }
}

extension MenuEntry {
  static let quitTitle = "Quit iMessage Max"
  static let quitHelp = "Quits this app. iMessage Max keeps running for your assistants."
}

extension Status {
  var tint: Color {
    switch self {
    case .running: .green
    case .attention: .orange
    case .settingUp: Design.blue
    case .stopped, .working: .secondary
    }
  }
}

/// The status item's menu: a header with the face and one status word, the
/// one thing to do next if there is one, Connections, Settings and Quit.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
  let menu = NSMenu()
  private let model: AppModel
  private let openSettings: (SettingsPage?) -> Void
  private var shown: [MenuEntry] = []
  private lazy var header: NSMenuItem = {
    let item = NSMenuItem(title: "iMessage Max", action: nil, keyEquivalent: "")
    let view = MenuItemHostingView(
      rootView: MenuHeaderView(model: model) { [weak self] in self?.choose(.general) })
    view.frame.size = view.fittingSize
    view.resized = { [weak self, weak item] in
      guard let self, let item, self.menu.index(of: item) >= 0 else { return }
      self.menu.itemChanged(item)
    }
    item.view = view
    return item
  }()

  init(model: AppModel, openSettings: @escaping (SettingsPage?) -> Void) {
    self.model = model
    self.openSettings = openSettings
    super.init()
    menu.delegate = self
    menu.autoenablesItems = false
    observe()
  }

  func menuNeedsUpdate(_ menu: NSMenu) { apply(model.state.menu) }

  func menuWillOpen(_ menu: NSMenu) {
    model.menuOpen = true
    Task { await model.opened() }
  }

  func menuDidClose(_ menu: NSMenu) {
    model.menuOpen = false
    model.newsSeen()
  }

  /// Rebuilds the items whenever the entries change while the menu is
  /// closed. An open menu grows for an added item but never shrinks back,
  /// so the list waits for the next open; the header still updates live.
  private func observe() {
    let entries = withObservationTracking {
      _ = model.triedNews
      return model.state.menu
    } onChange: { [weak self] in
      Task { @MainActor in self?.observe() }
    }
    if !model.menuOpen { apply(entries) }
  }

  private func apply(_ entries: [MenuEntry]) {
    guard entries != shown else { return }
    shown = entries
    menu.removeAllItems()
    for entry in entries {
      switch entry {
      case .header: menu.addItem(header)
      case .attention(let attention):
        let item = action(attention.text, page: attention.page)
        let symbol = attention.urgent ? "exclamationmark.triangle.fill" : "link"
        let color: NSColor = attention.urgent ? .systemOrange : .controlAccentColor
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
          .withSymbolConfiguration(.init(paletteColors: [color]))
        menu.addItem(item)
      case .connections(let title): menu.addItem(action(title, page: .connections))
      case .separator: menu.addItem(.separator())
      case .settings:
        let item = action("Settings…", page: nil)
        item.keyEquivalent = ","
        menu.addItem(item)
      case .quit:
        let item = NSMenuItem(
          title: MenuEntry.quitTitle, action: #selector(NSApplication.terminate(_:)),
          keyEquivalent: "q")
        item.toolTip = MenuEntry.quitHelp
        menu.addItem(item)
      }
    }
  }

  private func action(_ title: String, page: SettingsPage?) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(chooseItem(_:)), keyEquivalent: "")
    item.target = self
    item.representedObject = page?.rawValue
    return item
  }

  @objc private func chooseItem(_ item: NSMenuItem) {
    choose((item.representedObject as? String).flatMap(SettingsPage.init(rawValue:)))
  }

  /// Closes the menu first, so the window comes forward once tracking ends.
  private func choose(_ page: SettingsPage?) {
    menu.cancelTracking()
    DispatchQueue.main.async { self.openSettings(page) }
  }
}

/// Sizes a menu item's SwiftUI view to its content. Measured before it is
/// in the menu's window, the view comes out taller than it draws, and an
/// open menu keeps an item's old height until told the item changed.
final class MenuItemHostingView<Content: View>: NSHostingView<Content> {
  var resized: (() -> Void)?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    fit()
  }

  override func invalidateIntrinsicContentSize() {
    super.invalidateIntrinsicContentSize()
    fit()
  }

  private func fit() {
    let size = fittingSize
    guard size != frame.size, size.height > 0 else { return }
    setFrameSize(size)
    resized?()
  }
}

/// The face, the name and one status word. Clicking it opens Settings.
struct MenuHeaderView: View {
  let model: AppModel
  let open: () -> Void
  @State private var hovering = false

  var body: some View {
    let state = model.state
    Button(action: open) {
      HStack(spacing: 10) {
        MaxFaceView(
          mood: state.mood, celebration: model.celebration, size: 30, awake: model.menuOpen)
        VStack(alignment: .leading, spacing: 1) {
          Text("iMessage Max").font(.system(size: 13, weight: .semibold))
          HStack(spacing: 5) {
            Circle().fill(state.status.tint).frame(width: 7, height: 7)
            Text(state.status.word).foregroundStyle(.secondary)
          }
          .font(.system(size: 12))
          if model.triedNews {
            Text("Just used by your assistant")
              .font(.system(size: 11)).foregroundStyle(.green)
          }
        }
        Spacer(minLength: 8)
        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
      }
      .padding(.horizontal, 9).padding(.vertical, 6)
      .background(
        hovering ? Color.primary.opacity(0.08) : .clear,
        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .padding(.horizontal, 5).padding(.vertical, 3)
    .frame(width: 270)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("iMessage Max, \(state.status.word)")
    .accessibilityHint("Opens Settings")
  }
}

/// The status menu drawn in a window, for design captures: an open NSMenu
/// takes over the pointer, so the harness never pops the real one up.
struct StatusMenuPreview: View {
  let model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(model.state.menu.enumerated()), id: \.offset) { _, entry in
        switch entry {
        case .header: MenuHeaderView(model: model) {}
        case .attention(let attention):
          row(attention.text) {
            Image(systemName: attention.urgent ? "exclamationmark.triangle.fill" : "link")
              .foregroundStyle(attention.urgent ? Color.orange : Color.accentColor)
          }
        case .connections(let title): row(title)
        case .separator: Divider().padding(.horizontal, 14).padding(.vertical, 5)
        case .settings: row("Settings…", shortcut: "⌘,")
        case .quit: row(MenuEntry.quitTitle, shortcut: "⌘Q")
        }
      }
    }
    .padding(.vertical, 5)
    .frame(width: 280)
    // Opaque: a material would blur whatever is on screen behind the window
    // into the capture.
    .background(
      Color(nsColor: .windowBackgroundColor),
      in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.12)))
    .padding(24)
  }

  private func row(
    _ title: String, shortcut: String? = nil,
    @ViewBuilder icon: () -> some View = { EmptyView() }
  ) -> some View {
    HStack(spacing: 6) {
      icon()
      Text(title)
      Spacer()
      if let shortcut { Text(shortcut).foregroundStyle(.tertiary) }
    }
    .font(.system(size: 13))
    .padding(.horizontal, 14).frame(height: 24)
  }
}
