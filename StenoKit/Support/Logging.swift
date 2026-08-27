import OSLog

/// Logging entry point.
///
/// The subsystem is fixed by REQUIREMENTS.md §9.1 and lives here so it is
/// written once.
///
/// `Logger` writes to the unified log, never to stdio — so this output does not
/// appear in the terminal even under `make run`, whose visible launch line is a
/// separate `print`. To watch it, in another terminal:
///
///     log stream --predicate 'subsystem == "com.lgabrielgr.steno"'
public enum Log {
    public static let subsystem = "com.lgabrielgr.steno"

    public static let app = Logger(subsystem: subsystem, category: "app")

    /// Intervals around the capture path.
    ///
    /// §1.1 makes capture latency a P0 functional requirement and §13 requires
    /// it measured rather than assumed. `CapturePerformanceTests` is the
    /// automated gate; this is how the same path is measured *in the running
    /// app*, where GUI automation is unavailable:
    ///
    ///     /usr/bin/log show --last 5m --signpost --predicate \
    ///       'subsystem == "com.lgabrielgr.steno"'
    ///
    /// Spell out `/usr/bin/log` — zsh has a `log` builtin that shadows it and
    /// fails with "too many arguments". `--signpost` rather than `--info`,
    /// because intervals are signpost records, not log messages.
    ///
    /// M1-03 and M1-04 must each show they did not regress it.
    public static let captureSignposter = OSSignposter(
        subsystem: subsystem, category: "capture")
}
