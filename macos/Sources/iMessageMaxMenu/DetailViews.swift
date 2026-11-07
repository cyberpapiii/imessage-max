import IMessageMaxContract
import MaxCore
import ServiceManagement
import SwiftUI

struct SetupStep: View {
  let model: AppModel

  var body: some View {
    Card {
      if let diagnosis = model.diagnosis {
        switch diagnosis.readiness {
        case .messages:
          if diagnosis.database.status == .permissionDenied {
            heading("Let Messages in")
            line(
              "In Full Disk Access, turn on iMessage Max. If it isn’t listed, click + and add the iMessage Max app shown in Finder. Then come back and restart it."
            )
            buttons {
              Button("Open Settings") { model.openSettings("Privacy_AllFiles") }
                .buttonStyle(MaxButtonStyle(primary: true))
              Button("Show app") { model.revealApp() }
              Button("Restart after allowing") { model.perform(.restart) }
                .disabled(model.busy != nil)
            }
          } else {
            heading("Find your Messages")
            line(
              "Open Messages and make sure iMessage is set up on this Mac. Then restart iMessage Max to check again."
            )
            buttons {
              Button("Open Messages") { model.openMessages() }
                .buttonStyle(MaxButtonStyle(primary: true))
              Button("Restart and check") { model.perform(.restart) }.disabled(model.busy != nil)
            }
          }
        case .contacts:
          if diagnosis.contacts.authorized {
            heading("Names did not load")
            line("Contacts access is allowed. Restart iMessage Max and check again.")
            buttons {
              Button("Restart and check") { model.perform(.restart) }
                .buttonStyle(MaxButtonStyle(primary: true)).disabled(model.busy != nil)
              recheck
            }
          } else {
            heading("Put names to numbers")
            line(
              "Allow Contacts so your assistants can recognize people. This does not change your contacts."
            )
            buttons {
              if [.denied, .restricted].contains(diagnosis.contacts.status) {
                Button("Open Contacts Settings") { model.openSettings("Privacy_Contacts") }
                  .buttonStyle(MaxButtonStyle(primary: true))
                // The helper reads Contacts access once at launch.
                Button("Restart after allowing") { model.perform(.restart) }
                  .disabled(model.busy != nil)
              } else {
                Button("Allow Contacts") { model.request(.contacts) }
                  .buttonStyle(MaxButtonStyle(primary: true)).disabled(model.busy != nil)
                recheck
              }
            }
          }
        case .sending:
          heading(model.messagesNeedOpening ? "Check sending" : "Enable sending")
          line(
            model.messagesNeedOpening
              ? "Messages needs to be open to check access. We’ll open it for you. macOS may ask for permission. No message is sent."
              : "Allow iMessage Max to work with Messages. Your assistant sends only when you ask. Setup sends no message."
          )
          buttons {
            if diagnosis[.permAutomation]?.isPermissionGated == true {
              Button("Open Automation Settings") { model.openSettings("Privacy_Automation") }
                .buttonStyle(MaxButtonStyle(primary: true))
            } else {
              Button(
                model.messagesNeedOpening ? "Open Messages and check" : "Allow Messages access"
              ) { model.request(.automation) }
              .buttonStyle(MaxButtonStyle(primary: true)).disabled(model.busy != nil)
            }
            recheck
          }
        case .ready:
          EmptyView()
        }
      }
    }
  }

  private func heading(_ text: String) -> some View { Text(text).font(.maxStrong) }

  private func line(_ text: String) -> some View {
    Text(text).font(.maxLine).foregroundStyle(Design.muted)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    FlowRow(spacing: Space.tight) { content() }.buttonStyle(MaxButtonStyle())
  }

  private var recheck: some View {
    Button("Check again after allowing") { Task { await model.refresh() } }
      .disabled(model.busy != nil || model.checking)
  }
}

