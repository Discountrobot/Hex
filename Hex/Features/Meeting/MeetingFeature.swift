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
    /// Speaker-attributed transcript turns, produced after stop by aligning ASR + diarization.
    var segments: [AttributedSegment] = []
    var isDiarizing: Bool = false
    var statusMessage: String = ""
    var errorMessage: String?
    var startedAt: Date?
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.meetingNotes) var meetingNotes: MeetingNotes
  }

  enum Action {
    case start
    case transcriptUpdated(String)
    case startFailed(String)
    case stop
    case finished(transcript: String, wavURL: URL)
    case analyzed(segments: [AttributedSegment], speakers: [DiarizedSegment], rawTranscript: String, wavURL: URL)
    case analysisFailed(String)
    case dismiss
  }

  @Dependency(\.recording) var recording
  @Dependency(\.meetingTranscription) var meetingTranscription
  @Dependency(\.diarization) var diarization

  private enum CancelID { case session, finishing, analyze }

  /// Cap on persisted meeting notes; older ones (and their audio) are evicted past this.
  private static let maxMeetingNotes = 100

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
        state.segments = []
        state.errorMessage = nil
        state.statusMessage = "Loading model…"
        state.startedAt = Date()
        state.isDiarizing = false
        // Tear down any still-in-flight finish/analysis from a prior session before starting,
        // so a late result can't bleed into this new meeting.
        return .merge(
          .cancel(id: CancelID.finishing),
          .cancel(id: CancelID.analyze),
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
        state.statusMessage = "Analyzing speakers…"
        return .run { send in
          // The stale-stop / shared-engine race can hand back a WAV that was never written.
          guard FileManager.default.fileExists(atPath: wavURL.path) else {
            await send(.analysisFailed("Recording was interrupted; nothing to analyze."))
            return
          }
          do {
            try await diarization.ensureLoaded { _ in }
            // Canonical batch transcription (with token timings) + diarization on the same WAV,
            // run concurrently, then align tokens to speaker segments.
            async let tokensTask = meetingTranscription.transcribeFile(wavURL)
            let speakers = try await diarization.diarize(wavURL)
            let tokens = try await tokensTask
            let segments = SpeakerAlignment.attribute(tokens: tokens, speakers: speakers)
            let rawTranscript = tokens.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            // The recording is moved to durable storage in the reducer, atomically with persisting
            // the note, so a cancellation mid-analysis can't orphan a moved-but-unsaved file.
            await send(.analyzed(segments: segments, speakers: speakers, rawTranscript: rawTranscript, wavURL: wavURL))
          } catch {
            await send(.analysisFailed(error.localizedDescription))
          }
        }
        .cancellable(id: CancelID.analyze)

      case .finished:
        // Stale completion from an abandoned/superseded session — ignore.
        return .none

      case let .analyzed(segments, speakers, rawTranscript, wavURL) where state.phase == .finished:
        state.isDiarizing = false
        state.segments = segments
        state.diarization = speakers
        if !rawTranscript.isEmpty { state.finalTranscript = rawTranscript }
        let distinctSpeakers = Set(segments.map(\.speakerId)).subtracting([SpeakerAlignment.unknownSpeakerId]).count
        state.statusMessage = {
          if segments.isEmpty, rawTranscript.isEmpty { return "No speech detected." }
          if distinctSpeakers == 0 { return "Transcript ready (speakers not detected)." }
          return "\(distinctSpeakers) speaker\(distinctSpeakers == 1 ? "" : "s"), \(segments.count) turns."
        }()
        // Nothing worth saving for an empty result.
        guard !segments.isEmpty || !rawTranscript.isEmpty else { return .none }
        // Move the recording into durable storage and persist the note together, so the
        // irreversible move and the @Shared insert commit atomically under this phase guard.
        let storedURL = persistMeetingRecording(wavURL)
        let note = MeetingNote(
          startedAt: state.startedAt ?? Date(),
          duration: segments.last?.endSeconds ?? 0,
          audioPath: storedURL,
          rawTranscript: rawTranscript,
          segments: segments
        )
        var evictedAudio: [URL] = []
        state.$meetingNotes.withLock { store in
          store.notes.insert(note, at: 0)
          if store.notes.count > Self.maxMeetingNotes {
            evictedAudio = store.notes[Self.maxMeetingNotes...].map(\.audioPath)
            store.notes.removeLast(store.notes.count - Self.maxMeetingNotes)
          }
        }
        let evicted = evictedAudio
        guard !evicted.isEmpty else { return .none }
        return .run { _ in
          for url in evicted { try? FileManager.default.removeItem(at: url) }
        }

      case .analyzed:
        return .none

      case let .analysisFailed(message) where state.phase == .finished:
        state.isDiarizing = false
        state.statusMessage = "Analysis failed: \(message)"
        return .none

      case .analysisFailed:
        return .none

      case .dismiss:
        state.isVisible = false
        state.phase = .idle
        state.isDiarizing = false
        return .merge(
          .cancel(id: CancelID.session),
          .cancel(id: CancelID.finishing),
          .cancel(id: CancelID.analyze),
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

/// Moves a finished meeting recording out of the temp directory into a durable Meetings folder so
/// the persisted note's audio keeps resolving across launches. Returns the new URL, or the
/// original on any failure.
private func persistMeetingRecording(_ wavURL: URL) -> URL {
  guard let support = try? URL.hexApplicationSupport else { return wavURL }
  let dir = support.appendingPathComponent("Meetings", isDirectory: true)
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let dest = dir.appendingPathComponent(wavURL.lastPathComponent)
  if dest == wavURL { return wavURL }
  try? FileManager.default.removeItem(at: dest)
  do {
    try FileManager.default.moveItem(at: wavURL, to: dest)
    return dest
  } catch {
    return wavURL
  }
}
