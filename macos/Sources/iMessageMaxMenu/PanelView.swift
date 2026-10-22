import AppKit
import MaxCore
import SwiftUI

enum PanelSection: String { case connection, details, preferences }

/// One fixed-width panel. The home page shows the service's state and the one
/// thing that needs the person; everything else is a page that slides in
/// inside the same panel.
struct PanelView: View {
  let model: AppModel
  var dismissPanel: () -> Void = {}
  @State private var contentHeight: CGFloat = 260
  @MotionReduced private var reduceMotion
  private static let footerHeight: CGFloat = 41

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        ZStack(alignment: .top) {
          if let section = model.section {
            page(section).id(section)
              .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
          } else {
            home
              .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
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
        Toast(text: notice, good: model.problem == nil && !notice.hasPrefix("Setup isn’t"))
          .padding(.bottom, Self.footerHeight + Space.tight)
          .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
      }
    }
    .tint(Design.blue)
    .animation(reduceMotion ? nil : Move.step, value: model.section)
    .animation(reduceMotion ? nil : Move.swap, value: model.notice)
    .animation(reduceMotion ? nil : Move.glide, value: model.problem)
    .animation(reduceMotion ? nil : Move.glide, value: model.diagnosis?.readiness)
    .animation(reduceMotion ? nil : Move.swap, value: model.busy)
    .onAppear { Task { await model.refresh() } }
    .onChange(of: model.notice) {
      guard let notice = model.notice else { return }
      model.noticeAppeared()
      NSAccessibility.post(
        element: NSApplication.shared, notification: .announcementRequested,
        userInfo: [.announcement: notice, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    .onExitCommand {
      if model.section != nil { model.section = nil } else { dismissPanel() }
    }
  }

  // MARK: Home

  private var home: some View {
    VStack(alignment: .leading, spacing: Space.regular) {
      header
      if let problem = model.problem {
        Card(wash: Design.attention) {
          IconLabel(title: "Needs a little attention", glyph: .warning)
            .font(.maxStrong).foregroundStyle(Design.attention)
          Text(problem).font(.maxLine).fixedSize(horizontal: false, vertical: true)
          if model.canControl && !model.stopped {
            Button("Restart iMessage Max") { model.perform(.restart) }
              .buttonStyle(MaxButtonStyle())
          }
        }
        .transition(.opacity)
      }
      if model.diagnosis != nil {
        if !model.ready { SetupStep(model: model).transition(.opacity) }
        status
      }
      if model.diagnosis == nil || model.ready {
        Button(action: primaryAction) {
          HStack(spacing: Space.tight) {
            Text(model.primaryTitle).contentTransition(.interpolate)
            ActionGlyph(
              mark: model.busy != nil ? .more : (model.stopped ? .play : .arrow), size: 14)
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(MaxButtonStyle(primary: true))
        .disabled(model.busy != nil || (model.lastCheck == nil && model.problem == nil))
        .accessibilityIdentifier("primaryAction")
      }
      VStack(spacing: Space.hairline) {
        if !model.ready {
          NavRow(title: "Connection", glyph: .connection) { model.section = .connection }
        }
        NavRow(title: "Details & help", glyph: .details) { model.section = .details }
        NavRow(title: "Preferences", glyph: .preferences) { model.section = .preferences }
      }
      .padding(.horizontal, -Space.snug + Space.hairline)
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: Space.snug + Space.hairline) {
      MaxFaceView(mood: model.mood, celebration: model.celebration, awake: model.panelOpen)
      VStack(alignment: .leading, spacing: Space.hairline) {
        HStack(alignment: .center) {
          Text(model.title).font(.maxTitle).contentTransition(.interpolate)
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
        Text(model.subtitle).font(.maxLine).foregroundStyle(Design.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var status: some View {
    let diagnosis = model.diagnosis
    let sending = diagnosis?.capabilities["perm_automation"]?.state
    return Card {
      VStack(spacing: Space.hairline) {
        StatusLine(
          glyph: .messages, title: "Messages",
          detail: diagnosis?.database.accessible == true ? "Ready" : "Needs access",
          good: diagnosis?.database.accessible == true,
          attention: diagnosis?.database.accessible == false)
        StatusLine(
          glyph: .contacts, title: "Contact names",
          detail: diagnosis?.namesReady == true
            ? (diagnosis?.contacts.status == "limited" ? "Some names" : "Ready")
            : (diagnosis?.contacts.authorized == true ? "Needs a check" : "Needs access"),
          good: diagnosis?.namesReady == true, attention: diagnosis?.namesReady == false)
        StatusLine(
          glyph: .sending, title: "Sending",
          detail: sending == "supported"
            ? "Ready" : (sending == "permission-gated" ? "Needs access" : "Not checked"),
          good: sending == "supported", attention: sending == "permission-gated")
      }
      .padding(.vertical, -Space.rowGap)
    }
  }

  // MARK: Pages

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

  private func primaryAction() {
    if model.diagnosis != nil {
      model.section = .connection
    } else if model.stopped {
      model.perform(.start)
    } else {
      Task { await model.refresh() }
    }
  }
}

extension PanelSection {
  var heading: String {
    switch self {
    case .connection: "Connect your assistant"
    case .details: "A closer look"
    case .preferences: "Preferences"
    }
  }
}
