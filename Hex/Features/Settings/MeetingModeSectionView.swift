import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

/// Settings section for the experimental Meeting Mode (diarized long-form dictation with a
/// live transcript notepad). Gated behind a dev/opt-in flag while the feature is built out.
struct MeetingModeSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		Section {
			Label {
				Toggle(
					"Meeting Mode (Experimental)",
					isOn: Binding(
						get: { store.hexSettings.meetingModeEnabled },
						set: { store.send(.setMeetingModeEnabled($0)) }
					)
				)
				Text("Adds a “Start Meeting” menu-bar item: long-form recording with a live transcript notepad and on-device speaker diarization. Work in progress.")
			} icon: {
				Image(systemName: "person.3.fill")
			}
		} header: {
			Text("Meeting Mode")
		}
		.enableInjection()
	}
}
