// IOS26CCStyle 0.4.21
// iOS 26 "Liquid Glass" look for the iOS 18 Control Center.
// Target: iOS 18.x · rootless (Dopamine / ElleKit) · arm64e · SpringBoard only.
//
// No CydiaSubstrate dependency: hooks are installed with the ObjC runtime
// (class_addMethod / method_setImplementation). The header pocket (top oval) is
// intentionally left untouched.

#import <dlfcn.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <notify.h>
#import <objc/message.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <os/lock.h>
#include <sys/sysctl.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/time.h>

static NSString *const kPrefsDomain = @"com.xenon.ios26ccstyle";
static NSString *const kReloadNotification = @"com.xenon.ios26ccstyle/reload";
#define XC_VERSION "0.4.21"

// MARK: - Preferences ---------------------------------------------------------

static BOOL    gEnabled, gSliderCapsule, gContinuous, gExtraBlur, gMotion, gPressGrow, gPageSpring, gShimmer;
static double  gPageSpeed = 1.8, gPageFx = 60.0;     // open / close speed (x stock), page effect %
static double  gSpringK = 380.0, gSpringD = 26.0;   // iOS 27 animation spring (stiffness, damping)
static BOOL    gStyleModules, gStyleButtons, gStyleSliders, gStyleMenus;
static CGFloat gMaxRadius;     // corner radius cap for modules (pt)
static CGFloat gRim, gRimWidth;// rim light intensity 0…1, stroke width pt
static CGFloat gSheen, gTint;  // top sheen alpha, extra fill tint alpha
// iOS 27-style master slider: 0 = ultra clear … 1 = fully tinted (default 0.5)
static CGFloat gGlass;         // raw slider value
static CGFloat gMatAlpha;      // alpha of the system material views (blur) behind modules
static CGFloat gEffTint;       // resulting fill tint alpha
static CGFloat gRimMul;        // rim brightness multiplier (clearer glass = brighter edges)
static CGFloat gInner, gHot;   // inner edge glow 0…1, corner highlight 0…0.3
static CGFloat gReflect;       // reflectivity of the glass (specular rim, sheen, streak, highlights) 0…1
static CGFloat gEdgeDark;      // iOS 27-style darkened edge 0…1
static CGFloat gDisp;          // chromatic fringe on the rim 0…1
static CGFloat gBgDim;         // extra darkening of the page behind Control Center (reference: white screen -> 88/255)
static CGFloat gBgBlur;        // full-screen backdrop blur: 1 = stock, lower = clearer
static BOOL    gRefract;       // real refraction glass via the backboardd renderer
static BOOL    gDebugDump;     // write a view-tree dump (for class-name diagnostics)
// Diagnostics: isolate one layer of the look. With everything off you get the plain stock Control
// Center, so a wrong-looking tile can be bisected on the phone instead of in a rebuild.
static BOOL    gIsoDecor = YES, gIsoGlass = YES, gIsoBlur = YES, gIsoMotion = YES;
static BOOL    gSampleGrid;    // renderer: draw the sampling grid instead of glass (needs backboardd)
static BOOL    gPerfLog = YES;  // frame-time counters for the style pass
static UIColor *gRimColor, *gFillColor;
static NSUInteger gGeneration; // bumped on every prefs reload

static CFPropertyListRef CopyPref(NSString *key) {
    return CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kPrefsDomain);
}

static double PrefDouble(NSString *key, double def, double lo, double hi) {
    double out = def;
    CFPropertyListRef v = CopyPref(key);
    if (v) {
        if (CFGetTypeID(v) == CFNumberGetTypeID()) {
            CFNumberGetValue((CFNumberRef)v, kCFNumberDoubleType, &out);
        }
        CFRelease(v);
    }
    return round(MAX(lo, MIN(hi, out)) * 100.0) / 100.0;   // sliders store long fractions; keep two decimals
}

static BOOL PrefBool(NSString *key, BOOL def) {
    BOOL out = def;
    CFPropertyListRef v = CopyPref(key);
    if (v) {
        if (CFGetTypeID(v) == CFBooleanGetTypeID()) {
            out = CFBooleanGetValue((CFBooleanRef)v);
        } else if (CFGetTypeID(v) == CFNumberGetTypeID()) {
            int n = 0;
            CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &n);
            out = (n != 0);
        }
        CFRelease(v);
    }
    return out;
}

static NSString *PrefString(NSString *key, NSString *def) {
    NSString *out = def;
    CFPropertyListRef v = CopyPref(key);
    if (v) {
        if (CFGetTypeID(v) == CFStringGetTypeID()) out = [(__bridge NSString *)v copy];
        CFRelease(v);
    }
    return out;
}

static UIColor *ColorNamed(NSString *name) {
    static NSDictionary<NSString *, UIColor *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"white":  [UIColor colorWithWhite:1.0 alpha:1.0],
            @"black":  [UIColor colorWithWhite:0.0 alpha:1.0],
            @"blue":   [UIColor colorWithRed:10/255.0  green:132/255.0 blue:255/255.0 alpha:1.0],
            @"teal":   [UIColor colorWithRed:64/255.0  green:200/255.0 blue:224/255.0 alpha:1.0],
            @"green":  [UIColor colorWithRed:48/255.0  green:209/255.0 blue:88/255.0  alpha:1.0],
            @"orange": [UIColor colorWithRed:255/255.0 green:159/255.0 blue:10/255.0  alpha:1.0],
            @"pink":   [UIColor colorWithRed:255/255.0 green:55/255.0  blue:95/255.0  alpha:1.0],
            @"purple": [UIColor colorWithRed:191/255.0 green:90/255.0  blue:242/255.0 alpha:1.0],
        };
    });
    return map[name] ?: map[@"white"];
}

static void LoadPrefs(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPrefsDomain);
    gEnabled       = PrefBool(@"enabled", YES);
    gStyleModules  = PrefBool(@"styleModules", YES);
    gStyleButtons  = PrefBool(@"styleButtons", YES);
    gStyleSliders  = PrefBool(@"styleSliders", YES);
    gStyleMenus    = PrefBool(@"styleMenus", YES);
    gSliderCapsule = PrefBool(@"sliderCapsule", YES);
    gContinuous    = PrefBool(@"continuousCorners", YES);
    gExtraBlur     = PrefBool(@"extraBlur", NO);
    gMotion        = PrefBool(@"motion", YES);
    gPressGrow     = PrefBool(@"pressGrow", YES);
    gPageSpring    = PrefBool(@"pageSpring", YES);
    gShimmer       = PrefBool(@"shimmer", YES);
    gSpringK       = PrefDouble(@"motionStiffness", 380.0, 50.0, 1000.0);
    gSpringD       = PrefDouble(@"motionDamping", 26.0, 2.0, 80.0);
    gPageSpeed     = PrefDouble(@"pageSpeed", 1.8, 0.5, 3.0);
    gPageFx        = PrefDouble(@"pageEffect", 60.0, 0.0, 100.0);
    gMaxRadius     = (CGFloat)PrefDouble(@"maxRadius", 46.0, 16.0, 70.0);
    // iOS 27 reference: the rim is a soft, low-contrast trace, not a bright outline; the glow is a hint
    // in the corner and the top sheen is barely there. The transparencies below keep the tile close to
    // the wallpaper so the colour behind it comes through.
    gRim           = (CGFloat)PrefDouble(@"rimIntensity", 0.45, 0.0, 1.0);
    gRimWidth      = (CGFloat)PrefDouble(@"rimWidth", 0.7, 0.3, 2.5);
    gSheen         = (CGFloat)PrefDouble(@"sheen", 0.035, 0.0, 0.2);
    gTint          = (CGFloat)PrefDouble(@"fillTint", 0.0, 0.0, 0.3);
    gInner         = (CGFloat)PrefDouble(@"innerRim", 0.15, 0.0, 1.0);
    gHot           = (CGFloat)PrefDouble(@"glow", 0.05, 0.0, 0.3);
    gGlass         = (CGFloat)PrefDouble(@"glassTint", 0.55, 0.0, 1.0);
    gMatAlpha      = 0.28 + 0.58 * gGlass;
    gEffTint       = MIN(0.5, 0.02 + 0.12 * gGlass + gTint);
    gRimMul        = 1.3 - 0.5 * gGlass;
    gReflect       = (CGFloat)PrefDouble(@"reflect", 0.6, 0.0, 1.0);
    gEdgeDark      = (CGFloat)PrefDouble(@"edgeDark", 0.30, 0.0, 1.0);
    gBgBlur        = (CGFloat)PrefDouble(@"bgBlur", 1.0, 0.0, 1.0);
    gBgDim         = (CGFloat)PrefDouble(@"bgDim", 0.65, 0.0, 0.9);
    gDisp          = (CGFloat)PrefDouble(@"dispersion", 0.5, 0.0, 1.0);
    gDebugDump     = PrefBool(@"debugDump", YES);   // on by default: a report is what a bug report needs
    gIsoDecor      = PrefBool(@"isoDecor", YES);
    gIsoGlass      = PrefBool(@"isoGlass", YES);
    gIsoBlur       = PrefBool(@"isoBlur", YES);
    gIsoMotion     = PrefBool(@"isoMotion", YES);
    gSampleGrid    = PrefBool(@"debugSampleGrid", NO);
    gPerfLog       = PrefBool(@"debugPerf", YES);
    gRefract       = PrefBool(@"refraction", YES) && PrefBool(@"Renderer.Enabled", YES);
    gRimColor      = ColorNamed(PrefString(@"rimColor", @"white"));
    gFillColor     = ColorNamed(PrefString(@"fillColor", @"white"));
    gGeneration++;
}

// MARK: - Diagnostics ---------------------------------------------------------

// 0.4.x wrote its dumps into Apple's Preferences directory and its renderer files into Apple's
// Accessibility directory, straight from the layout and touch paths. They go into one directory of
// ours now, and the writing happens on a serial background queue: those dumps are built from live
// view trees during layout, and a synchronous file write there cost frames.
static NSString *LGDiagnosticsDirectory(void) {
    static NSString *directory;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *preferred = @"/var/mobile/Library/Logs/IOS26CCStyle";
        [NSFileManager.defaultManager createDirectoryAtPath:preferred
                                withIntermediateDirectories:YES attributes:nil error:NULL];
        directory = [NSFileManager.defaultManager isWritableFileAtPath:preferred]
            ? preferred : @"/var/mobile/Library/Accessibility";   // 0.4.x location, for older sandboxes
    });
    return directory;
}

// Marker files are written by backboardd, which may have had to fall back to the old directory.
static BOOL LGDiagnosticsMarkerExists(NSString *name) {
    for (NSString *directory in @[LGDiagnosticsDirectory(), @"/var/mobile/Library/Accessibility"])
        if ([NSFileManager.defaultManager fileExistsAtPath:
                [directory stringByAppendingPathComponent:name]]) return YES;
    return NO;
}

static void LGWriteDiagnostic(NSString *name, NSString *text) {
    if (text.length == 0) return;
    text = [text copy];   // most dumps reuse one mutable buffer; snapshot it before leaving this thread
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.xenon.ios26ccstyle.diagnostics", DISPATCH_QUEUE_SERIAL);
    });
    NSString *path = [LGDiagnosticsDirectory() stringByAppendingPathComponent:name];
    dispatch_async(queue, ^{
        [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    });
}

// MARK: - Launch breadcrumb ----------------------------------------------------
// A constructor runs during dyld initialisation, before SpringBoard owns a UIApplication: one wrong
// call there kills the boot, leaves no stack behind and drops the device into safe mode, so there is
// nothing to read back afterwards unless the launch itself writes as it goes. Every constructor step
// appends one line here through POSIX open/write — no NSString formatting, no UIKit, nothing that can
// fail on its own — and the file is truncated at the start of each launch. The last line is therefore
// the step that boot died in; a boot that reaches "alive: 30 s" finished the whole launch path.
static NSString *const kLaunchLogName = @"ios26ccstyle-launch.txt";
static NSString *const kLaunchPreviousName = @"ios26ccstyle-launch-previous.txt";
static int gLaunchLogFD = -1;

static void LGLaunchStep(const char *step) {
    if (gLaunchLogFD < 0) return;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    char line[256];
    int n = snprintf(line, sizeof(line), "%ld.%03ld %d %s\n",
                     (long)tv.tv_sec, (long)(tv.tv_usec / 1000), (int)getpid(), step);
    if (n <= 0) return;
    size_t len = MIN((size_t)n, sizeof(line) - 1);   // snprintf may have truncated the line
    ssize_t ignored = write(gLaunchLogFD, line, len);
    (void)ignored;   // a breadcrumb that cannot be written must never take the launch down with it
}

// Called first in the constructor. The last launch is moved aside, not deleted: SpringBoard restarts
// after a crash and would otherwise truncate the only record of the launch that killed it. After a
// crash the current file holds the launch that is running now and the previous one holds the crashed.
static void LGLaunchBegin(void) {
    if (gLaunchLogFD >= 0) return;
    NSString *directory = LGDiagnosticsDirectory();
    NSString *path = [directory stringByAppendingPathComponent:kLaunchLogName];
    NSString *previous = [directory stringByAppendingPathComponent:kLaunchPreviousName];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:previous error:nil];
    [fm moveItemAtPath:path toPath:previous error:nil];   // nothing to rotate on the first launch
    gLaunchLogFD = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    LGLaunchStep("begin");
}

static void LGLaunchEnd(void) {
    if (gLaunchLogFD < 0) return;
    close(gLaunchLogFD);
    gLaunchLogFD = -1;
}

// MARK: - Frame-time counters -------------------------------------------------
// Every visible layer of this tweak runs inside SpringBoard's layout and scroll paths, so a change can
// cost frames without looking wrong. These counters are cheap (a clock read around the hot paths)
// and land in ios26ccstyle-perf.txt, so a slowdown is a number, not a feeling.

typedef struct { const char *name; uint64_t calls; double total, worst; } LGPerfSlot;
static LGPerfSlot gPerf[8];
static int gPerfUsed;

static double PerfNowMS(void) { return CACurrentMediaTime() * 1000.0; }

static void PerfAdd(const char *name, double ms) {
    if (!gPerfLog || ms < 0) return;
    for (int i = 0; i < gPerfUsed; i++) {
        if (strcmp(gPerf[i].name, name) != 0) continue;
        gPerf[i].calls++;
        gPerf[i].total += ms;
        if (ms > gPerf[i].worst) gPerf[i].worst = ms;
        return;
    }
    if (gPerfUsed >= 8) return;
    gPerf[gPerfUsed].name = name;
    gPerf[gPerfUsed].calls = 1;
    gPerf[gPerfUsed].total = ms;
    gPerf[gPerfUsed].worst = ms;
    gPerfUsed++;
}

static void PerfFlush(void) {
    static CFTimeInterval last;
    CFTimeInterval now = CACurrentMediaTime();
    if (!gPerfLog || !gPerfUsed || now - last < 2.0) return;
    last = now;
    NSMutableString *o = [NSMutableString stringWithFormat:@"ios26ccstyle %s perf (ms)\n", XC_VERSION];
    for (int i = 0; i < gPerfUsed; i++) {
        [o appendFormat:@"%-16s calls=%llu avg=%.2f worst=%.2f\n", gPerf[i].name,
            (unsigned long long)gPerf[i].calls, gPerf[i].calls ? gPerf[i].total / (double)gPerf[i].calls : 0.0,
            gPerf[i].worst];
    }
    LGWriteDiagnostic(@"ios26ccstyle-perf.txt", o);
}

// MARK: - Accessibility -------------------------------------------------------
// The system settings that decide how much of this look a user can actually take: Reduce Motion
// (no springs), Reduce Transparency (opaque material, no glass), Increase Contrast (stronger edge).

// Reduce Motion lives in another process: asking costs an accessibility round trip. The layer, scroll
// and touch hooks ask on every animation and every event, so the answer is kept for half a second and
// thrown away when the setting changes (see the status-change observers below).
static BOOL gReduceMotion;
static CFTimeInterval gReduceMotionAt = -1.0;

static BOOL ReduceMotionOn(void) {
    CFTimeInterval now = CACurrentMediaTime();
    if (gReduceMotionAt < 0 || now - gReduceMotionAt > 0.5) {
        gReduceMotionAt = now;
        gReduceMotion = UIAccessibilityIsReduceMotionEnabled();
    }
    return gReduceMotion;
}

static BOOL ReduceTransparencyOn(void) { return UIAccessibilityIsReduceTransparencyEnabled(); }
static BOOL IncreaseContrastOn(void) { return UIAccessibilityDarkerSystemColorsEnabled(); }
static BOOL LowPowerOn(void) { return NSProcessInfo.processInfo.isLowPowerModeEnabled; }

// Motion: the preference, the isolation switch and Reduce Motion all have to agree.
static BOOL MotionAllowed(void) { return gEnabled && gMotion && gIsoMotion && !ReduceMotionOn(); }

// MARK: - Backdrop luminance --------------------------------------------------
// The reference keeps tiles translucent, so how much white a tile needs under its dark label depends
// on what is behind it. The window under Control Center is rendered once into an 8x8 grid (cheap and
// capped), then read per tile. 0.5 when it cannot be read, which is what we used before.

static CGFloat gBackLum[8][8];
static BOOL gBackLumValid;
static CFTimeInterval gBackLumAt = -100.0;

static UIWindow *WindowBelow(UIWindow *top) {
    UIWindow *best = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w == top || w.hidden || w.alpha < 0.01) continue;
        if (w.windowLevel >= top.windowLevel) continue;
        if (!best || w.windowLevel > best.windowLevel) best = w;
    }
    return best;
}

static void CaptureBackdropLuminance(UIWindow *cc) {
    if (!cc) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - gBackLumAt < 1.0) return;   // once per open is enough, and it is not free
    gBackLumAt = now;
    gBackLumValid = NO;
    @try {
        UIWindow *below = WindowBelow(cc);
        if (!below || below.bounds.size.width < 1) return;
        UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
        fmt.scale = 1.0;
        fmt.opaque = YES;
        UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(8, 8) format:fmt];
        UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *c) {
            [below drawViewHierarchyInRect:CGRectMake(0, 0, 8, 8) afterScreenUpdates:NO];
        }];
        CGImageRef cg = img.CGImage;
        if (!cg) return;
        uint8_t px[8 * 8 * 4] = { 0 };
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(px, 8, 8, 8, 8 * 4, space, kCGImageAlphaNoneSkipLast);
        CGColorSpaceRelease(space);
        if (!ctx) return;
        CGContextDrawImage(ctx, CGRectMake(0, 0, 8, 8), cg);
        CGContextRelease(ctx);
        for (int y = 0; y < 8; y++) {
            for (int x = 0; x < 8; x++) {
                const uint8_t *p = px + (y * 8 + x) * 4;
                gBackLum[y][x] = (0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2]) / 255.0;
            }
        }
        gBackLumValid = YES;
    } @catch (__unused NSException *e) { gBackLumValid = NO; }
}

static CGFloat BackdropLuminanceFor(UIView *v) {
    if (!gBackLumValid || !v.window) return 0.5;
    CGSize ws = v.window.bounds.size;
    if (ws.width < 1 || ws.height < 1) return 0.5;
    CGRect r = [v convertRect:v.bounds toView:v.window];
    int x0 = (int)MAX(0.0, MIN(7.0, (r.origin.x / ws.width) * 8.0));
    int y0 = (int)MAX(0.0, MIN(7.0, (r.origin.y / ws.height) * 8.0));
    int x1 = (int)MAX(0.0, MIN(7.0, (CGRectGetMaxX(r) / ws.width) * 8.0));
    int y1 = (int)MAX(0.0, MIN(7.0, (CGRectGetMaxY(r) / ws.height) * 8.0));
    CGFloat sum = 0;
    int n = 0;
    for (int y = y0; y <= y1; y++) for (int x = x0; x <= x1; x++) { sum += gBackLum[y][x]; n++; }
    return n ? sum / (CGFloat)n : 0.5;
}

// MARK: - Styling -------------------------------------------------------------

typedef NS_ENUM(NSInteger, CCKind) {
    CCKindModuleFill,   // CCUIContentModuleBackgroundView – owns the glass fill
    CCKindModule,       // module cards / control templates (pills, tiles)
    CCKindContainer,    // module content container; also decorates expanded-menu views inside it
    CCKindRound,        // circular buttons (+, power, accessories)
    CCKindSlider,       // brightness / volume sliders
};

static const void *kSheenKey  = &kSheenKey;   // top sheen
static const void *kHotTLKey  = &kHotTLKey;   // corner highlight, top-left
static const void *kHotBRKey  = &kHotBRKey;   // corner highlight, bottom-right
static const void *kBlurKey   = &kBlurKey;    // optional extra blur view
static const void *kSigKey    = &kSigKey;
static const void *kStreakKey  = &kStreakKey;  // diagonal reflection band
static const void *kShadeKey   = &kShadeKey;   // top-lit sphere shading (circles)
static const void *kStyledKey = &kStyledKey; // set on views styled through a class hook
static const void *kMenuKey   = &kMenuKey;   // set on views decorated by the menu walk
static const void *kLastRKey  = &kLastRKey;  // corner radius we applied last
static const void *kSysRKey   = &kSysRKey;   // corner radius the system had set
static const void *kSysMasksKey = &kSysMasksKey;   // masksToBounds the system had
static const void *kSysCurveKey = &kSysCurveKey;   // cornerCurve the system had
static const void *kSysBgKey    = &kSysBgKey;      // backgroundColor the system had
static const void *kHookBusyKey = &kHookBusyKey;   // this view is already inside a style hook
static const void *kKindKey     = &kKindKey;       // the CCKind this view was styled as
static const void *kProfileKey  = &kProfileKey;    // the LGProfile chosen for it (diagnostics)
static const void *kOnFillKey   = &kOnFillKey;     // on a system on-fill: its stock backgroundColor
static const void *kSynthFillKey = &kSynthFillKey; // on a tile: our own fill view
static NSHashTable<UIView *> *gTracked;       // weak; used to restyle after a prefs change

