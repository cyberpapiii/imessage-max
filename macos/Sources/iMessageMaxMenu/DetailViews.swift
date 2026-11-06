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
              "In Full Disk Access, click + and add the iMessage Max helper shown in Finder. Then come back and restart it."
            )
            buttons {
              Button("Open Settings") { model.openSettings("Privacy_AllFiles") }
                .buttonStyle(MaxButtonStyle(primary: true))
              Button("Show helper") { model.revealHelper() }
              Button("I’ve allowed access — restart") { model.perform(.restart) }
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
            heading("Names need another look")
            line("Contacts access is allowed, but the names did not load. Restart iMessage Max and check again.")
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
              } else {
                Button("Allow Contacts") { model.request(.contacts) }
                  .buttonStyle(MaxButtonStyle(primary: true)).disabled(model.busy != nil)
              }
              recheck
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
    Button("I’ve allowed access — check again") { Task { await model.refresh() } }
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
    VStack(alignment: .leading, spacing: Space.regular) {
      Text(
        "Add iMessage Max as a local MCP server in your assistant’s settings. Then reconnect the assistant."
      )
      .font(.maxLine).fixedSize(horizontal: false, vertical: true)
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
        Menu {
          Button("Codex configuration") {
            model.copy(model.codexConfiguration, acknowledgement: "Codex configuration copied.")
          }
          Button("MCP HTTP configuration") {
            model.copy(model.clientConfiguration, acknowledgement: "MCP configuration copied.")
          }
          Button("Plug configuration") {
            model.copy(model.plugConfiguration, acknowledgement: "Plug configuration copied.")
          }
        } label: {
          IconLabel(title: "Copy setup", glyph: .document)
        }
        .menuStyle(.button).fixedSize()
      }
      .buttonStyle(MaxButtonStyle())
      .disabled(model.inspection == nil)
      Text("This address works only on this Mac. Each assistant controls its own tool approvals.")
        .font(.maxSmall).foregroundStyle(Design.muted).fixedSize(horizontal: false, vertical: true)
    }
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
            acknowledgement: "Report copied. No messages or contact details included.")
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
