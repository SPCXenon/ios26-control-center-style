# iOS 26 Control Center Style 0.1.4

Liquid Glass look for the iOS 18 Control Center. Rootless · arm64e · SpringBoard only (iPhone XS, iOS 18.5, Dopamine).

Hooks only selected Control Center view classes via the ObjC runtime, including the header pocket and module views. Classes missing on the current iOS version are logged and skipped. It does not hook `UIView` globally or change inherited superclass implementations. Runtime class-name checks are cached per class, and style layers are recalculated only when geometry, radius, appearance, or visual preferences change. Layer mutations disable implicit Core Animation actions to avoid layout-time animation drift; the rim is raised above newly added subviews. No CydiaSubstrate dependency. The 0.4.2 source is kept as `old-Tweak-0.4.2.x.txt`.

## Glass layers (per module / button / slider)
Expanded menus (Wi-Fi, Focus, brightness, ...) get the same glass layers: every rounded, clipping view inside a module container is decorated using its own system radius. Switch: "Expanded menus".

Outer specular rim (bright top-left and bottom-right) · refracted inner rim · inner edge glow (glass thickness) · top sheen · corner highlights · tunable fill tint · optional extra blur.

## Liquid Glass slider (iOS 27 style)
A master slider (Settings > iOS 26 CC Style > Liquid Glass) runs from ultra clear to fully tinted, default centered, like iOS 27 Settings > Appearance > Liquid Glass. It drives the transparency of the system blur behind modules, the fill tint and the rim brightness together.

## Settings
Settings → **iOS 26 CC Style** (PreferenceLoader preference bundle). Changes apply live; **Respring** button at the bottom.

Prefs domain `com.xenon.ios26ccstyle`: enabled, styleModules, styleButtons, styleSliders, continuousCorners, sliderCapsule, maxRadius, rimColor, rimIntensity, rimWidth, fillColor, fillTint, sheen, innerRim, glow, extraBlur, bgBlur, reflect, edgeDark, debugDump. Darwin notification: `com.xenon.ios26ccstyle/reload`.

## Build
arm64e needs Apple's linker, so build with GitHub Actions (**Build rootless tweak**, every push). The workflow installs the Theos iOS 16.5 SDK (it contains the private `Preferences` framework stub) and fails if the package has a double `/var/jb` prefix or lacks the prefs bundle.
Download the `IOS26CCStyle-rootless-deb-v0.1.4` artifact, extract the `.deb`, install with Sileo/Filza, and respring.
