# Mascot Motion Preview

Open [mascot-motion-preview.html](/Users/wangruobing/Personal/open-island/docs/review/mascot-motion-preview.html) to review the live animation version.

Format recommendation:

- for review: self-contained `HTML`
- for product: frame data or a tiny sprite atlas
- not recommended for product: `GIF`

Why:

- `HTML` is the easiest format for review because it can show the real loop and timing.
- The shipping app does not need a video-style asset because only the `4x4` spark changes.
- A GIF would lock us into raster timing and can get ugly when scaled inside the notch.

This preview keeps the same constraints as the static review:

- mascot body: fixed `8x8`
- spark: fixed `4x4`
- every pixel: square and equal sized
- only the working state moves
