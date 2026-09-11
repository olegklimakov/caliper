import SwiftUI

/// The login-item switch and what it does when the system refuses.
///
/// Its own view because the state is not a preference: `SMAppService` holds the
/// registration, so the switch reads back from the system and has to be put
/// straight again when a registration fails.
struct LaunchAtLoginToggle: View {
    let preferences: Preferences
    @State private var isOn: Bool
    @State private var error: String?

    init(preferences: Preferences) {
        self.preferences = preferences
        _isOn = State(initialValue: preferences.launchesAtLogin)
    }

    var body: some View {
        Toggle("Launch at login", isOn: $isOn)
            .onChange(of: isOn) { _, enabled in
                do {
                    try preferences.setLaunchesAtLogin(enabled)
                    error = nil
                } catch {
                    // The system's to refuse, so put the switch back rather
                    // than pretending.
                    self.error = error.localizedDescription
                    isOn = preferences.launchesAtLogin
                }
            }
        if let error {
            Text(error)
                .font(.footnote)
                .foregroundStyle(Color(Palette.critical))
        }
    }
}
