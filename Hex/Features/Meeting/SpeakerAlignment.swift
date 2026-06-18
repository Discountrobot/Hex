//
//  SpeakerAlignment.swift
//  Hex
//
//  Aligns ASR token timings (from the canonical batch transcription) with diarization speaker
//  segments to produce a speaker-attributed transcript ("Speaker 1: …", "Speaker 2: …"). Both
//  inputs share the same time base (absolute seconds from the start of the same 16 kHz WAV).
//

import Foundation
import HexCore

enum SpeakerAlignment {
  /// Speaker id used when there is no diarization to attribute against (renders as unattributed).
  static let unknownSpeakerId = ""

  /// A silence of at least this many seconds within one speaker's turn starts a new line, so long
  /// turns read as natural paragraphs instead of one unbroken block. (Token timings are quantized
  /// to 80 ms, so this is roughly a typical sentence-boundary pause.)
  static let pauseLineBreakSeconds: Double = 0.6

  /// Assign each ASR token to the diarization speaker whose interval best matches the token's
  /// midpoint, then merge consecutive same-speaker tokens into contiguous attributed turns.
  static func attribute(tokens: [TranscriptToken], speakers: [DiarizedSegment]) -> [AttributedSegment] {
    guard !tokens.isEmpty else { return [] }

    // No diarization at all (e.g. very short/quiet audio that produced no speaker segments):
    // emit one unattributed turn so the transcript text still shows, rather than a bogus speaker.
    guard !speakers.isEmpty else {
      let text = tokens.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return [] }
      return [
        AttributedSegment(
          speakerId: unknownSpeakerId,
          text: text,
          startSeconds: tokens.first?.start ?? 0,
          endSeconds: tokens.last?.end ?? 0
        )
      ]
    }

    // Distance from a time to a segment's interval: 0 inside, else the distance to the nearest edge.
    func distance(_ segment: DiarizedSegment, to time: Double) -> Double {
      if time < segment.startSeconds { return segment.startSeconds - time }
      if time > segment.endSeconds { return time - segment.endSeconds }
      return 0
    }

    func speaker(at time: Double) -> String {
      // Prefer the segment that actually covers this instant.
      if let covering = speakers.first(where: { $0.startSeconds <= time && time < $0.endSeconds }) {
        return covering.speakerId
      }
      // In a gap between diarized spans, attribute to the physically closest segment by edge
      // distance (closest boundary), which is correct at turn boundaries.
      return speakers.min(by: { distance($0, to: time) < distance($1, to: time) })?.speakerId ?? unknownSpeakerId
    }

    var turns: [AttributedSegment] = []
    for token in tokens {
      let midpoint = (token.start + token.end) / 2
      let id = speaker(at: midpoint)
      if let lastIndex = turns.indices.last, turns[lastIndex].speakerId == id {
        let gap = token.start - turns[lastIndex].endSeconds
        if gap >= pauseLineBreakSeconds {
          // A noticeable pause becomes a line break; drop the token's own leading space first.
          turns[lastIndex].text += "\n" + String(token.text.drop(while: { $0.isWhitespace }))
        } else {
          // SentencePiece tokens carry their own leading spaces, so plain concatenation rebuilds words.
          turns[lastIndex].text += token.text
        }
        turns[lastIndex].endSeconds = token.end
      } else {
        turns.append(
          AttributedSegment(speakerId: id, text: token.text, startSeconds: token.start, endSeconds: token.end)
        )
      }
    }

    // Trim the leading/trailing whitespace each turn inherits from token boundaries.
    return turns
      .map { turn -> AttributedSegment in
        var trimmed = turn
        trimmed.text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed
      }
      .filter { !$0.text.isEmpty }
  }
}
