# iOS 26 Control Center Style 0.4.20

Liquid Glass look for the iOS 18 Control Center. Rootless · arm64e · SpringBoard only (iPhone XS, iOS 18.5, Dopamine).

Hooks only selected Control Center view classes via the ObjC runtime, including the header pocket and module views. Classes missing on the current iOS version are logged and skipped. It does not hook `UIView` globally or change inherited superclass implementations, and the scroll hooks are installed on the Control Center pager (`CCUIIconScrollView`) rather than on `UIScrollView`. A subclass and its hooked superclass apply the style once per layout pass, not twice. Runtime class-name checks are cached per class, and style layers are recalculated only when geometry, radius, appearance, or visual preferences change. Layer mutations disable implicit Core Animation actions to avoid layout-time animation drift; the rim is raised above newly added subviews. Switching the tweak off restores the system corner radius, clip and fill it had before. No CydiaSubstrate dependency.

## Glass layers (per module / button / slider)
Expanded menus (Wi-Fi, Focus, brightness, ...) get the same glass layers: every rounded, clipping view inside a module container is decorated using its own system radius. Switch: "Expanded menus".

Outer specular rim (bright top-left and bottom-right) · refracted inner rim · inner edge glow (glass thickness) · top sheen · corner highlights · tunable fill tint · optional extra blur.

## Liquid Glass slider (iOS 27 style)
A master slider (Settings > iOS 26 CC Style > Liquid Glass) runs from ultra clear to fully tinted, default centered, like iOS 27 Settings > Appearance > Liquid Glass. It drives the transparency of the system blur behind modules, the fill tint and the rim brightness together.

## Settings
Settings → **iOS 26 CC Style** (PreferenceLoader preference bundle). Changes apply live; **Respring** button at the bottom.

**Presets** at the top set every look slider at once: *iOS 27 Clear* (the tuned reference state),
*iOS 26 Frosted*, *Old dark* (the 0.4.x look) and *Reset all*. **Copy settings** / **Paste settings** move the
whole preference domain as an XML plist, so a look can be reproduced exactly on another device.

Prefs domain `com.xenon.ios26ccstyle`: enabled, styleModules, styleButtons, styleSliders, styleMenus, continuousCorners, sliderCapsule, maxRadius, rimColor, rimIntensity, rimWidth, fillColor, fillTint, sheen, innerRim, glow, extraBlur, bgBlur, reflect, edgeDark, dispersion, glassTint, glassBlurRadius, motion, pageSpring, pageSpeed, pageEffect, isoDecor, isoGlass, isoBlur, isoMotion, debugSampleGrid, debugDump, debugPerf. Darwin notification: `com.xenon.ios26ccstyle/reload`.

## Diagnostics (on by default)
Everything lands in `/var/mobile/Library/Logs/IOS26CCStyle` and is readable on the phone: **Settings ▸
iOS 26 CC Style ▸ Open logs** (or **Compatibility report** for the first one).

| File | What it answers |
|---|---|
| `ios26ccstyle-compat.txt` | build, device, screen, accessibility state, renderer marker, Liquid (Gl)ass detection, switches, which hooked classes exist |
| `ios26ccstyle-launch.txt`, `-launch-previous.txt` | every step of the last SpringBoard launch from the constructor, and the launch before it (kept because a crash restarts SpringBoard and would overwrite it); the last line is the step a boot that safe-moded died in, `alive: 30 s, launch path clean` means the whole launch path finished |
| `ios26ccstyle-style.txt` | one line per styled view: class, **profile**, radius, frame, on-screen rect, backdrop luminance, what was drawn |
| `ios26ccstyle-perf.txt` | calls, average and worst ms for the style pass and the backdrop walk |
| `ios26ccstyle-scroll.txt`, `-module-dump.txt`, `-tile-chain.txt`, `-expanded-*.txt`, `-edit.txt`, `-press.txt`, `-anim-log.txt` | view trees and animation inventory for the matching surface |
| `xenonglass.log`, `xenonglass-breadcrumb.txt` | renderer session log, and the last host/surface before a draw (survives a crash) |

**Isolation switches** draw one layer of the look at a time (decoration, refraction glass, extra blur,
motion); all off is the stock Control Center. **Show sampling grid** makes the renderer draw a 10 × 10
checker over the sampled backdrop, which proves the 1:1 mapping visually.

## Profiles
`LGProfile` decides how a view is drawn — `tile`, `slider`, `round`, `menu`, `panel`, `backdrop` — from a
class table with geometry only as the fallback. The page wrapper and the backdrop of an expanded module
are `backdrop`: no rim, no glass of ours, the system material stays. The chosen profile is part of the
style report, so a wrong tile names its own reason.

## Accessibility
Reduce Motion disables the page spring, the page stretch and the press springs. Reduce Transparency
switches the tiles to opaque material without refraction glass. Increase Contrast strengthens the rim and
the dark edge. Low Power Mode drops the purely decorative layers (sheen, corner glints, streak).

## Performance
`ios26ccstyle-perf.txt` carries a call count, an average and a worst case for the style pass and the
backdrop walk. The scroll hooks bail out when the Control Center window is not visible, the display link
is invalidated when its pager goes away, and the backdrop walk is capped and rate limited.

## Build
arm64e needs Apple's linker, so build with GitHub Actions (**Build rootless tweak**, every push). The workflow installs the Theos iOS 16.5 SDK (it contains the private `Preferences` framework stub) and fails if the package has a double `/var/jb` prefix or lacks the prefs bundle.
Download the `IOS26CCStyle-rootless-deb-v0.4.20` artifact, extract the `.deb`, install with Sileo/Filza, and respring.

## Refraction glass (backboardd)
`backboardd/` is a second tweak injected into `backboardd` that registers a Metal render pass in the render
server. SpringBoard attaches a `CABackdropLayer` with filter `xenon.liquidglass.cc.*` to the Control Center
modules; the pass refracts the backdrop at the bezel, with dispersion and fresnel specular.

Install the package, then do a **userspace reboot / reboot** (a respring does not reload backboardd). SpringBoard
only uses the shader once backboardd wrote `/var/mobile/Library/Accessibility/xenonglass-ready`; otherwise the
CALayer look is used. After 3 backboardd starts within 60 s the renderer disables itself
(`xenonglass-backboardd-guard.bin`, `xenonglass-safemode.log`).

### Using it next to Liquid (Gl)ass
Both can be installed together. This tweak keeps the Control Center and, once at start, switches the
Control Center surface off in Liquid (Gl)ass (its other surfaces are untouched). The previous value is
remembered and put back when "Own Control Center when Liquid (Gl)ass is installed" is turned off or this
tweak is disabled. The setting is written through CFPreferences, not by rewriting Liquid (Gl)ass's plist.

### Credits / license
The renderer is derived from **Liquid (Gl)ass** by dylv — https://github.com/winaviation-tweaks/liquidass —
licensed **CC BY-NC 4.0**. Non-commercial use only. See [`LICENSE`](LICENSE) for the files covered by that
license and for the terms of the rest of the source. Changes: renamed filter namespace/files/prefs domain, crash-loop
guard no longer wiped at start, ready marker, delayed prefs reload. See headers in `backboardd/`.
