#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// SwiftUI support, which is one modifier because one is all that is needed.
public extension View {

    /// Names this view as a screen.
    ///
    /// ```swift
    /// NavigationStack {
    ///     HomeView().lightSessionScreen("Home")
    /// }
    /// ```
    ///
    /// Reported on `onAppear`, not during `body`. A `body` runs whenever SwiftUI decides to re-evaluate
    /// it — off screen, speculatively, several times for one appearance — and reporting from there would
    /// name screens the user never reached. `onAppear` fires when the view is actually on screen, which
    /// is the question being asked.
    ///
    /// It fires before layout is finished, and that is handled rather than assumed: the capture waits
    /// for the hierarchy to stop changing before it reads anything.
    func lightSessionScreen(_ name: String) -> some View {
        onAppear { LightSession.setScreen(name) }
    }

    /// Declares this view as a part of the current screen that is a place of its own — a sheet, a tab, a
    /// step. Cleared when it goes away.
    ///
    /// Paired on purpose. A sheet that names itself on appear and never clears leaves the screen wearing
    /// its name after it closes, and every later capture is filed under a modal that is not on screen.
    func lightSessionSubScreen(_ name: String) -> some View {
        onAppear { LightSession.setSubScreen(name) }
            .onDisappear { LightSession.clearSubScreen(name) }
    }
}
#endif
