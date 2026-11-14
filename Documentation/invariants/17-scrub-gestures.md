# Invariant 17: Scrub gestures need .highPriorityGesture

Read before touching `ScrubbableWaveform`, `VoiceMemoRow`, the gallery pager.

**Scrub gestures need `.highPriorityGesture`** (`ScrubbableWaveform`) in the gallery pager; never wrap a waveform in a `Button` (see `VoiceMemoRow`). A plain `.gesture` loses to the horizontal paging ScrollView. In a vertical ScrollView pass `scrollSafe: true` (`HorizontalScrub`, a pan that fails on vertical movement), or the drag hijacks scrolling.
