import SwiftUI

extension View {
    /// Settings tabs are grouped Forms, which scroll and so report no height of
    /// their own. Turning scrolling off and fixing the vertical size makes each
    /// tab as tall as its content, and the Settings window resizes to fit it
    /// whenever the tab changes.
    func settingsPane() -> some View {
        frame(width: 520)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
    }
}
