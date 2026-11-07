import AppKit
import IMessageMaxContract
import MaxCore
import SwiftUI

enum PanelSection: String { case connection, details, preferences }

struct PanelView: View {
  let model: AppModel
  @State private var contentHeight: CGFloat = 260
  @PanelMotion private var motion
  private static let footerHeight: CGFloat = 41

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        ZStack(alignment: .top) {
          if let section = model.section {
            page(section).id(section)
              .transition(
                motion.reduced ? .opacity : .move(edge: .trailing).combined(with: .opacity))
          } else {
            home
              .transition(
                motion.reduced ? .opacity : .move(edge: .leading).combined(with: .opacity))
          }
        }
        .padding([.horizontal, .top], Design.inset).padding(.bottom, Space.snug)
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: {
          contentHeight = $0
        }
      }
      .scrollBounceBehavior(.basedOnSize)
      .scrollIndicators(.hidden)
      .frame(height: min(contentHeight, model.maximumPanelHeight - Self.footerHeight))
      .clipped()
      footer
    }
    .frame(width: Design.width)
    .background(Design.canvas)
    .overlay(alignment: .bottom) {
      if let notice = model.notice {
        Toast(text: notice.text, good: notice.tone == .good && model.problem == nil)
          .padding(.bottom, Self.footerHeight + Space.tight)
          .transition(motion.reduced ? .opacity : .move(edge: .bottom).combined(with: .opacity))
      }
    }
    .tint(Design.blue)
    .animation(motion[.step], value: model.section)
    .animation(motion[.swap], value: model.notice)
    .animation(motion[.glide], value: model.problem)
    .animation(motion[.glide], value: model.state.phase)
    .animation(motion[.swap], value: model.busy)
    .onChange(of: model.notice) {
      guard let notice = model.notice else { return }
      model.noticeAppeared()
      NSAccessibility.post(
        element: NSApplication.shared, notification: .announcementRequested,
        userInfo: [
          .announcement: notice.text, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }
  }

  private var home: some View {
    let state = model.state
    return VStack(alignment: .leading, spacing: Space.regular) {
      header(state)
      if let problem = model.problem {
        Card(wash: Design.attention) {
          IconLabel(title: "Needs attention", glyph: .warning)
            .font(.maxStrong).foregroundStyle(Design.attention)
          Text(problem).font(.maxLine).fixedSize(horizontal: false, vertical: true)
          if model.canControl && !model.stopped {
            Button("Restart iMessage Max") { model.perform(.restart) }
              .buttonStyle(MaxButtonStyle())
          }
        }
        .transition(.opacity)
      }
      if let firstRun = state.firstRun {
        StepList(model: model, firstRun: firstRun).transition(.opacity)
      }
      if state.primary != nil {
        Button(action: model.runPrimary) {
          HStack(spacing: Space.tight) {
            Text(state.primaryTitle).contentTransition(.interpolate)
            ActionGlyph(mark: state.primaryMark, size: 14)
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(MaxButtonStyle(primary: true))
        .disabled(!state.primaryEnabled)
        .accessibilityIdentifier("primaryAction")
      }
      VStack(spacing: Space.hairline) {
        NavRow(title: "Connection", glyph: .connection) { model.section = .connection }
        NavRow(title: "Details & help", glyph: .details) { model.section = .details }
        NavRow(title: "Preferences", glyph: .preferences) { model.section = .preferences }
      }
      .padding(.horizontal, -Space.snug + Space.hairline)
    }
  }

  private func header(_ state: PanelState) -> some View {
    HStack(alignment: .top, spacing: Space.snug + Space.hairline) {
      MaxFaceView(mood: state.mood, celebration: model.celebration, awake: model.panelOpen)
      VStack(alignment: .leading, spacing: Space.hairline) {
        HStack(alignment: .center) {
          Text(state.title).font(.maxTitle).contentTransition(.interpolate)
          Spacer(minLength: Space.snug)
          if model.showsSwitch {
            Toggle(
              "iMessage Max",
              isOn: Binding(
                get: { model.switchOn },
                set: { model.perform($0 ? .start : .stop) })
            )
            .toggleStyle(MaxSwitchStyle())
            .disabled(!model.canControl)
            .help(model.switchOn ? "Stop iMessage Max" : "Start iMessage Max")
            .accessibilityIdentifier("serviceSwitch")
          }
        }
        .frame(minHeight: 22)
        Text(state.subtitle).font(.maxLine).foregroundStyle(Design.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  @ViewBuilder
  private func page(_ section: PanelSection) -> some View {
    VStack(alignment: .leading, spacing: Space.regular) {
      Button {
        model.section = nil
      } label: {
        HStack(spacing: Space.tight) {
          ActionGlyph(mark: .chevron, size: 14).scaleEffect(x: -1)
            .foregroundStyle(Design.muted)
          Text(section.heading).font(.maxTitle)
          Spacer()
        }
        .frame(minHeight: 22).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Back").accessibilityHint(section.heading)
      switch section {
      case .connection: ConnectionView(model: model)
      case .details: DetailsView(model: model)
      case .preferences: PreferencesView(model: model)
      }
    }
  }

  private var footer: some View {
    HStack(spacing: Space.tight) {
      HStack(spacing: Space.rowGap) {
        AppGlyph(glyph: .lock, size: 12)
        Text("Only on this Mac")
      }
      .accessibilityElement(children: .combine)
      Spacer()
      IconButton(glyph: .refresh, label: "Check status") { Task { await model.refresh() } }
        .disabled(model.checking || model.busy != nil)
        .accessibilityIdentifier("refreshStatus")
      Button("Quit") { NSApp.terminate(nil) }
        .buttonStyle(.plain)
        .help("Quit the companion. iMessage Max keeps running.")
    }
    .font(.maxSmall).foregroundStyle(Design.muted)
    .padding(.horizontal, Design.inset)
    .frame(height: Self.footerHeight - 1)
    .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1) }
    .padding(.top, 1)
  }
}

extension PanelSection {
  var heading: String {
    switch self {
    case .connection: "Connect your assistant"
    case .details: "Details & help"
    case .preferences: "Preferences"
    }
  }
}
