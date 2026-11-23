//
//  WindowDragArea.swift
//  Hex
//
//  A transparent AppKit view that starts a native window drag on mouse-down. Placed behind
//  SwiftUI content (`.background(WindowDragArea())`), it makes the empty parts of a borderless
//  panel draggable while buttons, text fields and selectable text in front keep their clicks.
//
//  `isMovableByWindowBackground` alone does not work for SwiftUI content: `NSHostingView`
//  does not report itself as draggable background, so clicks never start a window move.
//

import AppKit
import SwiftUI

struct WindowDragArea: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { DragView() }
  func updateNSView(_ nsView: NSView, context: Context) {}

  private final class DragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    // The agent panel is non-activating and usually not key, so the first click must already
    // start the drag instead of being spent on focusing the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
      window?.performDrag(with: event)
    }
  }
}