struct FlowRow: Layout {
  var spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(width: proposal.width ?? .infinity, subviews: subviews).size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let places = arrange(width: bounds.width, subviews: subviews).places
    for (subview, place) in zip(subviews, places) {
      subview.place(
        at: CGPoint(x: bounds.minX + place.x, y: bounds.minY + place.y), proposal: .unspecified)
    }
  }

  private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, places: [CGPoint]) {
    var places: [CGPoint] = []
    var (x, y, rowHeight, widest): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0 && x + size.width > width {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      places.append(CGPoint(x: x, y: y))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
      widest = max(widest, x - spacing)
    }
    return (CGSize(width: widest, height: y + rowHeight), places)
  }
}

struct ConnectionView: View {
  let model: AppModel

  var body: some View {
    let access = model.clientAccess
    VStack(alignment: .leading, spacing: Space.regular) {
      Text(
        "Connect an assistant in one click. iMessage Max adds itself to the assistant’s settings and saves a backup of any file it changes."
      )
      .font(.maxLine).fixedSize(horizontal: false, vertical: true)
      if access == nil {
        IconLabel(title: "Start iMessage Max first. Its access key appears on first start.", glyph: .warning)
          .font(.maxSmall).foregroundStyle(Design.attention)
          .fixedSize(horizontal: false, vertical: true)
      }
      if !model.clients.isEmpty {
        Card {
          VStack(spacing: Space.snug) {
            ForEach(model.clients) { row in
              ClientRowView(row: row, canConnect: access != nil) { model.connect(row.id) }
              if row.id != model.clients.last?.id { Divider() }
            }
          }
        }
      } else if model.clientsScanned {
        Card {
          Text("No assistants found on this Mac").font(.maxStrong)
          Text(
            "iMessage Max looks for Claude, Claude Code, Codex, Cursor and Plug. Any other MCP client can connect with the address and access header below."
          )
          .font(.maxLine).foregroundStyle(Design.muted).fixedSize(horizontal: false, vertical: true)
        }
      }
      VStack(alignment: .leading, spacing: Space.tight) {
        Text("Any other MCP client").font(.maxStrong)
        Text(
          "Add a streamable HTTP server with this address, and have it send the access header with every request."
        )
        .font(.maxSmall).foregroundStyle(Design.muted).fixedSize(horizontal: false, vertical: true)
        HStack(spacing: Space.snug) {
          AppGlyph(glyph: .connection, size: 14).foregroundStyle(Design.muted)
          Text(model.endpoint).font(.maxCode)
            .textSelection(.enabled).lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.snug)
        .background(
          Design.well, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        FlowRow(spacing: Space.tight) {
          CopyButton(title: "Copy address") {
            model.copy(model.endpoint, acknowledgement: "Address copied.")
          }
          CopyButton(title: "Copy access header") {
            if let header = model.accessHeader {
              model.copy(header, acknowledgement: "Access header copied. Keep it private.")
            }
          }
          .disabled(access == nil)
        }
        .buttonStyle(MaxButtonStyle())
      }
      Text("This address works only on this Mac. Each assistant controls its own tool approvals.")
        .font(.maxSmall).foregroundStyle(Design.muted).fixedSize(horizontal: false, vertical: true)
    }
    .task { await model.refreshClients() }
  }
}

struct ClientRowView: View {
  let row: ClientRow
  let canConnect: Bool
  let connect: () -> Void
  @PanelMotion private var motion

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
      case .connected: "Uses iMessage Max on this Mac"
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
    VStack(alignment: .leading, spacing: Space.tight) {
      HStack(spacing: Space.snug) {
        VStack(alignment: .leading, spacing: Space.hairline) {
          Text(row.name).font(.maxLine)
          Text(status).font(.maxSmall).foregroundStyle(Design.muted)
            .contentTransition(.interpolate)
        }
        .accessibilityElement(children: .combine)
        Spacer(minLength: Space.snug)
        trailing
      }
      .frame(minHeight: 32)
      if let note {
        Text(note.text).font(.maxSmall)
          .foregroundStyle(note.problem ? Design.attention : Design.muted)
          .fixedSize(horizontal: false, vertical: true)
          .transition(.opacity)
      }
    }
    .animation(motion[.swap], value: row)
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder private var trailing: some View {
    if row.activity == .connecting {
      ProgressView().controlSize(.small).accessibilityLabel("Connecting \(row.name)")
    } else if connected {
      HStack(spacing: Space.rowGap) {
        Text("Connected").font(.maxSmall)
        ActionGlyph(mark: .check, size: 12)
      }
      .foregroundStyle(Design.ready)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(row.name) connected")
    } else {
      Button(isFailure ? "Try again" : "Connect", action: connect)
        .buttonStyle(MaxButtonStyle())
        .disabled(!canConnect)
        .accessibilityLabel(isFailure ? "Try connecting \(row.name) again" : "Connect \(row.name)")
    }
  }

