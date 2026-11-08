import IMessageMaxContract
import MaxCore
import ServiceManagement
import SwiftUI

/// A grouped-form row: a title, a line under it, and a control at the end.
struct DetailRow<Trailing: View>: View {
  let title: String
  var detail: String?
  var detailColor: Color = .secondary
  @ViewBuilder var trailing: Trailing

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        if let detail {
          Text(detail).font(.subheadline).foregroundStyle(detailColor)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 8)
      trailing
    }
  }
}

/// A section footnote, aligned with the group's leading edge as in System
/// Settings.
struct Footnote: View {
  let text: String
  var color: Color = .secondary

  init(_ text: String, color: Color = .secondary) {
    self.text = text
    self.color = color
  }

  var body: some View {
    Text(text).font(.footnote).foregroundStyle(color)
      .multilineTextAlignment(.leading)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 10)
  }
}

/// Copies, then says Copied on the button itself for a moment.
struct CopyButton: View {
  let title: String
  let action: () -> Void
  @State private var copied = false

  var body: some View {
    Button {
      action()
      copied = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    } label: {
      Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
        .contentTransition(.symbolEffect(.replace))
    }
    .accessibilityLabel(copied ? "\(title), copied" : title)
  }
}

// MARK: - General

struct GeneralPage: View {
  let model: AppModel
  @State private var confirmingStop = false

  var body: some View {
    let state = model.state
    Form {
      Section {
        HStack(spacing: 12) {
          MaxFaceView(
            mood: state.mood, celebration: model.celebration, size: 40, awake: model.windowOpen)
          VStack(alignment: .leading, spacing: 2) {
            Text("iMessage Max").font(.headline)
            Text(state.subtitle).font(.subheadline).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 8)
          serviceButton(state)
        }
        .padding(.vertical, 2)
        if let problem = model.problem {
          Label {
            DetailRow(title: "Needs attention", detail: problem) {
              if model.canControl && !model.stopped {
                Button("Restart iMessage Max") { model.perform(.restart) }
              }
            }
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          }
        }
        if model.triedNews {
          Label {
            Text("Your assistant just used iMessage Max. You’re all set.")
          } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
          }
        }
      }
      Section {
        Toggle(
          isOn: Binding(
            get: { model.loginStatus == .enabled || model.loginStatus == .requiresApproval },
            set: { model.setLaunchAtLogin($0) })
        ) {
          Text("Open at login")
          Text("Shows iMessage Max in the menu bar when you log in.")
        }
        if model.loginStatus == .requiresApproval {
          DetailRow(title: "macOS needs your approval in Login Items.") {
            Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
          }
        }
        if let keepRunning = model.keepRunning {
          Toggle(isOn: Binding(get: { keepRunning }, set: { model.setKeepRunning($0) })) {
            Text("Keep running")
            Text("If iMessage Max quits, it starts again by itself. Stop iMessage Max… still turns it off.")
          }
        }
      } footer: {
        Footnote("Quitting this app leaves iMessage Max running for your assistants.")
      }
    }
    .confirmationDialog("Stop iMessage Max?", isPresented: $confirmingStop) {
      Button("Stop", role: .destructive) { model.perform(.stop) }
    } message: {
      Text("Your assistants can’t use Messages until you start it again.")
    }
  }

  @ViewBuilder private func serviceButton(_ state: PanelState) -> some View {
    if let busy = model.busy {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text(busy.title).foregroundStyle(.secondary)
      }
    } else if state.primary != nil {
      Button(state.primaryTitle, action: model.runPrimary)
        .buttonStyle(.borderedProminent)
        .disabled(!state.primaryEnabled)
    } else if model.service?.isRunning == true {
      Button("Stop iMessage Max…") { confirmingStop = true }
        .disabled(!model.canControl)
    } else if state.step != nil {
      Button("Show Permissions") { model.show(.permissions) }
        .buttonStyle(.borderedProminent)
    }
  }
}

// MARK: - Permissions

struct PermissionsPage: View {
  let model: AppModel
  @MotionStyle private var motion

