# iOS 26 Control Center Style 0.10.0

Liquid Glass look for the iOS 18 Control Center. Rootless · arm64e · SpringBoard only (iPhone XS, iOS 18.5, Dopamine).

Hooks only the Control Center classes via the ObjC runtime (no global UIView hook, no CydiaSubstrate). The header pocket (top oval) is not styled. The 0.4.2 source is kept as `old-Tweak-0.4.2.x.txt`.

## Glass layers (per module / button / slider)
Expanded menus (Wi-Fi, Focus, brightness, ...) get the same glass layers: every rounded, clipping view inside a module container is decorated using its own system radius. Switch: "Expanded menus".

Outer specular rim (bright top-left and bottom-right) · refracted inner rim · inner edge glow (glass thickness) · top sheen · corner highlights · tunable fill tint · optional extra blur.

## Liquid Glass slider (iOS 27 style)
A master slider (Settings > iOS 26 CC Style > Liquid Glass) runs from ultra clear to fully tinted, default centered, like iOS 27 Settings > Appearance > Liquid Glass. It drives the transparency of the system blur behind modules, the fill tint and the rim brightness together.

## Settings
Settings → **iOS 26 CC Style** (PreferenceLoader preference bundle). Changes apply live; **Respring** button at the bottom.

Prefs domain `com.codex.ios26ccstyle`: enabled, styleModules, styleButtons, styleSliders, continuousCorners, sliderCapsule, maxRadius, rimColor, rimIntensity, rimWidth, fillColor, fillTint, sheen, innerRim, glow, extraBlur, bgBlur, reflect, edgeDark, debugDump. Darwin notification: `com.codex.ios26ccstyle/reload`.

## Build
arm64e needs Apple's linker, so build with GitHub Actions (**Build rootless tweak**, every push). The workflow installs the Theos iOS 16.5 SDK (it contains the private `Preferences` framework stub) and fails if the package has a double `/var/jb` prefix or lacks the prefs bundle.
Download the `IOS26CCStyle-rootless-deb` artifact, install with Sileo/Filza, respring.
