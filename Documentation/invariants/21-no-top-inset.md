# Invariant 21: No .safeAreaInset(edge: .top) over a scrolling list in a NavigationStack

Read before touching any `NavigationStack` with a scrolling list, Home's offline card.

**No `.safeAreaInset(edge: .top)` over a scrolling list in a `NavigationStack`**: the bar tracks the scroll offset the inset adjusts, and they loop until the watchdog kills the app. `StatusHistoryView`/`MomentLibraryView` pin their filter in a plain `VStack`. Home's offline card lives *inside* its scroll content — a pinned banner above Home's `ScrollView` hung launch the same way.
