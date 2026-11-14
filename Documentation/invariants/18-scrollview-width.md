# Invariant 18: Pin vertical-ScrollView content with .containerRelativeFrame(.horizontal)

Read before touching any vertical `ScrollView` (`HomeView`).

**Pin vertical-ScrollView content with `.containerRelativeFrame(.horizontal)`** (see `HomeView`): a child with a wide *ideal* size (a long single-line `Text`) can let the screen pan sideways; prefer `.fixedSize(horizontal: false, vertical: true)` on wrapping text. (`WaveformBars` never reports more than its width.)
