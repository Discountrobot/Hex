//
//  MeetingTranscriptionClient.swift
//  Hex
//
//  Live, streaming speech-to-text for Meeting Mode, wrapping FluidAudio's StreamingAsrManager.
//  It is fed 16 kHz mono sample blocks forked from the capture engine (see
//  RecordingClient.observeMicSamples) and publishes a continuously-updated transcript for the live
//  notepad, plus a clean de-duplicated final transcript on finish().
//

import AVFoundation
import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

#if canImport(FluidAudio)
import FluidAudio
#endif

/// One ASR token with absolute start/end seconds, used to align transcript text to diarization
/// speaker segments.
struct TranscriptToken: Sendable, Equatable {
  let text: String
  let start: Double
  let end: Double
}

@DependencyClient
struct MeetingTranscriptionClient {
  /// Loads the streaming ASR models and starts a fresh session. Call once per meeting.
  var start: @Sendable () async throws -> Void
  /// Feed a block of 16 kHz mono samples (fire-and-forget on the engine side).
  var feed: @Sendable (_ samples: [Float]) async -> Void
  /// A stream of the latest running transcript (confirmed + volatile) for the live notepad.
  var transcripts: @Sendable () async -> AsyncStream<String> = { AsyncStream { _ in } }
  /// Ends the session and returns the clean, de-duplicated final transcript.
  var finish: @Sendable () async throws -> String = { "" }
  /// Abandons the session without producing a final transcript.
  var cancel: @Sendable () async -> Void = {}
  /// Canonical batch transcription of a finished recording, with per-token absolute timings.
  var transcribeFile: @Sendable (_ wavURL: URL) async throws -> [TranscriptToken] = { _ in [] }
}

extension MeetingTranscriptionClient: DependencyKey {
  static var liveValue: Self {
    #if canImport(FluidAudio)
    let live = MeetingTranscriber()
    return Self(
      start: { try await live.start() },
      feed: { await live.feed($0) },
      transcripts: { await live.transcripts() },
      finish: { try await live.finish() },
      cancel: { await live.cancel() },
      transcribeFile: { try await live.transcribeFile($0) }
    )
    #else
    return Self(
      start: { throw MeetingTranscriptionError.unavailable },
      feed: { _ in },
      transcripts: { AsyncStream { _ in } },
      finish: { "" },
      cancel: {},
      transcribeFile: { _ in [] }
    )
    #endif
  }
}

extension DependencyValues {
  var meetingTranscription: MeetingTranscriptionClient {
    get { self[MeetingTranscriptionClient.self] }
    set { self[MeetingTranscriptionClient.self] = newValue }
  }
}

enum MeetingTranscriptionError: Error, LocalizedError {
  case unavailable
  var errorDescription: String? {
    switch self {
    case .unavailable:
      return "Live transcription requires FluidAudio, which isn't linked in this build."
    }
  }
}

#if canImport(FluidAudio)

/// Owns a FluidAudio streaming session (live notepad) plus a batch manager (canonical, timestamped
/// transcription) for one meeting. Both share a single set of loaded `AsrModels`.
private actor MeetingTranscriber {
  private var models: AsrModels?
  private var streaming: StreamingAsrManager?
  private var batch: AsrManager?
  private var consumeTask: Task<Void, Never>?
  private var transcriptContinuation: AsyncStream<String>.Continuation?
  private let logger = HexLog.meeting

  /// 16 kHz mono Float32 — exactly what the capture engine forks, and StreamingAsrManager's
  /// fast path (so its internal converter skips any resampling).
  private let inputFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 16_000,
    channels: 1,
    interleaved: false
  )!

  /// Loads the Parakeet v3 models once and caches them for both the streaming and batch managers.
  /// They are read from the same on-disk cache the offline ParakeetClient uses, so this never
  /// re-downloads — only an extra in-memory load. A later phase can share ParakeetClient's copy.
  private func ensureModels() async throws -> AsrModels {
    if let models { return models }
    let t0 = Date()
    let loaded = try await AsrModels.downloadAndLoad(version: .v3)
    models = loaded
    logger.notice("Loaded meeting ASR models in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    return loaded
  }

  func start() async throws {
    stopStreaming()

    let models = try await ensureModels()
    let manager = StreamingAsrManager(config: .streaming)
    try await manager.start(models: models, source: .microphone)
    self.streaming = manager
    logger.notice("Streaming ASR session started")

    // `transcriptionUpdates` overwrites its single continuation on each access, so it must be
    // iterated exactly once. On each update we publish the running confirmed + volatile text.
    consumeTask = Task { [weak self] in
      for await _ in await manager.transcriptionUpdates {
        guard let self else { break }
        let confirmed = await manager.confirmedTranscript
        let volatile = await manager.volatileTranscript
        let text = (confirmed + " " + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
        await self.publish(text)
      }
    }
  }

  func transcripts() -> AsyncStream<String> {
    let (stream, continuation) = AsyncStream<String>.makeStream()
    transcriptContinuation = continuation
    return stream
  }

  private func publish(_ text: String) {
    transcriptContinuation?.yield(text)
  }

  func feed(_ samples: [Float]) async {
    guard let streaming, !samples.isEmpty else { return }
    guard
      let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
      let channel = buffer.floatChannelData?[0]
    else { return }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { ptr in
      if let base = ptr.baseAddress {
        channel.update(from: base, count: ptr.count)
      }
    }
    await streaming.streamAudio(buffer)
  }

  func finish() async throws -> String {
    defer { stopStreaming() }
    guard let streaming else { return "" }
    return try await streaming.finish()
  }

  func cancel() async {
    if let streaming {
      await streaming.cancel()
    }
    stopStreaming()
  }

  /// Batch-transcribe a finished recording into tokens carrying absolute start/end seconds.
  func transcribeFile(_ url: URL) async throws -> [TranscriptToken] {
    // Parakeet's batch ASR requires >= 1s of 16 kHz audio (it throws otherwise). For a degenerate
    // sub-1s "meeting", skip the pass and return no tokens so the flow degrades to "no speech"
    // instead of surfacing an error. (AVAudioFile.length is a cheap header read, not a decode.)
    if let file = try? AVAudioFile(forReading: url), file.length < 16_000 {
      logger.notice("Meeting recording too short for batch transcription (\(file.length) frames); skipping.")
      return []
    }

    let models = try await ensureModels()
    let manager: AsrManager
    if let batch {
      manager = batch
    } else {
      let created = AsrManager(config: .init())
      try await created.initialize(models: models)
      batch = created
      manager = created
    }

    let t0 = Date()
    // source: .microphone matches how the meeting was recorded (transcribe(_:) defaults to .system).
    let result = try await manager.transcribe(url, source: .microphone)
    let tokens = (result.tokenTimings ?? []).map {
      TranscriptToken(text: $0.token, start: $0.startTime, end: $0.endTime)
    }
    logger.notice("Batch-transcribed meeting in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s (\(tokens.count) tokens)")
    return tokens
  }

  /// Tears down the live streaming session but keeps the loaded models + batch manager so the
  /// post-stop canonical transcription can reuse them.
  private func stopStreaming() {
    consumeTask?.cancel()
    consumeTask = nil
    transcriptContinuation?.finish()
    transcriptContinuation = nil
    streaming = nil
  }
}

#endif
