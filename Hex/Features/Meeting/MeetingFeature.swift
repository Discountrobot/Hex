//
//  MeetingFeature.swift
//  Hex
//
//  Phase 0 of Meeting Mode: long-form recording with a live transcript notepad (FluidAudio
//  streaming ASR fed by mic samples forked from the capture engine) plus a post-stop speaker
//  diarization dump. Gated behind the `meetingModeEnabled` dev flag. No persistence, speaker
//  memory, or summarization yet — those are later phases (see docs/meeting-dictation-plan.md).
//

import ComposableArchitecture
import Foundation
import HexCore

@Reducer
struct MeetingFeature {
  enum Phase: Equatable {
    case idle
    case recording
    case processing   // stopping: finishing the transcript + diarizing
    case finished
    case failed
  }

  @ObservableState
  struct State {
    var isVisible: Bool = false
    var phase: Phase = .idle
    var liveTranscript: String = ""
    var finalTranscript: String = ""
    var diarization: [DiarizedSegment] = []
    var isDiarizing: Bool = false
    var statusMessage: String = ""
    var errorMessage: String?
    var startedAt: Date?
    @Shared(.hexSettings) var hexSettings: HexSettings
  }

  enum Action {
    case start
    case transcriptUpdated(String)
    case startFailed(String)
    case stop
    case finished(transcript: String, wavURL: URL)
    case diarized([DiarizedSegment])
    case diarizationFailed(String)
    case dismiss
  }

  @Dependency(\.recording) var recording
  @Dependency(\.meetingTranscription) var meetingTranscription
  @Dependency(\.diarization) var diarization

  private enum CancelID { case session, finishing, diarize }

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .start:
        // Allow (re)starting only from a settled state.
        guard state.phase != .recording, state.phase != .processing else { return .none }
        state.isVisible = true
        state.phase = .recording
        state.liveTranscript = ""
        state.finalTranscript = ""
        state.diarization = []
        state.errorMessage = nil
        state.statusMessage = "Loading model…"
        state.startedAt = Date()
        state.isDiarizing = false
        // Tear down any still-in-flight finish/diarize from a prior session before starting,
        // so a late result can't bleed into this new meeting.
        return .merge(
          .cancel(id: CancelID.finishing),
          .cancel(id: CancelID.diarize),
          .run { send in
            do {
              try await meetingTranscription.start()
            } catch {
              await send(.startFailed(error.localizedDescription))
              return
            }
            await recording.startRecording()
            // Two concurrent pumps: forked mic samples -> ASR, and ASR updates -> the notepad.
            await withTaskGroup(of: Void.self) { group in
              group.addTask {
                for await samples in await recording.observeMicSamples() {
                  await meetingTranscription.feed(samples)
                }
              }
              group.addTask {
                for await text in await meetingTranscription.transcripts() {
                  await send(.transcriptUpdated(text))
                }
              }
            }
          }
          .cancellable(id: CancelID.session)
        )

      case let .transcriptUpdated(text):
        state.liveTranscript = text
        if state.phase == .recording { state.statusMessage = "Recording…" }
        return .none

      case let .startFailed(message):
        state.phase = .failed
        state.errorMessage = message
        state.statusMessage = "Couldn’t start meeting"
        return .merge(
          .cancel(id: CancelID.session),
          .run { _ in _ = await recording.stopRecording() }
        )

      case .stop:
        guard state.phase == .recording else { return .none }
        state.phase = .processing
        state.statusMessage = "Finishing transcript…"
        return .merge(
          .cancel(id: CancelID.session),
          .run { send in
            let wavURL = await recording.stopRecording()
            let finalText = (try? await meetingTranscription.finish()) ?? ""
            await send(.finished(transcript: finalText, wavURL: wavURL))
          }
          .cancellable(id: CancelID.finishing)
        )

      case let .finished(transcript, wavURL) where state.phase == .processing:
        state.phase = .finished
        if !transcript.isEmpty { state.finalTranscript = transcript }
        state.isDiarizing = true
        state.statusMessage = "Diarizing…"
        return .run { send in
          // The stale-stop / shared-engine race can hand back a WAV that was never written.
          guard FileManager.default.fileExists(atPath: wavURL.path) else {
            await send(.diarizationFailed("Recording was interrupted; nothing to diarize."))
            return
          }
          do {
            try await diarization.ensureLoaded { _ in }
            let segments = try await diarization.diarize(wavURL)
            await send(.diarized(segments))
          } catch {
            await send(.diarizationFailed(error.localizedDescription))
          }
        }
        .cancellable(id: CancelID.diarize)

      case .finished:
        // Stale completion from an abandoned/superseded session — ignore.
        return .none

      case let .diarized(segments) where state.phase == .finished:
        state.isDiarizing = false
        state.diarization = segments
        let speakers = Set(segments.map(\.speakerId)).count
        state.statusMessage = segments.isEmpty
          ? "No speech segments detected."
          : "\(speakers) speaker\(speakers == 1 ? "" : "s"), \(segments.count) segments."
        return .none

      case .diarized:
        return .none

      case let .diarizationFailed(message) where state.phase == .finished:
        state.isDiarizing = false
        state.statusMessage = "Diarization failed: \(message)"
        return .none

      case .diarizationFailed:
        return .none

      case .dismiss:
        state.isVisible = false
        state.phase = .idle
        state.isDiarizing = false
        return .merge(
          .cancel(id: CancelID.session),
          .cancel(id: CancelID.finishing),
          .cancel(id: CancelID.diarize),
          .run { _ in
            // Stop the mic too: .dismiss is now reachable mid-recording (⌘W / dev-flag off).
            _ = await recording.stopRecording()
            await meetingTranscription.cancel()
          }
        )
      }
    }
  }
}
