import IMessageMaxContract
import MaxCore
import ServiceManagement
import SwiftUI

/// The first-run steps in one card. The current step opens in place, with
/// what to do and its buttons. Every other row is one line.
struct StepList: View {
  let model: AppModel
  let firstRun: FirstRun
  @PanelMotion private var motion

  var body: some View {
    Card {
      VStack(alignment: .leading, spacing: Space.tight) {
        ForEach(Array(firstRun.rows.enumerated()), id: \.element.id) { index, row in
          StepRowView(number: index + 1, count: firstRun.rows.count, row: row) {
            model.skipConnect(false)
          }
          if row.progress == .current {
            StepDetail(model: model, step: row.step)
              .padding(.leading, StepRowView.markerSize + Space.snug)
              .padding(.bottom, Space.rowGap)
              .transition(.opacity)
          }
        }
      }
    }
    .animation(motion[.glide], value: firstRun)
  }
}

struct StepRowView: View {
  static let markerSize: CGFloat = 20
  let number: Int
  let count: Int
  let row: StepRow
  let resume: () -> Void

  var body: some View {
    HStack(spacing: Space.snug) {
      HStack(spacing: Space.snug) {
        marker
        Text(row.step.title)
          .font(row.progress == .current ? .maxStrong : .maxLine)
          .foregroundStyle(row.progress == .current || isDone ? Color.primary : Design.muted)
        Spacer(minLength: Space.snug)
        if case .done(let word) = row.progress {
          Text(word).font(.maxSmall).foregroundStyle(Design.ready)
            .lineLimit(1).contentTransition(.interpolate)
        } else if row.progress == .skipped {
          Text("Skipped").font(.maxSmall).foregroundStyle(Design.muted)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityAddTraits(.isStaticText)
      .accessibilityLabel("Step \(number) of \(count), \(row.step.title): \(spoken)")
      if row.progress == .skipped {
        Button("Connect", action: resume)
          .buttonStyle(MaxButtonStyle())
          .accessibilityLabel("Connect an assistant")
          .accessibilityHint("Shows the step you skipped")
      }
    }
    .frame(minHeight: 26)
  }

  private var isDone: Bool {
    if case .done = row.progress { true } else { false }
  }

  private var spoken: String {
    switch row.progress {
    case .done(let word): word
    case .current: "current step"
    case .skipped: "skipped"
    case .upcoming: "not started"
    }
  }

  @ViewBuilder private var marker: some View {
    let size = Self.markerSize
    switch row.progress {
    case .done:
      ActionGlyph(mark: .check, size: 11).foregroundStyle(Design.ready)
        .frame(width: size, height: size)
        .background(Design.ready.opacity(Design.wash + 0.05), in: Circle())
    case .current:
      Text("\(number)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
        .frame(width: size, height: size).background(Design.blue, in: Circle())
    case .skipped, .upcoming:
      Text("\(number)").font(.system(size: 11, weight: .medium)).foregroundStyle(Design.muted)
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Design.track, lineWidth: 1.5))
    }
  }
}

/// What the current step asks, and the buttons that do it. A step whose
/// grant reaches only a new helper restarts the helper itself on Check again
/// and when the panel opens, so the user never restarts anything.
struct StepDetail: View {
  static let samplePrompt = "Using iMessage Max, list my five most recent conversations."

  let model: AppModel
  let step: SetupStep

  var body: some View {
    VStack(alignment: .leading, spacing: Space.snug) {
      switch step {
      case .allowInBackground: background
      case .readMessages: readMessages
      case .showNames: showNames
      case .sendMessages: sendMessages
      case .connectAssistant: connectAssistant
      case .tryIt: tryIt
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
      line("iMessage Max adds a small helper to Login Items, so your assistants reach Messages even when this panel is closed.")
      buttons {
        Button("Allow in the background") { model.perform(.start) }
          .buttonStyle(MaxButtonStyle(primary: true)).disabled(model.busy != nil)
      }
    }
  }

  @ViewBuilder private var readMessages: some View {
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

  @ViewBuilder private var showNames: some View {
    let contacts = model.diagnosis?.contacts
    if contacts?.authorized == true {
      line("Contacts access is on, but names did not load yet. Check again to start a fresh helper.")
      buttons {
        Button("Check again") { model.recheck() }
          .buttonStyle(MaxButtonStyle(primary: true)).disabled(model.busy != nil)
      }
    } else if let status = contacts?.status, [.denied, .restricted].contains(status) {
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

  @ViewBuilder private var sendMessages: some View {
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

  @ViewBuilder private var connectAssistant: some View {
    let access = model.clientAccess
    let firstOpen = model.clients.first { $0.link != .connected }?.id
    line("Pick the assistant you use. iMessage Max adds itself to its settings and keeps a backup of any file it changes.")
    if !model.clients.isEmpty {
      VStack(spacing: Space.rowGap) {
        ForEach(model.clients) { row in
          ClientRowView(row: row, canConnect: access != nil, prominent: row.id == firstOpen) {
            model.connect(row.id)
          }
        }
      }
    } else if model.clientsScanned {
      line("No assistants found on this Mac. Any MCP client can connect with the address on the Connection page.")
    }
    buttons {
      if model.clients.isEmpty {
        Button("Other ways to connect") { model.section = .connection }
          .buttonStyle(MaxButtonStyle(primary: model.clientsScanned))
      } else {
        Button("Other ways") { model.section = .connection }
      }
      Button("Skip for now") { model.skipConnect(true) }
    }
  }

  @ViewBuilder private var tryIt: some View {
    line("Paste this into your assistant. This step turns green after its first request to iMessage Max.")
    Text(Self.samplePrompt).font(.maxLine)
      .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(Space.snug)
      .background(Design.well, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
      .accessibilityLabel("Sample prompt: \(Self.samplePrompt)")
    buttons {
      CopyButton(title: "Copy prompt", primary: true) {
        model.copy(Self.samplePrompt, acknowledgement: "Prompt copied. Paste it into your assistant.")
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
