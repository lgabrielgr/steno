import Foundation

@testable import StenoKit

/// `FilePanels` that answer from a script instead of opening anything.
///
/// The whole reason `FilePanels` is a protocol: the test bundle is unhosted and
/// has no window server (D-010), so a real `NSOpenPanel` here would **hang** the
/// suite rather than fail it.
@MainActor
final class StubFilePanels: FilePanels {
    var exportDestination: ExportDestination?
    var importSource: URL?
    var exportFolder: URL?

    private(set) var exportPrompts = 0
    private(set) var importPrompts = 0
    private(set) var folderPrompts = 0
    private(set) var lastDefaultName: String?
    private(set) var lastFolderStart: URL?

    init(
        exportDestination: ExportDestination? = nil, importSource: URL? = nil,
        exportFolder: URL? = nil
    ) {
        self.exportDestination = exportDestination
        self.importSource = importSource
        self.exportFolder = exportFolder
    }

    func chooseExportDestination(defaultName: String) -> ExportDestination? {
        exportPrompts += 1
        lastDefaultName = defaultName
        return exportDestination
    }

    func chooseImportSource() -> URL? {
        importPrompts += 1
        return importSource
    }

    func chooseExportFolder(startingAt current: URL) -> URL? {
        folderPrompts += 1
        lastFolderStart = current
        return exportFolder
    }
}
