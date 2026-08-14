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
enum Log {
    static let subsystem = "com.lgabrielgr.steno"

    static let app = Logger(subsystem: subsystem, category: "app")
}