  var body: some View {
    let state = model.state
    Form {
      if let permissions = state.permissions {
        Section {
          ForEach(permissions.rows) { row in
            VStack(alignment: .leading, spacing: 10) {
              PermissionRowView(row: row)
              if row.step == permissions.current {
                PermissionFix(model: model, step: row.step)
                  .padding(.leading, PermissionRowView.iconWidth + 10)
              }
            }
            .padding(.vertical, 2)
          }
        } footer: {
          Footnote("System Settings lists each of these as iMessage Max.")
        }
        if state.offersConnect { ConnectPrompt(model: model) }
      } else if state.phase == .checking {
        Section {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Checking…").foregroundStyle(.secondary)
          }
        }
      } else {
        Section {
          ContentUnavailableView {
            Label(
              state.phase == .stopped ? "iMessage Max Is Stopped" : "Can’t Check Permissions",
              systemImage: "hand.raised")
          } description: {
            Text(state.subtitle)
          } actions: {
            if state.primary != nil {
              Button(state.primaryTitle, action: model.runPrimary)
                .buttonStyle(.borderedProminent).disabled(!state.primaryEnabled)
            }
          }
        }
      }
    }
    .animation(motion[.glide], value: state.permissions)
  }
}

struct PermissionRowView: View {
  static let iconWidth: CGFloat = 20
  let row: PermissionRow

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      icon.frame(width: Self.iconWidth)
      DetailRow(title: row.step.title, detail: row.step.purpose) {
        Text(row.word).foregroundStyle(wordColor).contentTransition(.interpolate)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(row.step.title): \(row.word)")
    .accessibilityHint(row.step.purpose)
  }

  @ViewBuilder private var icon: some View {
    switch row.grant {
    case .granted: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    case .missing: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
    case .unknown: Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
    }
  }

  private var wordColor: Color {
    if case .missing = row.grant { return .orange }
    return .secondary
  }
}

/// What a missing permission asks, and the buttons that grant it. A grant
/// that reaches only a new helper restarts the helper itself on Check Again
/// and when the user comes back to the window, so the user never restarts
/// anything.
struct PermissionFix: View {
  let model: AppModel
  let step: SetupStep

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      switch step {
      case .backgroundActivity: background
      case .fullDiskAccess: fullDisk
      case .contacts: contacts
      case .automation: automation
      }
      if model.notice == .setupUnfinished {
        Text(Notice.setupUnfinished.text).font(.subheadline).foregroundStyle(.orange)
      }
    }
  }

  @ViewBuilder private var background: some View {
    if model.state.phase == .blocked {
      line("macOS runs the helper only while iMessage Max is on in Login Items. Turn it on there, then come back.")
      buttons {
        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
          .buttonStyle(.borderedProminent)
        recheck
      }
    } else {
      line("iMessage Max adds a small helper to your Login Items.")
      buttons {
        Button("Turn On") { model.perform(.start) }
          .buttonStyle(.borderedProminent).disabled(model.busy != nil)
      }
    }
  }

  @ViewBuilder private var fullDisk: some View {
    if model.diagnosis?.database.status == .databaseNotFound {
      line("Open Messages and make sure iMessage is set up on this Mac. Then check again.")
      buttons {
        Button("Open Messages") { model.openMessages() }.buttonStyle(.borderedProminent)
        Button("Check Again") { model.perform(.restart) }.disabled(model.busy != nil)
      }
    } else {
      line("In Full Disk Access, turn on iMessage Max. If it isn’t listed, click + and add the app shown in Finder. When you come back, iMessage Max checks by itself.")
      buttons {
        Button("Open Settings") { model.openSettings("Privacy_AllFiles") }
          .buttonStyle(.borderedProminent)
        Button("Show App") { model.revealApp() }
        recheck
      }
    }
  }

  @ViewBuilder private var contacts: some View {
    let access = model.diagnosis?.contacts
    if access?.authorized == true {
      line("Contacts access is on, but names did not load yet. Check again to start a fresh helper.")
      buttons {
        Button("Check Again") { model.recheck() }
          .buttonStyle(.borderedProminent).disabled(model.busy != nil)
      }
    } else if let status = access?.status, [.denied, .restricted].contains(status) {
      line("Contacts access is off for iMessage Max. Turn it on in Contacts settings. When you come back, iMessage Max checks by itself.")
      buttons {
        Button("Open Contacts Settings") { model.openSettings("Privacy_Contacts") }
          .buttonStyle(.borderedProminent)
        recheck
      }
    } else {
      line("Allow Contacts so your assistants can recognize people. This does not change your contacts.")
      buttons {
        Button("Allow Contacts") { model.request(.contacts) }
          .buttonStyle(.borderedProminent).disabled(model.busy != nil)
        recheck
      }
    }
  }

  @ViewBuilder private var automation: some View {
    let opensMessages = model.messagesNeedOpening
    line(
      opensMessages
        ? "Messages needs to be open to check access. We’ll open it for you. macOS may ask for permission. No message is sent."
        : "Allow iMessage Max to work with Messages. Your assistant sends only when you ask. Setup sends no message."
    )
    buttons {
      if model.diagnosis?[.permAutomation]?.isPermissionGated == true {
        Button("Open Automation Settings") { model.openSettings("Privacy_Automation") }
          .buttonStyle(.borderedProminent)
      } else {
        Button(opensMessages ? "Open Messages and Check" : "Allow Messages Access") {
          model.request(.automation)
        }
        .buttonStyle(.borderedProminent).disabled(model.busy != nil)
      }
      recheck
    }
  }

  private func line(_ text: String) -> some View {
    Text(text).font(.subheadline).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func buttons(@ViewBuilder _ content: () -> some View) -> some View {
    HStack(spacing: 8) {
      content()
      if let busy = model.busy {
        ProgressView().controlSize(.small)
        Text(busy.title).font(.subheadline).foregroundStyle(.secondary)
      }
    }
  }

  private var recheck: some View {
    Button("Check Again") { model.recheck() }
      .disabled(model.busy != nil || model.checking)
  }
}

