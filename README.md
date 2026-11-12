# iOS 26 Control Center Style

This rootless tweak targets SpringBoard on iOS 18.5 and uses the runtime-confirmed `SBControlCenterWindow` to limit styling to Control Center. Version 0.4.3 adds a PreferenceLoader page in Settings and leaves `CCUIHeaderPocketView` unchanged, removing the extra oval highlight around the top status/header area. Supported module surfaces and controls keep the system's native actions.

This is a visual style pass, not a replacement for Control Center's layout or edit controls. The exact iOS 26 Liquid Glass renderer is not available on iOS 18.5; the tweak adds a subtle gradient sheen and rim to selected module views.

## Build

The GitHub Actions workflow builds the rootless package on macOS, which supports the arm64e build path.

1. Open the repository's **Actions** tab.
2. Run **Build rootless tweak** on the `codex/ios18-5-header-prefs` branch, or push a commit to that branch.
3. Download the `IOS26CCStyle-rootless-deb` artifact from the completed run.
4. Install the `.deb` with Sileo and respring SpringBoard. The tweak page appears under **Settings → Tweaks**; if it does not appear after installation, restart Preferences once.

The package includes a PreferenceLoader bundle and installs into rootless paths through Theos. It does not install a daemon.

## Local build

On macOS with Theos and its iOS SDK installed:

```sh
make clean package FINALPACKAGE=1
```

The package is written to `packages/`.
