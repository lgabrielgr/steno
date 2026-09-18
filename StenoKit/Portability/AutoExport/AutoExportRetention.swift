import Foundation

/// §10.5's "sensible retention so the folder does not grow without bound".
///
/// Pure over file names, so the whole policy is testable without a filesystem.
public enum AutoExportRetention {
    /// Fourteen files. `ExportFilename` is one name per local day and the
    /// write overwrites, so this is about two weeks of history — long enough to
    /// notice a mistake and go back past it, short enough that a synced folder
    /// stays small.
    public static let keep = 14

    /// Which of `urls` are surplus, newest kept.
    ///
    /// **Ordered by the date in the file name, never by modification time.** A
    /// cloud drive rewrites mtime whenever it re-downloads a file, so an
    /// mtime-ordered sweep in a Dropbox or iCloud folder — the folder §10.5
    /// actually recommends — would delete whichever files the sync engine
    /// happened to touch least recently. The name is the durable key, and it is
    /// also the only value the format carries, which is the same reason
    /// M2.5-01's ordering sorts on serialized values.
    ///
    /// **Only exact matches are candidates.** Anything else in the folder — a
    /// manual export saved under another name, an unrelated file, a directory —
    /// is never returned, so nothing this function says can delete a file Steno
    /// did not write.
    public static func prunable(from urls: [URL], keeping: Int = keep) -> [URL] {
        let dated = urls.compactMap { url -> (day: String, url: URL)? in
            guard let day = day(inFilename: url.lastPathComponent) else { return nil }
            return (day, url)
        }
        // Lexicographic *is* chronological for zero-padded ISO-8601, so no date
        // parsing is involved and no calendar can get it wrong.
        .sorted { $0.day > $1.day }
        return dated.dropFirst(max(0, keeping)).map(\.url)
    }

    /// The `YYYY-MM-DD` in `steno-export-YYYY-MM-DD.json`, or `nil`.
    ///
    /// Hand-parsed rather than matched with `Regex`: the shape is fixed by
    /// `ExportFilename.forDate`, and `Regex` is not `Sendable`, so a stored or
    /// static one would have to be rebuilt per call anyway (D-025's cost).
    static func day(inFilename filename: String) -> String? {
        let prefix = "steno-export-"
        let suffix = ".json"
        guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else { return nil }
        let day = String(filename.dropFirst(prefix.count).dropLast(suffix.count))
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
            parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            // `isNumber` alone accepts Eastern Arabic digits, which would make
            // two different names sort as if they were the same day.
            parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } })
        else { return nil }
        return day
    }
}
