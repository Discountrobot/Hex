import ComposableArchitecture
import Foundation
import HexCore

// Persisted store of finished meeting notes, mirroring the transcription-history pattern.
extension SharedReaderKey where Self == FileStorageKey<MeetingNotes>.Default {
	static var meetingNotes: Self {
		Self[
			.fileStorage(.meetingNotesURL),
			default: .init()
		]
	}
}

extension URL {
	static var meetingNotesURL: URL {
		URL.hexMigratedFileURL(named: "meeting_notes.json")
	}
}
