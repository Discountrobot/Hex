//
//  MenuBarStartMeetingButton.swift
//  Hex
//
//  Phase 0 entry point for Meeting Mode. Only shown when the `meetingModeEnabled` dev flag is on
//  (Settings → Meeting Mode). Sends `.meeting(.start)` to begin a recording + live notepad.
//

import ComposableArchitecture
import HexCore
import SwiftUI

struct MenuBarStartMeetingButton: View {
  @Shared(.hexSettings) var hexSettings: HexSettings

  var body: some View {
    if hexSettings.meetingModeEnabled {
      Button("Start Meeting") {
        HexApp.appStore.send(.meeting(.start))
      }
    }
  }
}
