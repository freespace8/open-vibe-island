# Mascot Motion Review

Open [mascot-motion-concepts.svg](/Users/wangruobing/Personal/open-island/docs/review/mascot-motion-concepts.svg) to review the motion options.

This file is separate from the existing static mascot review. It compares:

- `3` mascots: `Pebble`, `Mochi`, `Scout`
- `3` working-state motion ideas: `Blink`, `Morph`, `Orbit`

Rules held constant:

- mascot body stays on a fixed `8x8` canvas
- spark stays on a fixed `4x4` canvas
- every pixel is a square with the same size
- motion is represented as a `3`-frame storyboard, not live animation

Quick read:

- `Blink`: safest, calmest, best first implementation
- `Morph`: still simple, but gives the mascot more personality
- `Orbit`: most lively, but also the busiest at tiny sizes

Practical recommendation:

- If you want the most conservative notch/menu bar animation, start from `Pebble × Blink` or `Mochi × Blink`.
- If you want a bit more delight without moving the mascot body, `Mochi × Morph` is a strong middle ground.