static BOOL KindEnabled(CCKind kind) {
    switch (kind) {
        case CCKindModuleFill:
        case CCKindModule:
        case CCKindContainer: return gStyleModules;
        case CCKindRound:  return gStyleButtons;
        case CCKindSlider: return gStyleSliders;
    }
    return YES;
}

static CGFloat TargetRadius(CCKind kind, CGSize size) {
    CGFloat half = MIN(size.width, size.height) / 2.0;
    switch (kind) {
        case CCKindRound:  return half;
        case CCKindSlider: return gSliderCapsule ? half : MIN(half, gMaxRadius);
        default:           return MIN(half, gMaxRadius);
    }
}

static const void *kEdgesKey = &kEdgesKey;   // one 9-slice image: rim, bevel, dark outline, inner glow

static void HideDecor(UIView *v) {
    const void *keys[] = { kEdgesKey, kSheenKey, kHotTLKey, kHotBRKey, kStreakKey, kShadeKey };
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        CALayer *l = objc_getAssociatedObject(v, keys[i]);
        if (l && !l.hidden) l.hidden = YES;
    }
    UIView *blur = objc_getAssociatedObject(v, kBlurKey);
    blur.hidden = YES;
}

static CAGradientLayer *EnsureGradient(UIView *v, const void *key, NSString *name,
                                       CGFloat z, BOOL radial, BOOL want) {
    CAGradientLayer *l = objc_getAssociatedObject(v, key);
    if (want && !l) {
        l = [CAGradientLayer layer];
        l.name = name;
        l.zPosition = z;
        if (radial) l.type = kCAGradientLayerRadial;
        objc_setAssociatedObject(v, key, l, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (l && l.hidden == want) l.hidden = !want;
    if (want && l.superlayer != v.layer) [v.layer addSublayer:l];
    return l;
}

static UIColor *RimUI(CGFloat alpha) {
    return [gRimColor colorWithAlphaComponent:MAX(0.0, MIN(1.0, alpha))];
}

// Rim colour with a slight cool / warm fringe (glass chromatic dispersion).
static UIColor *RimUID(CGFloat alpha, int warm) {
    CGFloat r = 1, g = 1, b = 1, a = 1;
    [gRimColor getRed:&r green:&g blue:&b alpha:&a];
    CGFloat k = 0.30 * gDisp;
    CGFloat tr = warm > 0 ? 1.0 : 0.70;
    CGFloat tg = warm > 0 ? 0.82 : 0.90;
    CGFloat tb = warm > 0 ? 0.68 : 1.00;
    return [UIColor colorWithRed:r + (tr - r) * k green:g + (tg - g) * k blue:b + (tb - b) * k
                           alpha:MAX(0.0, MIN(1.0, alpha))];
}

// System appearance of the view (Control Center follows light/dark mode).
static BOOL IsDarkUI(UIView *v) {
    UIUserInterfaceStyle st = v.window.traitCollection.userInterfaceStyle;
    if (st == UIUserInterfaceStyleUnspecified) st = v.traitCollection.userInterfaceStyle;
    return st != UIUserInterfaceStyleLight;
}

// --- Edge image ---------------------------------------------------------------
// Everything that traces the glass outline is drawn ONCE into a tiny bitmap and shown
// through a single plain layer using a 9-slice (contentsCenter). That replaces five
// gradient layers with masks (offscreen passes every frame) per view, and resizing a
// module during the expand animation costs nothing: only the layer frame changes.

static void StrokeGradient(CGContextRef c, CGSize size, CGFloat radius, CGFloat inset, CGFloat width,
                           UIColor *c0, UIColor *c1, UIColor *c2, UIColor *c3, BOOL flip) {
    CGRect r = CGRectInset(CGRectMake(0, 0, size.width, size.height), inset + width / 2.0, inset + width / 2.0);
    if (r.size.width <= 0 || r.size.height <= 0) return;
    UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:r
                                                 cornerRadius:MAX(0.0, radius - inset - width / 2.0)];
    CGContextSaveGState(c);
    CGContextAddPath(c, p.CGPath);
    CGContextSetLineWidth(c, width);
    CGContextReplacePathWithStrokedPath(c);
    CGContextClip(c);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    NSArray *cols = @[(__bridge id)c0.CGColor, (__bridge id)c1.CGColor,
                      (__bridge id)c2.CGColor, (__bridge id)c3.CGColor];
    const CGFloat loc[4] = { 0.0, 0.30, 0.70, 1.0 };
    CGGradientRef g = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)cols, loc);
    CGPoint s = flip ? CGPointMake(size.width, 0) : CGPointZero;
    CGPoint e = flip ? CGPointMake(0, size.height) : CGPointMake(size.width, size.height);
    CGContextDrawLinearGradient(c, g, s, e, kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(g);
    CGColorSpaceRelease(cs);
    CGContextRestoreGState(c);
}

static NSCache<NSString *, UIImage *> *gEdgeCache;
static NSUInteger gEdgeCacheGen;

static UIImage *EdgeImage(CGFloat cap, CGFloat radius, BOOL dark, CGFloat scale) {
    if (!gEdgeCache) gEdgeCache = [NSCache new];
    if (gEdgeCacheGen != gGeneration) { [gEdgeCache removeAllObjects]; gEdgeCacheGen = gGeneration; }
    BOOL contrast = IncreaseContrastOn();   // part of the cache key: the same shape, a stronger edge
    NSString *key = [NSString stringWithFormat:@"%.0f|%.1f|%d|%.0f|%d", cap, radius, dark, scale, contrast];
    UIImage *img = [gEdgeCache objectForKey:key];
    if (img) return img;

    CGFloat S = 2.0 * cap + 2.0;
    CGSize size = CGSizeMake(S, S);
    CGFloat rs   = gReflect * 2.0;
    CGFloat rimE = MIN(1.0, gRim * gRimMul) * (contrast ? 1.35 : 1.0);
    CGFloat pk   = MIN(1.0, 0.6 + 0.4 * rs);
    BOOL wantOutline = gEdgeDark > 0.001;
    CGFloat rimInset = wantOutline ? 0.7 : 0.0;
    CGFloat bw = MIN(7.0, MAX(3.0, radius * 0.2));

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.scale = scale;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *rend = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
    img = [rend imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        UIColor *clear = [UIColor colorWithWhite:1.0 alpha:0.0];

        if (gInner > 0.02) {   // soft inner glow: stacked wide strokes, uniform all round
            for (int i = 1; i <= 3; i++) {
                UIColor *g = RimUI(0.05 * gInner * (4 - i));
                StrokeGradient(c, size, radius, rimInset, 2.5 * i, g, g, g, g, NO);
            }
        }
        if (gRim > 0.001) {
            // Thin specular line, strong at two opposite corners and nearly clear between ...
            StrokeGradient(c, size, radius, rimInset, gRimWidth,
                           RimUID(0.9 * pk * rimE, -1), RimUI(0.11 * rimE), RimUI(0.11 * rimE), RimUID(0.75 * pk * rimE, 1), NO);
            // ... backed by wider soft strokes so the highlight fades inward like a bevel.
            StrokeGradient(c, size, radius, rimInset, MAX(1.6, bw * 0.3),
                           RimUID(0.20 * rs * rimE, -1), clear, clear, RimUID(0.16 * rs * rimE, 1), NO);
            // iOS 27: broad, soft dispersion bevel. Warm at the top-left / top-right, cool blue-teal at the
            // bottom-right / bottom-left, fading inward, so the whole edge glows instead of a hairline.
            CGFloat dk = 0.4 + 0.6 * MIN(1.0, gDisp);
            CGFloat da = MIN(0.4, 0.20 * rimE * rs * dk);
            CGFloat dw = MIN(4.0, MAX(2.5, radius * 0.12));
            // iOS 27.2 reference: lavender at the top-left, cyan-blue at the bottom-right, teal at the top-right, blue at the bottom-left
            UIColor *warm = [UIColor colorWithRed:0.82 green:0.70 blue:1.0 alpha:da];
            UIColor *cool = [UIColor colorWithRed:0.50 green:0.80 blue:1.0 alpha:da];
            UIColor *warmS = [UIColor colorWithRed:0.58 green:0.92 blue:0.84 alpha:da * 0.6];
            UIColor *coolS = [UIColor colorWithRed:0.56 green:0.72 blue:1.0 alpha:da * 0.6];
            StrokeGradient(c, size, radius, rimInset, dw, warm, clear, clear, cool, NO);
            StrokeGradient(c, size, radius, rimInset, dw, warmS, clear, clear, coolS, YES);
            // the reference has no second hairline inside the first, only a faint refracted trace of it
        }
        if (wantOutline) {
            UIColor *o = [UIColor colorWithWhite:0.0 alpha:MIN(0.8, (dark ? 0.38 : 0.20) * gEdgeDark * (contrast ? 1.5 : 1.0))];
            StrokeGradient(c, size, radius, 0.0, 0.7, o, o, o, o, NO);
        }
    }];
    [gEdgeCache setObject:img forKey:key];
    return img;
}

// Liquid-glass decoration, modelled on the iOS 26 reference and the iOS 27 refinements
// ("darkened edge" + "brighter specular highlights"). Cheap by construction: one image
// layer for all edge work plus a few unmasked gradient layers (the view itself already
// clips to its rounded shape).
// Nested views of one shape (container, button module, menu wrapper) must not each draw a rim:
// that is the double edge. Only the outermost one keeps its decoration.
static BOOL SameShapeAncestorDecorated(UIView *v, CGRect b) {
    UIView *a = v.superview;
    for (int i = 0; a && i < 5; i++, a = a.superview) {
        CALayer *e = objc_getAssociatedObject(a, kEdgesKey);
        if (!e || e.hidden || e.superlayer != a.layer) continue;
        CGRect r = [v convertRect:b toView:a];
        CGSize as = a.bounds.size;
        if (fabs(r.size.width - as.width) <= 16.0 && fabs(r.size.height - as.height) <= 16.0 &&
            fabs(r.origin.x) <= 16.0 && fabs(r.origin.y) <= 16.0) return YES;
    }
    return NO;
}

