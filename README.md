# iOS 26 Control Center Style (first visual pass)

This rootless tweak targets SpringBoard on iOS 18. It uses the runtime-confirmed `SBControlCenterWindow` to limit changes to Control Center. Version 0.3.0 styles `CCUIContentModuleBackgroundView`, `CCUIControlTemplateView`, `CCUIContentModuleContentContainerView`, `CCUIHeaderPocketView`, and small header buttons with rounded translucent materials. It reapplies the treatment as views enter the window and after their layout updates. Existing Control Center modules and their native actions stay in place.

This is a visual style pass, not a full replacement of iOS 18 Control Center's layout or edit controls. The exact iOS 26 Liquid Glass renderer is not available to iOS 18; UIKit's dark thin material is used as a close approximation.

## Build for iPhone XS

iPhone XS is arm64e. Theos documents that the current arm64e ABI requires Apple's macOS/Xcode linker. This project includes a GitHub Actions workflow for that build path, so the package can be built without changing the device or installing the system-wide `oldabi` workaround.

1. Put this folder in a GitHub repository.
2. Open the repository's **Actions** tab and run **Build rootless tweak** (or push a commit).
3. Download the `IOS26CCStyle-rootless-deb` artifact from the completed run.
4. Install the `.deb` with Sileo and respring SpringBoard.

The package installs only into the rootless tweak-injection paths through Theos. It does not install a daemon or a preferences bundle.

## Local build

On macOS with Theos and its iOS SDK installed:

```sh
make clean package FINALPACKAGE=1
```

On WSL, the Theos environment is useful for editing and ordinary builds, but arm64e system tweaks need the ABI conversion/build route described above before installing on the XS.
