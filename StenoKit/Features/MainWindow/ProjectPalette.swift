/// The colours new projects are assigned, in order.
///
/// There is no colour picker: §3.1 describes `colorHex` as visual
/// identification in lists, and FR-6's Settings list does not include project
/// colour. FR-3 says to build the simple thing.
public enum ProjectPalette {
    public static let hexes = [
        "#3B82F6", "#F59E0B", "#10B981", "#EF4444",
        "#8B5CF6", "#EC4899", "#14B8A6", "#F97316",
    ]

    /// Cycles rather than trapping — D18 caps live projects well below this,
    /// but a crash on the ninth project would be an absurd way to find out.
    public static func hex(forIndex index: Int) -> String {
        let wrapped = ((index % hexes.count) + hexes.count) % hexes.count
        return hexes[wrapped]
    }
}