/// Under Permissions once every permission is on, until an assistant
/// connects or the user chooses Not Now.
struct ConnectPrompt: View {
  let model: AppModel

  var body: some View {
    let firstOpen = model.clients.first { $0.link != .connected }?.id
    Section {
      if model.clients.isEmpty {
        DetailRow(
          title: "No assistants found on this Mac",
          detail: "Any MCP client can connect with the address on the Connections page."
        ) {
          Button("Show Connections") { model.show(.connections) }
        }
      } else {
        ForEach(model.clients) { row in
          ClientRowView(row: row, canConnect: model.clientAccess != nil, prominent: row.id == firstOpen) {
            model.connect(row.id)
          }
        }
      }
    } header: {
      HStack {
        Text("Connect your assistant")
        Spacer()
        Button("Not Now") { model.dismissConnect() }.controlSize(.small)
      }
    } footer: {
      if !model.clients.isEmpty {
        Footnote("iMessage Max adds itself to the assistant’s settings and keeps a backup of any file it changes.")
      }
    }
  }
}

// MARK: - Connections

struct ConnectionsPage: View {
  let model: AppModel

  var body: some View {
    let access = model.clientAccess
    Form {
      Section {
        if !model.clients.isEmpty {
          ForEach(model.clients) { row in
            ClientRowView(row: row, canConnect: access != nil) { model.connect(row.id) }
          }
        } else if model.clientsScanned {
          ContentUnavailableView {
            Label("No Assistants Found", systemImage: "sparkle.magnifyingglass")
          } description: {
            Text("iMessage Max looks for Claude, Claude Code, Codex, Cursor and Plug.")
          } actions: {
            Button("Look Again") { Task { await model.refreshClients() } }
          }
        } else {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Looking for assistants…").foregroundStyle(.secondary)
          }
        }
      } header: {
        Text("Assistants on this Mac")
      } footer: {
        if access == nil {
          Footnote("Start iMessage Max first. Its access key appears on first start.", color: .orange)
        } else {
          Footnote("Connect adds iMessage Max to the assistant’s settings and keeps a backup of any file it changes.")
        }
      }
      Section {
        DetailRow(title: "Address") {
          Text(model.endpoint).font(.body.monospaced()).foregroundStyle(.secondary)
            .textSelection(.enabled)
          CopyButton(title: "Copy") {
            model.copy(model.endpoint, acknowledgement: "Address copied.")
          }
        }
        DetailRow(title: "Access header", detail: "Send it with every request. Keep it private.") {
          CopyButton(title: "Copy") {
            if let header = model.accessHeader {
              model.copy(header, acknowledgement: "Access header copied. Keep it private.")
            }
          }
          .disabled(access == nil)
        }
      } header: {
        Text("Any other MCP client")
      } footer: {
        Footnote("Add a streamable HTTP server with this address. It works only on this Mac, and each assistant controls its own tool approvals.")
      }
    }
    .task { await model.refreshClients() }
  }
}

