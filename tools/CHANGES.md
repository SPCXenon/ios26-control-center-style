# Patch for branch `liquid-glass-0.5.0` (0.1.4)

Apply from the repo root, on the branch checkout:

    python3 apply_patch.py            # patches Tweak.m and prefs/Resources/Root.plist
    git diff                          # review
    git commit -am "Fix bgBlur when disabled, sheen default, Reduce Transparency, debounce reload"

The script aborts without writing anything if any edit does not match exactly once.

## Fixes

1. **"Enabled" off did not restore the wallpaper blur.** `ApplyBackground` ignored `gEnabled`, so the
   `bgBlur` slider kept changing Control Center's blur even with the tweak switched off.
   Now `EffBgBlur()` returns 1.0 (stock) when disabled.
2. **Sheen default mismatch.** `Root.plist` showed 0.1, `Tweak.m` used 0.07 until the slider was touched.
   The plist default is now 0.07 so the slider shows what is actually applied.
   (Prefer 0.1 as the look? Change `PrefDouble(@"sheen", 0.07, ...)` instead and revert the plist.)

## Improvements

3. **Reduce Transparency** (Accessibility) now turns the effect off and back on live.
4. **Debounced live reload.** Dragging a slider posts a burst of notifications; each burst now costs one
   `LoadPrefs` + restyle pass (50 ms trailing) instead of one per notification.
5. **Hook hierarchy log.** At startup, logs a line when a hooked class inherits from another hooked class
   (both hooks would run). Check with: `idevicesyslog | grep IOS26CCStyle`.

## Not changed (needs on-device measurement)

Each styled view carries up to ~11 CALayers; four of them are gradient layers masked by a stroke shape
(rim, two bevels, edge) plus a shadow-based glow, all of which render offscreen. If Control Center
animations stutter on the iPhone XS, the next step is to bake rim/bevel/edge/outline into one cached
bitmap per (size, radius, colours) instead of live masks. Not done here because it changes the look
and cannot be validated without the device.