  private var isFailure: Bool {
    if case .failed = row.activity { true } else { false }
  }
}

struct DetailsView: View {
  let model: AppModel
  var body: some View {
    let inbox = model.diagnosis?[.liveInbox]?.isSupported == true ? "Available" : "Not available"
    VStack(alignment: .leading, spacing: Space.regular) {
      Card {
        VStack(spacing: Space.tight) {
          fact("Version", model.diagnosis?.version ?? "Not connected")
          fact("Live inbox", inbox)
          if let date = model.lastCheck {
            fact("Checked", date.formatted(date: .omitted, time: .shortened))
          }
        }
      }
      FlowRow(spacing: Space.tight) {
        CopyButton(title: "Copy diagnostic report") {
          model.copy(
            model.diagnosticReport,
            acknowledgement: "Report copied. It has no messages or contact details.")
        }
        Button {
          model.openLogs()
        } label: {
          IconLabel(title: "Open log", glyph: .document)
        }
        Button {
          model.perform(.restart)
        } label: {
          IconLabel(title: "Restart iMessage Max", glyph: .refresh)
        }
        .disabled(!model.canControl || model.stopped)
        Button {
          model.openMessages()
        } label: {
          IconLabel(title: "Open Messages", glyph: .messages)
        }
      }
      .buttonStyle(MaxButtonStyle())
      VStack(alignment: .leading, spacing: Space.tight) {
        Text(
          "If an assistant lost its connection after a restart, reconnect it in the assistant’s settings."
        )
        Text(
          "Quitting this app leaves iMessage Max running. Turn it off with the switch when you want a break."
        )
      }
      .font(.maxSmall).foregroundStyle(Design.muted).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func fact(_ title: String, _ value: String) -> some View {
    HStack {
      Text(title).foregroundStyle(Design.muted)
      Spacer()
      Text(value)
    }
    .font(.maxLine)
    .accessibilityElement(children: .ignore).accessibilityLabel("\(title): \(value)")
  }
}

struct PreferencesView: View {
  let model: AppModel
  var body: some View {
    VStack(alignment: .leading, spacing: Space.regular) {
      Card {
        HStack {
          Text("Open at login").font(.maxLine)
          Spacer()
          Toggle(
            "Open at login",
            isOn: Binding(
              get: { model.loginStatus == .enabled || model.loginStatus == .requiresApproval },
              set: { model.setLaunchAtLogin($0) })
          )
          .toggleStyle(MaxSwitchStyle())
        }
        if model.loginStatus == .requiresApproval {
          Text("macOS needs your approval in Login Items.").font(.maxLine)
          Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
            .buttonStyle(MaxButtonStyle())
        }
      }
      VStack(alignment: .leading, spacing: Space.tight) {
        Text("The companion follows your Mac’s appearance and accessibility preferences.")
        Text(
          "iMessage Max runs locally. This companion never reads your conversations or sends a message."
        )
      }
      .font(.maxSmall).foregroundStyle(Design.muted).fixedSize(horizontal: false, vertical: true)
    }
  }
}
