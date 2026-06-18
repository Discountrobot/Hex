//
//  DiarizationClient.swift
//  Hex
//
//  On-device speaker diarization via FluidAudio. Phase 0: download the diarizer models on first
//  use and produce "who spoke when" segments for a finished meeting recording (dumped to the log
//  and surfaced in the meeting notepad). Cross-meeting speaker memory and transcript-to-speaker
//  alignment come in later phases.
//

import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

#if canImport(FluidAudio)
import FluidAudio
#endif

/// A single diarized speech segment: which speaker, and the [start, end] window in seconds.
struct DiarizedSegment: Sendable, Equatable {
  let speakerId: String
  let startSeconds: Double
  let endSeconds: Double
  let quality: Float
}

@DependencyClient
struct DiarizationClient {
  /// Ensures the diarizer models are downloaded + loaded. `progress` is 0...1 (best-effort).
  var ensureLoaded: @Sendable (_ progress: @escaping @Sendable (Double) -> Void) async throws -> Void
  /// Diarize a 16 kHz mono WAV file on disk into speaker-attributed segments.
  var diarize: @Sendable (_ wavURL: URL) async throws -> [DiarizedSegment] = { _ in [] }
}

extension DiarizationClient: DependencyKey {
  static var liveValue: Self {
    #if canImport(FluidAudio)
    let live = DiarizationEngine()
    return Self(
      ensureLoaded: { try await live.ensureLoaded(progress: $0) },
      diarize: { try await live.diarize(wavURL: $0) }
    )
    #else
    return Self(
      ensureLoaded: { _ in throw DiarizationError.unavailable },
      diarize: { _ in [] }
    )
    #endif
  }
}

extension DependencyValues {
  var diarization: DiarizationClient {
    get { self[DiarizationClient.self] }
    set { self[DiarizationClient.self] = newValue }
  }
}

enum DiarizationError: Error, LocalizedError {
  case unavailable
  case notLoaded
  var errorDescription: String? {
    switch self {
    case .unavailable: return "Diarization requires FluidAudio, which isn't linked in this build."
    case .notLoaded: return "Diarization models are not loaded."
    }
  }
}

#if canImport(FluidAudio)

private actor DiarizationEngine {
  private var manager: DiarizerManager?
  private let logger = HexLog.meeting

  /// Speaker-clustering threshold (FluidAudio range 0.5–0.9). Lower = more speakers / less merging.
  /// Below the 0.7 default because mic-captured room audio (e.g. video played over speakers) tends
  /// to merge distinct voices; tune here if speakers are over- or under-split.
  private static let clusteringThreshold: Float = 0.6

  func ensureLoaded(progress: @escaping @Sendable (Double) -> Void) async throws {
    if manager != nil {
      progress(1)
      return
    }

    progress(0.02)
    // The diarizer models (pyannote_segmentation + wespeaker_v2) are NOT bundled — the first run
    // downloads them from HuggingFace into
    // <App Support>/FluidAudio/Models/speaker-diarization-coreml (FluidAudio ignores
    // XDG_CACHE_HOME for these). Poll the folder size for best-effort progress.
    let modelsDir = DiarizerModels.defaultModelsDirectory()
    let pollTask = Task {
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 250_000_000)
        if let size = directorySize(modelsDir) {
          let target: Double = 90 * 1024 * 1024  // ~90 MB (approximate; calibrate after first run)
          progress(max(0.05, min(0.95, Double(size) / target)))
        }
      }
    }
    defer { pollTask.cancel() }

    let t0 = Date()
    let models = try await DiarizerModels.downloadIfNeeded()
    let manager = DiarizerManager(config: DiarizerConfig(clusteringThreshold: Self.clusteringThreshold))
    manager.initialize(models: models)   // synchronous, non-throwing — do NOT `try await`
    self.manager = manager
    progress(1)
    logger.notice("Diarizer ready in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
  }

  func diarize(wavURL: URL) async throws -> [DiarizedSegment] {
    guard let manager else { throw DiarizationError.notLoaded }

    // WAV (already 16 kHz mono Float32) -> [Float]. AudioConverter hits its fast path here.
    let samples = try AudioConverter().resampleAudioFile(wavURL)
    guard !samples.isEmpty else { return [] }

    let t0 = Date()
    // Synchronous, CPU/ANE-heavy. Runs on this actor (off the main thread).
    let result = try manager.performCompleteDiarization(samples, sampleRate: 16_000)
    let segments = result.segments.map {
      DiarizedSegment(
        speakerId: $0.speakerId,
        startSeconds: Double($0.startTimeSeconds),
        endSeconds: Double($0.endTimeSeconds),
        quality: $0.qualityScore
      )
    }
    logger.notice("Diarized \(segments.count) segments in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    for seg in segments {
      logger.notice(
        "speaker=\(seg.speakerId, privacy: .public) [\(String(format: "%.2f", seg.startSeconds))s–\(String(format: "%.2f", seg.endSeconds))s] q=\(String(format: "%.2f", seg.quality))"
      )
    }
    return segments
  }

  private func directorySize(_ dir: URL) -> UInt64? {
    let fm = FileManager.default
    guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles) else {
      return nil
    }
    var total: UInt64 = 0
    for case let url as URL in en {
      total &+= UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    return total
  }
}

#endif
