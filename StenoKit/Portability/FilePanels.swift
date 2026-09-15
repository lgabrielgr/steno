import AppKit
import Foundation
import UniformTypeIdentifiers

/// Where an export should go, as the save panel answered it.
public struct ExportDestination: Equatable, Sendable {
    public let url: URL

    /// §10.2's opt-in for offline transfer, from the panel's checkbox.
    public let includesCachedExternalData: Bool

    public init(url: URL, includesCachedExternalData: Bool) {
        self.url = url
        self.includesCachedExternalData = includesCachedExternalData
    }
}

/// §10.5's save and open panels, behind a protocol.
///
/// **A seam, not an abstraction for its own sake.** The test bundle is unhosted
/// and runs with no window server (D-010), and a test that reached a real
/// `NSOpenPanel` would *hang* the suite rather than fail it — a far worse
/// failure than a red assertion, because it stops CI with no message. Every
/// injection point defaults to `UnavailableFilePanels`; only `StenoApp` passes
/// the AppKit one.
@MainActor
public protocol FilePanels {
    /// `nil` when the user cancelled.
    func chooseExportDestination(defaultName: String) -> ExportDestination?

    /// `nil` when the user cancelled.
    func chooseImportSource() -> URL?
}

/// The default everywhere except the app: opens nothing, and says so.
///
/// **Loud rather than silent.** Returning `nil` alone would make a wiring
/// mistake in `StenoApp` look exactly like the user pressing Cancel — a menu
/// item that does nothing, forever, with no way to tell. `didRefuse` lets the
/// caller turn that into a visible error.
@MainActor
public final class UnavailableFilePanels: FilePanels {
    public private(set) var didRefuse = false

    public init() {}

    public func chooseExportDestination(defaultName: String) -> ExportDestination? {
        didRefuse = true
        Log.app.error("file panels are unavailable; export was not offered")
        return nil
    }

    public func chooseImportSource() -> URL? {
        didRefuse = true
        Log.app.error("file panels are unavailable; import was not offered")
        return nil
    }
}

/// §10.5's "standard save/open panels", for real.
///
/// **`runModal()` rather than `beginSheetModal(for:)`.** A sheeted panel needs
/// the `NSWindow` to hang from, which would mean plumbing a window reference
/// from the scene into a view model whose whole point is not to know about
/// views. App-modal is also what the user gets from every other macOS app's
/// File menu.
///
/// Untestable by construction — it opens a modal panel — which is why it holds
/// no logic beyond configuring and reading the panels. Anything decidable lives
/// in `ImportPreviewModel`.
@MainActor
public final class AppKitFilePanels: FilePanels {
    public init() {}

    public func chooseExportDestination(defaultName: String) -> ExportDestination? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.title = "Export Steno Data"
        panel.message = "Choose where to write your Steno export."

        // §10.2's opt-in toggle, off by default: cached external data is bulky
        // and re-fetchable, and it is excluded from an ordinary export for
        // exactly that reason.
        let checkbox = NSButton(
            checkboxWithTitle: "Include cached Jira and Confluence summaries", target: nil,
            action: nil)
        checkbox.state = .off
        checkbox.toolTip =
            "Makes the file larger. Useful when the other Mac will be offline; "
            + "otherwise these are re-fetched."
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 32))
        checkbox.frame = NSRect(x: 16, y: 6, width: 328, height: 20)
        accessory.addSubview(checkbox)
        panel.accessoryView = accessory

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return ExportDestination(
            url: url, includesCachedExternalData: checkbox.state == .on)
    }

    public func chooseImportSource() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Import Steno Data"
        panel.message = "Choose a Steno export to read."
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
