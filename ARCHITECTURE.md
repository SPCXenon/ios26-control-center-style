# How this tweak sees Control Center

The look itself is a set of shader and layer constants. Everything that makes those constants land on
the right view is a model of the iOS 18 Control Center view tree, reverse-engineered from live dumps
(`ios26ccstyle-tile-chain.txt`, `ios26ccstyle-style.txt`) on an iPhone XS, iOS 18.5. This file records
that model so a later change does not re-derive it from scratch — or, worse, contradicts it.

## The chain

| Class | What it is | What the tweak does |
| --- | --- | --- |
| `CCUIContentModuleBackgroundView` | The material **behind** a module's content (a tile's fill) | Decor (rim, edge, sheen) + glass in `SyncGlassIn`, profile `ModuleFill` |
| `CCUIControlTemplateView` | Base tile on page 1 and 2 (Wi-Fi, Flashlight, …) | Decor, glass, press animation; `kind = Module` |
| `CCUIButtonModuleView`, `CCUIRoundButton`, `CCUIPowerButton`, `CCUIAccessoryButton` | Subclasses of the template / round button | Same, at their own radius; `kind = Round` |
| `CCUIContinuousSliderView`, `CCUISteppedSliderView` | Brightness and volume | `kind = Slider`; own glass, cleared dark track, slider rim |
| `CCUIContentModuleContentContainerView` | The container around a module's content | `kind = Container`; panel glass for expanded modules |
| `CCUIModuleCollectionView` / `CCUIIconScrollView` | The pager and its scroll view | Page scroll behaviour, settle callbacks |
| `MTMaterialView` | The system blur material | `setAlpha:` hooked so its alpha follows ours; a page-high material is hidden, not glazed |
| `CABackdropLayer` | Layer of the glass (`XCGlassView`'s layer class) | Backdrop filter type `xenon.liquidglass.cc.r<step>[.dark][.refresh]` |

## Rules that were learned the hard way

- **A material as tall as ~70 % of the window is a page backdrop, not a tile.** Glass on it is the extra
  pane behind a whole page of tiles (0.4.19). `lgIsPageHigh` in `common/LGLogic.h` is the one definition.
- **A page wrapper is as wide as the screen.** The expanded connectivity page is page-high but only
  ~299 pt wide, and is a panel, not a wrapper (`LGProfileFor`).
- **An expanded module's card is the shallowest rounded, clipping, ~200–400 pt wide view** that is big
  enough to hold it (`FindPanelCard`). Its glass must be the card's size, not the collapsed tile's
  (0.4.20: one outline, not two).
- **Tiles without a material of their own** (Flashlight, sliders) need a glass of their own, and the
  slider's dark track has to be cleared or it shows through (`SyncOwnGlass`).
- **Radius is a snapshot.** A glass created for a 38 pt container kept 33.2 pt after the container
  re-rounded; `XCGlassView.layoutSubviews` now keeps frame and radius with its host.
- **Two styles on one tile fight.** Liquid (Gl)ass is detected and its Control Center turned off, with
  the original value remembered (`LiquidAssInstalled`).

## Where the numbers live

- `backboardd/IOS26CCBackboardd.mm` — the Metal pass: backdrop sampling, the tile lift
  (`1.16 × backdrop + 0.06`), rim/bevel, dispersion. The shader's `Uniforms` struct must stay field-for-field
  identical to `LGUniforms` (`tools/lint.py` checks that), and the ObjC side that fills it must say the same.
- `Tweak.m` — the layer stack: `ApplyDecor` (edges, sheen, sheen-streak, corner glow, shade),
  `SyncGlassIn` / `SyncPanelGlass` / `SyncOwnGlass` (where glass goes), `ApplyBgDim`, page pager.
- `prefs/Resources/Root.plist` — the switches and sliders, i.e. what a user can move.

## Diagnostics map

| File | Written by | Answers |
| --- | --- | --- |
| `ios26ccstyle-launch.txt` / `-previous.txt` | constructor, POSIX write | which constructor step killed a boot |
| `ios26ccstyle-guard.txt` | boot guard | whether the crash-loop ladder stepped in, and at which level |
| `ios26ccstyle-hooks.txt` | `InstallHook` | which hook did not land, and why |
| `ios26ccstyle-compat.txt` | main queue, 4 s | shapes, accessibility, renderer/LiquidAss state |
| `ios26ccstyle-style.txt` | `ReportStyle`, 1/s | what each styled view got and why (profile, dark, glass, decor) |
| `ios26ccstyle-tile-chain.txt` | `DumpTileChain`, 1.5 s | the view chain of Wi-Fi, Flashlight and sliders |
| `ios26ccstyle-calibrate.txt` | `LGCalibrate` (switch) | tile mean colour vs page mean colour, per tile |
| `ios26ccstyle-perf.txt` | `PerfFlush`, 2 s | calls/avg/worst per hot path |
| `xenonglass.log` / `.1` | renderer, 512 KB capped | renderer start-up and per-pass failures |
| `xenonglass-breadcrumb.txt` | renderer | last frame the renderer reached |