struct ClientRowView: View {
  let row: ClientRow
  let canConnect: Bool
  /// The connect prompt makes its first Connect the page's one blue button.
  var prominent = false
  let connect: () -> Void
  @MotionStyle private var motion

  private var connected: Bool {
    if case .waiting = row.activity { return false }
    return row.link == .connected && row.activity != .connecting
  }

  private var status: String {
    switch row.activity {
    case .connecting: return "Connecting…"
    case .waiting: return "Finish in \(row.name)"
    case .failed: return "Not connected"
    case .idle, .finished:
      return switch row.link {
      case .connected: "Ready to use"
      case .outdated: "Set up for an older iMessage Max"
      case .notConnected: "Not connected"
      }
    }
  }

  private var note: (text: String, problem: Bool)? {
    switch row.activity {
    case .finished(let text), .waiting(let text): (text, false)
    case .failed(let text): (text, true)
    case .idle, .connecting: nil
    }
  }

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(row.name)
        Text(status).font(.subheadline).foregroundStyle(.secondary)
          .contentTransition(.interpolate)
        if let note {
          Text(note.text).font(.subheadline)
            .foregroundStyle(note.problem ? Color.red : .secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .accessibilityElement(children: .combine)
      Spacer(minLength: 8)
      trailing
    }
    .animation(motion[.swap], value: row)
  }

  @ViewBuilder private var trailing: some View {
    if row.activity == .connecting {
      ProgressView().controlSize(.small).accessibilityLabel("Connecting \(row.name)")
    } else if connected {
      Label("Connected", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .accessibilityLabel("\(row.name) connected")
    } else {
      let button = Button(isFailure ? "Try Again" : "Connect", action: connect)
        .disabled(!canConnect)
        .accessibilityLabel(isFailure ? "Try connecting \(row.name) again" : "Connect \(row.name)")
      if prominent { button.buttonStyle(.borderedProminent) } else { button }
    }
  }

  private var isFailure: Bool {
    if case .failed = row.activity { true } else { false }
  }
}

// MARK: - About & Help

struct AboutPage: View {
  let model: AppModel

  var body: some View {
    let inbox = model.diagnosis?[.liveInbox]?.isSupported == true ? "Available" : "Not available"
    Form {
      Section {
        LabeledContent("Version", value: model.diagnosis?.version ?? "Not connected")
        LabeledContent("Live inbox", value: inbox)
        DetailRow(
          title: "Last checked",
          detail: model.lastCheck?.formatted(date: .omitted, time: .shortened) ?? "Not yet"
        ) {
          Button("Check Now") { Task { await model.refresh() } }
            .disabled(model.checking || model.busy != nil)
        }
      }
      Section {
        DetailRow(title: "Diagnostic report", detail: "Has no messages or contact details.") {
          CopyButton(title: "Copy Report") {
            model.copy(
              model.diagnosticReport,
              acknowledgement: "Report copied. It has no messages or contact details.")
          }
        }
        DetailRow(
          title: "Service log",
          detail: model.notice == .noLog ? Notice.noLog.text : "What iMessage Max did recently.",
          detailColor: model.notice == .noLog ? .orange : .secondary
        ) {
          Button("Open Log") { model.openLogs() }
        }
        DetailRow(title: "Restart iMessage Max", detail: "Starts a fresh helper.") {
          Button("Restart") { model.perform(.restart) }
            .disabled(!model.canControl || model.stopped)
        }
        DetailRow(title: "Messages", detail: "The app your assistants read and send through.") {
          Button("Open Messages") { model.openMessages() }
        }
      } header: {
        Text("Help")
      } footer: {
        Footnote("If an assistant lost its connection after a restart, reconnect it in the assistant’s settings.")
      }
    }
  }
}
