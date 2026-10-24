import SwiftUI

/// Nordic palette shared with Tightbeam Chat and Harklight. The colors live in the asset
/// catalog with light and dark variants; the app's accent is moss (AccentColor).
extension View {
    /// Linen background and off-black text for a list or form, in place of system white and black.
    func nordicListStyle() -> some View {
        scrollContentBackground(.hidden)
            .background(Color.nordicBackground)
            .foregroundStyle(Color.nordicText)
    }
}
