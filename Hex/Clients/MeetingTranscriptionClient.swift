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
      cancel: { await live.cancel() }
    )
    #else
    return Self(
      start: { throw MeetingTranscriptionError.unavailable },
      feed: { _ in },
      transcripts: { AsyncStream { _ in } },
      finish: { "" },
      cancel: {}
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

/// Owns a single FluidAudio `StreamingAsrManager` session for the lifetime of one meeting.
private actor MeetingTranscriber {
  private var manager: StreamingAsrManager?
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

  func start() async throws {
    cleanup()

    let t0 = Date()
    // Phase 0: load our own copy of the Parakeet v3 models. They are read from the same on-disk
    // cache the offline ParakeetClient uses, so this never re-downloads — only an extra in-memory
    // load. A later phase can share the already-loaded models to save the few seconds + memory.
    let models = try await AsrModels.downloadAndLoad(version: .v3)
    let manager = StreamingAsrManager(config: .streaming)
    try await manager.start(models: models, source: .microphone)
    self.manager = manager
    logger.notice("Streaming ASR session started in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")

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
    guard let manager, !samples.isEmpty else { return }
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
    await manager.streamAudio(buffer)
  }

  func finish() async throws -> String {
    guard let manager else { return "" }
    defer { cleanup() }
    return try await manager.finish()
  }

  func cancel() async {
    if let manager {
      await manager.cancel()
    }
    cleanup()
  }

  private func cleanup() {
    consumeTask?.cancel()
    consumeTask = nil
    transcriptContinuation?.finish()
    transcriptContinuation = nil
    manager = nil
  }
}

#endif
