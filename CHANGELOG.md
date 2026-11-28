# Changelog

Package version stays **0.4.22** until explicitly bumped; everything below is on branch
`liquid-glass-0.5.0`.

## Xperimental — diagnostics that close their own loop

### Report in one step

**Share all logs (one file)**, **Copy build fingerprint** and **Delete logs** live next to *View logs*:
the whole log directory becomes one document in the share sheet (AirDrop, Files, mail), so a report is
complete instead of hand-copied, carries its build (version, device, iOS, log list) and is trimmed on the
phone afterwards. The viewer reads the same list as the archive, so the two cannot drift.

Every file in the directory is now bounded: the style/perf/dump writer rotates at 512 KB (keeping one
`.1` for a before/after) and so does the renderer log, which until now grew for as long as the session ran.

### Unconfirmed crashes are measured, then bisected

The boot guard used to give up on the second bad boot and go stock. It is now a ladder: four starts in
90 s keeps the decor and leaves the Metal renderer out — the half that can kill a boot and the half a
screenshot does not need — and only a loop that survives that goes stock. The chosen level is written to
`ios26ccstyle-guard.txt`.

`ios26ccstyle-hooks.txt` records every hook that installed and every one that did not, with the reason,
so `CCUIControlTemplateView` tiles that never change can be traced to a missing class or selector instead
of to the drawing code.

### The look is compared as numbers

New switch *Tile/page colour calibration*: once per page open, the Control Center window is drawn into a
small bitmap and the mean colour of a tile and of the page around it are written side by side to
`ios26ccstyle-calibrate.txt`. "The tile is 6/255 darker than the page" replaces "looks a bit off".

Related fixes from the same pass:

- the glass lays out with its host, so bounds and corner radius follow a container that expands, rotates
  or re-rounds (the 33.2 pt glass on a 38.0 pt tile) — and it does so conservatively: bounds and center
  rather than frame so a transform is left alone, implicit animations disabled, a 0.5 pt threshold, a
  re-entrancy guard, and it stops following a radius as soon as the caller sets one of its own;
- `prefsSchema` stamps the look schema but rewrites nothing: no default changed between the two schemas,
  so there is nothing to move, and a value the user tuned is never overwritten;
- an enabled tile is translucent glass with white in it, not a white card: the on-fill drops from
  0.92 … 0.97 to 0.78 … 0.86 and is only ever painted on a tile, so the rim, the sheen and the
  wallpaper stay visible through it instead of a white capsule sitting on a second one;
- Increase Contrast raises the rim, sheen, streak and edge of the same look instead of changing it;
- class-derived predicates (slider, exact material) are cached per class, removing a string build from
  every layout pass;
- `common/LGLogic.h` holds the heuristics that need no UIKit, and `tests/test_logic.c` proves them in CI;
- Theos and the SDK are pinned and cached, a `v*` tag produces a GitHub release with the `.deb`, and
  `ARCHITECTURE.md` records the Control Center model and the diagnostics map.

### Launch crash (safe mode before Control Center opens)

The previous build read UIKit from the dylib constructor. A constructor runs during dyld
initialisation, while SpringBoard is still starting: `UIScreen.mainScreen` and the Reduce Motion /
Reduce Transparency queries (which go out to the accessibility server) are not usable there, so
SpringBoard died before it finished launching and iOS dropped into safe mode without Control Center
ever being opened. Nothing in the constructor touches UI now: the compatibility report is built on the
main queue once the app runs, the launch path only does file and preference reads, and the Reduce
Motion answer the layer/scroll/touch hooks ask for on every frame is cached for 0.5 s instead of
crossing to the accessibility server per animation.

The animation log (off in older builds, on by default now) is written from a process-wide `CALayer`
hook that can run on any thread; its shared buffer is serialised with an unfair lock.

The tweak also cannot loop the device into safe mode any more: four SpringBoard starts inside 90 s
means the build itself is what is killing it, so it stays out of the way for that boot (no hooks,
stock Control Center) and says so in `ios26ccstyle-guard.txt`. A boot that stays up clears it.

The constructor cause above was inferred from the diff, not from a crash log. To measure it instead,
the constructor now names every step it is about to run in `ios26ccstyle-launch.txt` (POSIX
`open`/`write`, no UIKit, fresh file at each launch). After a safe mode the last line is the step that
boot died in, and a boot that reaches `alive: 30 s, launch path clean` finished the whole launch path —
that file, not the theory, is what tells which call killed SpringBoard. A launch that ends in a plain
respring is rotated to `ios26ccstyle-launch-previous.txt` first, because the restarted SpringBoard
would otherwise overwrite the only record of the crash. Both files are in Settings ▸ Open logs.

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
