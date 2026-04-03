# Mascot Review

Open [mascot-concepts.svg](/Users/wangruobing/Personal/open-island/docs/review/mascot-concepts.svg) to review the current direction set.

This sheet is intentionally separate from the app UI. It is only for choosing the mascot style before wiring anything back into the product.

All concepts now follow a strict pixel-grid rule:

- mascot body: `8x8` canvas
- working spark: separate `4x4` canvas
- every pixel: same square size

## What Changed In This Round

- The previously integrated mascot UI change has been backed out in the working tree.
- Three softer pixel directions were rebuilt for review only.
- Each direction includes two states:
  - `idle`: green 8x8 mascot
  - `working`: blue 8x8 mascot plus 4x4 activity spark

## Reading Guide

- `A. Pebble` is the closest to the reference you shared.
- `B. Mochi` is the roundest and easiest to shrink into tiny icon sizes.
- `C. Scout` keeps a bit more personality without getting too busy.

## Next Step After Review

Pick one direction, then I can split it into:

- app icon direction
- menu bar / notch tiny icon
- idle / working animation states
