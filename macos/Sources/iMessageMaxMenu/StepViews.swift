import IMessageMaxContract
import MaxCore
import ServiceManagement
import SwiftUI

/// The four permissions in one card, the same during first run and after.
/// The first missing one opens in place, with what to do and its buttons.
struct PermissionList: View {
  let model: AppModel
  let permissions: Permissions
  @PanelMotion private var motion

  var body: some View {
    VStack(alignment: .leading, spacing: Space.tight) {
      Text("Permissions").font(.maxSmall.weight(.medium)).foregroundStyle(Design.muted)
        .padding(.leading, Space.hairline)
        .accessibilityAddTraits(.isHeader)
      Card {
        ForEach(permissions.rows) { row in
          let open = row.step == permissions.current
          PermissionRowView(row: row, open: open)
          if open {
            PermissionDetail(model: model, step: row.step)
              .padding(.leading, PermissionRowView.markerSize + Space.snug)
              .padding(.bottom, Space.rowGap)
              .transition(.opacity)
          }
        }
      }
    }
    .animation(motion[.glide], value: permissions)
  }
}

struct PermissionRowView: View {
  static let markerSize: CGFloat = 20
  let row: PermissionRow
  let open: Bool

  var body: some View {
    HStack(alignment: .top, spacing: Space.snug) {
      marker
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: Space.snug) {
          Text(row.step.title).font(open ? .maxStrong : .maxLine)
          Spacer(minLength: 0)
          Text(row.word).font(.maxSmall).foregroundStyle(tint)
            .lineLimit(1).fixedSize().contentTransition(.interpolate)
        }
        .frame(minHeight: Self.markerSize)
        Text(row.step.purpose).font(.maxSmall).foregroundStyle(Design.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isStaticText)
    .accessibilityLabel("\(row.step.title): \(row.word)")
    .accessibilityHint(row.step.purpose)
  }

  private var tint: Color {
    switch row.grant {
    case .granted: Design.ready
    case .missing: Design.attention
    case .unknown: Design.muted
    }
  }

  @ViewBuilder private var marker: some View {
    let size = Self.markerSize
    switch row.grant {
    case .granted:
      ActionGlyph(mark: .check, size: 11).foregroundStyle(Design.ready)
        .frame(width: size, height: size)
        .background(Design.ready.opacity(Design.wash + 0.05), in: Circle())
    case .missing:
      Text("!").font(.system(size: 12, weight: .bold)).foregroundStyle(Design.attention)
        .frame(width: size, height: size)
        .background(Design.attention.opacity(Design.wash + 0.05), in: Circle())
    case .unknown:
      Circle().strokeBorder(Design.track, lineWidth: 1.5).frame(width: size, height: size)
    }
  }
}

/// Shown under Permissions once every permission is on, until an assistant
/// connects or the user chooses Not now.
struct ConnectCard: View {
  let model: AppModel

  var body: some View {
    let access = model.clientAccess
    let firstOpen = model.clients.first { $0.link != .connected }?.id
    Card {
      Text("Connect your assistant").font(.maxStrong)
      if !model.clients.isEmpty {
        Text("Pick the assistant you use. iMessage Max adds itself to its settings and keeps a backup of any file it changes.")
          .font(.maxLine).foregroundStyle(Design.muted)
          .fixedSize(horizontal: false, vertical: true)
        VStack(spacing: Space.rowGap) {
          ForEach(model.clients) { row in
            ClientRowView(row: row, canConnect: access != nil, prominent: row.id == firstOpen) {
              model.connect(row.id)
            }
          }
        }
      } else if model.clientsScanned {
        Text("No assistants found on this Mac. Any MCP client can connect with the address on the Connections page.")
          .font(.maxLine).foregroundStyle(Design.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
      FlowRow(spacing: Space.tight) {
        if model.clients.isEmpty {
          Button("Other ways to connect") { model.section = .connections }
            .buttonStyle(MaxButtonStyle(primary: model.clientsScanned))
        } else {
          Button("Other ways") { model.section = .connections }
        }
        Button("Not now") { model.dismissConnect() }
      }
      .buttonStyle(MaxButtonStyle())
    }
  }
}

/// What a missing permission asks, and the buttons that grant it. A grant
/// that reaches only a new helper restarts the helper itself on Check again
/// and when the panel opens, so the user never restarts anything.
struct PermissionDetail: View {
  let model: AppModel
  let step: SetupStep

  var body: some View {
    VStack(alignment: .leading, spacing: Space.snug) {
      switch step {
      case .backgroundActivity: background
      case .fullDiskAccess: fullDisk
      case .contacts: contacts
      case .automation: automation
      }
    }
  }

  @ViewBuilder private var background: some View {
    if model.state.phase == .blocked {
      line("macOS runs the helper only while iMessage Max is on in Login Items. Turn it on there, then come back.")
      buttons {
        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
          .buttonStyle(MaxButtonStyle(primary: true))
        recheck
      }
    } else {
      line("iMessage Max adds a small helper to your Login Items.")
      buttons {
        Button("Turn on") { model.perform(.start) }
          .buttonStyle(MaxButtonStyle(primary: true)).disabled(model.busy != nil)
      }
    }
  }

  @ViewBuilder private var fullDisk: some View {
    if model.diagnosis?.database.status == .databaseNotFound {
      line("Open Messages and make sure iMessage is set up on this Mac. Then check again.")
      buttons {
        Button("Open Messages") { model.openMessages() }
          .buttonStyle(MaxButtonStyle(primary: true))
        Button("Check again") { model.perform(.restart) }.disabled(model.busy != nil)
      }
    } else {
      line("In Full Disk Access, turn on iMessage Max. If it isn’t listed, click + and add the app shown in Finder. When you come back, iMessage Max checks by itself.")
      buttons {
        Button("Open Settings") { model.openSettings("Privacy_AllFiles") }
          .buttonStyle(MaxButtonStyle(primary: true))
        Button("Show app") { model.revealApp() }
        recheck
      }
    }
  }

  @ViewBuilder private var contacts: some View {
    let access = model.diagnosis?.contacts
    if access?.authorized == true {
      line("Contacts access is on, but names did not load yet. Check again to start a fresh helper.")
      buttons {
        Button("Check again") { model.recheck() }
          .buttonStyle(MaxButtonStyle(primary: true)).disabled(model.busy != nil)
      }
    } else if let status = access?.status, [.denied, .restricted].contains(status) {
      line("Contacts access is off for iMessage Max. Turn it on in Contacts settings. When you come back, iMessage Max checks by itself.")
      buttons {
        Button("Open Contacts Settings") { model.openSettings("Privacy_Contacts") }
          .buttonStyle(MaxButtonStyle(primary: true))
        recheck
      }
    } else {
      line("Allow Contacts so your assistants can recognize people. This does not change your contacts.")
      buttons {
        Button("Allow Contacts") { model.request(.contacts) }
          .buttonStyle(MaxButtonStyle(primary: true)).disabled(model.busy != nil)
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
          .buttonStyle(MaxButtonStyle(primary: true))
      } else {
        Button(opensMessages ? "Open Messages and check" : "Allow Messages access") {
          model.request(.automation)
        }
        .buttonStyle(MaxButtonStyle(primary: true)).disabled(model.busy != nil)
      }
      recheck
    }
  }

  private func line(_ text: String) -> some View {
    Text(text).font(.maxLine).foregroundStyle(Design.muted)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    FlowRow(spacing: Space.tight) { content() }.buttonStyle(MaxButtonStyle())
  }

  private var recheck: some View {
    Button("Check again") { model.recheck() }
      .disabled(model.busy != nil || model.checking)
  }
}
