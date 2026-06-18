//
//  MeetingView.swift
//  Hex
//
//  The live meeting notepad: a recording indicator, elapsed time, and the streaming transcript.
//  After stopping, it replaces the running text with the speaker-attributed transcript
//  ("Speaker 1: …", "Speaker 2: …") produced by aligning the canonical transcription with
//  diarization.
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

  @ViewBuilder
  private var transcript: some View {
    ScrollView {
      if !store.segments.isEmpty {
        attributedTranscript
      } else {
        Text(displayText.isEmpty ? "Listening…" : displayText)
          .frame(maxWidth: .infinity, alignment: .leading)
          .foregroundStyle(displayText.isEmpty ? .secondary : .primary)
          .textSelection(.enabled)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  /// The speaker-attributed transcript, one block per turn, color-coded by speaker.
  private var attributedTranscript: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(store.segments) { segment in
        VStack(alignment: .leading, spacing: 2) {
          Text(segment.speakerId.isEmpty ? "Transcript" : "Speaker \(segment.speakerId)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(segment.speakerId.isEmpty ? Color.secondary : speakerColor(segment.speakerId))
          Text(segment.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// While recording we show the running live transcript; once finished, the clean final one.
  private var displayText: String {
    if store.phase == .finished, !store.finalTranscript.isEmpty {
      return store.finalTranscript
    }
    return store.liveTranscript
  }

  /// Deterministic, distinct color per diarization speaker id ("1", "2", …).
  private func speakerColor(_ id: String) -> Color {
    let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .red]
    let index = (Int(id) ?? abs(id.hashValue)) % palette.count
    return palette[index]
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
