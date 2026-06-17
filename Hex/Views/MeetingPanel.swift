//
//  MeetingPanel.swift
//  Hex
//
//  A floating, non-activating panel that hosts the live Meeting notepad. Mirrors `AgentPanel`:
//  `.nonactivatingPanel` + `becomesKeyOnlyIfNeeded` keep it above other apps (so you can watch the
//  transcript during a call) without yanking focus away from whatever you're doing.
//

import AppKit
import SwiftUI

final class MeetingPanel: NSPanel {
  // Becomes key only when a control (e.g. the Stop button) actually needs it.
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 460, height: 460),
      styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .closable, .resizable],
      backing: .buffered,
      defer: false
    )

    isFloatingPanel = true
    becomesKeyOnlyIfNeeded = true
    level = .floating
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    standardWindowButton(.closeButton)?.isHidden = true
    standardWindowButton(.miniaturizeButton)?.isHidden = true
    standardWindowButton(.zoomButton)?.isHidden = true
    isMovableByWindowBackground = true
    backgroundColor = .clear
    isOpaque = false
    hasShadow = false
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    animationBehavior = .none
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
  }

  static func fromView<V: View>(_ view: V) -> MeetingPanel {
    let panel = MeetingPanel()
    let host = NSHostingController(rootView: view)
    host.sizingOptions = [.preferredContentSize]
    panel.contentViewController = host
    return panel
  }
}

/// Routes a native window close (⌘W via the standard File ▸ Close menu item) through the TCA
/// reducer, so the meeting is properly torn down — recording stopped, ASR/diarize effects
/// cancelled — instead of the panel being hidden out-of-band while state still thinks it's
/// recording (which would leave the mic live with no window).
final class MeetingPanelCloseDelegate: NSObject, NSWindowDelegate {
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    HexApp.appStore.send(.meeting(.dismiss))
    return false
  }
}
