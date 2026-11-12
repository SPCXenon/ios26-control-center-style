# iOS 26 Control Center Style 0.6.0

Liquid Glass look for the iOS 18 Control Center. Rootless · arm64e · SpringBoard only (iPhone XS, iOS 18.5, Dopamine).

Hooks only the Control Center classes via the ObjC runtime (no global UIView hook, no CydiaSubstrate). The 0.4.2 source is kept as `old-Tweak-0.4.2.x.txt`.

## Settings
Settings → **iOS 26 CC Style** (needs PreferenceLoader). Changes apply live.

| Section | Options |
|---|---|
| General | Enabled |
| Elements | Modules/tiles, Header, Round buttons, Sliders (each on/off) |
| Shape | Continuous corners, Capsule sliders, Module radius cap, Header radius |
| Glass rim | Color (8 presets), Intensity, Width |
| Glass fill | Color (8 presets), Tint, Top sheen |

Prefs domain: `com.codex.ios26ccstyle` (keys: enabled, styleModules, styleHeader, styleButtons, styleSliders, continuousCorners, sliderCapsule, maxRadius, headerRadius, rimColor, rimIntensity, rimWidth, fillColor, fillTint, sheen). Darwin notification: `com.codex.ios26ccstyle/reload`.

Small tiles, pills and round buttons are always capsules/circles; the full-page wrapper is skipped so no outline is drawn around the whole page. Turning an element off fully takes effect after a respring.

## Build
arm64e needs Apple's linker, so build with the GitHub Actions workflow (**Build rootless tweak**, runs on every push).
Download the `IOS26CCStyle-rootless-deb` artifact, install with Sileo/Filza, respring.
