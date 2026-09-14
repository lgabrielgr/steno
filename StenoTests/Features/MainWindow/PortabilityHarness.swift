import Foundation
import SwiftData

@testable import StenoKit

/// Shared by `MainWindowPortabilityTests` and `MainWindowReplaceTests`.
///
/// Extracted when the single test file crossed SwiftLint's 400-line limit.
/// Internal rather than `private`, because two files now use it — which is
/// the only reason the access level changed.
struct BackupRefused: Error {}

func portabilityScratchDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-portability-tests-\(UUID().uuidString)", isDirectory: true)
}

/// A window under test: the model, and the pieces a test needs to look behind
/// it.
///
/// A named type rather than a three-member tuple, which SwiftLint's
/// `large_tuple` rejects under `--strict`. `container` is held rather than
/// discarded because `mainContext` does not retain its container — a test whose
/// container is a local would dangle.
@MainActor
struct Window {
    let model: MainWindowModel
    let container: ModelContainer
    let context: ModelContext
}

/// Every record in the store, at wire precision — the shape §10.4's
/// "nothing was changed" is actually a statement about.
@MainActor
func wholeStore(_ context: ModelContext) throws -> MergedStore {
    try MergedStore(
        try ExportEncoder(
            context: context, includesCachedExternalData: true,
            exportedBy: "steno/test (macOS)"
        ).snapshot()
    ).wireNormalized()
}

/// A store with one project and one task, plus the model over it.
@MainActor
func window(
    panels: StubFilePanels,
    backupDirectory: URL? = nil,
    backupWrite: ((Data, URL) throws -> Void)? = nil
) throws -> Window {
    let container = try StenoStore.inMemory()
    let context = ModelContext(container)
    let project = Project(
        id: UUID(), name: "Payments", colorHex: "#112233",
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
    context.insert(project)
    let task = TaskItem(
        id: UUID(), title: "Fix the retry handler", projectID: project.id,
        createdAt: Date(timeIntervalSince1970: 1_700_000_010))
    context.insert(task)
    try context.save()

    let model = MainWindowModel(
        context: context,
        panels: panels,
        makeBackupWriter: { context in
            try BackupWriter(
                context: context,
                directory: backupDirectory ?? portabilityScratchDirectory(),
                now: { Date(timeIntervalSince1970: 1_700_000_000) },
                write: backupWrite ?? { try $0.write(to: $1, options: .atomic) })
        })
    return Window(model: model, container: container, context: context)
}
