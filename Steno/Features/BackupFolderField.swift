import SwiftUI

/// The auto-export folder, rendered the same way in both places that offer to
/// change it: the first-run sheet and Settings › Data.
///
/// **One view rather than two copies.** These two surfaces were built in
/// separate tasks and had already drifted apart once — the same folder row,
/// written twice, with a cancel-handling bug that had to be fixed in both
/// halves at once (D-123's review). The layout lives here so there is one
/// thing to change.
///
/// The path reads as a *field*: bordered, one line, middle-truncated. A long
/// iCloud Drive path is common (`~/Library/Mobile Documents/com~apple~…`) and
/// wrapping it across two lines pushed the button out of alignment, which is
/// what made the row look broken.
struct BackupFolderField: View {
    let folder: URL
    let onChoose: () -> Void

    /// `~/Steno Backups`, not `/Users/someone/Steno Backups`.
    ///
    /// The home prefix is noise in a control whose only question is *which
    /// folder* — but the absolute path is still what the tooltip shows and what
    /// a selection copies, because that is the form a person pastes into a
    /// terminal.
    private var displayPath: String {
        (folder.path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(displayPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(folder.path)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )

            Button("Choose…", action: onChoose)
        }
    }
}
