import Foundation

/// A speaker-attributed span of a meeting transcript: who spoke, what they said, and when.
/// Produced by aligning ASR token timings against diarization speaker segments.
public struct AttributedSegment: Codable, Equatable, Identifiable, Sendable {
	public var id: UUID
	/// Diarization speaker id (e.g. "1", "2"). Maps to a display name via `MeetingNote.speakerNames`.
	public var speakerId: String
	public var text: String
	public var startSeconds: Double
	public var endSeconds: Double

	public init(
		id: UUID = UUID(),
		speakerId: String,
		text: String,
		startSeconds: Double,
		endSeconds: Double
	) {
		self.id = id
		self.speakerId = speakerId
		self.text = text
		self.startSeconds = startSeconds
		self.endSeconds = endSeconds
	}
}

/// A finished meeting: its audio, the speaker-attributed transcript, and (later) a summary.
public struct MeetingNote: Codable, Equatable, Identifiable, Sendable {
	public var id: UUID
	public var startedAt: Date
	public var duration: TimeInterval
	public var audioPath: URL
	/// The canonical (batch) transcript, unattributed.
	public var rawTranscript: String
	/// Speaker-attributed transcript turns, in order.
	public var segments: [AttributedSegment]
	/// Optional display names per speaker id (assigned in a later phase; empty for now).
	public var speakerNames: [String: String]
	/// Optional generated summary (a later phase; nil for now).
	public var summaryMarkdown: String?

	public init(
		id: UUID = UUID(),
		startedAt: Date,
		duration: TimeInterval,
		audioPath: URL,
		rawTranscript: String,
		segments: [AttributedSegment],
		speakerNames: [String: String] = [:],
		summaryMarkdown: String? = nil
	) {
		self.id = id
		self.startedAt = startedAt
		self.duration = duration
		self.audioPath = audioPath
		self.rawTranscript = rawTranscript
		self.segments = segments
		self.speakerNames = speakerNames
		self.summaryMarkdown = summaryMarkdown
	}

	/// Number of distinct speakers across the attributed segments.
	public var speakerCount: Int {
		Set(segments.map(\.speakerId)).count
	}

	/// The display name for a speaker id, falling back to "Speaker N" (or "Unknown speaker" for the
	/// empty/unattributed sentinel used when diarization produced no segments).
	public func displayName(for speakerId: String) -> String {
		if let name = speakerNames[speakerId] { return name }
		return speakerId.isEmpty ? "Unknown speaker" : "Speaker \(speakerId)"
	}
}

/// Persisted collection of meeting notes (newest first).
public struct MeetingNotes: Codable, Equatable, Sendable {
	public var notes: [MeetingNote] = []

	public init(notes: [MeetingNote] = []) {
		self.notes = notes
	}
}
