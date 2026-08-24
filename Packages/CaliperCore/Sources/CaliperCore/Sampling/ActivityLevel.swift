/// How much of the app the user can currently see.
///
/// Sampling cost is paid for visibility: nothing on screen means nothing needs
/// to be sampled at one hertz. The app layer owns this value — it is the only
/// side that knows about occlusion, open popovers and window state.
public enum ActivityLevel: Sendable, Comparable, CaseIterable {
    /// Menu bar not visible: display asleep, or a full-screen app covering it.
    case hidden
    /// Menu bar indicators visible, nothing else open.
    case menuBarOnly
    /// A metric popover is open.
    case panelOpen
    /// The dashboard window is open.
    case dashboardOpen
}
