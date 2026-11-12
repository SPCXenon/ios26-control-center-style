# iOS 26 Control Center Style 0.5.0

Liquid Glass look for the iOS 18 Control Center. Rootless · arm64e · SpringBoard only (iPhone XS, iOS 18.5, Dopamine).

Rewritten from 0.4.2 (kept as `old-Tweak-0.4.2.x.txt`): hooks only the Control Center classes via the ObjC runtime (no global UIView hook, no CydiaSubstrate).

- Glass rim: 0.8pt gradient stroke, bright at top-left / bottom-right.
- Adaptive corners: pills, tiles and round buttons become capsules/circles; large modules capped by `maxRadius`.
- Capsule sliders, tunable fill tint.
- Live settings (PreferenceLoader page, or `com.codex.ios26ccstyle` prefs); no respring needed.

| Key | Default | Range |
|---|---|---|
| enabled | true | |
| sliderCapsule | true | |
| maxRadius | 46 | 16-70 |
| headerRadius | 38 | 12-70 |
| rimIntensity | 0.6 | 0-1 |
| fillTint | 0.04 | 0-0.15 |

## Build
arm64e needs Apple's linker, so build with the GitHub Actions workflow (**Build rootless tweak**, runs on every push).
Download the `IOS26CCStyle-rootless-deb` artifact, install with Sileo/Filza, respring.
