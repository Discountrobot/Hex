//
//  MeetingView.swift
//  Hex
//
//  The live meeting notepad: a recording indicator, elapsed time, and the streaming transcript.
//  After stopping it shows the final transcript plus the diarization (who-spoke-when) summary.
//

import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct MeetingView: View {
  @ObserveInjection var inject
  @Bindable var store: StoreOf<MeetingFeature>

  private var isRecording: Bool { store.phase == .recording }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      Divider()
      transcript
      if !store.diarization.isEmpty {
        Divider()
        diarizationSummary
      }
      controls
    }
    .padding(16)
    .frame(width: 460, height: 460)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    .enableInjection()
  }

  private var header: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(isRecording ? Color.red : Color.secondary)
        .frame(width: 10, height: 10)
        .opacity(isRecording ? 1 : 0.4)
      Text("Meeting").font(.headline)
      Spacer()
      if let startedAt = store.startedAt, isRecording {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
          Text(elapsed(since: startedAt))
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var transcript: some View {
    ScrollView {
      Text(displayText.isEmpty ? "Listening…" : displayText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(displayText.isEmpty ? .secondary : .primary)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  /// While recording we show the running live transcript; once finished, the clean final one.
  private var displayText: String {
    if store.phase == .finished, !store.finalTranscript.isEmpty {
      return store.finalTranscript
    }
    return store.liveTranscript
  }

  private var diarizationSummary: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Speakers")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      ForEach(Array(store.diarization.prefix(10).enumerated()), id: \.offset) { _, seg in
        Text(String(format: "Speaker %@   %.1f–%.1fs", seg.speakerId, seg.startSeconds, seg.endSeconds))
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
      }
      if store.diarization.count > 10 {
        Text("… \(store.diarization.count - 10) more (full list in Console under category “Meeting”)")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var controls: some View {
    HStack(spacing: 8) {
      if let error = store.errorMessage {
        Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
      } else if !store.statusMessage.isEmpty {
        Text(store.statusMessage).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if store.phase == .processing || store.isDiarizing {
        ProgressView().controlSize(.small)
      }
      if isRecording {
        Button("Stop") { store.send(.stop) }
          .keyboardShortcut(.return)
      } else {
        Button("Close") { store.send(.dismiss) }
          .keyboardShortcut(.cancelAction)
      }
    }
  }

  private func elapsed(since start: Date) -> String {
    let total = max(0, Int(Date().timeIntervalSince(start)))
    return String(format: "%02d:%02d", total / 60, total % 60)
  }
}
