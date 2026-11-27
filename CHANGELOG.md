# Changelog

Package version stays **0.4.17** until explicitly bumped; everything below is on branch
`liquid-glass-0.5.0`.

## Xperimental — reference pass, diagnostics, presets, robustness

### Look (measured values, not adjectives)

These are the values the "iOS 27 Clear" preset writes, and the formulas the code uses when a slider has
not been touched. Everything the look depends on is in `Tweak.m` (`LoadPrefs`, `ApplyDecor`,
`SyncGlassIn`) and, for the refracted backdrop, in `backboardd/IOS26CCBackboardd.mm`.

| What | Value | Where |
|---|---|---|
| Liquid Glass master | 0.55 | `glassTint` |
| Material behind a tile | `0.28 + 0.58 × tint` (light mode floor 0.60) | `LoadPrefs` → `gMatAlpha` |
| White veil on the glass | `0.01 + 0.05 × tint` | `SyncGlassIn` |
| Fill tint | `0.02 + 0.12 × tint + fillTint` | `gEffTint` |
| Rim intensity / width | 0.45 / 0.7 pt | `rimIntensity`, `rimWidth` |
| Corner highlights | 0.05 | `glow` |
| Top sheen | 0.035 | `sheen` |
| Reflection streak scale | 0.6 | `reflect` |
| Dark edge | 0.30 | `edgeDark` |
| Edge colour fringe | 0.5 | `dispersion` |
| Inner glow | 0.15 | `innerRim` |
| Refracted backdrop blur | 20 pt | `glassBlurRadius` (renderer) |
| On-tile white fill | `0.92/0.94 − 0.06 × tint`, then `− 0.22 × (backdrop luminance − 0.35)`, clamped 0.62…0.97 | `OnFillAlpha` |

Reference measurements the code copies (from the recordings the earlier commits were fitted to):

* page flick landing: spring ω = 11.2 rad/s, ζ = 0.86, overshoot ≈ 26 pt, settles in ≈ 0.4 s;
* page motion: up to 7 % stretch along the scroll, area kept, released in 140 ms;
* open/close: stock spring played at 1.8× speed.

### Fixes

* **First open.** The page-wrapper test used `bounds`, and on the first layout pass page 1's modules are
  page-sized, so they were skipped; afterwards only transforms change, so no layout hook ever came back.
  The wrapper is now identified structurally (`HoldsIconList`), and the pager restyles the tracked views
  0.35 s and 1.1 s after each open.
* **Regression that shipped in `6573eed*`.** Widening that test to the on-screen rect made whole pages
  and expanded-module backdrops get a rim and glass. Reverted: a backdrop is a size test plus the
  structural check, nothing else.
* Turning the tweak off now also drops our own `xc.*` animations (a press killed mid-flight keeps
  `fillMode = forwards`), the synthetic fills, the on-fill colours and the menu marks of the whole
  subtree — not only the outermost view.

### Profiles

`LGProfile` (`tile`, `slider`, `round`, `menu`, `panel`, `backdrop`) replaces the scattered size tests.
The class table decides first; geometry is only the fallback. The chosen profile is stored per view and
appears in the style report, so a wrong tile names its own reason.

### Diagnostics (on by default)

* `ios26ccstyle-compat.txt` — build, device, screen, accessibility state, renderer marker, Liquid (Gl)ass
  detection, switches, and which hooked classes exist.
* `ios26ccstyle-style.txt` — one line per styled view: class, profile, radius, frame, on-screen rect,
  backdrop luminance, what was drawn.
* `ios26ccstyle-perf.txt` — calls, average and worst ms for the style pass and the backdrop walk.
* `xenonglass-breadcrumb.txt` — host, filter atom, source surface and scale written just before the
  renderer draws (survives a crash, unlike the buffered session log).
* Isolation switches: decoration, glass, extra blur, motion, sampling grid — draw one layer of the look
  at a time.
* Settings ▸ iOS 26 CC Style ▸ Compatibility report / Open logs / Copy settings / Paste settings.

### Presets

iOS 27 Clear (the tuned reference state), iOS 26 Frosted, Old dark (the 0.4.x look), and Reset all.

### Accessibility

* Reduce Motion → no page spring, no stretch, no press springs (stills the whole tweak's motion).
* Reduce Transparency → opaque material, no refraction glass, no extra blur; shape kept.
* Increase Contrast → stronger rim and a deeper dark edge (cached separately, so it applies at once).
* Low Power → sheen, corner glints and the streak (three layers per tile) are dropped.

### Renderer robustness

* Per-surface fail-soft: unusable geometry is passed through to the stock gaussian path; a host with
  three bad surfaces is disabled for the session only.
* Host table reads are snapshotted under a lock, writes hold the same lock, so a frame cannot see a
  half-updated host.
* Sampling-grid mode draws a 10 × 10 checker over the sampled source to prove the 1:1 backdrop mapping.

### Build

* `tools/lint.py` (brace/plist/uniform-sync/SDK-trap checks, about a second) runs in CI before the build.

### Still device-side

The visual result, the sampling grid, and the restore path are verified on a phone, not in CI. The
diagnostic files above are what to send when something looks wrong.
