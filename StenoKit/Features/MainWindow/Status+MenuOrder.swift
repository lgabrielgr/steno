extension Status {
    /// The order the four statuses are offered in when the user is picking one.
    ///
    /// Named here rather than taken from `allCases`, for the reason
    /// `TaskGrouping.order` gives about the window's sections: reordering the
    /// enum for any other purpose must not silently reorder a menu. M1-04 is
    /// what makes that worth paying for — the popover is the second surface to
    /// render `StatusMenuItems`, so a reorder would move the items under the
    /// user's cursor in two places at once.
    ///
    /// Deliberately **not** `TaskGrouping.order`. That order answers "what
    /// should I look at first" and is right for a list of sections; a picker
    /// reads best in workflow order. Two orders that differ is the correct
    /// outcome, and naming both is what makes the difference inspectable.
    public static let menuOrder: [Status] = [.todo, .inProgress, .blocked, .done]
}
