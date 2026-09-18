import Foundation

/// §10.5's first-run sheet, and the banner that reports an unattended failure.
///
/// The state itself lives in `AutoExportWindowModel`; this is the sheet
/// plumbing, which belongs to whoever owns `activeSheet` — the same split
/// `MainWindowModel+Portability` makes for `ImportPreviewModel`.
extension MainWindowModel {
    /// Show the first-run sheet if it is still owed (D-126).
    ///
    /// **Called from the window's `.task`, not from `init`.** A sheet set
    /// during initialization would be assigned before SwiftUI has a window to
    /// present it over, and the guard on `activeSheet` keeps it from displacing
    /// a modal that is already up — which, on a first launch, nothing should
    /// be, but this is the cheapest way to say so.
    ///
    /// A store that failed to open never reaches here: `StenoApp` renders
    /// `StoreFailureView` instead, and no `MainWindowModel` exists. The flag is
    /// therefore not written by a broken launch, so the sheet appears on the
    /// next healthy one.
    public func presentAutoExportOnboardingIfNeeded() {
        guard autoExport.needsOnboarding, activeSheet == nil else { return }
        activeSheet = .autoExportOnboarding
    }

    /// The sheet's "Done": take the first backup, then close.
    ///
    /// Closing regardless of the outcome is deliberate. A failure has already
    /// been recorded and posted, so it arrives in the banner behind the sheet —
    /// the same channel every later failure uses — rather than trapping the
    /// user in a modal they cannot satisfy without leaving it.
    public func finishAutoExportOnboarding() {
        autoExport.finishOnboarding()
        activeSheet = nil
    }
}