static void ApplyDecor(UIView *v, CGRect b, CGFloat radius) {
    if (SameShapeAncestorDecorated(v, b)) { HideDecor(v); return; }
    BOOL dark = IsDarkUI(v);
    CGFloat shortSide = MIN(b.size.width, b.size.height);
    BOOL circle = fabs(b.size.width - b.size.height) < 2.0 && radius >= shortSide / 2.0 - 0.5;
    CGFloat rs = gReflect * 2.0;                 // 0…2, 1 = neutral

    // Low Power: the sheen, the corner glints and the diagonal streak are each a layer for decoration
    // only, so they are the first thing to drop.
    BOOL lowPower = LowPowerOn();
    BOOL wantEdges  = gRim > 0.001 || gEdgeDark > 0.001 || gInner > 0.02;
    BOOL wantSheen  = !lowPower && gSheen > 0.001 && gReflect > 0.001;
    BOOL wantHot    = !lowPower && gHot > 0.001 && gReflect > 0.001;
    BOOL wantStreak = !lowPower && gReflect > 0.001;
    BOOL wantShade  = circle && !lowPower;

    CGFloat cap = MAX(1.0, MIN(ceil(radius) + 2.0, floor(shortSide / 2.0)));
    CGFloat scale = v.window.screen.scale > 0 ? v.window.screen.scale : UIScreen.mainScreen.scale;

    CALayer *edges = objc_getAssociatedObject(v, kEdgesKey);
    if (wantEdges && !edges) {
        edges = [CALayer layer];
        edges.name = @"IOS26CCEdges";
        edges.zPosition = 1000;
        edges.magnificationFilter = kCAFilterNearest;
        objc_setAssociatedObject(v, kEdgesKey, edges, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (edges && edges.hidden == wantEdges) edges.hidden = !wantEdges;
    if (wantEdges && edges.superlayer != v.layer) [v.layer addSublayer:edges];

    CAGradientLayer *hotTL  = EnsureGradient(v, kHotTLKey,  @"IOS26CCHotTL",  910, YES, wantHot);
    CAGradientLayer *hotBR  = EnsureGradient(v, kHotBRKey,  @"IOS26CCHotBR",  910, YES, wantHot);
    CAGradientLayer *streak = EnsureGradient(v, kStreakKey, @"IOS26CCStreak", 905, NO,  wantStreak);
    CAGradientLayer *sheen  = EnsureGradient(v, kSheenKey,  @"IOS26CCSheen",  900, NO,  wantSheen);
    CAGradientLayer *shade  = EnsureGradient(v, kShadeKey,  @"IOS26CCShade",  880, NO,  wantShade);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    // geometry: frames only (cheap, runs every layout)
    CALayer *all[] = { edges, hotTL, hotBR, streak, sheen, shade };
    for (size_t i = 0; i < sizeof(all) / sizeof(all[0]); i++) {
        CALayer *l = all[i];
        if (l && !l.hidden && !CGRectEqualToRect(l.frame, b)) l.frame = b;
    }

    // style: only when a setting, the appearance or the corner shape changed
    NSString *sig = [NSString stringWithFormat:@"%lu|%d|%d|%.0f|%.1f",
                     (unsigned long)gGeneration, dark, circle, cap, radius];
    if (![objc_getAssociatedObject(v, kSigKey) isEqualToString:sig]) {
        objc_setAssociatedObject(v, kSigKey, sig, OBJC_ASSOCIATION_COPY_NONATOMIC);

        if (wantEdges) {
            UIImage *img = EdgeImage(cap, MIN(radius, cap), dark, scale);
            edges.contents = (__bridge id)img.CGImage;
            edges.contentsScale = scale;
            CGFloat S = 2.0 * cap + 2.0;
            edges.contentsCenter = CGRectMake(cap / S, cap / S, 2.0 / S, 2.0 / S);
        }

        if (wantShade) {
            shade.startPoint = CGPointMake(0.5, 0.0);
            shade.endPoint = CGPointMake(0.5, 1.0);
            shade.locations = @[@0.0, @0.45, @1.0];
            shade.colors = @[
                (__bridge id)[UIColor colorWithWhite:0.0 alpha:0.0].CGColor,
                (__bridge id)[UIColor colorWithWhite:0.0 alpha:0.0].CGColor,
                (__bridge id)[UIColor colorWithWhite:0.0 alpha:dark ? 0.20 : 0.09].CGColor,
            ];
        }
        if (wantSheen) {
            CGFloat a = MIN(0.3, gSheen * rs * (dark ? 0.8 : 1.3));
            sheen.startPoint = CGPointMake(0.5, 0.0);
            sheen.endPoint = CGPointMake(0.5, 1.0);
            sheen.locations = @[@0.0, @0.45, @1.0];
            sheen.colors = @[
                (__bridge id)[UIColor colorWithWhite:1.0 alpha:a].CGColor,
                (__bridge id)[UIColor colorWithWhite:1.0 alpha:a * 0.25].CGColor,
                (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
            ];
        }
        if (wantStreak) {
            CGFloat a = MIN(0.30, (dark ? 0.05 : 0.14) * rs);
            CGColorRef clear = [UIColor colorWithWhite:1.0 alpha:0.0].CGColor;
            streak.startPoint = CGPointMake(0.0, 0.0);
            streak.endPoint = CGPointMake(1.0, 1.0);
            streak.locations = @[@0.0, @0.06, @0.16, @0.30, @1.0];
            streak.colors = @[(__bridge id)clear, (__bridge id)clear,
                              (__bridge id)[UIColor colorWithWhite:1.0 alpha:a].CGColor,
                              (__bridge id)clear, (__bridge id)clear];
        }
        if (wantHot) {
            CGFloat a = MIN(0.7, gHot * (dark ? 1.8 : 2.5) * rs * (circle ? 1.7 : 1.0));
            NSArray *cols = @[(__bridge id)[UIColor colorWithWhite:1.0 alpha:a].CGColor,
                              (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor];
            hotTL.locations = @[@0.0, @1.0];
            hotTL.colors = cols;
            hotTL.startPoint = CGPointMake(0.06, 0.04);
            hotTL.endPoint = CGPointMake(0.62, 0.70);
            hotBR.locations = @[@0.0, @1.0];
            hotBR.colors = cols;
            hotBR.startPoint = CGPointMake(0.94, 0.96);
            hotBR.endPoint = CGPointMake(0.38, 0.30);
        }
    }

    [CATransaction commit];
}

// Optional extra backdrop blur behind the module fill (experimental, off by default).
static void ApplyExtraBlur(UIView *v, CGRect b) {
    UIVisualEffectView *blur = objc_getAssociatedObject(v, kBlurKey);
    if (!gExtraBlur || !gIsoBlur || ReduceTransparencyOn()) {
        blur.hidden = YES;
        return;
    }
    if (!blur) {
        blur = [[UIVisualEffectView alloc] initWithEffect:
                [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
        blur.userInteractionEnabled = NO;
        objc_setAssociatedObject(v, kBlurKey, blur, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    blur.hidden = NO;
    if (blur.superview != v) [v insertSubview:blur atIndex:0];
    if (!CGRectEqualToRect(blur.frame, b)) blur.frame = b;
}

// MARK: - Material clarity (iOS 27-style Clear ↔ Tinted) ----------------------

// Dims the system blur material behind a view so the wallpaper shows through.
static const void *kGlassKey = &kGlassKey;   // on the MTMaterialView: its XCGlassView
static const void *kPageHidKey = &kPageHidKey;     // on a page-sized material we hid (no glass for it)
static const void *kOwnGlassKey = &kOwnGlassKey;   // on a tile / slider with no material of its own: our glass
static const void *kTrackClearKey = &kTrackClearKey; // on a slider's dark track view: the colour we cleared
static void SetMaterialAlpha(UIView *root, int depth, CGFloat alpha) {
    if (depth > 3) return;
    for (UIView *s in root.subviews) {
        if ([NSStringFromClass(s.class) containsString:@"MaterialView"]) {
            if (fabs(s.alpha - alpha) > 0.001) s.alpha = alpha;
            continue;
        }
        SetMaterialAlpha(s, depth + 1, alpha);
    }
}

// MARK: - Expanded menus ------------------------------------------------------

// The expanded volume slider is just the pill; the wide MRUVolumeView around it must stay bare.
static BOOL IsVolumeHost(UIView *v) {
    NSString *n = NSStringFromClass(v.class);
    return [n hasPrefix:@"MRU"] && [n containsString:@"Volume"];
}

static void ApplyMenuDecor(UIView *v) {
    if (!v.window) return;
    if (IsVolumeHost(v)) { if (objc_getAssociatedObject(v, kMenuKey)) HideDecor(v); return; }
    if ([NSStringFromClass(v.class) hasPrefix:@"XC"]) return;   // our own glass / fill views never get a rim
    CALayer *layer = v.layer;
    CGRect b = v.bounds;
    // Only views the system already rounds AND clips: the glass layers stay inside the shape.
    BOOL candidate = layer.masksToBounds && layer.cornerRadius >= 10.0 &&
                     b.size.width >= 36.0 && b.size.height >= 36.0 && !v.hidden && v.alpha > 0.01;
    BOOL flagged = objc_getAssociatedObject(v, kMenuKey) != nil;

    if (!gEnabled || !gStyleMenus || !candidate) {
        if (flagged) HideDecor(v);
        return;
    }
    objc_setAssociatedObject(v, kMenuKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApplyDecor(v, b, MIN(layer.cornerRadius, MIN(b.size.width, b.size.height) / 2.0));

    if (!gTracked) gTracked = [NSHashTable weakObjectsHashTable];
    [gTracked addObject:v];
}

static void WalkMenus(UIView *root, int depth, int *budget) {
    if (depth > 10) return;
    for (UIView *s in root.subviews) {
        if (*budget <= 0) return;
        (*budget)--;
        if (IsVolumeHost(s)) { ApplyMenuDecor(s); continue; }
        if (!objc_getAssociatedObject(s, kStyledKey)) ApplyMenuDecor(s);
        WalkMenus(s, depth + 1, budget);
    }
}

static void DecorateMenus(UIView *container) {
    int budget = 250;
    WalkMenus(container, 0, &budget);
}

// MARK: - Control Center background blur -------------------------------------

// The full-screen blur/dim behind the whole Control Center is a separate view from
// the module materials. Find large material/backdrop-like views in the window and
// scale their alpha with the "bgBlur" slider (1 = stock).
// The wallpaper blur is a CAFilter (gaussianBlur) inside the full-screen MTMaterialView's
// layer tree. Scale its radius with the slider (1 = stock, 0 = sharp wallpaper).
// The wallpaper blur of the Control Center is the full-screen MTMaterialView. Editing the
// radius of its own filters has no effect (the material re-applies its recipe), so with the
// slider below "stock" that view is hidden and a plain CABackdropLayer with a stock
// gaussianBlur filter takes its place. Its alpha follows the hidden material, so the
// open/close fade stays as the system drives it.
static const void *kBlurViewKey = &kBlurViewKey;   // on the MTMaterialView: its XCBlurView

@interface XCBlurView : UIView
- (void)updateRadius:(CGFloat)radius dark:(BOOL)dark;
@end

@implementation XCBlurView {
    CGFloat _radius;
    BOOL _set;
}
+ (Class)layerClass { return NSClassFromString(@"CABackdropLayer") ?: [CALayer class]; }
- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (self) { self.userInteractionEnabled = NO; self.opaque = NO; }
    return self;
}
- (void)updateRadius:(CGFloat)radius dark:(BOOL)dark {
    CALayer *layer = self.layer;
    Class backdrop = NSClassFromString(@"CABackdropLayer");
    Class filterCls = NSClassFromString(@"CAFilter");
    if (!backdrop || !filterCls || ![layer isKindOfClass:backdrop]) return;
    if (_set && fabs(radius - _radius) < 0.3) return;
    _set = YES; _radius = radius;
    @try {
        [layer setValue:@NO forKey:@"layerUsesCoreImageFilters"];
        [layer setValue:@0.25 forKey:@"scale"];
        [layer setValue:@YES forKey:@"ignoresScreenClip"];
        [layer setValue:[NSString stringWithFormat:@"xenon.bgblur.%p", self] forKey:@"groupName"];
        id f = ((id (*)(Class, SEL, NSString *))objc_msgSend)(filterCls, NSSelectorFromString(@"filterWithType:"), @"gaussianBlur");
        [f setValue:@(radius) forKey:@"inputRadius"];
        [f setValue:@YES forKey:@"inputNormalizeEdges"];
        layer.filters = @[f];
    } @catch (__unused NSException *e) {}
    // stock material also dims slightly
    CGFloat dim = 0.22 * MIN(1.0, radius / 30.0);
    self.backgroundColor = dark ? [UIColor colorWithWhite:0.0 alpha:dim] : [UIColor colorWithWhite:1.0 alpha:dim * 0.6];
}
@end

static void RemoveBgBlur(UIView *mat) {
    XCBlurView *b = objc_getAssociatedObject(mat, kBlurViewKey);
    if (!b) return;
    [b removeFromSuperview];
    objc_setAssociatedObject(mat, kBlurViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    mat.hidden = NO;
}

// The page behind Control Center is dimmed hard on the reference: a white screen comes out at 88/255 and a
// black one at 12/255 (about 0.29 x the screen + 12), which is also what keeps bright widgets from
// washing the tiles out. A black layer and a faint white one on top of the backdrop make that.
static const void *kDimKey = &kDimKey;   // on the MTMaterialView: our dim view

static void RemoveBgDim(UIView *mat) {
    UIView *d = objc_getAssociatedObject(mat, kDimKey);
    if (!d) return;
    [d removeFromSuperview];
    objc_setAssociatedObject(mat, kDimKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApplyBgDim(UIView *s) {
    UIView *parent = s.superview;
    if (!gEnabled || gBgDim < 0.01 || !parent || !IsDarkUI(s)) { RemoveBgDim(s); return; }
    UIView *d = objc_getAssociatedObject(s, kDimKey);
    if (!d) {
        d = [[UIView alloc] initWithFrame:s.frame];
        d.userInteractionEnabled = NO;
        UIView *w = [[UIView alloc] initWithFrame:d.bounds];
        w.userInteractionEnabled = NO;
        w.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        w.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.05];
        [d addSubview:w];
        objc_setAssociatedObject(s, kDimKey, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    d.backgroundColor = [UIColor colorWithWhite:0.0 alpha:gBgDim];
    UIView *anchor = objc_getAssociatedObject(s, kBlurViewKey) ?: s;
    NSArray *sib = parent.subviews;
    NSUInteger ai = [sib indexOfObject:anchor], di = [sib indexOfObject:d];
    if (d.superview != parent || di == NSNotFound || ai == NSNotFound || di != ai + 1) [parent insertSubview:d aboveSubview:anchor];
    if (!CGRectEqualToRect(d.frame, s.frame)) d.frame = s.frame;
    if (fabs(d.alpha - s.alpha) > 0.001) d.alpha = s.alpha;
}

static void ScaleBackdrop(UIView *s) {
    ApplyBgDim(s);
    XCBlurView *b = objc_getAssociatedObject(s, kBlurViewKey);
    UIView *parent = s.superview;
    if (!gEnabled || gBgBlur >= 0.999 || !parent) { RemoveBgBlur(s); return; }
    if (!b) {
        b = [[XCBlurView alloc] initWithFrame:s.frame];
        objc_setAssociatedObject(s, kBlurViewKey, b, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (b.superview != parent) [parent insertSubview:b aboveSubview:s];
    if (!CGRectEqualToRect(b.frame, s.frame)) b.frame = s.frame;
    if (fabs(b.alpha - s.alpha) > 0.001) b.alpha = s.alpha;
    [b updateRadius:30.0 * gBgBlur dark:IsDarkUI(s)];
    if (!s.hidden) s.hidden = YES;
}

static void (*orig_setAlpha)(UIView *, SEL, CGFloat);
static void hook_setAlpha(UIView *self, SEL _cmd, CGFloat a) {
    orig_setAlpha(self, _cmd, a);
    XCBlurView *b = objc_getAssociatedObject(self, kBlurViewKey);
    if (b) b.alpha = a;
    UIView *d = objc_getAssociatedObject(self, kDimKey);
    if (d) d.alpha = a;
}


static BOOL IsBgCandidate(UIView *s, UIWindow *w) {
    CGSize ws = w.bounds.size;
    if (s.bounds.size.width < ws.width * 0.9 || s.bounds.size.height < ws.height * 0.9) return NO;
    NSString *n = NSStringFromClass(s.class);
    if ([n hasPrefix:@"CCUI"] || [n containsString:@"IconList"] || [n containsString:@"ScrollView"]) return NO;
    if ([n containsString:@"Material"] || [n containsString:@"Backdrop"] || [n containsString:@"Blur"] ||
        [n containsString:@"Background"] || [n isEqualToString:@"UIVisualEffectView"]) return YES;
    return [NSStringFromClass(s.layer.class) containsString:@"Backdrop"];
}

// Only near-full-screen views can be (or contain) the backdrop, so small subtrees
// (modules, icons) are never entered and the walk stays cheap.
static void WalkBg(UIView *root, UIWindow *w, int depth, int *budget, NSMutableString *dump) {
    if (depth > 10 || *budget <= 0) return;
    CGSize ws = w.bounds.size;
    for (UIView *s in root.subviews) {
        if ((*budget)-- <= 0) return;
        BOOL big = s.bounds.size.width >= ws.width * 0.9 && s.bounds.size.height >= ws.height * 0.9;
        if (dump) {
            [dump appendFormat:@"%*s%@ [layer %@] %@ a=%.2f hidden=%d subviews=%lu%@\n", depth * 2, "",
             NSStringFromClass(s.class), NSStringFromClass(s.layer.class), NSStringFromCGRect(s.frame),
             s.alpha, s.hidden, (unsigned long)s.subviews.count, big ? @"" : @" (not entered)"];
        }
        if (!big) continue;
        if (IsBgCandidate(s, w)) {
            static Class mt; static dispatch_once_t o; dispatch_once(&o, ^{ mt = NSClassFromString(@"MTMaterialView"); });
            if (mt && s.class == mt) ScaleBackdrop(s);
            continue;
        }
        WalkBg(s, w, depth + 1, budget, dump);
    }
}

static void ApplyBackground(UIView *v) {
    UIWindow *w = v.window;
    if (!w || w.hidden || w.alpha < 0.01) return;   // nothing visible, nothing to blur
    static CFTimeInterval last = 0;
    static NSUInteger lastGen = (NSUInteger)-1, dumpGen = (NSUInteger)-1;
    CFTimeInterval now = CACurrentMediaTime();
    if (lastGen == gGeneration && now - last < 0.25) return;
    last = now; lastGen = gGeneration;

    NSMutableString *dump = nil;
    if (gDebugDump && dumpGen != gGeneration) {
        dumpGen = gGeneration;
        dump = [NSMutableString stringWithFormat:@"window %@ %@\n", NSStringFromClass(w.class),
                NSStringFromCGRect(w.bounds)];
    }
    int budget = 1500;
    double t0 = PerfNowMS();
    WalkBg(w, w, 0, &budget, dump);
    PerfAdd("background", PerfNowMS() - t0);
    if (dump) LGWriteDiagnostic(@"ios26ccstyle-dump.txt", dump);
}

// MARK: - Refraction glass (rendered by the backboardd component) --------------

// A CABackdropLayer whose filter type is routed, inside the render server, to a Metal
// shader that refracts what is behind it (see backboardd/). The system MTMaterialView
// it replaces is hidden. The renderer announces itself with a marker file; without it
// the plain CALayer look is used.

static BOOL GlassRendererReady(void) {
    static CFTimeInterval last = -100.0;
    static BOOL ready = NO;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - last > 2.0) {
        last = now;
        ready = LGDiagnosticsMarkerExists(@"xenonglass-ready");
    }
    return ready;
}

static NSHashTable<UIView *> *gGlassViews;
static BOOL gGlassObserverSet;

@interface XCGlassView : UIView
@property (nonatomic) CGFloat glassRadius;
@property (nonatomic) BOOL glassDark;
- (void)attachFilter;
- (void)reloadFilter;
@end

@implementation XCGlassView {
    BOOL _configured;
    BOOL _variant;
    CGFloat _appliedScale;
    NSInteger _lastStep;
    NSString *_attachedType;
    NSString *_group;
}

+ (Class)layerClass { return NSClassFromString(@"CABackdropLayer") ?: [CALayer class]; }

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    static unsigned counter = 0;
    static uint32_t salt = 0;
    if (!salt) salt = arc4random();
    _lastStep = -1;
    _group = [NSString stringWithFormat:@"xenon.liquidglass.p%d.%08x.g%u", getpid(), salt, ++counter];
    self.userInteractionEnabled = NO;
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    return self;
}

- (void)attachFilter {
    CALayer *layer = self.layer;
    Class backdrop = NSClassFromString(@"CABackdropLayer");
    CGSize sz = self.bounds.size;
    if (!backdrop || ![layer isKindOfClass:backdrop] || sz.width < 1.0 || sz.height < 1.0) return;
    @try {
        if (!_configured) {
            [layer setValue:@NO forKey:@"layerUsesCoreImageFilters"];
            [layer setValue:@NO forKey:@"windowServerAware"];
            [layer setValue:_group forKey:@"groupName"];
            [layer setValue:@"xenon.liquidglass" forKey:@"groupNamespace"];
            [layer setValue:@YES forKey:@"ignoresScreenClip"];
            _configured = YES;
        }
        CGFloat scale = sqrt(8000.0 / MAX(1.0, sz.width * sz.height));
        scale = MIN(0.75, MAX(0.25, scale));
        if (fabs(scale - _appliedScale) > 0.02) {
            [layer setValue:@(scale) forKey:@"scale"];
            _appliedScale = scale;
        }

        CGFloat shortest = MIN(sz.width, sz.height);
        CGFloat ratio = shortest > 0.0 ? self.glassRadius / shortest : 0.0;
        CGFloat exact = MAX(0.0, MIN(0.5, ratio)) * 32.0;
        NSInteger step = (NSInteger)llround(exact);
        if (_lastStep >= 0 && fabs(exact - (CGFloat)_lastStep) < 0.75) step = _lastStep;
        _lastStep = step;

        NSMutableString *type = [NSMutableString stringWithFormat:@"xenon.liquidglass.cc.r%ld", (long)step];
        if (self.glassDark) [type appendString:@".dark"];
        if (_variant) [type appendString:@".refresh"];
        if ([_attachedType isEqualToString:type] && layer.filters.count == 1) return;

        Class filterCls = NSClassFromString(@"CAFilter");
        if (!filterCls) return;
        id filter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
            filterCls, NSSelectorFromString(@"filterWithType:"), type);
        if (!filter) return;
        layer.filters = @[filter];   // no radius here: the shader blurs the backdrop itself
        _attachedType = [type copy];
    } @catch (__unused NSException *e) {}
}

// Render parameters changed in backboardd: flip to the ".refresh" twin atom so the
// render server rebuilds the pass with the new numbers.
- (void)reloadFilter {
    _variant = !_variant;
    _attachedType = nil;
    [self attachFilter];
}

@end

static void GlassParametersReloaded(CFNotificationCenterRef c, void *o, CFStringRef n,
                                    const void *obj, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (XCGlassView *g in gGlassViews.allObjects) [g reloadFilter];
        [CATransaction commit];
    });
}

static BOOL IsExactMaterial(UIView *s) {
    static Class mt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mt = NSClassFromString(@"MTMaterialView"); });
    return mt && s.class == mt;
}

static void RemoveGlass(UIView *mat) {
    XCGlassView *g = objc_getAssociatedObject(mat, kGlassKey);
    if (!g) return;
    [g removeFromSuperview];
    objc_setAssociatedObject(mat, kGlassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    mat.hidden = NO;
}

static void SyncGlassIn(UIView *root, BOOL want, CGFloat radius, BOOL dark, int depth) {
    if (depth > 2) return;
    NSString *rn = NSStringFromClass(root.class);
    if ([rn hasPrefix:@"MRU"] && ([rn containsString:@"Volume"] || [rn containsString:@"Artwork"])) want = NO;   // the empty-artwork placeholder keeps its stock look
    for (UIView *s in [root.subviews copy]) {
        if ([s isKindOfClass:XCGlassView.class]) continue;
        if (IsExactMaterial(s)) {
            if (!want && objc_getAssociatedObject(s, kPageHidKey)) { s.hidden = NO; objc_setAssociatedObject(s, kPageHidKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
            // A page-high material is the backdrop the tiles of a page sit on, not a tile: glass on it is the
            // extra pane behind the connectivity tiles. The tiles carry their own glass.
            CGFloat wh = root.window ? root.window.bounds.size.height : 0.0;
            if (want && wh > 1.0 && s.bounds.size.height > wh * 0.7) {
                RemoveGlass(s);
                if (!s.hidden) s.hidden = YES;
                objc_setAssociatedObject(s, kPageHidKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                continue;
            }
            if (!want || s.bounds.size.width < 30.0 || s.bounds.size.height < 30.0) { RemoveGlass(s); continue; }
            XCGlassView *g = objc_getAssociatedObject(s, kGlassKey);
            if (!g) {
                g = [[XCGlassView alloc] initWithFrame:s.frame];
                objc_setAssociatedObject(s, kGlassKey, g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (!gGlassViews) gGlassViews = [NSHashTable weakObjectsHashTable];
                [gGlassViews addObject:g];
                if (!gGlassObserverSet) {
                    gGlassObserverSet = YES;
                    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                        GlassParametersReloaded, CFSTR("xenon.liquidglass/ParametersReloaded"),
                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
                }
            }
            // keep the glass directly above its material: CCUI re-inserts views while modules
            // expand and collapse, and a glass left above the on-fill hides the toggle's fill
            NSArray *sib = root.subviews;
            NSUInteger si = [sib indexOfObject:s], gi = [sib indexOfObject:g];
            if (g.superview != root || gi == NSNotFound || gi != si + 1) [root insertSubview:g aboveSubview:s];
            if (!CGRectEqualToRect(g.frame, s.frame)) g.frame = s.frame;
            g.layer.cornerCurve = kCACornerCurveContinuous;
            g.layer.cornerRadius = radius;
            g.layer.masksToBounds = YES;
            g.glassRadius = radius;
            g.glassDark = dark;
            // base tint on the glass itself (the stock background view is alpha 0): a light veil, as on the
            // reference, where an off tile is clearly lighter and more vivid than the page around it.
            g.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.01 + 0.05 * gGlass];
            [g attachFilter];
            if (!s.hidden) s.hidden = YES;
            continue;
        }
        if ([NSStringFromClass(s.class) containsString:@"Slider"]) continue;
        SyncGlassIn(s, want, radius, dark, depth + 1);
    }
}

// An expanded module (Now Playing, volume, menus) is one big panel. Its glass is made for the collapsed
// tile (the Now Playing background is 612 x 299 and ends half way down the expanded 321 x 534 card), so
// the panel gets a glass of its own over its full size, behind the content, and the tile glass inside
// it steps aside: one look with the tiles.
static const void *kPanelGlassKey = &kPanelGlassKey;
static const void *kPanelHidKey   = &kPanelHidKey;

static void HideInnerGlass(UIView *root, UIView *keep, BOOL hide, int depth) {
    if (depth > 5) return;
    for (UIView *s in root.subviews) {
        if (s == keep) continue;
        if ([s isKindOfClass:XCGlassView.class]) {
            if (hide && !s.hidden) { s.hidden = YES; objc_setAssociatedObject(s, kPanelHidKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
            else if (!hide && objc_getAssociatedObject(s, kPanelHidKey)) { s.hidden = NO; objc_setAssociatedObject(s, kPanelHidKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
            continue;
        }
        if (s.subviews.count && s.bounds.size.width * s.bounds.size.height > 400) HideInnerGlass(s, keep, hide, depth + 1);
    }
}

// The card of an expanded module: the shallowest view the system rounds and clips that is big enough to be a
// panel (Now Playing's 299 x 534 card). The container around it can be page-high and holds other things
// (the connectivity page's tiles have glass of their own), so it is not the card.
static UIView *FindPanelCard(UIView *root, int depth) {
    for (UIView *s in root.subviews) {
        if ([s isKindOfClass:XCGlassView.class] || s.hidden || s.alpha < 0.9) continue;   // (the faded artwork blur is no card)
        CGSize z = s.bounds.size;
        if (s.layer.masksToBounds && s.layer.cornerRadius >= 14.0 && z.width >= 200.0 && z.height >= 240.0 && z.width < 400.0) return s;
        if (depth < 5) { UIView *r = FindPanelCard(s, depth + 1); if (r) return r; }
    }
    return nil;
}

static void SyncPanelGlass(UIView *v, CGFloat radius, BOOL dark, BOOL want) {
    XCGlassView *pg = objc_getAssociatedObject(v, kPanelGlassKey);
    UIView *card = nil;
    BOOL fullGlass = NO;   // a glass that already covers the whole panel (the volume panel's)
    CGSize sz = v.bounds.size;
    if (want && sz.height > 240.0 && MIN(sz.width, sz.height) > 200.0) {
        for (UIView *s in v.subviews) {
            if (s != pg && [s isKindOfClass:XCGlassView.class] && CGRectEqualToRect(s.frame, v.bounds)) fullGlass = YES;
        }
        if (!fullGlass) card = FindPanelCard(v, 0);
    }
    if (!card) {
        if (pg) { [pg removeFromSuperview]; objc_setAssociatedObject(v, kPanelGlassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
        if (!(want && sz.height > 240.0 && MIN(sz.width, sz.height) > 200.0)) HideInnerGlass(v, nil, NO, 0);
        return;
    }
    if (!pg) {
        pg = [[XCGlassView alloc] initWithFrame:card.bounds];
        objc_setAssociatedObject(v, kPanelGlassKey, pg, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!gGlassViews) gGlassViews = [NSHashTable weakObjectsHashTable];
        [gGlassViews addObject:pg];
    }
    CGFloat r = MIN(card.layer.cornerRadius, MIN(card.bounds.size.width, card.bounds.size.height) / 2.0);
    if (pg.superview != card || [card.subviews indexOfObject:pg] != 0) [card insertSubview:pg atIndex:0];
    if (!CGRectEqualToRect(pg.frame, card.bounds)) pg.frame = card.bounds;
    pg.layer.cornerCurve = kCACornerCurveContinuous;
    pg.layer.cornerRadius = r;
    pg.layer.masksToBounds = YES;
    pg.glassRadius = r;
    pg.glassDark = dark;
    pg.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.01 + 0.05 * gGlass];
    [pg attachFilter];
    HideInnerGlass(v, pg, YES, 0);
}

// Some tiles have no material of their own (Flashlight and the other controls on a shared page), and the
// slider track is a plain dark view: both stayed black with no tint. They get a glass of their own at the
// bottom of the view, with the same veil as every other tile.
static BOOL SubtreeHasGlass(UIView *root, UIView *skip, int depth) {
    if (depth > 2) return NO;
    for (UIView *s in root.subviews) {
        if (s == skip) continue;
        if ([s isKindOfClass:XCGlassView.class]) { if (!s.hidden) return YES; continue; }
        if (SubtreeHasGlass(s, skip, depth + 1)) return YES;
    }
    return NO;
}

// A glass of the tile's own size behind it, on the same level or higher up (the single-tile modules keep
// theirs on the container).
static BOOL AncestorGlassCovers(UIView *v) {
    UIView *a = v.superview;
    CGSize vs = v.bounds.size;
    for (int i = 0; a && i < 4; i++, a = a.superview) {
        for (UIView *s in a.subviews) {
            if (![s isKindOfClass:XCGlassView.class] || s.hidden) continue;
            CGRect r = [v convertRect:s.bounds fromView:s];
            if (fabs(r.size.width - vs.width) <= 10.0 && fabs(r.size.height - vs.height) <= 10.0 &&
                fabs(r.origin.x) <= 10.0 && fabs(r.origin.y) <= 10.0) return YES;
        }
    }
    return NO;
}

static void ClearSliderTrack(UIView *v, BOOL clear) {
    for (UIView *s in v.subviews) {
        if ([s isKindOfClass:XCGlassView.class]) continue;
        UIColor *saved = objc_getAssociatedObject(s, kTrackClearKey);
        if (!clear) {
            if (saved) { s.backgroundColor = saved; objc_setAssociatedObject(s, kTrackClearKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
            continue;
        }
        if (saved) { if (s.backgroundColor) s.backgroundColor = nil; continue; }
        CGFloat w = 0, a = 0;
        UIColor *c = s.backgroundColor;
        if (c && [c getWhite:&w alpha:&a] && w < 0.25 && a > 0.4 &&
            s.bounds.size.width >= v.bounds.size.width * 0.9 && s.bounds.size.height >= v.bounds.size.height * 0.9) {
            objc_setAssociatedObject(s, kTrackClearKey, c, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            s.backgroundColor = nil;
        }
    }
}

static void SyncOwnGlass(UIView *v, CGFloat radius, BOOL dark, BOOL want, BOOL slider) {
    XCGlassView *g = objc_getAssociatedObject(v, kOwnGlassKey);
    BOOL need = want && v.bounds.size.width >= 30.0 && v.bounds.size.height >= 30.0;
    if (need && !slider && v.bounds.size.height > 240.0) need = NO;   // expanded content is the panel's business
    if (need && SubtreeHasGlass(v, g, 0)) need = NO;
    if (need && !slider && AncestorGlassCovers(v)) need = NO;
    if (!need) {
        if (g) { [g removeFromSuperview]; objc_setAssociatedObject(v, kOwnGlassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
        if (slider) ClearSliderTrack(v, NO);
        return;
    }
    if (!g) {
        g = [[XCGlassView alloc] initWithFrame:v.bounds];
        objc_setAssociatedObject(v, kOwnGlassKey, g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!gGlassViews) gGlassViews = [NSHashTable weakObjectsHashTable];
        [gGlassViews addObject:g];
    }
    if (slider) ClearSliderTrack(v, YES);
    if (g.superview != v || [v.subviews indexOfObject:g] != 0) [v insertSubview:g atIndex:0];
    if (!CGRectEqualToRect(g.frame, v.bounds)) g.frame = v.bounds;
    g.layer.cornerCurve = kCACornerCurveContinuous;
    g.layer.cornerRadius = radius;
    g.layer.masksToBounds = YES;
    g.glassRadius = radius;
    g.glassDark = dark;
    g.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.01 + 0.05 * gGlass];
    [g attachFilter];
}

static void SyncGlass(UIView *v, CCKind kind, CGFloat radius, BOOL dark, BOOL enabled) {
    BOOL want = enabled && gRefract && GlassRendererReady();
    if (kind == CCKindModule || kind == CCKindSlider) {
        if (kind == CCKindSlider) SyncGlassIn(v, want, radius, dark, 0);   // a track material of its own, if the system has one
        SyncOwnGlass(v, radius, dark, want, kind == CCKindSlider);
        return;
    }
    if (kind != CCKindModuleFill && kind != CCKindContainer) return;
    SyncGlassIn(v, want, radius, dark, 0);
    if (kind == CCKindContainer) SyncPanelGlass(v, radius, dark, want);
}

// Take a view back to what the system had before we styled it. Switching the tweak off used to
// hide our decoration and leave the radius, the clip and the fill we had written on the view, so
// a module stayed a glass capsule with no glass in it. Every value is restored from the copy
// taken the first time the view was styled.
// Everything of ours below a view: decoration layers, the synthetic fill of a tile and the background
// colour we wrote on a system on-fill. Restoring only the outermost view used to leave the inner
// pieces in place, which is how "tweak off, some glass still there" happens.
static void RestoreDecorTree(UIView *v, int depth) {
    if (depth > 5) return;
    HideDecor(v);
    UIView *synth = objc_getAssociatedObject(v, kSynthFillKey);
    if ([synth isKindOfClass:UIView.class]) {
        [synth removeFromSuperview];
        objc_setAssociatedObject(v, kSynthFillKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    id fill = objc_getAssociatedObject(v, kOnFillKey);
    if (fill) {
        v.backgroundColor = [fill isKindOfClass:UIColor.class] ? (UIColor *)fill : nil;
        objc_setAssociatedObject(v, kOnFillKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(v, kMenuKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for (UIView *s in v.subviews) RestoreDecorTree(s, depth + 1);
}

static void RestoreStock(UIView *v) {
    // Our own animations: a press that never ended keeps fillMode forwards and would hold the view
    // scaled forever; the page stretch/relax animations can outlive a style change.
    for (NSString *k in [v.layer animationKeys]) {
        if ([k hasPrefix:@"xc."]) [v.layer removeAnimationForKey:k];
    }
    RestoreDecorTree(v, 0);
    // Never styled by us (the tweak is off from the start): the view still has its stock values,
    // so leave them alone instead of clearing the system's own clip and background.
    if (!objc_getAssociatedObject(v, kSysMasksKey)) return;
    UIView *blur = objc_getAssociatedObject(v, kBlurKey);
    if ([blur isKindOfClass:UIView.class]) {
        [blur removeFromSuperview];
        objc_setAssociatedObject(v, kBlurKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CALayer *layer = v.layer;
    NSNumber *sysR = objc_getAssociatedObject(v, kSysRKey);
    if (sysR) layer.cornerRadius = sysR.doubleValue;
    NSNumber *sysMasks = objc_getAssociatedObject(v, kSysMasksKey);
    layer.masksToBounds = sysMasks ? sysMasks.boolValue : NO;
    // Stored as a BOOL, so neither the SDK's enum name nor its type has to be spelled out here.
    layer.cornerCurve = [objc_getAssociatedObject(v, kSysCurveKey) boolValue]
        ? kCACornerCurveContinuous : kCACornerCurveCircular;
    id sysBg = objc_getAssociatedObject(v, kSysBgKey);
    v.backgroundColor = [sysBg isKindOfClass:UIColor.class] ? (UIColor *)sysBg : nil;
    layer.borderWidth = 0.0;
    objc_setAssociatedObject(v, kLastRKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(v, kStyledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SyncGlassIn(v, NO, 0.0, IsDarkUI(v), 0);
    SyncPanelGlass(v, 0.0, NO, NO);
    SyncOwnGlass(v, 0.0, NO, NO, YES);
    SetMaterialAlpha(v, 0, 1.0);
}


// Enabled (selected) toggles: iOS 18 shows them as a nearly opaque white fill drawn by a
// child of the button module, which hides the glass behind it. Round it like the shell and
// let the backdrop show through (iOS 26 "on" tiles are frosted, not solid).
@interface XCOnFillView : UIView
@end
@implementation XCOnFillView
@end

static BOOL LooksLikeOnFill(UIView *s, CGSize parent) {
    NSString *n = NSStringFromClass(s.class);
    if ([n hasPrefix:@"XC"] || [n containsString:@"Material"] || [n containsString:@"Slider"] ||
        [n containsString:@"Label"] || [n containsString:@"Image"] || [n containsString:@"Glyph"] ||
        [n containsString:@"ContentModuleBackground"]) return NO;
    if (s.bounds.size.width < parent.width * 0.9 || s.bounds.size.height < parent.height * 0.9) return NO;
    if ([n containsString:@"Highlight"] || [n containsString:@"Selected"] || [n containsString:@"Background"]) return YES;
    CGFloat w = 0, a = 0;
    UIColor *c = s.backgroundColor;
    return c && [c getWhite:&w alpha:&a] && w > 0.7 && a > 0.3;
}

static void DumpTree(UIView *v, int depth, NSMutableString *dump) {
    if (depth > 5) return;
    for (UIView *s in v.subviews) {
        NSString *extra = @"";
        if ([s isKindOfClass:UILabel.class]) {
            UILabel *l = (UILabel *)s; CGFloat w = -1, a = 0;
            [l.textColor getWhite:&w alpha:&a];
            extra = [NSString stringWithFormat:@" text=\"%@\" textWhite=%.2f", l.text, w];
        }
        [dump appendFormat:@"%*s%@ %@ a=%.2f hidden=%d bg=%@ comp=%@%@\n", depth * 2, "", NSStringFromClass(s.class),
         NSStringFromCGRect(s.frame), s.alpha, s.hidden, s.backgroundColor, s.layer.compositingFilter, extra];
        DumpTree(s, depth + 1, dump);
    }
}

static UILabel *FirstLabel(UIView *v, int depth) {
    if (depth > 4) return nil;
    for (UIView *s in v.subviews) {
        if ([s isKindOfClass:UILabel.class] && ((UILabel *)s).text.length) return (UILabel *)s;
        UILabel *l = FirstLabel(s, depth + 1);
        if (l) return l;
    }
    return nil;
}

// Returns the number of system on-fills that were restyled.
// How white the fill has to be is not a constant: a dark label needs a light tile, and the darker the
// wallpaper behind the tile the more white it takes to keep that label readable. Bright wallpapers
// therefore get a thinner fill, which is also what the reference looks like.
static CGFloat OnFillAlpha(UIView *tile, BOOL dark) {
    CGFloat lum = BackdropLuminanceFor(tile);
    CGFloat base = (dark ? 0.92 : 0.94) - 0.06 * gGlass;
    return MIN(0.97, MAX(0.62, base - 0.22 * (lum - 0.35)));
}

static int StyleOnFills(UIView *v, CGFloat radius, BOOL dark, int depth) {
    if (depth > 4) return 0;
    int n = 0;
    for (UIView *s in v.subviews) {
        NSString *sn = NSStringFromClass(s.class);
        // Round buttons inside a tile (Cellular, Hotspot, ...) draw their own circle and tint;
        // restyling their white base view changed its shape and colour.
        if ([sn containsString:@"RoundButton"] || [sn containsString:@"GlyphWrapper"] || [sn containsString:@"IconView"]) continue;
        if (LooksLikeOnFill(s, v.bounds.size)) {
            // Never touch the view's alpha: CCUI animates it 0 <-> 1 as the toggle turns on/off,
            // so any cached or scaled alpha leaves enabled tiles empty or grey. Only soften the
            // fill colour instead; the system keeps full control of visibility.
            if (!objc_getAssociatedObject(s, kOnFillKey)) {
                objc_setAssociatedObject(s, kOnFillKey, s.backgroundColor ?: (id)[NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            s.layer.cornerCurve = gContinuous ? kCACornerCurveContinuous : kCACornerCurveCircular;
            s.layer.cornerRadius = radius;
            s.layer.masksToBounds = YES;
            // iOS 26+ "on" tiles are bright, slightly translucent white glass.
            CGFloat fa = OnFillAlpha(v, dark);
            CGFloat w = 0, ca = 0;
            if (!(s.backgroundColor && [s.backgroundColor getWhite:&w alpha:&ca] && fabs(ca - fa) < 0.005 && w > 0.99)) {
                s.backgroundColor = [UIColor colorWithWhite:1.0 alpha:fa];
            }
            // The stock fill carries a layer filter that depends on the stock material behind it; with
            // that material replaced by glass the fill is sometimes not drawn at all (clear tiles with
            // dark text). A plain translucent white fill needs no filter, so drop it.
            if (s.layer.filters.count) s.layer.filters = nil;
            if (s.layer.compositingFilter) s.layer.compositingFilter = nil;
            n++;
            continue;
        }
        if (s.subviews.count && s.bounds.size.width * s.bounds.size.height > 400) n += StyleOnFills(s, radius, dark, depth + 1);
    }
    return n;
}

// Some tiles (Orientation Lock) turn their label dark when enabled but get no system fill view,
// which leaves dark text on a dark tile. Give those tiles a fill of our own, matching the look of
// the other enabled tiles, and remove it again when the label turns light.
static void SyncSynthFill(UIView *v, CGFloat radius, BOOL dark, BOOL systemFillVisible) {
    UIView *fill = objc_getAssociatedObject(v, kSynthFillKey);
    UILabel *label = systemFillVisible ? nil : FirstLabel(v, 0);
    CGFloat w = 1.0, a = 0;
    BOOL enabledLook = label && [label.textColor getWhite:&w alpha:&a] && w < 0.4 && a > 0.3;
    if (!enabledLook) { if (fill && !fill.hidden) fill.hidden = YES; return; }
    if (!fill) {
        fill = [[XCOnFillView alloc] init];
        fill.userInteractionEnabled = NO;
        objc_setAssociatedObject(v, kSynthFillKey, fill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Must sit above the module's material and its glass, or the glass covers it.
    UIView *anchorView = nil;
    for (UIView *s in v.subviews) {
        if (s != fill && ([s isKindOfClass:XCGlassView.class] || [NSStringFromClass(s.class) containsString:@"MaterialView"])) anchorView = s;
    }
    NSArray *sib = v.subviews;
    if (anchorView) {
        if (fill.superview != v || [sib indexOfObject:fill] != [sib indexOfObject:anchorView] + 1) [v insertSubview:fill aboveSubview:anchorView];
    } else if (fill.superview != v) {
        [v insertSubview:fill atIndex:0];
    }
    if (fill.hidden) fill.hidden = NO;
    if (!CGRectEqualToRect(fill.frame, v.bounds)) fill.frame = v.bounds;
    fill.layer.cornerCurve = gContinuous ? kCACornerCurveContinuous : kCACornerCurveCircular;
    fill.layer.cornerRadius = radius;
    fill.layer.masksToBounds = YES;
    fill.backgroundColor = [UIColor colorWithWhite:1.0 alpha:OnFillAlpha(v, dark)];
}

// Debug dump of the view hierarchy of each module / round button, once per object.
static BOOL OnFillVisible(UIView *v, int depth);
static void DumpViewOnce(UIView *v, CGFloat radius, const char *tag) {
    static NSUInteger dumpGen = (NSUInteger)-1;
    static NSMutableString *acc; static int dumped;
    static NSMapTable *seen;   // view -> last dumped on/off state, so both states of a tile are captured
    if (!gDebugDump || (v.bounds.size.height > 200 && strcmp(tag, "slider") != 0)) return;
    if (dumpGen != gGeneration) { dumpGen = gGeneration; acc = [NSMutableString string]; dumped = 0; seen = [NSMapTable weakToStrongObjectsMapTable]; }
    NSNumber *st = @(OnFillVisible(v, 0));
    NSNumber *prev = [seen objectForKey:v];
    if (dumped >= 70 || (prev && [prev isEqual:st])) return;
    [seen setObject:st forKey:v]; dumped++;
    [acc appendFormat:@"%s [%@] %@ %@ r=%.1f curve=%@ own-bg=%@ layer-bg=%@\n", tag, st.boolValue ? @"ON" : @"off", NSStringFromClass(v.class), NSStringFromCGRect(v.bounds), radius,
     v.layer.cornerCurve, v.backgroundColor, (__bridge id)v.layer.backgroundColor];
    DumpTree(v, 1, acc);
    LGWriteDiagnostic(@"ios26ccstyle-module-dump.txt", acc);
}

static void MotionToggle(UIView *v, BOOL on);
static void StyleOnFillsTop(UIView *v, CGFloat radius, BOOL dark) {
    DumpViewOnce(v, radius, "module");
    int n = StyleOnFills(v, radius, dark, 1);
    SyncSynthFill(v, radius, dark, n > 0 && OnFillVisible(v, 0));
    if (n > 0) MotionToggle(v, OnFillVisible(v, 0));
}

// Debug: the whole subtree of an expanded module (Now Playing, volume, ...), to see which view
// owns a leftover rim or glass layer. Written at most once per second, last write wins.
static void DumpExpandedTree(UIView *v, int depth, NSMutableString *out) {
    if (depth > 6) return;
    for (UIView *s in v.subviews) {
        CALayer *l = s.layer;
        [out appendFormat:@"%*s%@ %@ a=%.2f hidden=%d clip=%d r=%.1f%@%@%@\n", depth * 2, "", NSStringFromClass(s.class),
         NSStringFromCGRect(s.frame), s.alpha, s.hidden, l.masksToBounds, l.cornerRadius,
         objc_getAssociatedObject(s, kMenuKey) ? @" [menu-decor]" : @"",
         objc_getAssociatedObject(s, kGlassKey) ? @" [has-glass]" : @"",
         objc_getAssociatedObject(s, kStyledKey) ? @" [styled]" : @""];
        DumpExpandedTree(s, depth + 1, out);
    }
}

static void DumpExpanded(UIView *v) {
    static CFAbsoluteTime last;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!gDebugDump || now - last < 1.0 || v.bounds.size.height < 200) return;
    last = now;
    NSMutableString *out = [NSMutableString stringWithFormat:@"%@ %@\n", NSStringFromClass(v.class), NSStringFromCGRect(v.bounds)];
    DumpExpandedTree(v, 1, out);
    NSString *name = [out containsString:@"NowPlaying"] ? @"ios26ccstyle-expanded-np.txt"
                                                       : @"ios26ccstyle-expanded-dump.txt";
    LGWriteDiagnostic(name, out);
}

// Debug: where a Wi-Fi / Bluetooth tile sits in the page and in what order its siblings are drawn,
// written every time such a tile lands in a window. Shows whether glass, fill or material ends up
// in the wrong place after the page is reopened.
static void ChainLine(NSMutableString *out, UIView *v, int indent, UIView *mark) {
    CALayer *l = v.layer;
    NSString *fl = l.filters.count ? [NSString stringWithFormat:@"%@", l.filters] : @"0";
    fl = [fl stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    [out appendFormat:@"%*s%@%@ %@ a=%.2f hid=%d z=%.0f op=%.2f filters=%@ clip=%d%@%@\n", indent * 2, "", v == mark ? @"* " : @"",
     NSStringFromClass(v.class), NSStringFromCGRect(v.frame), v.alpha, v.hidden, l.zPosition, l.opacity,
     fl, l.masksToBounds, objc_getAssociatedObject(v, kGlassKey) ? @" [has-glass]" : @"",
     [v isKindOfClass:XCGlassView.class] ? @" [GLASS]" : @""];
}

static void DumpTileChain(UIView *tile) {
    if (!gDebugDump) return;
    UILabel *lab = FirstLabel(tile, 0);
    if (!lab || ![lab.text isEqualToString:@"Wi-Fi"]) return;
    static NSMutableString *acc; static int n; static CFTimeInterval last;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - last < 1.5) return;   // one snapshot per page open, not one per animation frame
    last = now;
    if (!acc) acc = [NSMutableString string];
    if (n >= 8) { n = 0; [acc setString:@""]; }
    n++;
    [acc appendFormat:@"--- snapshot %d %.1f\n", n, CACurrentMediaTime()];
    UIView *top = tile;
    for (int i = 0; i < 4 && top.superview; i++) top = top.superview;
    // ancestors with their children, one level down
    UIView *a = tile; NSMutableArray *chain = [NSMutableArray array];
    for (int i = 0; i < 5 && a; i++) { [chain addObject:a]; a = a.superview; }
    for (NSInteger i = chain.count - 1; i >= 0; i--) {
        UIView *c = chain[i];
        ChainLine(acc, c, (int)(chain.count - 1 - i), tile);
        if (i == 0) { for (UIView *s in c.subviews) ChainLine(acc, s, (int)chain.count, tile); }
        else { for (UIView *s in c.subviews) if (s != chain[i - 1]) ChainLine(acc, s, (int)(chain.count - i), tile); }
    }
    LGWriteDiagnostic(@"ios26ccstyle-tile-chain.txt", acc);
}

// MARK: Edit mode ------------------------------------------------------------

// In edit mode the module background view turns visible (alpha 0 in normal use) and is larger than the module
// content that shrinks inside it; the stock outline lives there with the stock corner radius, which no longer
// matches the tweak's rounder tiles. The geometry tells the two cases apart: an expanded module has a
// background exactly as large as its content.
static BOOL EditOutlineGeometry(UIView *bg, CGFloat *gap, CGFloat *innerRadius) {
    if (bg.alpha < 0.05 || !bg.superview) return NO;
    for (UIView *s in bg.superview.subviews) {
        if (![NSStringFromClass(s.class) isEqualToString:@"CCUIContentModuleContentContainerView"]) continue;
        CGSize bs = bg.frame.size, cs = s.frame.size;
        if (cs.height < 8.0 || bs.height - cs.height < 2.0 || bs.height - cs.height > 40.0) return NO;
        CGFloat k = cs.height / MAX(1.0, s.bounds.size.height);   // the content's own scale in edit mode
        *gap = (bs.height - cs.height) / 2.0;
        *innerRadius = MIN(s.layer.cornerRadius * k, cs.height / 2.0);
        return YES;
    }
    return NO;
}

static NSString *SublayerSummary(UIView *v) {
    NSMutableArray *a = [NSMutableArray array];
    for (CALayer *sl in v.layer.sublayers) {
        id d = sl.delegate;
        if ([d isKindOfClass:UIView.class] && ((UIView *)d).superview == v) continue;   // a subview's own layer
        NSString *c = NSStringFromClass(sl.class);
        if ([sl isKindOfClass:CAShapeLayer.class]) {
            CAShapeLayer *sh = (CAShapeLayer *)sl;
            c = [NSString stringWithFormat:@"%@(lw=%.1f stroke=%d fill=%d)", c, sh.lineWidth, sh.strokeColor != NULL, sh.fillColor != NULL];
        }
        [a addObject:[NSString stringWithFormat:@"%@ %@ bw=%.1f r=%.1f", c, NSStringFromCGRect(sl.frame), sl.borderWidth, sl.cornerRadius]];
    }
    return a.count ? [a componentsJoinedByString:@"; "] : @"-";
}

static void EditLine(NSMutableString *o, UIView *v, int depth, int maxDepth, int *budget) {
    if ((*budget)-- <= 0) return;
    CALayer *l = v.layer;
    [o appendFormat:@"%*s%@ f=%@ a=%.2f hid=%d clip=%d r=%.1f bw=%.1f ts=%.3f/%.3f mask=%@ cf=%d filters=%lu layers=%@\n", depth * 2, "",
     NSStringFromClass(v.class), NSStringFromCGRect(v.frame), v.alpha, v.hidden, l.masksToBounds, l.cornerRadius, l.borderWidth,
     l.transform.m11, l.transform.m22, l.mask ? NSStringFromClass(l.mask.class) : @"-", l.compositingFilter != nil,
     (unsigned long)l.filters.count, SublayerSummary(v)];
    if (depth >= maxDepth) return;
    for (UIView *s in v.subviews) EditLine(o, s, depth + 1, maxDepth, budget);
}

// The edit-mode module: its whole subtree, and the views around it (remove button, resize handle, outline).
static void DumpEditMode(UIView *bg) {
    if (!gDebugDump) return;
    static NSMutableString *acc; static int n; static CFTimeInterval last;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - last < 2.0 || n >= 3) return;
    last = now; n++;
    if (!acc) acc = [NSMutableString string];
    UIView *root = bg.superview.superview ?: bg.superview;
    [acc appendFormat:@"--- edit snapshot %d, module background %@ alpha=%.2f\n", n, NSStringFromCGRect(bg.frame), bg.alpha];
    int budget = 120;
    EditLine(acc, root, 0, 7, &budget);
    UIView *up = root.superview;
    [acc appendString:@"--- around the module (parent and its other children, depth 1)\n"];
    if (up) {
        budget = 40;
        [acc appendFormat:@"parent %@ f=%@\n", NSStringFromClass(up.class), NSStringFromCGRect(up.frame)];
        for (UIView *s in up.subviews) EditLine(acc, s, 1, s == root ? 1 : 2, &budget);
    }
    LGWriteDiagnostic(@"ios26ccstyle-edit.txt", acc);
}

static void ApplyStyle(UIView *v, CCKind kind);

// The expanded volume / mute panel is a 321x360 container holding a 135 pt wide pill (plus a hidden
// twin). The container itself has no visible shape in stock iOS, so it gets no rim, glass or corner.
static BOOL HoldsSliderOrVolume(UIView *v, int depth) {
    for (UIView *s in v.subviews) {
        if (IsVolumeHost(s) || [NSStringFromClass(s.class) containsString:@"SliderView"]) return YES;
        if (depth < 2 && HoldsSliderOrVolume(s, depth + 1)) return YES;
    }
    return NO;
}
static BOOL ContainerHoldsVolume(UIView *v) { return HoldsSliderOrVolume(v, 0); }

// The page wrapper holds the page's icon list views, so it must stay bare or a rim is drawn around
// the whole page. That is a structural test: on the first open the modules of the first page are
// laid out at page size for a moment, so their bounds cannot tell them apart from the wrapper.
static BOOL HoldsIconList(UIView *v, int depth) {
    for (UIView *s in v.subviews) {
        if ([NSStringFromClass(s.class) hasSuffix:@"IconListView"]) return YES;
        if (depth < 2 && HoldsIconList(s, depth + 1)) return YES;
    }
    return NO;
}

// MARK: - Profiles -------------------------------------------------------------
// What a view is decides how it is drawn: a tile gets glass and a rim, an expanded module's backdrop
// or a page wrapper gets nothing of ours, a menu row is decorated on its own. This used to be
// scattered size tests in the style function, and every one of them could silently match the wrong
// view (the page-1 tiles were page-sized on the first layout pass). The table makes the decision one
// place, records it for the diagnostics report, and leaves the size rules only as a fallback.

typedef NS_ENUM(NSInteger, LGProfile) {
    LGProfileTile,      // pill, square, control template
    LGProfileSlider,    // brightness / volume track
    LGProfileRound,     // +, power, accessory buttons
    LGProfileMenu,      // row inside an expanded menu
    LGProfilePanel,     // expanded module content
    LGProfileBackdrop,  // page wrapper / expanded module background: bare, stock material only
};

static const char *LGProfileName(LGProfile p) {
    switch (p) {
        case LGProfileTile:     return "tile";
        case LGProfileSlider:   return "slider";
        case LGProfileRound:    return "round";
        case LGProfileMenu:     return "menu";
        case LGProfilePanel:    return "panel";
        case LGProfileBackdrop: return "backdrop";
    }
    return "?";
}

static LGProfile LGProfileFor(UIView *v, CCKind kind, CGRect b) {
    static NSDictionary<NSString *, NSNumber *> *classes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        classes = @{
            @"CCUIContinuousSliderView":          @(LGProfileSlider),
            @"CCUISteppedSliderView":             @(LGProfileSlider),
            @"CCUIRoundButton":                   @(LGProfileRound),
            @"CCUIPowerButton":                   @(LGProfileRound),
            @"CCUIAccessoryButton":               @(LGProfileRound),
            @"CCUIModuleCollectionView":          @(LGProfileBackdrop),
            @"CCUIContentModuleBackgroundView":   @(LGProfilePanel),
            @"CCUIContentModuleContentContainerView": @(LGProfilePanel),
            @"CCUIControlTemplateView":           @(LGProfileTile),
            @"CCUIButtonModuleView":              @(LGProfileTile),
        };
    });
    LGProfile p = LGProfileTile;
    NSNumber *mapped = classes[NSStringFromClass(v.class)];
    if (mapped) p = (LGProfile)mapped.integerValue;
    else if (kind == CCKindSlider) p = LGProfileSlider;
    else if (kind == CCKindRound) p = LGProfileRound;

    // Geometry only as the fallback, and only for the module kinds: a page wrapper or the backdrop of
    // an expanded module must stay bare whatever its class.
    if (kind == CCKindModule || kind == CCKindModuleFill || kind == CCKindContainer) {
        CGSize ws = v.window ? v.window.bounds.size : CGSizeZero;
        // a page wrapper is as wide as the screen; the expanded connectivity page is page-high but only 299 pt wide
        if (ws.height > 1 && b.size.height > ws.height * 0.72 && b.size.width > ws.width * 0.9) return LGProfileBackdrop;
        if (ws.height > 1 && b.size.height > ws.height * 0.6 && HoldsIconList(v, 0)) return LGProfileBackdrop;
        if (p == LGProfileTile && objc_getAssociatedObject(v, kMenuKey)) p = LGProfileMenu;
        else if (p == LGProfileTile && b.size.height > 240) p = LGProfilePanel;
    }
    return p;
}

// One compact line per view instead of a whole tree: class, profile, size and what was drawn. Read on
// the phone from Settings > iOS 26 CC Style > Logs, so a screenshot of a wrong tile comes with the
// reason it was drawn that way.
static void ReportStyle(UIView *v, LGProfile p, CGFloat radius, BOOL glass, BOOL decor) {
    if (!gDebugDump) return;
    static NSMutableString *acc;
    static CFTimeInterval last, lastVisit;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - lastVisit < 0.25) return;   // this runs in the layout path: a few lines a second is plenty
    lastVisit = now;
    if (!acc) acc = [NSMutableString string];
    if ([acc length] > 60000) [acc setString:@""];   // a stuck loop must not fill the disk
    CGFloat lum = BackdropLuminanceFor(v);
    BOOL dark = IsDarkUI(v);
    [acc appendFormat:@"%@ %s r=%.1f f=%@ on=%@ lum=%.2f %@%@%@%@\n",
        NSStringFromClass(v.class), LGProfileName(p), radius, NSStringFromCGRect(v.frame),
        NSStringFromCGRect([v convertRect:v.bounds toView:v.window]), lum,
        dark ? @"dark" : @"light", glass ? @" glass" : @"", decor ? @" decor" : @"",
        ReduceTransparencyOn() ? @" reduce-transparency" : @""];
    if (now - last < 1.0) return;
    last = now;
    [acc appendString:@"-----\n"];
    LGWriteDiagnostic(@"ios26ccstyle-style.txt", acc);
    [acc setString:@""];
}

static void ApplyStyle(UIView *v, CCKind kind) {
    if (!v.window) return;
    ApplyBackground(v);
    if (kind == CCKindModuleFill) {
        CGFloat gap = 0, rin = 0;
        if (EditOutlineGeometry(v, &gap, &rin)) {   // edit mode: the stock outline, concentric with the tile, nothing of ours on it
            RestoreStock(v);
            v.layer.cornerCurve = kCACornerCurveContinuous;
            v.layer.cornerRadius = MIN(rin + gap, MIN(v.bounds.size.width, v.bounds.size.height) / 2.0);
            DumpEditMode(v);
            return;
        }
    }
    if (kind == CCKindContainer && ContainerHoldsVolume(v)) {
        RestoreStock(v);
        DecorateMenus(v);   // keeps the volume host bare, still styles the stepper buttons
        DumpExpanded(v);
        return;
    }
    if (!gEnabled || !KindEnabled(kind)) {
        RestoreStock(v);
        if (kind == CCKindContainer && gEnabled) DecorateMenus(v);
        return;
    }

    CGRect b = v.bounds;
    if (b.size.width < 4.0 || b.size.height < 4.0) return;

    double perfStart = PerfNowMS();
    LGProfile profile = LGProfileFor(v, kind, b);
    objc_setAssociatedObject(v, kProfileKey, @(profile), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // The page wrapper and the backdrop of an expanded module stay bare: the system's own material,
    // no rim and no glass of ours. Page 1's tiles are transiently page-sized on the first layout pass
    // and are classified as a backdrop then too; the pager restyles them at their real size once the
    // open animation has run (ScheduleStyleSettle), which is the fix for the first open.
    if (profile == LGProfileBackdrop) {
        RestoreStock(v);
        if (kind == CCKindContainer) DecorateMenus(v);
        ReportStyle(v, profile, 0, NO, NO);
        PerfAdd("style.backdrop", PerfNowMS() - perfStart);
        return;
    }

    // Reduce Transparency: the shape stays, the translucency goes. Apple's own Control Center turns
    // opaque under that setting, and a see-through tile there reads as broken.
    BOOL opaque = ReduceTransparencyOn();

    CALayer *layer = v.layer;

    // First styling of this view: keep what the system had so the tweak can be switched off again.
    if (!objc_getAssociatedObject(v, kSysMasksKey)) {
        objc_setAssociatedObject(v, kSysMasksKey, @(layer.masksToBounds), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(v, kSysCurveKey, @(layer.cornerCurve == kCACornerCurveContinuous), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(v, kSysBgKey, v.backgroundColor ?: (id)[NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // Remember the radius the system itself uses (expanded modules are rounder than
    // tiles) and never go below it, so inner and outer shapes keep matching.
    CGFloat cur = layer.cornerRadius;
    NSNumber *last = objc_getAssociatedObject(v, kLastRKey);
    CGFloat sys;
    if (last && fabs(cur - last.doubleValue) < 0.5) {
        sys = [objc_getAssociatedObject(v, kSysRKey) doubleValue];
    } else {
        sys = cur;
        objc_setAssociatedObject(v, kSysRKey, @(cur), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    CGFloat r = TargetRadius(kind, b.size);
    if (kind != CCKindRound && kind != CCKindSlider) {
        r = MIN(MIN(b.size.width, b.size.height) / 2.0, MAX(r, sys));
    }
    objc_setAssociatedObject(v, kLastRKey, @(r), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(v, kStyledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(v, kKindKey, @(kind), OBJC_ASSOCIATION_RETAIN_NONATOMIC);   // for the late restyle

    layer.cornerCurve   = gContinuous ? kCACornerCurveContinuous : kCACornerCurveCircular;
    layer.cornerRadius  = r;
    layer.masksToBounds = YES;
    layer.borderWidth   = 0.0;

    BOOL darkUI = IsDarkUI(v);
    SetMaterialAlpha(v, 0, opaque ? 1.0 : (darkUI ? gMatAlpha : MAX(gMatAlpha, 0.6)));
    BOOL glassWanted = gIsoGlass && !opaque;
    SyncGlass(v, kind, r, darkUI, glassWanted);
    BOOL glassOn = glassWanted && gRefract && GlassRendererReady();

    if (kind == CCKindModuleFill) {
        CGFloat ft = opaque ? 0.55 : (glassOn ? 0.0 : (darkUI ? gEffTint * 0.2 : gEffTint * 0.85));
        v.backgroundColor = ft > 0.001 ? [gFillColor colorWithAlphaComponent:ft] : nil;
        ApplyExtraBlur(v, b);
    }

    if (kind == CCKindModule) { StyleOnFillsTop(v, r, darkUI); DumpTileChain(v); }
    else if (kind == CCKindRound) DumpViewOnce(v, r, "round");

    // Diagnostics isolation: decor off leaves glass only, glass off leaves decor only, both off is
    // stock. That is how a wrong-looking tile gets bisected on the phone.
    BOOL decorOn = gIsoDecor && !opaque;
    // the page-high container behind a page of tiles has no rim: each tile draws its own
    if ((kind == CCKindContainer || kind == CCKindModuleFill) && v.window && b.size.height > v.window.bounds.size.height * 0.7) decorOn = NO;
    if (kind == CCKindSlider) DumpViewOnce(v, r, "slider");
    if (decorOn) ApplyDecor(v, b, r);
    else HideDecor(v);

    if (!gTracked) gTracked = [NSHashTable weakObjectsHashTable];
    [gTracked addObject:v];

    if (kind == CCKindContainer) { DecorateMenus(v); DumpExpanded(v); }
    ReportStyle(v, profile, r, glassOn, decorOn);
    PerfAdd("style", PerfNowMS() - perfStart);
}

// Style everything we have styled once more, with the geometry it has now. On the first open of
// Control Center the modules are styled while the page is still being sized (page 1 starts at its
// pre-open bounds), and the open animation only changes transforms afterwards, so the layout hooks
// never run again on those views. The pager calls this once it has settled (ScheduleStyleSettle).
static void RestyleTrackedGeom(void) {
    if (!gEnabled || !gTracked) return;
    for (UIView *v in gTracked.allObjects) {
        if (!v.window) continue;
        NSNumber *k = objc_getAssociatedObject(v, kKindKey);
        if (k) ApplyStyle(v, (CCKind)k.integerValue);
    }
}

// CCUI occasionally resets its own corner radius right after the view lands in a
// window, so re-apply once shortly afterwards.
static void ScheduleReapply(UIView *v, CCKind kind) {
    if (!v.window) return;
    __weak UIView *weak = v;
    const double delays[] = { 0.12, 0.45 };   // second pass catches menu content added after expansion
    for (int i = 0; i < 2; i++) {
        if (i == 1 && kind != CCKindContainer && kind != CCKindModule) break;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIView *strong = weak;
            if (strong) ApplyStyle(strong, kind);
        });
    }
}

// MARK: - Hooks ---------------------------------------------------------------

static BOOL InstallHook(const char *className, SEL sel, IMP replacement, IMP *original) {
    Class cls = objc_getClass(className);
    if (!cls) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;

    IMP orig = method_getImplementation(m);
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(m))) {
        // The class implements the method itself: swap it in place.
        orig = method_setImplementation(m, replacement);
    }
    *original = orig;
    return orig != NULL;
}

// The hooked classes are a hierarchy (CCUIButtonModuleView is a CCUIControlTemplateView,
// CCUISteppedSliderView a CCUIContinuousSliderView, CCUIPowerButton/CCUIAccessoryButton are
// CCUIRoundButtons), so one layout pass runs both the subclass hook and the inherited superclass
// hook and every tile was styled twice per pass. The inner hook now only lets the system lay out;
// the outermost one applies the style, once.
#define DEFINE_HOOKS(TAG, KIND)                                                     \
    static void (*orig_layout_##TAG)(UIView *, SEL);                                \
    static void new_layout_##TAG(UIView *self, SEL _cmd) {                          \
        BOOL outer = objc_getAssociatedObject(self, kHookBusyKey) == nil;           \
        if (outer) objc_setAssociatedObject(self, kHookBusyKey, @YES,               \
                                            OBJC_ASSOCIATION_RETAIN_NONATOMIC);     \
        orig_layout_##TAG(self, _cmd);                                              \
        if (!outer) return;                                                         \
        objc_setAssociatedObject(self, kHookBusyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); \
        ApplyStyle(self, KIND);                                                     \
    }                                                                               \
    static void (*orig_window_##TAG)(UIView *, SEL);                                \
    static void new_window_##TAG(UIView *self, SEL _cmd) {                          \
        BOOL outer = objc_getAssociatedObject(self, kHookBusyKey) == nil;           \
        if (outer) objc_setAssociatedObject(self, kHookBusyKey, @YES,               \
                                            OBJC_ASSOCIATION_RETAIN_NONATOMIC);     \
        orig_window_##TAG(self, _cmd);                                              \
        if (!outer) return;                                                         \
        objc_setAssociatedObject(self, kHookBusyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); \
        ApplyStyle(self, KIND);                                                     \
        ScheduleReapply(self, KIND);                                                \
    }                                                                               \
    static void Install_##TAG(const char *cls) {                                    \
        IMP o1 = NULL, o2 = NULL;                                                   \
        if (InstallHook(cls, @selector(layoutSubviews),                             \
                        (IMP)new_layout_##TAG, &o1)) {                              \
            orig_layout_##TAG = (void (*)(UIView *, SEL))o1;                        \
        }                                                                           \
        if (InstallHook(cls, @selector(didMoveToWindow),                            \
                        (IMP)new_window_##TAG, &o2)) {                              \
            orig_window_##TAG = (void (*)(UIView *, SEL))o2;                        \
        }                                                                           \
    }

// MARK: - Motion (iOS 27 style springs) ----------------------------------------
// Animations are added to the layer only (never the model transform), so Control Center's own
// transforms and expansion animations keep working and the layer always settles back by itself.

static CASpringAnimation *Spring(NSString *keyPath, double from, double to, double damping, double stiffness) {
    CASpringAnimation *a = [CASpringAnimation animationWithKeyPath:keyPath];
    a.fromValue = @(from); a.toValue = @(to);
    a.mass = 1.0; a.damping = damping; a.stiffness = stiffness; a.initialVelocity = 0;
    a.duration = a.settlingDuration;
    return a;
}

static double CurrentScale(UIView *v) {
    CALayer *p = v.layer.presentationLayer ?: v.layer;
    return [[p valueForKeyPath:@"transform.scale"] doubleValue] ?: 1.0;
}

static void MotionPress(UIView *v, double target, BOOL down) {
    if (!MotionAllowed()) return;
    double now = CurrentScale(v);
    if (down) {
        CASpringAnimation *a = Spring(@"transform.scale", now, target, 16, 420);
        a.fillMode = kCAFillModeForwards; a.removedOnCompletion = NO;
        [v.layer addAnimation:a forKey:@"xc.press"];
    } else {
        // release: bounce past 1 and settle; the model value is 1, so the layer ends there
        [v.layer addAnimation:Spring(@"transform.scale", now, 1.0, 9, 260) forKey:@"xc.press"];
    }
}

// MARK: Whole-tile press -------------------------------------------------------------------
// The view that receives a touch is rarely the whole tile. On most tiles the glass and the rim sit next to
// the touched control view, so scaling that view only squeezed the label, the icon and a toggle's white
// fill while the glass stayed where it was: only the tiles that carry their own glass seemed to bounce.
// The press is driven from the window instead. The tile is the view that holds the tile's glass, and that
// view is scaled, so glass, rim, fill and content move together on every kind of tile.

static const void *kPressTokenKey = &kPressTokenKey;
static NSUInteger gPressToken;

@interface XCPress : NSObject
@property (nonatomic, weak) UIView *root;
@property (nonatomic) CGPoint start;
@property (nonatomic) BOOL slider, done;
@end
@implementation XCPress
@end

static NSMapTable<UITouch *, XCPress *> *gPresses;

// The nearest view at or above `v` that holds a glass as large as itself.
static UIView *GlassOwnerOf(UIView *v, int maxUp) {
    int n = 0;
    for (UIView *a = v; a && n <= maxUp; a = a.superview, n++) {
        CGSize as = a.bounds.size;
        for (UIView *s in a.subviews) {
            if (![s isKindOfClass:XCGlassView.class]) continue;
            CGSize gs = s.bounds.size;
            if (fabs(as.width - gs.width) < 3.0 && fabs(as.height - gs.height) < 3.0) return a;
        }
    }
    return nil;
}

// Tile-sized: pills, small squares, sliders. Expanded panels and the big media page are not tiles.
static BOOL TileFits(CGSize s) {
    return MIN(s.width, s.height) <= 150.0 && s.width * s.height <= 299.0 * 150.0;
}

// In edit mode (and in an expanded module) the stock outline view behind the content is visible.
static BOOL TileInEditMode(UIView *root) {
    UIView *c = root;
    for (int i = 0; c && i < 5; i++, c = c.superview)
        if ([NSStringFromClass(c.class) isEqualToString:@"CCUIContentModuleContentContainerView"]) break;
    if (!c) return NO;
    for (UIView *s in c.superview.subviews)
        if ([NSStringFromClass(s.class) isEqualToString:@"CCUIContentModuleBackgroundView"] && s.alpha > 0.05) return YES;
    return NO;
}

// The whole tile around a view: the module's content container when it is tile-sized (it carries the rim
// and holds the glass or the template that does), else the view that holds the glass (the tiles of the
// connectivity page share one big container and carry their own glass and rim).
static UIView *TileRootFor(UIView *v) {
    static Class cont;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cont = NSClassFromString(@"CCUIContentModuleContentContainerView"); });
    int n = 0;
    for (UIView *a = v; a && n < 10 && cont; a = a.superview, n++) {
        if ([a isKindOfClass:cont]) {
            if (TileFits(a.bounds.size)) return a;
            break;
        }
    }
    UIView *g = GlassOwnerOf(v, 8);
    return (g && TileFits(g.bounds.size)) ? g : nil;
}

static NSString *ChainText(UIView *v, int n) {
    NSMutableArray *a = [NSMutableArray array];
    for (UIView *x = v; x && n-- > 0; x = x.superview) [a addObject:NSStringFromClass(x.class)];
    return [a componentsJoinedByString:@" < "];
}

static void PressLog(NSString *line) {
    if (!gDebugDump) return;
    static NSMutableArray *lines;
    if (!lines) lines = [NSMutableArray array];
    [lines addObject:line];
    if (lines.count > 60) [lines removeObjectAtIndex:0];
    LGWriteDiagnostic(@"ios26ccstyle-press.txt", [lines componentsJoinedByString:@"\n"]);
}

// The view to scale for a touch that landed on `hit`, with the scale it presses to. nil: not a tile.
static UIView *PressTarget(UIView *hit, double *scale, BOOL *slider) {
    static Class sliderCls, roundCls, buttonCls, templateCls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sliderCls = NSClassFromString(@"CCUIContinuousSliderView");
        roundCls = NSClassFromString(@"CCUIRoundButton");
        buttonCls = NSClassFromString(@"CCUIButtonModuleView");
        templateCls = NSClassFromString(@"CCUIControlTemplateView");
    });
    *slider = NO;
    UIView *root = TileRootFor(hit);
    if (root) {
        if (TileInEditMode(root)) return nil;
        CGSize s = root.bounds.size;
        BOOL sl = NO;
        int n = 0;
        for (UIView *a = hit; a && a != root.superview && n < 10 && sliderCls; a = a.superview, n++)
            if ([a isKindOfClass:sliderCls]) { sl = YES; break; }
        *slider = sl;
        double md = MIN(s.width, s.height);
        if (sl) *scale = 1.04;
        else if (gPressGrow) *scale = 1.0 + MIN(0.10, MAX(0.04, 7.0 / md));   // iOS 26: the glass swells under the finger
        else *scale = md > 100.0 ? 0.96 : (fabs(s.width - s.height) < 6.0 ? 0.93 : 0.95);
        return root;
    }
    // No glass to carry along (the top buttons) or not a tile: the stock buttons keep a squeeze of their own.
    int n = 0;
    for (UIView *a = hit; a && n < 4; a = a.superview, n++) {
        if (roundCls && [a isKindOfClass:roundCls]) { *scale = 0.9; return a; }
        if (buttonCls && [a isKindOfClass:buttonCls]) { *scale = 0.93; return a; }
        if (templateCls && [a isKindOfClass:templateCls]) { *scale = 0.95; return a; }
    }
    return nil;
}

static void PressUp(UIView *root);

static void PressDown(UIView *root, double target, BOOL slider) {
    MotionPress(root, target, YES);
    NSNumber *tok = @(++gPressToken);
    objc_setAssociatedObject(root, kPressTokenKey, tok, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // never stay squeezed if the end of the touch is missed (the page closes under the finger, say)
    __weak UIView *guard = root;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((slider ? 20.0 : 2.5) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *r = guard;
        if (r && [objc_getAssociatedObject(r, kPressTokenKey) isEqual:tok]) PressUp(r);
    });
    if (slider) return;
    // iOS lets the squeeze ease off while the finger stays down (and the module's long press then expands it)
    __weak UIView *weak = root;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *r = weak;
        if (!r || ![objc_getAssociatedObject(r, kPressTokenKey) isEqual:tok]) return;
        CASpringAnimation *a = Spring(@"transform.scale", CurrentScale(r), 1.0 + (target - 1.0) * 0.65, 22, 180);
        a.fillMode = kCAFillModeForwards; a.removedOnCompletion = NO;
        [r.layer addAnimation:a forKey:@"xc.press"];
    });
}

static void PressUp(UIView *root) {
    objc_setAssociatedObject(root, kPressTokenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    MotionPress(root, 1.0, NO);
}

static void PressEvent(UIWindow *w, UIEvent *e) {
    if (!gPresses) gPresses = [NSMapTable weakToStrongObjectsMapTable];
    for (UITouch *t in [e touchesForWindow:w]) {
        switch (t.phase) {
            case UITouchPhaseBegan: {
                UIView *hit = t.view ?: [w hitTest:[t locationInView:w] withEvent:e];
                if (!hit) break;
                double scale = 1.0; BOOL slider = NO;
                UIView *root = PressTarget(hit, &scale, &slider);
                if (!root) {
                    if (gDebugDump && [ChainText(hit, 12) containsString:@"CCUI"])
                        PressLog([NSString stringWithFormat:@"%.2f no tile: %@", CACurrentMediaTime(), ChainText(hit, 8)]);
                    break;
                }
                XCPress *p = [XCPress new];
                p.root = root; p.start = [t locationInView:w]; p.slider = slider;
                [gPresses setObject:p forKey:t];
                PressDown(root, scale, slider);
                if (gDebugDump)
                    PressLog([NSString stringWithFormat:@"%.2f press %@ %@ -> %.2f%@  (hit %@)", CACurrentMediaTime(),
                              NSStringFromClass(root.class), NSStringFromCGSize(root.bounds.size), scale, slider ? @" slider" : @"", ChainText(hit, 5)]);
                break;
            }
            case UITouchPhaseMoved: {
                XCPress *p = [gPresses objectForKey:t];
                if (!p || p.done || p.slider || !p.root) break;
                CGPoint l = [t locationInView:w];
                if (hypot(l.x - p.start.x, l.y - p.start.y) > 14.0) { p.done = YES; PressUp(p.root); }   // a scroll or a drag took over
                break;
            }
            case UITouchPhaseEnded:
            case UITouchPhaseCancelled: {
                XCPress *p = [gPresses objectForKey:t];
                if (!p) break;
                [gPresses removeObjectForKey:t];
                if (!p.done && p.root) PressUp(p.root);
                break;
            }
            default: break;
        }
    }
}

static void (*orig_win_sendEvent)(UIWindow *, SEL, UIEvent *);
static void new_win_sendEvent(UIWindow *self, SEL _cmd, UIEvent *e) {
    if (MotionAllowed() && e.type == UIEventTypeTouches) PressEvent(self, e);
    orig_win_sendEvent(self, _cmd, e);
}


// iOS 26 interactive glass: a soft white light blooms under the finger on the brightness and volume
// sliders, below their content, and fades when the finger lifts.
static CALayer *GlowLayer(UIView *v) {
    for (CALayer *l in v.layer.sublayers) if ([l.name isEqualToString:@"xc.touchglow"]) return l;
    return nil;
}

static void GlowShow(UIView *v, CGPoint p) {
    CGSize sz = v.bounds.size;
    CALayer *clip = GlowLayer(v);
    if (!clip) {
        clip = [CALayer layer];
        clip.name = @"xc.touchglow";
        clip.masksToBounds = YES;
        clip.opacity = 0;
        CAGradientLayer *g = [CAGradientLayer layer];
        g.type = kCAGradientLayerRadial;
        g.startPoint = CGPointMake(0.5, 0.5);
        g.endPoint = CGPointMake(1.0, 1.0);
        g.locations = @[@0.0, @0.5, @1.0];
        g.colors = @[(id)[UIColor colorWithWhite:1.0 alpha:0.34].CGColor, (id)[UIColor colorWithWhite:1.0 alpha:0.12].CGColor, (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor];
        [clip addSublayer:g];
        [v.layer insertSublayer:clip atIndex:0];
    }
    CGFloat rad = v.layer.cornerRadius > 0 ? v.layer.cornerRadius : MIN(MIN(sz.width, sz.height) * 0.5, gMaxRadius);
    clip.frame = v.bounds;
    clip.cornerRadius = MIN(rad, MIN(sz.width, sz.height) * 0.5);
    clip.cornerCurve = kCACornerCurveContinuous;
    CGFloat R = MAX(80.0, MIN(140.0, MAX(sz.width, sz.height) * 0.75));
    CAGradientLayer *g = (CAGradientLayer *)clip.sublayers.firstObject;
    g.bounds = CGRectMake(0, 0, R * 2, R * 2);
    g.position = p;
    [clip removeAnimationForKey:@"xc.glowout"];
    clip.opacity = 1;
    CABasicAnimation *in = [CABasicAnimation animationWithKeyPath:@"opacity"];
    in.fromValue = @0; in.toValue = @1; in.duration = 0.08;
    [clip addAnimation:in forKey:@"xc.glowin"];
    CABasicAnimation *bloom = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    bloom.fromValue = @0.55; bloom.toValue = @1.0; bloom.duration = 0.28;
    bloom.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [g addAnimation:bloom forKey:@"xc.bloom"];
}

static void GlowHide(CALayer *clip) {
    CABasicAnimation *out = [CABasicAnimation animationWithKeyPath:@"opacity"];
    out.fromValue = @(clip.presentationLayer ? clip.presentationLayer.opacity : 1.0f);
    out.toValue = @0; out.duration = 0.55;
    out.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    clip.opacity = 0;
    [clip addAnimation:out forKey:@"xc.glowout"];
}

static void TouchGlow(UIView *v, NSSet *touches, BOOL down) {
    static Class slider;   // brightness is a CCUIContinuousSliderView, volume is a subclass of it (MRUContinuousSliderView)
    if (!slider) slider = objc_getClass("CCUIContinuousSliderView");
    if (!MotionAllowed() || !slider || ![v isKindOfClass:slider]) return;
    if (v.bounds.size.width < 20 || v.bounds.size.height < 20) return;
    CALayer *clip = GlowLayer(v);
    if (down) {
        UITouch *t = touches.anyObject;
        if (t) GlowShow(v, [t locationInView:v]);
    } else if (clip && clip.opacity > 0) {
        GlowHide(clip);
    }
}

static const void *kWasOnKey = &kWasOnKey;

// iOS 26: a soft band of light sweeps across a glass tile as it switches on.
static void Shimmer(UIView *v) {
    CGSize sz = v.bounds.size;
    if (sz.width < 30 || sz.height < 30) return;
    CAGradientLayer *g = [CAGradientLayer layer];
    g.name = @"xc.shimmer";
    g.colors = @[(id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor, (id)[UIColor colorWithWhite:1.0 alpha:0.5].CGColor, (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor];
    g.locations = @[@0.0, @0.5, @1.0];
    g.startPoint = CGPointMake(0.0, 0.35);
    g.endPoint = CGPointMake(1.0, 0.65);
    g.zPosition = 1001;
    CGFloat w = sz.width * 0.55;
    g.bounds = CGRectMake(0, 0, w, sz.height * 1.4);
    g.position = CGPointMake(sz.width + w * 0.5, sz.height * 0.5);
    [v.layer addSublayer:g];
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"position.x"];
    a.fromValue = @(-w * 0.5);
    a.toValue = @(sz.width + w * 0.5);
    a.duration = 0.6;
    a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{ [g removeFromSuperlayer]; }];
    [g addAnimation:a forKey:@"xc.shimmer"];
    [CATransaction commit];
}

// A toggle turning on pops: a quick overshoot spring, like the iOS 27 tiles.
static void MotionToggle(UIView *v, BOOL on) {
    NSNumber *was = objc_getAssociatedObject(v, kWasOnKey);
    objc_setAssociatedObject(v, kWasOnKey, @(on), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!MotionAllowed() || !was || was.boolValue == on) return;
    UIView *tile = TileRootFor(v);   // the whole tile pops, not the fill alone
    if (!tile || TileInEditMode(tile)) tile = v;
    double from = on ? 0.9 : 1.06;
    if (gPressGrow) {   // the tile is swollen under the finger: carry on from there, no jump
        from = CurrentScale(tile);
        if (fabs(from - 1.0) < 0.02) from = on ? 1.07 : 0.96;
    }
    [tile.layer addAnimation:Spring(@"transform.scale", from, 1.0, 8, 240) forKey:@"xc.pop"];
    if (on && gShimmer) Shimmer(v);
}


static BOOL OnFillVisible(UIView *v, int depth) {
    if (depth > 3) return NO;
    for (UIView *s in v.subviews) {
        if (LooksLikeOnFill(s, v.bounds.size)) return s.alpha > 0.5 && !s.hidden;
        if (s.subviews.count && OnFillVisible(s, depth + 1)) return YES;
    }
    return NO;
}

// A toggle flips its label colour and fill after the touch, with no layout pass of ours in between.
static void TouchRefresh(UIView *v) {
    NSString *n = NSStringFromClass(v.class);
    if (![n isEqualToString:@"CCUIControlTemplateView"] && ![n isEqualToString:@"CCUIButtonModuleView"]) return;
    __weak UIView *weak = v;
    const double delays[] = { 0.15, 0.4, 0.9 };
    for (int i = 0; i < 3; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *strong = weak;
            if (strong) ApplyStyle(strong, CCKindModule);
        });
    }
}

#define DEFINE_TOUCH_HOOKS(TAG, TARGET)                                                       \
    static void (*orig_tb_##TAG)(UIView *, SEL, NSSet *, UIEvent *);                          \
    static void (*orig_te_##TAG)(UIView *, SEL, NSSet *, UIEvent *);                          \
    static void (*orig_tc_##TAG)(UIView *, SEL, NSSet *, UIEvent *);                          \
    static void new_tb_##TAG(UIView *self, SEL _cmd, NSSet *t, UIEvent *e) { orig_tb_##TAG(self, _cmd, t, e); TouchGlow(self, t, YES); } \
    static void new_te_##TAG(UIView *self, SEL _cmd, NSSet *t, UIEvent *e) { orig_te_##TAG(self, _cmd, t, e); TouchGlow(self, t, NO); TouchRefresh(self); }  \
    static void new_tc_##TAG(UIView *self, SEL _cmd, NSSet *t, UIEvent *e) { orig_tc_##TAG(self, _cmd, t, e); TouchGlow(self, t, NO); }  \
    static void InstallTouch_##TAG(const char *cls) {                                         \
        IMP o = NULL;                                                                         \
        if (InstallHook(cls, @selector(touchesBegan:withEvent:), (IMP)new_tb_##TAG, &o)) orig_tb_##TAG = (void (*)(UIView *, SEL, NSSet *, UIEvent *))o;     \
        if (InstallHook(cls, @selector(touchesEnded:withEvent:), (IMP)new_te_##TAG, &o)) orig_te_##TAG = (void (*)(UIView *, SEL, NSSet *, UIEvent *))o;     \
        if (InstallHook(cls, @selector(touchesCancelled:withEvent:), (IMP)new_tc_##TAG, &o)) orig_tc_##TAG = (void (*)(UIView *, SEL, NSSet *, UIEvent *))o; \
    }


// MARK: - Stock animation finder -------------------------------------------------
// Records which Control Center views get which animations (class, key, key path, duration) so the
// stock expand / menu animations can be located and switched off. Only active with debug dump on.

// The stock module expand / collapse and menu animations are 0.4 s spring animations on position,
// bounds, corner radius and transform of every view involved. They are replaced in place by the
// same animation (same from/to values) with iOS 27 spring parameters, so the whole morph (panel,
// glass, sliders, menu rows) stays consistent and there is only one animation, not two.
static BOOL IsExpandContext(UIView *v) {
    for (UIView *a = v; a; a = a.superview) {
        NSString *n = NSStringFromClass(a.class);
        if ([n isEqualToString:@"CCUIContentModuleContentContainerView"] || [n hasPrefix:@"FCUI"] || [n hasPrefix:@"MRU"] ||
            [n isEqualToString:@"CCUIContentModuleBackgroundView"]) return YES;
    }
    return NO;
}

// Control Center's open / close springs (scale and fade of every tile, the status bar) live on views
// inside the icon list folder and the CC status bar, not in a module container. The page buttons stay stock.
static BOOL IsPageContext(UIView *v) {
    UIWindow *w = v.window;
    if (w && ![NSStringFromClass(w.class) containsString:@"ControlCenter"]) return NO;   // not the home screen
    int n = 0;
    for (UIView *a = v; a && n < 10; a = a.superview, n++) {
        NSString *c = NSStringFromClass(a.class);
        if ([c containsString:@"IconListFolderView"] || [c isEqualToString:@"CCUIStatusBar"]) return YES;
    }
    return NO;
}

// The full-screen dim / blur behind Control Center, and behind an expanded module, fades on a very
// short spring, so it is gone while the tiles are still fading out.
static BOOL IsCCBackdrop(UIView *v) {
    UIWindow *w = v.window;
    if (!w) return NO;
    CGSize ws = w.bounds.size, s = v.bounds.size;
    if (s.width < ws.width * 0.9 || s.height < ws.height * 0.9) return NO;
    NSString *n = NSStringFromClass(v.class);
    if ([n containsString:@"IconList"] || [n containsString:@"ScrollView"]) return NO;
    BOOL bg = [n containsString:@"Material"] || [n containsString:@"Backdrop"] || [n containsString:@"Blur"] ||
              [n containsString:@"Background"] || [n isEqualToString:@"UIVisualEffectView"];
    if (!bg) return NO;
    int d = 0;
    for (UIView *a = v; a && d < 8; a = a.superview, d++) if ([NSStringFromClass(a.class) hasPrefix:@"CCUI"]) return YES;
    return [NSStringFromClass(w.class) containsString:@"ControlCenter"];
}

static CAAnimation *RetuneStockSpring(CALayer *layer, CAAnimation *anim) {
    if (!MotionAllowed()) return anim;
    BOOL spring = [anim isKindOfClass:CASpringAnimation.class];
    if (!spring && ![anim isKindOfClass:CABasicAnimation.class]) return anim;
    NSString *kp = ((CAPropertyAnimation *)anim).keyPath;
    if (([kp isEqualToString:@"opacity"] || [kp hasPrefix:@"filters."]) && anim.duration <= 0.6) {
        id bd = layer.delegate;
        if ([bd isKindOfClass:UIView.class] && IsCCBackdrop(bd)) {
            CAAnimation *c = [anim copy];
            if (spring) {
                CASpringAnimation *sa = (CASpringAnimation *)c;
                sa.mass = 1.0; sa.stiffness = 150.0; sa.damping = 24.5;   // critically damped, ~0.4 s
                sa.duration = sa.settlingDuration;
            } else {
                c.duration = 0.4;
            }
            return c;
        }
    }
    if (!spring) return anim;
    BOOL page = anim.duration > 0.55 && anim.duration <= 1.6;
    if (!page && (anim.duration < 0.3 || anim.duration > 0.55)) return anim;
    id del = layer.delegate;
    if (![del isKindOfClass:UIView.class]) return anim;
    if (page) {
        // open / close: the stock curve, played faster (stock settles over 1-1.5 s)
        if (!([kp isEqualToString:@"transform"] || [kp isEqualToString:@"opacity"] || [kp isEqualToString:@"position"]) || !IsPageContext(del)) return anim;
        CASpringAnimation *c = [anim copy];
        c.speed = anim.speed * gPageSpeed;
        return c;
    }
    static NSSet *ok;
    if (!ok) ok = [NSSet setWithArray:@[@"position", @"bounds.size", @"bounds.origin", @"bounds", @"cornerRadius", @"transform"]];
    if (![ok containsObject:kp] || !IsExpandContext(del)) return anim;
    CASpringAnimation *c = [anim copy];
    c.mass = 1.0;
    c.stiffness = gSpringK;
    c.damping = gSpringD;
    c.duration = c.settlingDuration;
    return c;
}

// The rim / sheen layers we add are plain sublayers whose frame is set at layout time, so they
// jump to the final size while the view itself springs there (the ghost outlines). Give them the
// same spring on size and position as the view.
// The glass that replaces an MTMaterialView must animate exactly like it. Copy every stock property
// animation the material's layer receives onto the glass layer (same keyPath, same values), after
// syncing the glass model layer to the material's final model values.
static void MirrorToGlass(CALayer *layer, CAAnimation *anim) {
    if (![anim isKindOfClass:CAPropertyAnimation.class]) return;
    UIView *dv = (UIView *)layer.delegate;
    if (![dv isKindOfClass:UIView.class] || ![NSStringFromClass(dv.class) containsString:@"MTMaterialView"]) return;
    UIView *glass = objc_getAssociatedObject(dv, kGlassKey);
    if (!glass || [glass isKindOfClass:NSNull.class]) return;
    NSString *kp = ((CAPropertyAnimation *)anim).keyPath;
    static NSSet *ok;
    if (!ok) ok = [NSSet setWithArray:@[@"position", @"bounds.size", @"bounds.origin", @"bounds", @"cornerRadius", @"transform"]];
    if (!kp || ![ok containsObject:kp]) return;
    CALayer *gl = glass.layer;
    if (!CGRectEqualToRect(gl.bounds, layer.bounds)) gl.bounds = layer.bounds;
    if (!CGPointEqualToPoint(gl.position, layer.position)) gl.position = layer.position;
    CAAnimation *cp = [anim copy];
    cp.removedOnCompletion = YES;           // never let a copied animation pin the glass at an old size
    cp.fillMode = kCAFillModeRemoved;
    // iOS 27: the glass shell trails the panel and settles slightly later
    if ([cp isKindOfClass:CASpringAnimation.class]) ((CASpringAnimation *)cp).stiffness *= 0.6;
    if (cp.repeatCount > 0 || cp.autoreverses) return;
    [gl addAnimation:cp forKey:[@"xc.glass." stringByAppendingString:kp]];
}

static void FollowSizeAnimation(CALayer *layer, CAAnimation *anim) {
    MirrorToGlass(layer, anim);
    if (![anim isKindOfClass:CASpringAnimation.class]) return;
    CASpringAnimation *sa = (CASpringAnimation *)anim;
    if (![sa.keyPath isEqualToString:@"bounds.size"]) return;
    id fromV = sa.fromValue, toV = sa.toValue;
    if (![fromV isKindOfClass:NSValue.class] || ![toV isKindOfClass:NSValue.class]) return;
    if (strcmp([(NSValue *)fromV objCType], @encode(CGSize)) != 0) return;
    UIView *dv = (UIView *)layer.delegate;
    const void *k[6] = { kEdgesKey, kHotTLKey, kHotBRKey, kStreakKey, kSheenKey, kShadeKey };
    CGSize f = [fromV CGSizeValue], t = [toV CGSizeValue];
    for (int i = 0; i < 6; i++) {
        CALayer *l = objc_getAssociatedObject(dv, k[i]);
        if (![l isKindOfClass:CALayer.class] || l.hidden) continue;
        CASpringAnimation *c = [sa copy];
        [l addAnimation:c forKey:@"xc.decor.size"];
        CASpringAnimation *p = [sa copy];
        p.keyPath = @"position";
        p.fromValue = [NSValue valueWithCGPoint:CGPointMake(f.width / 2, f.height / 2)];
        p.toValue = [NSValue valueWithCGPoint:CGPointMake(t.width / 2, t.height / 2)];
        [l addAnimation:p forKey:@"xc.decor.pos"];
    }
}

// The layer hook is process-wide, so this runs for every animation SpringBoard adds, and layers can be
// animated off the main thread: the scratch buffer and the "already seen" set are shared, so the dump is
// serialised. With the view dumps on by default this path is live from the first frame of the home screen.
static os_unfair_lock gAnimLogLock = OS_UNFAIR_LOCK_INIT;

static void LogCCAnimation(UIView *v, CAAnimation *anim, NSString *key) {
    BOOL cc = NO;
    for (UIView *a = v; a && !cc; a = a.superview) {
        NSString *n = NSStringFromClass(a.class);
        cc = [n hasPrefix:@"CCUI"] || [n hasPrefix:@"ControlCenter"] ||
             [n containsString:@"ContextMenu"] || [n containsString:@"CCUIModule"];
    }
    if (!cc) return;

    static NSMutableSet *seen;
    static NSMutableString *acc;
    static int lines;
    os_unfair_lock_lock(&gAnimLogLock);
    if (!seen) { seen = [NSMutableSet set]; acc = [NSMutableString string]; }
    NSString *kp = [anim isKindOfClass:CAPropertyAnimation.class] ? ((CAPropertyAnimation *)anim).keyPath : @"-";
    NSString *sig = [NSString stringWithFormat:@"%@|%@|%@|%@", NSStringFromClass(v.class), key, kp, NSStringFromClass(anim.class)];
    if ([seen containsObject:sig] || lines > 160) { os_unfair_lock_unlock(&gAnimLogLock); return; }
    [seen addObject:sig]; lines++;
    NSString *parent = v.superview ? NSStringFromClass(v.superview.class) : @"-";
    [acc appendFormat:@"%@ (in %@) key=%@ keyPath=%@ %@ dur=%.2f size=%@\n", NSStringFromClass(v.class), parent, key, kp,
     NSStringFromClass(anim.class), anim.duration, NSStringFromCGSize(v.bounds.size)];
    LGWriteDiagnostic(@"ios26ccstyle-anim-log.txt", acc);
    os_unfair_lock_unlock(&gAnimLogLock);
}

static void (*orig_addAnimation)(CALayer *, SEL, CAAnimation *, NSString *);
static void new_addAnimation(CALayer *self, SEL _cmd, CAAnimation *anim, NSString *key) {
    // CALayer is hooked process-wide, so every animation in SpringBoard lands here: get out with
    // two flag tests when there is nothing to retune (motion off, tweak off, or our own keys).
    if (!gEnabled || (!MotionAllowed() && !gDebugDump) || [key hasPrefix:@"xc."]) {
        orig_addAnimation(self, _cmd, anim, key);
        return;
    }
    CAAnimation *use = [key hasPrefix:@"xc."] ? anim : RetuneStockSpring(self, anim);
    orig_addAnimation(self, _cmd, use, key);
    if (MotionAllowed() && ![key hasPrefix:@"xc."] && [self.delegate isKindOfClass:UIView.class]) FollowSizeAnimation(self, use);
    if (!gDebugDump || [key hasPrefix:@"xc."]) return;
    id d = self.delegate;
    if (![d isKindOfClass:UIView.class]) return;
    LogCCAnimation((UIView *)d, anim, key);
}

DEFINE_HOOKS(ModuleFill,   CCKindModuleFill)
DEFINE_HOOKS(Container,    CCKindContainer)
DEFINE_HOOKS(Template,     CCKindModule)
DEFINE_HOOKS(ButtonModule, CCKindModule)
DEFINE_HOOKS(Accessory,    CCKindRound)
DEFINE_HOOKS(Power,        CCKindRound)
DEFINE_HOOKS(Round,        CCKindRound)
DEFINE_HOOKS(Slider,       CCKindSlider)
DEFINE_HOOKS(Stepped,      CCKindSlider)

DEFINE_TOUCH_HOOKS(Template, 0.95)
DEFINE_TOUCH_HOOKS(ButtonModule, 0.93)
DEFINE_TOUCH_HOOKS(Round, 0.9)
DEFINE_TOUCH_HOOKS(Slider, 1.04)

// MARK: - Live reload ---------------------------------------------------------

// ---- iOS 27 page scrolling ------------------------------------------------------------------
// The Control Center pages sit in a plain UIScrollView, so there is no spring to retune: the effect
// is driven by the scroll offset. A page scales down and fades as it leaves the centre.
static void (*orig_sv_ls)(UIScrollView *, SEL);
static const void *kPageScrollKey = &kPageScrollKey;
static const void *kPageFxKey = &kPageFxKey;

static void DumpPageScroll(UIScrollView *sv) {
    NSMutableString *o = [NSMutableString stringWithFormat:@"%@ bounds=%@ content=%@ paging=%d\n", NSStringFromClass(sv.class),
        NSStringFromCGRect(sv.bounds), NSStringFromCGSize(sv.contentSize), sv.pagingEnabled];
    for (UIView *p in sv.subviews) {
        [o appendFormat:@"  %@ frame=%@ subviews=%lu\n", NSStringFromClass(p.class), NSStringFromCGRect(p.frame), (unsigned long)p.subviews.count];
        for (UIView *q in p.subviews) [o appendFormat:@"    %@ frame=%@\n", NSStringFromClass(q.class), NSStringFromCGRect(q.frame)];
    }
    LGWriteDiagnostic(@"ios26ccstyle-scroll.txt", o);
}

static void CollectPages(UIView *v, int depth, NSMutableArray *out) {
    for (UIView *s in v.subviews) {
        if ([NSStringFromClass(s.class) hasSuffix:@"IconListView"]) { [out addObject:s]; continue; }
        if (depth < 3) CollectPages(s, depth + 1, out);
    }
}

static const void *kPageGenKey = &kPageGenKey;
static const void *kPageStateKey = &kPageStateKey;

@interface XCPageState : NSObject
@property (nonatomic) CGFloat off, speed, peak, k;
@property (nonatomic) BOOL armed, released, finger, dirty, dumped, styled;
@property (nonatomic) CFTimeInterval time;
// finger flick landing (a spring of our own, see PageSpringBegin)
@property (nonatomic) BOOL wasTracking, spring, pending, vertical;
@property (nonatomic) CGFloat vel, shift, sD0, sV0, sT, sO0, relaxFrom;
@property (nonatomic) CFTimeInterval sT0, sLast, relaxT0;
@property (nonatomic, strong) CADisplayLink *link;
@end
@implementation XCPageState
// The display link is the only thing that keeps a pager state alive; a page that goes away must not
// leave a ticking link behind.
- (void)dealloc { [_link invalidate]; }
@end

// Pages stretch along the scroll direction and squeeze across it, area kept (k = 0.05: 5 % taller, 1/1.05 as wide).
static CATransform3D PageStretch(BOOL vertical, CGFloat k) {
    CGFloat s = 1.0 + k;
    return vertical ? CATransform3DMakeScale(1.0 / s, s, 1.0) : CATransform3DMakeScale(s, 1.0 / s, 1.0);
}

static CATransform3D PageXform(BOOL vertical, CGFloat k, CGFloat shift) {
    CATransform3D t = PageStretch(vertical, k);
    if (fabs(shift) > 0.01) t = CATransform3DConcat(t, CATransform3DMakeTranslation(vertical ? 0 : shift, vertical ? shift : 0, 0));
    return t;
}

// The stretch lets go as the page lands: a straight line back to rest in 140 ms, no swing the other way.
static void ReleasePageStretch(NSArray *pages, BOOL vertical, CGFloat k) {
    if (fabs(k) < 0.004) return;
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform"];
    a.fromValue = [NSValue valueWithCATransform3D:PageStretch(vertical, k)];
    a.toValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
    a.duration = 0.14;
    a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    for (UIView *p in pages) [p.layer addAnimation:a forKey:@"xc.relax"];
}

static void ApplyPageScrollTo(UIScrollView *self, BOOL settle);

// No scroll callback for 55 ms: the scroll has landed. This runs on every scroll frame, so the
// pending check is cancelled and replaced instead of a new dispatch_after being queued each time
// (60 timers a second, all but the last one no-ops, for as long as the finger moves).
static const void *kPageSettleKey = &kPageSettleKey;
static void SchedulePageSettle(UIScrollView *self) {
    dispatch_block_t pending = (dispatch_block_t)objc_getAssociatedObject(self, kPageSettleKey);
    if (pending) dispatch_block_cancel(pending);
    NSUInteger gen = [objc_getAssociatedObject(self, kPageGenKey) unsignedIntegerValue] + 1;
    objc_setAssociatedObject(self, kPageGenKey, @(gen), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIScrollView *wself = self;
    dispatch_block_t block = dispatch_block_create(0, ^{
        UIScrollView *sv = wself;
        if (!sv) return;
        objc_setAssociatedObject(sv, kPageSettleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if ([objc_getAssociatedObject(sv, kPageGenKey) unsignedIntegerValue] == gen) ApplyPageScrollTo(sv, YES);
    });
    objc_setAssociatedObject(self, kPageSettleKey, block, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.055 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), block);
}

// The first layout of the pager is what the first page is styled in, while Control Center is still
// sizing it. Style the tracked views again once the open animation has run (twice: the spring can
// still be settling at the first delay). Runs once per pager view.
static const void *kStyleSettleKey = &kStyleSettleKey;
static void ScheduleStyleSettle(UIScrollView *sv) {
    if (objc_getAssociatedObject(sv, kStyleSettleKey)) return;
    objc_setAssociatedObject(sv, kStyleSettleKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIScrollView *wsv = sv;
    const double delays[] = { 0.35, 1.10 };
    for (int i = 0; i < 2; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!wsv) return;
            if (i == 1) objc_setAssociatedObject(wsv, kStyleSettleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            CaptureBackdropLuminance(wsv.window);   // what the tiles are actually over
            RestyleTrackedGeom();
            PerfFlush();
        });
    }
}

// Fade by distance from the centre and the stretch, for the scroll position `off` (the displayed one while a
// landing spring runs) and the landing spring's shift.
static void LayoutPages(UIScrollView *sv, NSArray *pages, BOOL vertical, CGFloat span, CGFloat off, CGFloat k, CGFloat shift) {
    CGFloat fx = gPageFx / 100.0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (UIView *p in pages) {
        CGPoint m = [p.superview convertPoint:p.center toView:sv];
        CGFloat d = (vertical ? m.y : m.x) - off - span * 0.5;
        CGFloat a = MIN(1.0, fabs(d / span));
        CGFloat opacity = 1.0 - 0.83 * fx * a;
        CALayer *l = p.layer;
        if (!objc_getAssociatedObject(p, kPageFxKey)) {
            l.allowsGroupOpacity = NO;   // fade each tile on its own: no offscreen pass over the glass
            objc_setAssociatedObject(p, kPageFxKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (fabs(l.opacity - opacity) > 0.004) l.opacity = opacity;
        l.transform = PageXform(vertical, k, shift);
    }
    [CATransaction commit];
}

// ---- finger flick landing ---------------------------------------------------------------------
// iOS 27, measured on the recording (page top edge, frame by frame): a flicked page does not just slow
// down, it carries on past its place by about 26 pt and eases back over ~0.4 s. That is a spring with
// w = 11.2 rad/s and damping ratio 0.86, started with the speed of the finger (the fit is within 1 pt).
// The stock paging deceleration lands flat and slower, so while it runs the pages are drawn where the
// spring says, by shifting them by the difference with a display link; the page effect follows the
// displayed position.
static const double kSpringW = 11.2, kSpringZ = 0.86;

static void SpringEval(double A, double v0, double t, double *d, double *v) {
    double wd = kSpringW * sqrt(1.0 - kSpringZ * kSpringZ), zw = kSpringZ * kSpringW;
    double B = (v0 + zw * A) / wd, E = exp(-zw * t), C = cos(wd * t), S = sin(wd * t);
    *d = E * (A * C + B * S);
    *v = E * (-zw * (A * C + B * S) + wd * (-A * S + B * C));
}

@interface XCPageLink : NSObject
@property (nonatomic, weak) UIScrollView *sv;
- (void)tick:(CADisplayLink *)l;
@end

static void PageSpringEnd(UIScrollView *sv, XCPageState *st) {
    NSMutableArray *pages = [NSMutableArray array];
    CollectPages(sv, 0, pages);
    st.spring = NO; st.pending = NO; st.shift = 0; st.k = 0; st.finger = NO; st.armed = NO;
    [st.link invalidate]; st.link = nil;
    CGSize b = sv.bounds.size;
    CGFloat span = st.vertical ? b.height : b.width;
    LayoutPages(sv, pages, st.vertical, span, st.vertical ? sv.contentOffset.y : sv.contentOffset.x, 0, 0);
}

@implementation XCPageLink
- (void)tick:(CADisplayLink *)l {
    UIScrollView *sv = self.sv;
    XCPageState *st = sv ? objc_getAssociatedObject(sv, kPageStateKey) : nil;
    if (!st || !st.spring) { [l invalidate]; return; }
    if (sv.tracking) { PageSpringEnd(sv, st); return; }   // a finger took the page again
    CFTimeInterval now = CACurrentMediaTime();
    CGFloat dt = MAX(0.001, now - st.sLast);
    st.sLast = now;
    CGSize b = sv.bounds.size, c = sv.contentSize;
    CGFloat span = st.vertical ? b.height : b.width;
    CGFloat o = st.vertical ? sv.contentOffset.y : sv.contentOffset.x;
    NSMutableArray *pages = [NSMutableArray array];
    CollectPages(sv, 0, pages);

    if (st.pending) {
        // The stock deceleration has just begun; it ends on a page boundary in the direction it moves.
        if (fabs(o - st.sO0) > 1.0) {
            CGFloat q = o / span, maxOff = MAX(0, st.vertical ? c.height - b.height : c.width - b.width);
            CGFloat T = ((o > st.sO0) ? ceil(q - 1e-3) : floor(q + 1e-3)) * span;
            st.sT = MIN(maxOff, MAX(0, T));
            st.sD0 = o - st.sT;
            st.sT0 = now;
            st.pending = NO;
        } else if (now - st.sT0 > 0.15) { PageSpringEnd(sv, st); return; }   // it did not move on
        else { LayoutPages(sv, pages, st.vertical, span, o, st.k, 0); return; }
    }

    CFTimeInterval t = now - st.sT0;
    double d, v;
    SpringEval(st.sD0, st.sV0, t, &d, &v);
    CGFloat sp = fabs(v), disp = st.sT + d;
    st.shift = o - disp;   // the pages are drawn at `disp`, the scroll view is at `o`
    BOOL springDone = (t > 0.15 && fabs(d) < 0.3 && sp < 8) || t > 1.5;
    BOOL landed = fabs(o - st.sT) < 0.3 && !sv.decelerating;
    if (!st.released) {
        st.peak = MAX(st.peak, sp);
        if (sp > 1500) st.armed = YES;
        if ((st.armed && sp < 320) || springDone) { st.released = YES; st.relaxFrom = st.k; st.relaxT0 = now; }
        else {
            CGFloat target = MIN(1.0, st.peak / 1500.0) * 0.07 * (gPageFx / 100.0) / 0.6;
            st.k += (target - st.k) * (1.0 - exp(-dt / 0.08));
        }
    }
    if (st.released) st.k = st.relaxFrom * MAX(0.0, 1.0 - (now - st.relaxT0) / 0.14);
    if (springDone && landed && st.released && now - st.relaxT0 >= 0.14) { PageSpringEnd(sv, st); return; }
    if (t > 2.5) { PageSpringEnd(sv, st); return; }
    LayoutPages(sv, pages, st.vertical, span, disp, st.k, st.shift);
}
@end

// The lift of a finger that leaves the pages moving. The stock deceleration keeps running (Control Center
// keeps its pages loaded and visible by it); the pages are drawn where the spring says, by shifting them
// by the difference. The page the stock deceleration lands on is read from the way it moves.
static void PageSpringBegin(UIScrollView *sv, XCPageState *st, BOOL vertical, CGFloat span, CGFloat vel) {
    NSMutableArray *pages = [NSMutableArray array];
    CollectPages(sv, 0, pages);
    for (UIView *p in pages) [p.layer removeAnimationForKey:@"xc.relax"];
    st.vertical = vertical;
    st.sO0 = vertical ? sv.contentOffset.y : sv.contentOffset.x;
    st.sV0 = vel;
    st.sT0 = st.sLast = CACurrentMediaTime();
    st.spring = YES; st.pending = YES; st.released = NO; st.shift = 0;
    st.peak = MAX(st.peak, fabs(vel)); st.armed = fabs(vel) > 1500;
    XCPageLink *tgt = [XCPageLink new];
    tgt.sv = sv;
    st.link = [CADisplayLink displayLinkWithTarget:tgt selector:@selector(tick:)];
    [st.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

// iOS 27, measured frame by frame on a recording of finger flicks between pages: a page fades with its
// distance from the centre (about half at a full page away) and, while the pages move, is stretched along
// the scroll by up to 7 % (area kept; it builds over about 200 ms and is held while the flick runs, set by
// its speed: full at 1500 pt/s). The stretch is released as the flick slows to a stop, at about 250 pt/s
// (ReleasePageStretch: a straight line home in 140 ms). Only a scroll that a finger started gets any of this;
// the side buttons' scroll stays stock.
static void ApplyPageScrollTo(UIScrollView *self, BOOL settle) {
    if (!gEnabled) return;
    // Closed control center / switched page: no scroll frames to decorate, and the display link work
    // would be pure cost (battery).
    if (!self.window || self.window.hidden || self.window.alpha < 0.01) return;
    NSNumber *flag = objc_getAssociatedObject(self, kPageScrollKey);
    if (!flag) {
        flag = @([NSStringFromClass(self.class) isEqualToString:@"CCUIIconScrollView"]);   // not the home screen's SBIconScrollView
        objc_setAssociatedObject(self, kPageScrollKey, flag, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!flag.boolValue) return;

    CGSize c = self.contentSize, b = self.bounds.size;
    BOOL vertical = c.height > b.height * 1.2;
    CGFloat span = vertical ? b.height : b.width;
    if (span < 100) return;

    NSMutableArray *pages = [NSMutableArray array];
    CollectPages(self, 0, pages);
    CGFloat fx = gPageFx / 100.0;

    XCPageState *st = objc_getAssociatedObject(self, kPageStateKey);
    if (!st) {
        st = [XCPageState new];
        objc_setAssociatedObject(self, kPageStateKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!st.dumped) { st.dumped = YES; DumpPageScroll(self); }   // once the view has its real size
    if (!st.styled && self.window) { st.styled = YES; ScheduleStyleSettle(self); }
    // Everything below this line moves the pages. Reduce Motion, or the motion switch, must not take
    // the settle pass above with it (that one is what keeps the look right, not an animation).
    if (!MotionAllowed()) return;
    if (st.spring) return;   // the landing spring (its display link) owns the pages
    if (gPageSpring && !settle) {
        UIPanGestureRecognizer *pan = self.panGestureRecognizer;
        CGFloat pv = pan ? -(vertical ? [pan velocityInView:self].y : [pan velocityInView:self].x) : 0;
        if (self.tracking) { st.wasTracking = YES; if (fabs(pv) > 1) st.vel = pv; }
        else if (st.wasTracking) {
            st.wasTracking = NO;
            if (self.decelerating) PageSpringBegin(self, st, vertical, span, fabs(pv) > 1 ? pv : st.vel);
        }
    }
    if (settle && self.decelerating) { SchedulePageSettle(self); return; }   // a late frame, not a landing

    CGFloat off = vertical ? self.contentOffset.y : self.contentOffset.x;
    if (!settle && (self.tracking || self.dragging)) st.finger = YES;
    if (!st.finger && !settle) {
        if (st.dirty && fabs(off - st.off) > 0.5) {   // a scroll without a finger (side buttons): back to stock
            st.dirty = NO;
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            for (UIView *p in pages) {
                [p.layer removeAnimationForKey:@"xc.relax"];
                p.layer.opacity = 1.0;
                p.layer.transform = CATransform3DIdentity;
            }
            [CATransaction commit];
        }
        return;
    }

    CFTimeInterval now = CACurrentMediaTime(), dt = now - st.time;
    BOOL lands = NO;
    if (settle) {
        lands = !st.released;   // the slowing down did not catch this landing
        st.speed = st.peak = 0;
        st.armed = NO;
    } else if (dt > 0.004) {
        st.speed = 0.5 * st.speed + 0.5 * (dt < 0.25 ? fabs(off - st.off) / dt : 0);
        if (st.released && (self.tracking || st.speed > 1500)) {   // a new touch or flick takes over from the landing
            st.released = NO; st.peak = 0; st.k = 0;
            for (UIView *p in pages) [p.layer removeAnimationForKey:@"xc.relax"];
        }
        st.peak = MAX(st.peak, st.speed);
        if (self.tracking) st.armed = NO;   // a drag that slows down under the finger is not a landing
        else if (st.speed > 1500) st.armed = YES;
        else if (st.armed && st.speed < 320) { st.armed = NO; if (!st.released) { st.released = YES; lands = YES; } }
        if (!st.released) {
            CGFloat target = MIN(1.0, st.peak / 1500.0) * 0.07 * fx / 0.6;
            st.k += (target - st.k) * (1.0 - exp(-dt / 0.08));
        }
    }
    if (settle || dt > 0.004) { st.off = off; st.time = now; }

    CGFloat from = st.k;
    if (lands) { st.k = 0; st.released = YES; }
    st.dirty = YES;

    LayoutPages(self, pages, vertical, span, off, st.k, st.shift);
    if (lands) ReleasePageStretch(pages, vertical, from);

    if (!settle) SchedulePageSettle(self);
    else st.finger = NO;
}

static void ApplyPageScroll(UIScrollView *self) { ApplyPageScrollTo(self, NO); }

static void new_sv_ls(UIScrollView *self, SEL _cmd) {
    orig_sv_ls(self, _cmd);
    ApplyPageScroll(self);
}

// UIScrollView does not always relayout while it scrolls; the private scroll notification does fire.
static void (*orig_sv_nds)(UIScrollView *, SEL);
static void new_sv_nds(UIScrollView *self, SEL _cmd) {
    orig_sv_nds(self, _cmd);
    ApplyPageScroll(self);
}

static void YieldControlCenterFromLiquidAss(void);

static void PrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                         const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LoadPrefs();
        if (!gEnabled) {
            // Off: put every view we styled back the way the system had it, even if it never lays
            // out again (an expanded module that stays on screen, say).
            for (UIView *v in gTracked.allObjects) RestoreStock(v);
            YieldControlCenterFromLiquidAss();
            return;
        }
        for (UIView *v in gTracked.allObjects) {
            if (objc_getAssociatedObject(v, kMenuKey) && !objc_getAssociatedObject(v, kStyledKey)) {
                ApplyMenuDecor(v);
            }
            [v setNeedsLayout];
            [v layoutIfNeeded];
        }
        YieldControlCenterFromLiquidAss();
    });
}

// MARK: - Entry point ---------------------------------------------------------

// Logs older than one change are deleted. The first run of each version is recorded, and whatever was
// written before the previous version first ran is removed (a crash report from an old build once
// outlived six updates). The current backboardd session log (xenonglass.log) and the crash-loop guard
// are never touched.
static void PruneOldLogs(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = LGDiagnosticsDirectory();
    NSString *state = [dir stringByAppendingPathComponent:@"ios26ccstyle-changes.state"];   // "<version> <first run> <previous version's first run>"
    NSArray *s = [[NSString stringWithContentsOfFile:state encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@" "];
    BOOL known = s.count == 3;
    time_t now = time(NULL), cur = known ? (time_t)[s[1] longLongValue] : now, prev = known ? (time_t)[s[2] longLongValue] : now;
    if (!known || ![s[0] isEqualToString:@XC_VERSION]) {
        prev = known ? cur : now;   // the very first run keeps nothing that is older than itself
        cur = now;
        [[NSString stringWithFormat:@"%s %ld %ld", XC_VERSION, (long)cur, (long)prev] writeToFile:state atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    for (NSString *n in [fm contentsOfDirectoryAtPath:dir error:nil]) {
        if (![n hasPrefix:@"ios26ccstyle-"] && ![n hasPrefix:@"xenonglass-"]) continue;
        // An active crash-loop lockout and the launch breadcrumb must survive: both are what a boot
        // that never came up leaves behind to be read.
        if ([n containsString:@"guard"] || [n containsString:@"crashloop"] || [n containsString:@"launch"]) continue;
        NSString *path = [dir stringByAppendingPathComponent:n];
        NSDate *m = [fm attributesOfItemAtPath:path error:nil].fileModificationDate;
        if (m && m.timeIntervalSince1970 < prev) [fm removeItemAtPath:path error:nil];
    }
    // 0.4.x left its files in Apple's own directories. Remove what is older than the previous version:
    // a backboardd that had to fall back to the old location keeps its current session.
    for (NSString *legacy in @[@"/var/mobile/Library/Preferences", @"/var/mobile/Library/Accessibility"]) {
        for (NSString *n in [fm contentsOfDirectoryAtPath:legacy error:nil]) {
            if (![n hasPrefix:@"ios26ccstyle-"] && ![n hasPrefix:@"xenonglass-"]) continue;
            if ([n containsString:@"guard"] || [n containsString:@"crashloop"] || [n containsString:@"launch"]) continue;
            NSString *path = [legacy stringByAppendingPathComponent:n];
            NSDate *m = [fm attributesOfItemAtPath:path error:nil].fileModificationDate;
            if (m && m.timeIntervalSince1970 < prev) [fm removeItemAtPath:path error:nil];
        }
    }
}

// Liquid (Gl)ass by dylv can be installed next to this tweak. Both style the Control Center, and two styles on
// one tile fight (double rounding, double glass), so this tweak keeps the Control Center and switches that
// surface off in Liquid (Gl)ass. Everything else of Liquid (Gl)ass (dock, tab bars, keyboard ...) keeps working.
//
// Written through CFPreferences, not by rewriting dylv.liquidassprefs.plist: the plist is another tweak's
// data, its process may be writing the same file, and a whole-file rewrite puts back whatever we happened to
// read. The value we replaced is remembered, so turning "Own Control Center" off (or switching this tweak
// off) hands the Control Center back instead of leaving Liquid (Gl)ass disabled for good.
static NSString *const kLiquidAssDomain = @"dylv.liquidassprefs";
static NSString *const kLiquidAssCCKey = @"ControlCenter.Enabled";
static NSString *const kLiquidAssSavedKey = @"liquidass.originalControlCenter";

// Cached for a couple of seconds, not forever: Liquid (Gl)ass can be installed or updated while
// SpringBoard is running, and a dispatch_once answer would keep this tweak from ever handing the
// Control Center over (or back) until the next respring.
static BOOL LiquidAssInstalled(void) {
    static BOOL installed;
    static CFTimeInterval last = -100.0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - last > 2.0) {
        last = now;
        installed = [[NSFileManager defaultManager] fileExistsAtPath:
                        @"/var/jb/Library/MobileSubstrate/DynamicLibraries/liquidass.dylib"]
                 || dlsym(RTLD_DEFAULT, "LGLiquidGlassViewCreate") != NULL;
    }
    return installed;
}

static id LiquidAssControlCenterValue(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kLiquidAssDomain);
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)kLiquidAssCCKey,
                                                       (__bridge CFStringRef)kLiquidAssDomain));
}

static void LiquidAssSetControlCenter(id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)kLiquidAssCCKey,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)kLiquidAssDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kLiquidAssDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("dylv.liquidassprefs/Reload"), NULL, NULL, YES);
}

static void YieldControlCenterFromLiquidAss(void) {
    if (!LiquidAssInstalled()) return;
    id saved = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)kLiquidAssSavedKey,
                                                           (__bridge CFStringRef)kPrefsDomain));
    BOOL want = gEnabled && PrefBool(@"takeOverFromLiquidAss", YES);
    if (!want) {
        if (!saved) return;   // this tweak never changed it
        LiquidAssSetControlCenter([saved isKindOfClass:NSNull.class] ? nil : saved);
        CFPreferencesSetAppValue((__bridge CFStringRef)kLiquidAssSavedKey, NULL,
                                 (__bridge CFStringRef)kPrefsDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)kPrefsDomain);
        LGWriteDiagnostic(@"ios26ccstyle-liquidass.txt",
                          @"own Control Center off: handed the surface back to Liquid (Gl)ass\n");
        return;
    }
    id cur = LiquidAssControlCenterValue();
    if ([cur isKindOfClass:NSNumber.class] && ![cur boolValue]) return;   // already off
    if (!saved) {   // remember what was there before the first takeover
        CFPreferencesSetAppValue((__bridge CFStringRef)kLiquidAssSavedKey,
                                 (__bridge CFPropertyListRef)(cur ?: (id)[NSNull null]),
                                 (__bridge CFStringRef)kPrefsDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)kPrefsDomain);
    }
    LiquidAssSetControlCenter(@NO);
    LGWriteDiagnostic(@"ios26ccstyle-liquidass.txt",
                      @"Liquid (Gl)ass found: its Control Center surface is switched off\n");
}

// The first thing a bug report needs: the device, the build, which classes were found, whether the
// renderer announced itself, the accessibility state and the switches. Settings > Logs shows this file,
// so a screenshot of the report is enough to tell which build and which path produced a wrong tile.
static NSString *LGHardwareModel(void) {
    size_t size = 0;
    if (sysctlbyname("hw.machine", NULL, &size, NULL, 0) != 0 || size == 0) return @"?";
    char *buf = calloc(1, size + 1);   // sysctl does not promise a terminator
    if (!buf) return @"?";
    NSString *out = @"?";
    size_t got = size;
    if (sysctlbyname("hw.machine", buf, &got, NULL, 0) == 0) {
        buf[size] = '\0';
        out = [NSString stringWithUTF8String:buf] ?: @"?";
    }
    free(buf);
    return out;
}

static void WriteCompatibilityReport(void) {
    NSMutableString *o = [NSMutableString string];
    [o appendFormat:@"ios26ccstyle %s\n", XC_VERSION];
    [o appendFormat:@"ios %@\n", NSProcessInfo.processInfo.operatingSystemVersionString];
    [o appendFormat:@"model %@\n", LGHardwareModel()];
    UIScreen *s = UIScreen.mainScreen;
    if (s) [o appendFormat:@"screen %.0fx%.0f @%.0fx\n", s.nativeBounds.size.width / MAX(1.0, s.nativeScale),
            s.nativeBounds.size.height / MAX(1.0, s.nativeScale), s.nativeScale];
    else [o appendString:@"screen ?\n"];
    [o appendFormat:@"accessibility reduce-motion=%d reduce-transparency=%d increase-contrast=%d low-power=%d\n",
        ReduceMotionOn(), ReduceTransparencyOn(), IncreaseContrastOn(), LowPowerOn()];
    [o appendFormat:@"renderer-ready=%d liquidass-installed=%d\n",
        LGDiagnosticsMarkerExists(@"xenonglass-ready"), LiquidAssInstalled()];
    [o appendFormat:@"prefs enabled=%d modules=%d buttons=%d sliders=%d menus=%d motion=%d pageSpring=%d refract=%d iso=%d%d%d%d grid=%d\n",
        gEnabled, gStyleModules, gStyleButtons, gStyleSliders, gStyleMenus, gMotion, gPageSpring, gRefract,
        gIsoDecor, gIsoGlass, gIsoBlur, gIsoMotion, gSampleGrid];
    static const char *names[] = {
        "CCUIIconScrollView", "CCUIContentModuleBackgroundView", "CCUIContentModuleContentContainerView",
        "CCUIControlTemplateView", "CCUIButtonModuleView", "CCUIAccessoryButton", "CCUIPowerButton",
        "CCUIRoundButton", "CCUIContinuousSliderView", "CCUISteppedSliderView", "CCUIModuleCollectionView",
        "MTMaterialView", "CABackdropLayer",
    };
    [o appendString:@"classes:"];
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++)
        [o appendFormat:@" %s=%d", names[i], objc_getClass(names[i]) != NULL];
    [o appendString:@"\n"];
    LGWriteDiagnostic(@"ios26ccstyle-compat.txt", o);
}

// MARK: - Crash-loop guard ---------------------------------------------------
// A constructor runs again every time SpringBoard restarts, so a build that kills SpringBoard loops the
// device straight into safe mode. Four starts inside 90 s is not a respring, it is a loop: the tweak then
// stays out of the way for that boot (stock Control Center, no hooks) and says why in
// ios26ccstyle-guard.txt. The counter clears itself once a boot has stayed up.
static NSString *const kBootStateName = @"ios26ccstyle-crashloop.state";

static BOOL LGBootIsCrashLoop(void) {
    NSString *path = [LGDiagnosticsDirectory() stringByAppendingPathComponent:kBootStateName];
    NSArray *parts = [[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil]
                         componentsSeparatedByString:@" "];
    long count = 0;
    double when = 0;
    if (parts.count == 2) { count = (long)[parts[0] longLongValue]; when = [parts[1] doubleValue]; }
    time_t now = time(NULL);
    BOOL recent = when > 0 && (double)now - when < 90.0;
    count = recent ? count + 1 : 1;
    [[NSString stringWithFormat:@"%ld %ld", count, (long)now] writeToFile:path atomically:YES
                                                               encoding:NSUTF8StringEncoding error:nil];
    if (count < 4) return NO;
    LGWriteDiagnostic(@"ios26ccstyle-guard.txt",
        [NSString stringWithFormat:@"SpringBoard came back %ld times in under 90 s after this build was loaded,\n"
                                   @"so the tweak is off for this boot: no hooks, stock Control Center.\n"
                                   @"Nothing is changed on disk. A boot that stays up removes this lockout.\n", count]);
    return YES;
}

__attribute__((constructor))
static void IOS26CCStyleInit(void) {
    @autoreleasepool {
        // Every step below is named in ios26ccstyle-launch.txt before it runs: if SpringBoard safe-modes
        // before Control Center is ever opened, the last line of that file is the step that killed it.
        LGLaunchBegin();
        LGLaunchStep("bundle check");
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
            LGLaunchStep("not SpringBoard, nothing to do");
            LGLaunchEnd();
            return;
        }
        LGLaunchStep("boot guard");
        if (LGBootIsCrashLoop()) {
            LGLaunchStep("crash-loop lockout: no hooks this boot");
            LGLaunchEnd();
            return;
        }

        LGLaunchStep("prune logs");
        PruneOldLogs();
        LGLaunchStep("load prefs");
        LoadPrefs();

        // A dylib constructor runs during dyld initialisation, before SpringBoard owns a UIApplication:
        // UIScreen and the accessibility server are not up yet. Reading them here killed SpringBoard at
        // launch (safe mode, Control Center never opened), so the report is built from the main queue
        // once the app is actually running.
        LGLaunchStep("defer compat report");
        dispatch_async(dispatch_get_main_queue(), ^{
            LGLaunchStep("main queue: compat report");
            @autoreleasepool {
                @try { WriteCompatibilityReport(); } @catch (__unused NSException *e) {}
            }
            LGLaunchStep("main queue: compat report done");
        });
        LGLaunchStep("defer 4 s takeover + report");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            LGLaunchStep("alive: 4 s");
            @autoreleasepool {
                YieldControlCenterFromLiquidAss();
                @try { WriteCompatibilityReport(); } @catch (__unused NSException *e) {}   // the renderer marker needs a few seconds
            }
        });
        // Thirty seconds up: this boot is not a crash loop, so the next respring starts at one again.
        LGLaunchStep("defer 30 s boot-ok");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            LGLaunchStep("alive: 30 s, launch path clean");
            LGLaunchEnd();
            [NSFileManager.defaultManager removeItemAtPath:
                [LGDiagnosticsDirectory() stringByAppendingPathComponent:kBootStateName] error:nil];
        });

        // Accessibility changes take effect at once: they change what "motion" and "transparency"
        // mean for this look, and keeping a style that contradicts them is the wrong answer.
        LGLaunchStep("accessibility observers");
        NSArray<NSString *> *notes = @[
            UIAccessibilityReduceMotionStatusDidChangeNotification,
            UIAccessibilityReduceTransparencyStatusDidChangeNotification,
            UIAccessibilityDarkerSystemColorsStatusDidChangeNotification,
        ];
        for (NSString *note in notes) {
            [[NSNotificationCenter defaultCenter] addObserverForName:note object:nil queue:NSOperationQueue.mainQueue
                                                         usingBlock:^(__unused NSNotification *n) {
                gReduceMotionAt = -1.0;   // the cached answer is stale by definition
                LoadPrefs();
                RestyleTrackedGeom();
                PerfFlush();
            }];
        }

        LGLaunchStep("hook CCUIContentModuleBackgroundView");
        Install_ModuleFill  ("CCUIContentModuleBackgroundView");
        LGLaunchStep("hook CCUIContentModuleContentContainerView");
        Install_Container   ("CCUIContentModuleContentContainerView");
        LGLaunchStep("hook CCUIControlTemplateView");
        Install_Template    ("CCUIControlTemplateView");
        LGLaunchStep("hook CCUIButtonModuleView");
        Install_ButtonModule("CCUIButtonModuleView");
        LGLaunchStep("hook CCUIAccessoryButton");
        Install_Accessory   ("CCUIAccessoryButton");
        LGLaunchStep("hook CCUIPowerButton");
        Install_Power       ("CCUIPowerButton");
        LGLaunchStep("hook CCUIRoundButton");
        Install_Round       ("CCUIRoundButton");
        LGLaunchStep("hook CCUIContinuousSliderView");
        Install_Slider      ("CCUIContinuousSliderView");
        LGLaunchStep("hook CCUISteppedSliderView");
        Install_Stepped     ("CCUISteppedSliderView");
        LGLaunchStep("hook CALayer addAnimation");
        InstallHook("CALayer", @selector(addAnimation:forKey:), (IMP)new_addAnimation, (IMP *)&orig_addAnimation);
        LGLaunchStep("hook CCUIControlTemplateView touch");
        InstallTouch_Template("CCUIControlTemplateView");
        LGLaunchStep("hook CCUIButtonModuleView touch");
        InstallTouch_ButtonModule("CCUIButtonModuleView");
        LGLaunchStep("hook CCUIRoundButton touch");
        InstallTouch_Round("CCUIRoundButton");
        LGLaunchStep("hook CCUIContinuousSliderView touch");
        InstallTouch_Slider("CCUIContinuousSliderView");
        LGLaunchStep("hook UIWindow sendEvent");
        InstallHook("UIWindow", @selector(sendEvent:), (IMP)new_win_sendEvent, (IMP *)&orig_win_sendEvent);
        LGLaunchStep("hook MTMaterialView setAlpha");
        InstallHook("MTMaterialView", @selector(setAlpha:), (IMP)hook_setAlpha, (IMP *)&orig_setAlpha);
        // Only the Control Center pager: it was hooked on UIScrollView, so every scroll view in
        // SpringBoard (home screen, apps, menus) paid for two hooks that then bailed out on the
        // class-name check in ApplyPageScrollTo.
        LGLaunchStep("hook CCUIIconScrollView layout");
        InstallHook("CCUIIconScrollView", @selector(layoutSubviews), (IMP)new_sv_ls, (IMP *)&orig_sv_ls);
        LGLaunchStep("hook CCUIIconScrollView notifyDidScroll");
        InstallHook("CCUIIconScrollView", NSSelectorFromString(@"_notifyDidScroll"), (IMP)new_sv_nds, (IMP *)&orig_sv_nds);

        LGLaunchStep("prefs notification");
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        PrefsChanged,
                                        (__bridge CFStringRef)kReloadNotification,
                                        NULL, CFNotificationSuspensionBehaviorCoalesce);
        LGLaunchStep("done");
    }
}
