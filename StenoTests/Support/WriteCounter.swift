import Foundation

@testable import StenoKit

/// Counts `.stenoDidWrite` posts synchronously.
///
/// Posts are made on the main actor with no delivery queue, so by the time the
/// service call returns the count is final — which is what makes these
/// assertions deterministic rather than timed.
///
/// Shared by `CaptureNotificationTests` and `StatusServiceTests` rather than
/// duplicated: both services post the same notification, and two copies of the
/// counter would be two chances for one of them to stop counting correctly.
@MainActor
final class WriteCounter {
    /// Named `posts`, not `count`: SwiftLint's `empty_count` rejects
    /// `something.count == 0`, and `--strict` makes that a build failure.
    private(set) var posts = 0
    private var observation: WriteObservation?

    init() {
        observation = WriteObservation(
            NotificationCenter.default.addObserver(
                forName: .stenoDidWrite, object: nil, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.posts += 1 }
            })
    }
}
