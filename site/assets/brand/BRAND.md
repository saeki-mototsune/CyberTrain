# CyberTrain: brand sheet

**Concept.** A train nose seen head-on, cut from the same steel sheet as the letters. It sits on a perspective track, with one champagne-gold light bar across its face; that bar is the Cybercab front light strip. The wordmark is all caps, built from straight segments and 45-degree chamfers, with one monoline stroke. Its middle strokes (Y, B, E, R, A) share one band, and in the lockup the gold light bar lines up with that band, so the light runs through the name.

## Construction system
- Cap height **H = 60**, stroke **S = 10** (H/6), 45-degree chamfers only (K = 12), no curves anywhere.
- Letters are about 1.33 H wide. The base gap is 21, with optical kerns.
- The middle band is y 25..35.
- The mark shares S. The horizontal lockup uses an optical cut of the mark at 1.71 H so the stroke still matches S.

## Colour tokens
| token | hex | where |
|---|---|---|
| `--ct-ink-on-dark` | `#E8E8E8` | artwork on dark backgrounds |
| `--ct-ink-on-light` | `#0A0A0A` | artwork on light backgrounds; favicon tile |
| `--ct-accent` | `#C8A96A` | light bar, on dark |
| `--ct-accent-deep` | `#A8864A` | light bar, on light (at least 3:1 on white) |

**Accent rule:** gold appears on **one element only**, the mark's light bar. It is never used on letters, backgrounds or outlines, and never as a gradient. Drop it below 32 px (as `favicon.svg` does).

## Clear space and minimum size
- **Clear space:** at least **0.5 H** (half the cap height) on every side of the wordmark and lockups, and at least 1 S (10/104 of the width) around the standalone mark.
- **Minimum sizes:**
  - wordmark: 12 px cap height (use `wordmark-small.svg` below that, down to 8 px)
  - horizontal lockup: 20 px tall
  - stacked lockup: 64 px tall
  - mark: 24 px
  - below 24 px, use `favicon.svg`
- **Do not:** stretch, re-space, outline, add glow, shadow or bevel, recolour the letters gold, or place the light-ink files on light backgrounds.

## Which file where
| use | file |
|---|---|
| README header (GitHub, dark and light) | `lockup-dark.svg` + `lockup-light.svg` in a `<picture>` with `prefers-color-scheme` |
| site header (inline, inherits `color`) | `lockup.svg` (or `wordmark.svg` in tight bars) |
| hero / splash / about page | `lockup-stacked.svg` (or `-dark` / `-light`) |
| browser tab | `favicon.svg` (`<link rel="icon" type="image/svg+xml">`), with `favicon-32.png` and `favicon-16.png` as PNG fallbacks |
| iOS home screen | `apple-touch-icon.png` (180 x 180) |
| social card / avatar / app icon at 48 px and up | `app-icon.svg` for the avatar; the site's 1200 x 630 cards (`site/assets/og/`) are rendered by `script/og-cards` from `wordmark.svg` and `mark-dark.svg` on `#0A0A0A` |
| icon-only UI (nav, loader) | `mark.svg` (currentColor) or `mark-dark.svg` / `mark-light.svg` |

```html
<link rel="icon" href="assets/brand/favicon.svg" type="image/svg+xml">
<link rel="icon" href="assets/brand/favicon-32.png" sizes="32x32" type="image/png">
<link rel="apple-touch-icon" href="assets/brand/apple-touch-icon.png">
```
The `currentColor` files (`wordmark.svg`, `mark.svg`, `lockup.svg`, `lockup-stacked.svg`, `wordmark-small.svg`) take the text colour of their parent when inlined. Their gold stays the literal `#C8A96A`, which is tuned for dark themes. On a light theme, use the `-light` files, which carry `#A8864A`.
