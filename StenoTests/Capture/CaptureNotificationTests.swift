import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let epoch = Date(timeIntervalSince1970: 1_000_000)

@MainActor
private func makeService() throws -> (CaptureService, ModelContext) {
    let context = ModelContext(try StenoStore.inMemory())
    context.insert(
        Project(
            name: "Payments", colorHex: "#3B82F6", jiraProjectKeys: ["PAY"],
            sortOrder: 0, modifiedAt: epoch))
    try context.save()
    return (CaptureService(context: context, now: { epoch }), context)
}

/// Counts posts synchronously. The post is made on the main actor with no
/// delivery queue, so by the time `capture` returns the count is final —
/// which is what makes these assertions deterministic rather than timed.
@MainActor
private final class PostCounter {
    /// Named `posts`, not `count`: SwiftLint's `empty_count` rejects
    /// `something.count == 0`, and `--strict` makes that a build failure.
    private(set) var posts = 0
    private var observation: CaptureObservation?

    init() {
        observation = CaptureObservation(
            NotificationCenter.default.addObserver(
                forName: .stenoDidCapture, object: nil, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.posts += 1 }
            })
    }
}

@Test("a successful capture posts exactly once")
@MainActor
func successfulCapturePostsOnce() throws {
    let (service, _) = try makeService()
    let counter = PostCounter()

    try service.capture(text: "PAY-421 fix the retry handler", preferred: nil)

    #expect(counter.posts == 1)
}

@Test("text that is empty after trimming posts nothing")
@MainActor
func emptyCaptureDoesNotPost() throws {
    let (service, _) = try makeService()
    let counter = PostCounter()

    try service.capture(text: "   \n ", preferred: nil)

    #expect(counter.posts == 0)
}

@Test("a failed save posts nothing")
@MainActor
func failedSaveDoesNotPost() throws {
    let context = ModelContext(try StenoStore.inMemory())
    context.insert(
        Project(
            name: "Payments", colorHex: "#3B82F6", jiraProjectKeys: [],
            sortOrder: 0, modifiedAt: epoch))
    try context.save()

    struct SaveFailure: Error {}
    let service = CaptureService(
        context: context, now: { epoch }, save: { _ in throw SaveFailure() })
    let counter = PostCounter()

    #expect(throws: SaveFailure.self) {
        try service.capture(text: "something", preferred: nil)
    }
    #expect(counter.posts == 0)
}

@Test("the main window reloads when another surface captures")
@MainActor
func mainWindowReloadsOnCapture() throws {
    let container = try StenoStore.inMemory()
    let context = ModelContext(container)
    context.insert(
        Project(
            name: "Payments", colorHex: "#3B82F6", jiraProjectKeys: [],
            sortOrder: 0, modifiedAt: epoch))
    try context.save()

    let model = MainWindowModel(context: context, now: { epoch })
    #expect(model.groups.allSatisfy { $0.tasks.isEmpty })

    // A different surface, over the same store, exactly as the panel will be.
    try CaptureService(context: context, now: { epoch })
        .capture(text: "captured from elsewhere", preferred: nil)

    #expect(
        model.groups.contains { group in
            group.tasks.contains { $0.title == "captured from elsewhere" }
        })
}
