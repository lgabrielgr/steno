/// Holds the project list a `CaptureFieldModel` reads through.
///
/// A separate object because `CaptureFieldModel` takes its projects as a
/// closure, and that closure has to be built during its owner's `init` —
/// before `self` can be captured. A box constructed as a local first, then
/// stored, sidesteps that without an implicitly unwrapped property.
///
/// Top-level and shared rather than nested in one model: `QuickCaptureModel`
/// and `MenuBarModel` both need it, for the same reason, and two copies would
/// be two chances for one of them to drift.
@MainActor
final class ProjectBox {
    var projects: [Project] = []
}
