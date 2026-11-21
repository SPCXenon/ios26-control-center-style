// IOS26CCStyle 0.4.6
// iOS 26 "Liquid Glass" look for the iOS 18 Control Center.
// Target: iOS 18.x · rootless (Dopamine / ElleKit) · arm64e · SpringBoard only.
//
// No CydiaSubstrate dependency: hooks are installed with the ObjC runtime
// (class_addMethod / method_setImplementation). The header pocket (top oval) is
// intentionally left untouched.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <notify.h>
#import <objc/message.h>
#include <unistd.h>

static NSString *const kPrefsDomain = @"com.xenon.ios26ccstyle";
static NSString *const kReloadNotification = @"com.xenon.ios26ccstyle/reload";
#define XC_VERSION "0.4.6"

// MARK: - Preferences ---------------------------------------------------------

static BOOL    gEnabled, gSliderCapsule, gContinuous, gExtraBlur, gMotion, gShimmer;
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
static CGFloat gBgBlur;        // full-screen backdrop blur: 1 = stock, lower = clearer
static BOOL    gRefract;       // real refraction glass via the backboardd renderer
static BOOL    gDebugDump;     // write a view-tree dump (for class-name diagnostics)
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
    gShimmer       = PrefBool(@"shimmer", YES);
    gSpringK       = PrefDouble(@"motionStiffness", 380.0, 50.0, 1000.0);
    gSpringD       = PrefDouble(@"motionDamping", 26.0, 2.0, 80.0);
    gPageSpeed     = PrefDouble(@"pageSpeed", 1.8, 0.5, 3.0);
    gPageFx        = PrefDouble(@"pageEffect", 60.0, 0.0, 100.0);
    gMaxRadius     = (CGFloat)PrefDouble(@"maxRadius", 46.0, 16.0, 70.0);
    gRim           = (CGFloat)PrefDouble(@"rimIntensity", 0.9, 0.0, 1.0);
    gRimWidth      = (CGFloat)PrefDouble(@"rimWidth", 0.9, 0.3, 2.5);
    gSheen         = (CGFloat)PrefDouble(@"sheen", 0.07, 0.0, 0.2);
    gTint          = (CGFloat)PrefDouble(@"fillTint", 0.0, 0.0, 0.3);
    gInner         = (CGFloat)PrefDouble(@"innerRim", 0.1, 0.0, 1.0);
    gHot           = (CGFloat)PrefDouble(@"glow", 0.15, 0.0, 0.3);
    gGlass         = (CGFloat)PrefDouble(@"glassTint", 0.5, 0.0, 1.0);
    gMatAlpha      = 0.35 + 0.65 * gGlass;
    gEffTint       = MIN(0.5, 0.03 + 0.17 * gGlass + gTint);
    gRimMul        = 1.3 - 0.5 * gGlass;
    gReflect       = (CGFloat)PrefDouble(@"reflect", 0.8, 0.0, 1.0);
    gEdgeDark      = (CGFloat)PrefDouble(@"edgeDark", 0.5, 0.0, 1.0);
    gBgBlur        = (CGFloat)PrefDouble(@"bgBlur", 1.0, 0.0, 1.0);
    gDisp          = (CGFloat)PrefDouble(@"dispersion", 0.5, 0.0, 1.0);
    gDebugDump     = PrefBool(@"debugDump", YES);
    gRefract       = PrefBool(@"refraction", YES) && PrefBool(@"Renderer.Enabled", YES);
    gRimColor      = ColorNamed(PrefString(@"rimColor", @"white"));
    gFillColor     = ColorNamed(PrefString(@"fillColor", @"white"));
    gGeneration++;
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
    NSString *key = [NSString stringWithFormat:@"%.0f|%.1f|%d|%.0f", cap, radius, dark, scale];
    UIImage *img = [gEdgeCache objectForKey:key];
    if (img) return img;

    CGFloat S = 2.0 * cap + 2.0;
    CGSize size = CGSizeMake(S, S);
    CGFloat rs   = gReflect * 2.0;
    CGFloat rimE = MIN(1.0, gRim * gRimMul);
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
                           RimUID(1.0 * pk * rimE, -1), RimUI(0.16 * rimE), RimUI(0.16 * rimE), RimUID(0.85 * pk * rimE, 1), NO);
            // ... backed by wider soft strokes so the highlight fades inward like a bevel.
            StrokeGradient(c, size, radius, rimInset, MAX(2.0, bw * 0.55),
                           RimUID(0.40 * rs * rimE, -1), clear, clear, RimUID(0.30 * rs * rimE, 1), NO);
            StrokeGradient(c, size, radius, rimInset, MAX(3.5, bw),
                           RimUID(0.17 * rs * rimE, -1), clear, clear, RimUID(0.12 * rs * rimE, 1), NO);
            // iOS 27: broad, soft dispersion bevel. Warm at the top-left / top-right, cool blue-teal at the
            // bottom-right / bottom-left, fading inward, so the whole edge glows instead of a hairline.
            CGFloat dk = 0.4 + 0.6 * MIN(1.0, gDisp);
            CGFloat da = MIN(0.5, 0.26 * rimE * rs * dk);
            CGFloat dw = MIN(7.0, MAX(3.5, radius * 0.24));
            UIColor *warm = [UIColor colorWithRed:1.0 green:0.80 blue:0.60 alpha:da];
            UIColor *cool = [UIColor colorWithRed:0.52 green:0.78 blue:1.0 alpha:da];
            UIColor *warmS = [UIColor colorWithRed:1.0 green:0.82 blue:0.66 alpha:da * 0.6];
            UIColor *coolS = [UIColor colorWithRed:0.56 green:0.80 blue:1.0 alpha:da * 0.6];
            StrokeGradient(c, size, radius, rimInset, dw, warm, clear, clear, cool, NO);
            StrokeGradient(c, size, radius, rimInset, dw, warmS, clear, clear, coolS, YES);
            // second, refracted line just inside, lit from the opposite diagonal
            StrokeGradient(c, size, radius, rimInset + gRimWidth + 1.1, 0.55,
                           RimUI(0.05 * rimE), RimUI(0.28 * rimE), RimUI(0.28 * rimE), RimUI(0.05 * rimE), YES);
        }
        if (wantOutline) {
            UIColor *o = [UIColor colorWithWhite:0.0 alpha:MIN(0.6, (dark ? 0.38 : 0.20) * gEdgeDark)];
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

    BOOL wantEdges  = gRim > 0.001 || gEdgeDark > 0.001 || gInner > 0.02;
    BOOL wantSheen  = gSheen > 0.001 && gReflect > 0.001;
    BOOL wantHot    = gHot > 0.001 && gReflect > 0.001;
    BOOL wantStreak = gReflect > 0.001;
    BOOL wantShade  = circle;

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
    if (!gExtraBlur) {
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

static void ScaleBackdrop(UIView *s) {
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
    if (!w) return;
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
    WalkBg(w, w, 0, &budget, dump);
    if (dump) {
        [dump writeToFile:@"/var/mobile/Library/Preferences/ios26ccstyle-dump.txt" atomically:YES
                 encoding:NSUTF8StringEncoding error:NULL];
    }
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
        ready = access("/var/mobile/Library/Accessibility/xenonglass-ready", F_OK) == 0;
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
            // base tint on the glass itself (the stock background view is alpha 0)
            g.backgroundColor = [UIColor colorWithWhite:dark ? 0.55 : 1.0 alpha:dark ? 0.05 + 0.10 * gGlass : 0.03 + 0.08 * gGlass];
            [g attachFilter];
            if (!s.hidden) s.hidden = YES;
            continue;
        }
        if ([NSStringFromClass(s.class) containsString:@"Slider"]) continue;
        SyncGlassIn(s, want, radius, dark, depth + 1);
    }
}

static void SyncGlass(UIView *v, CCKind kind, CGFloat radius, BOOL dark, BOOL enabled) {
    if (kind != CCKindModuleFill && kind != CCKindContainer) return;
    BOOL want = enabled && gRefract && GlassRendererReady();
    SyncGlassIn(v, want, radius, dark, 0);
}


// Enabled (selected) toggles: iOS 18 shows them as a nearly opaque white fill drawn by a
// child of the button module, which hides the glass behind it. Round it like the shell and
// let the backdrop show through (iOS 26 "on" tiles are frosted, not solid).
@interface XCOnFillView : UIView
@end
@implementation XCOnFillView
@end

static const void *kOnFillKey = &kOnFillKey;   // on the fill view: its stock backgroundColor

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

static const void *kSynthFillKey = &kSynthFillKey;   // our own fill view, for tiles with no system fill

// Returns the number of system on-fills that were restyled.
static CGFloat OnFillAlpha(BOOL dark) { return (dark ? 0.96 : 0.98) - 0.06 * gGlass; }

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
            CGFloat fa = OnFillAlpha(dark);
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
    fill.backgroundColor = [UIColor colorWithWhite:1.0 alpha:OnFillAlpha(dark)];
}

// Debug dump of the view hierarchy of each module / round button, once per object.
static BOOL OnFillVisible(UIView *v, int depth);
static void DumpViewOnce(UIView *v, CGFloat radius, const char *tag) {
    static NSUInteger dumpGen = (NSUInteger)-1;
    static NSMutableString *acc; static int dumped;
    static NSMapTable *seen;   // view -> last dumped on/off state, so both states of a tile are captured
    if (!gDebugDump || v.bounds.size.height > 200) return;
    if (dumpGen != gGeneration) { dumpGen = gGeneration; acc = [NSMutableString string]; dumped = 0; seen = [NSMapTable weakToStrongObjectsMapTable]; }
    NSNumber *st = @(OnFillVisible(v, 0));
    NSNumber *prev = [seen objectForKey:v];
    if (dumped >= 70 || (prev && [prev isEqual:st])) return;
    [seen setObject:st forKey:v]; dumped++;
    [acc appendFormat:@"%s [%@] %@ %@ r=%.1f curve=%@ own-bg=%@ layer-bg=%@\n", tag, st.boolValue ? @"ON" : @"off", NSStringFromClass(v.class), NSStringFromCGRect(v.bounds), radius,
     v.layer.cornerCurve, v.backgroundColor, (__bridge id)v.layer.backgroundColor];
    DumpTree(v, 1, acc);
    [acc writeToFile:@"/var/mobile/Library/Preferences/ios26ccstyle-module-dump.txt" atomically:YES
            encoding:NSUTF8StringEncoding error:NULL];
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
    NSString *path = [out containsString:@"NowPlaying"] ? @"/var/mobile/Library/Preferences/ios26ccstyle-expanded-np.txt"
                                                         : @"/var/mobile/Library/Preferences/ios26ccstyle-expanded-dump.txt";
    [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
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
    [acc writeToFile:@"/var/mobile/Library/Preferences/ios26ccstyle-tile-chain.txt" atomically:YES
            encoding:NSUTF8StringEncoding error:NULL];
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

static void ApplyStyle(UIView *v, CCKind kind) {
    if (!v.window) return;
    ApplyBackground(v);
    if (kind == CCKindContainer && ContainerHoldsVolume(v)) {
        HideDecor(v);
        SyncGlass(v, kind, 0.0, IsDarkUI(v), NO);
        SetMaterialAlpha(v, 0, 1.0);
        DecorateMenus(v);   // keeps the volume host bare, still styles the stepper buttons
        DumpExpanded(v);
        return;
    }
    if (!gEnabled || !KindEnabled(kind)) {
        HideDecor(v);
        SyncGlass(v, kind, 0.0, IsDarkUI(v), NO);
        SetMaterialAlpha(v, 0, 1.0);
        if (kind == CCKindContainer && gEnabled) DecorateMenus(v);
        return;
    }

    CGRect b = v.bounds;
    if (b.size.width < 4.0 || b.size.height < 4.0) return;

    // Skip the full-page wrapper so no outline is drawn around the whole page.
    if ((kind == CCKindModule || kind == CCKindModuleFill || kind == CCKindContainer) &&
        b.size.height > v.window.bounds.size.height * 0.72) {
        HideDecor(v);
        if (kind == CCKindContainer) DecorateMenus(v);
        return;
    }

    CALayer *layer = v.layer;

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

    layer.cornerCurve   = gContinuous ? kCACornerCurveContinuous : kCACornerCurveCircular;
    layer.cornerRadius  = r;
    layer.masksToBounds = YES;
    layer.borderWidth   = 0.0;

    BOOL darkUI = IsDarkUI(v);
    SetMaterialAlpha(v, 0, darkUI ? gMatAlpha : MAX(gMatAlpha, 0.7));
    SyncGlass(v, kind, r, darkUI, YES);
    BOOL glassOn = gRefract && GlassRendererReady();

    if (kind == CCKindModuleFill) {
        CGFloat ft = glassOn ? 0.0 : (darkUI ? gEffTint * 0.2 : gEffTint * 0.85);
        v.backgroundColor = ft > 0.001 ? [gFillColor colorWithAlphaComponent:ft] : nil;
        ApplyExtraBlur(v, b);
    }

    if (kind == CCKindModule) { StyleOnFillsTop(v, r, darkUI); DumpTileChain(v); }
    else if (kind == CCKindRound) DumpViewOnce(v, r, "round");

    ApplyDecor(v, b, r);

    if (!gTracked) gTracked = [NSHashTable weakObjectsHashTable];
    [gTracked addObject:v];

    if (kind == CCKindContainer) { DecorateMenus(v); DumpExpanded(v); }
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

#define DEFINE_HOOKS(TAG, KIND)                                                     \
    static void (*orig_layout_##TAG)(UIView *, SEL);                                \
    static void new_layout_##TAG(UIView *self, SEL _cmd) {                          \
        orig_layout_##TAG(self, _cmd);                                              \
        ApplyStyle(self, KIND);                                                     \
    }                                                                               \
    static void (*orig_window_##TAG)(UIView *, SEL);                                \
    static void new_window_##TAG(UIView *self, SEL _cmd) {                          \
        orig_window_##TAG(self, _cmd);                                              \
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
    if (!gMotion || !gEnabled) return;
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
    if (!gMotion || !gEnabled || ![NSStringFromClass(v.class) isEqualToString:@"CCUIContinuousSliderView"]) return;
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
    if (!gMotion || !gEnabled || !was || was.boolValue == on) return;
    [v.layer addAnimation:Spring(@"transform.scale", on ? 0.9 : 1.06, 1.0, 8, 240) forKey:@"xc.pop"];
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
    static void new_tb_##TAG(UIView *self, SEL _cmd, NSSet *t, UIEvent *e) { orig_tb_##TAG(self, _cmd, t, e); MotionPress(self, TARGET, YES); TouchGlow(self, t, YES); } \
    static void new_te_##TAG(UIView *self, SEL _cmd, NSSet *t, UIEvent *e) { orig_te_##TAG(self, _cmd, t, e); MotionPress(self, TARGET, NO); TouchGlow(self, t, NO); TouchRefresh(self); }  \
    static void new_tc_##TAG(UIView *self, SEL _cmd, NSSet *t, UIEvent *e) { orig_tc_##TAG(self, _cmd, t, e); MotionPress(self, TARGET, NO); TouchGlow(self, t, NO); }  \
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

// Control Center's open / close springs (scale and fade of every tile, the page dots, the status bar)
// live on views inside the icon list folder and the CC status bar, not in a module container.
static BOOL IsPageContext(UIView *v) {
    UIWindow *w = v.window;
    if (w && ![NSStringFromClass(w.class) containsString:@"ControlCenter"]) return NO;   // the home screen has an SBIconListPageControl too
    int n = 0;
    for (UIView *a = v; a && n < 10; a = a.superview, n++) {
        NSString *c = NSStringFromClass(a.class);
        if ([c containsString:@"IconListFolderView"] || [c isEqualToString:@"SBIconListPageControl"] || [c isEqualToString:@"CCUIStatusBar"]) return YES;
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
    if (!gMotion || !gEnabled) return anim;
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

static void (*orig_addAnimation)(CALayer *, SEL, CAAnimation *, NSString *);
static void new_addAnimation(CALayer *self, SEL _cmd, CAAnimation *anim, NSString *key) {
    CAAnimation *use = [key hasPrefix:@"xc."] ? anim : RetuneStockSpring(self, anim);
    orig_addAnimation(self, _cmd, use, key);
    if (gMotion && gEnabled && ![key hasPrefix:@"xc."] && [self.delegate isKindOfClass:UIView.class]) FollowSizeAnimation(self, use);
    if (!gDebugDump || [key hasPrefix:@"xc."]) return;
    id d = self.delegate;
    if (![d isKindOfClass:UIView.class]) return;
    UIView *v = d;
    BOOL cc = NO;
    for (UIView *a = v; a && !cc; a = a.superview) {
        NSString *n = NSStringFromClass(a.class);
        cc = [n hasPrefix:@"CCUI"] || [n hasPrefix:@"ControlCenter"] || [n containsString:@"ContextMenu"] || [n containsString:@"CCUIModule"];
    }
    if (!cc) return;
    static NSMutableSet *seen; static NSMutableString *acc; static int lines;
    if (!seen) { seen = [NSMutableSet set]; acc = [NSMutableString string]; }
    NSString *kp = [anim isKindOfClass:CAPropertyAnimation.class] ? ((CAPropertyAnimation *)anim).keyPath : @"-";
    NSString *sig = [NSString stringWithFormat:@"%@|%@|%@|%@", NSStringFromClass(v.class), key, kp, NSStringFromClass(anim.class)];
    if ([seen containsObject:sig] || lines > 160) return;
    [seen addObject:sig]; lines++;
    NSString *parent = v.superview ? NSStringFromClass(v.superview.class) : @"-";
    [acc appendFormat:@"%@ (in %@) key=%@ keyPath=%@ %@ dur=%.2f size=%@\n", NSStringFromClass(v.class), parent, key, kp,
     NSStringFromClass(anim.class), anim.duration, NSStringFromCGSize(v.bounds.size)];
    [acc writeToFile:@"/var/mobile/Library/Preferences/ios26ccstyle-anim-log.txt" atomically:YES encoding:NSUTF8StringEncoding error:NULL];
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
    [o writeToFile:@"/var/mobile/Library/Preferences/ios26ccstyle-scroll.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
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
@property (nonatomic) CGFloat off, speed, peak, squeeze, dir;
@property (nonatomic) BOOL armed, dumped;
@property (nonatomic) CFTimeInterval time;
@end
@implementation XCPageState
@end

// iOS 27, measured on a recording: a page fades with its distance from the centre (about half at a full
// page away). While the pages move they are squeezed as well, about 1 % per 1000 pt/s of the fastest
// speed of the flick (at most 8 %). A flick lands with a bounce: the pages run past their rest position
// (up to 17 pt, more the faster the flick) and settle back while a spring releases the squeeze.
static void ApplyPageScrollTo(UIScrollView *self, BOOL settle) {
    if (!gMotion || !gEnabled) return;
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
    CGFloat off = vertical ? self.contentOffset.y : self.contentOffset.x, bounce = 0;
    CFTimeInterval now = CACurrentMediaTime(), dt = now - st.time;
    if (settle) {
        st.speed = st.peak = st.squeeze = 0;
        st.armed = NO;
    } else if (dt > 0.004) {
        CGFloat dv = off - st.off;
        st.speed = 0.5 * st.speed + 0.5 * (dt < 0.25 ? fabs(dv) / dt : 0);
        if (st.speed > 600 && dv != 0) st.dir = dv > 0 ? 1 : -1;
        st.peak = MAX(st.peak, st.speed);
        CGFloat target = MIN(1.0, st.peak / 8000.0) * 0.08 * fx / 0.6;
        st.squeeze += (target - st.squeeze) * (1.0 - exp(-dt / 0.08));
        if (self.tracking) st.armed = NO;   // a drag that slows down under the finger is not a landing
        else if (st.speed > 1500) st.armed = YES;
        else if (st.armed && st.speed < 500) {   // the flick is about to land: the pages run on a little
            st.armed = NO;
            bounce = -st.dir * MIN(17.0, st.peak / 450.0);
        }
    }
    if (settle || dt > 0.004) { st.off = off; st.time = now; }

    CAKeyframeAnimation *kick = nil;
    if (bounce != 0) {
        kick = [CAKeyframeAnimation animationWithKeyPath:vertical ? @"transform.translation.y" : @"transform.translation.x"];
        kick.values = @[@0, @(bounce), @0];
        kick.keyTimes = @[@0, @0.5, @1];
        kick.timingFunctions = @[[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut],
                                 [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
        kick.duration = 0.32;
        kick.additive = YES;
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (UIView *p in pages) {
        CGPoint m = [p.superview convertPoint:p.center toView:self];
        CGFloat d = vertical ? (m.y - self.contentOffset.y - span * 0.5) : (m.x - self.contentOffset.x - span * 0.5);
        CGFloat a = MIN(1.0, fabs(d / span));
        CGFloat scale = 1.0 - st.squeeze, opacity = 1.0 - 0.83 * fx * a;
        CALayer *l = p.layer;
        CGFloat from = (l.presentationLayer ?: l).transform.m11;
        if (!objc_getAssociatedObject(p, kPageFxKey)) {
            l.allowsGroupOpacity = NO;   // fade each tile on its own: no offscreen pass over the glass
            objc_setAssociatedObject(p, kPageFxKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (st.speed > 1200) {   // a new flick takes over from the previous landing
            [l removeAnimationForKey:@"xc.relax"];
            [l removeAnimationForKey:@"xc.bounce"];
        }
        if (fabs(l.opacity - opacity) > 0.004) l.opacity = opacity;
        if (fabs(l.transform.m11 - scale) > 0.002) {
            l.transform = CATransform3DMakeScale(scale, scale, 1.0);
            if (settle && fabs(from - scale) > 0.004) [l addAnimation:Spring(@"transform.scale", from, scale, 60, 900) forKey:@"xc.relax"];
        }
        if (kick) [l addAnimation:kick forKey:@"xc.bounce"];
    }
    [CATransaction commit];

    if (!settle) {
        // no scroll callback for 55 ms: the scroll has landed, release the squeeze
        NSUInteger gen = [objc_getAssociatedObject(self, kPageGenKey) unsignedIntegerValue] + 1;
        objc_setAssociatedObject(self, kPageGenKey, @(gen), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (st.squeeze > 0.002) {
            __weak UIScrollView *ws = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.055 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                UIScrollView *sv = ws;
                if (sv && [objc_getAssociatedObject(sv, kPageGenKey) unsignedIntegerValue] == gen) ApplyPageScrollTo(sv, YES);
            });
        }
    }
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

static void PrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                         const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LoadPrefs();
        for (UIView *v in gTracked.allObjects) {
            if (objc_getAssociatedObject(v, kMenuKey) && !objc_getAssociatedObject(v, kStyledKey)) {
                ApplyMenuDecor(v);
            }
            [v setNeedsLayout];
            [v layoutIfNeeded];
        }
    });
}

// MARK: - Entry point ---------------------------------------------------------

// Logs older than one change are deleted. The first run of each version is recorded, and whatever was
// written before the previous version first ran is removed (a crash report from an old build once
// outlived six updates). The current backboardd session log (xenonglass.log) is never touched.
static void PruneOldLogs(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *state = @"/var/mobile/Library/Preferences/ios26ccstyle-changes.state";   // "<version> <first run> <previous version's first run>"
    NSArray *s = [[NSString stringWithContentsOfFile:state encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@" "];
    BOOL known = s.count == 3;
    time_t now = time(NULL), cur = known ? (time_t)[s[1] longLongValue] : now, prev = known ? (time_t)[s[2] longLongValue] : now;
    if (!known || ![s[0] isEqualToString:@XC_VERSION]) {
        prev = known ? cur : now;   // the very first run keeps nothing that is older than itself
        cur = now;
        [[NSString stringWithFormat:@"%s %ld %ld", XC_VERSION, (long)cur, (long)prev] writeToFile:state atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    NSArray *dirs = @[@[@"/var/mobile/Library/Preferences/", @"ios26ccstyle-", @".txt"],    // view, tile and animation dumps
                      @[@"/var/mobile/Library/Accessibility/", @"xenonglass-", @".log"]];   // previous session, crash report, safe mode
    for (NSArray *d in dirs) {
        for (NSString *n in [fm contentsOfDirectoryAtPath:d[0] error:nil]) {
            if (![n hasPrefix:d[1]] || ![n hasSuffix:d[2]]) continue;
            NSString *path = [d[0] stringByAppendingString:n];
            NSDate *m = [fm attributesOfItemAtPath:path error:nil].fileModificationDate;
            if (m && m.timeIntervalSince1970 < prev) [fm removeItemAtPath:path error:nil];
        }
    }
}

__attribute__((constructor))
static void IOS26CCStyleInit(void) {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;

        PruneOldLogs();
        LoadPrefs();

        Install_ModuleFill  ("CCUIContentModuleBackgroundView");
        Install_Container   ("CCUIContentModuleContentContainerView");
        Install_Template    ("CCUIControlTemplateView");
        Install_ButtonModule("CCUIButtonModuleView");
        Install_Accessory   ("CCUIAccessoryButton");
        Install_Power       ("CCUIPowerButton");
        Install_Round       ("CCUIRoundButton");
        Install_Slider      ("CCUIContinuousSliderView");
        Install_Stepped     ("CCUISteppedSliderView");
        InstallHook("CALayer", @selector(addAnimation:forKey:), (IMP)new_addAnimation, (IMP *)&orig_addAnimation);
        InstallTouch_Template("CCUIControlTemplateView");
        InstallTouch_ButtonModule("CCUIButtonModuleView");
        InstallTouch_Round("CCUIRoundButton");
        InstallTouch_Slider("CCUIContinuousSliderView");
        InstallHook("MTMaterialView", @selector(setAlpha:), (IMP)hook_setAlpha, (IMP *)&orig_setAlpha);
        InstallHook("UIScrollView", @selector(layoutSubviews), (IMP)new_sv_ls, (IMP *)&orig_sv_ls);
        InstallHook("UIScrollView", NSSelectorFromString(@"_notifyDidScroll"), (IMP)new_sv_nds, (IMP *)&orig_sv_nds);

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        PrefsChanged,
                                        (__bridge CFStringRef)kReloadNotification,
                                        NULL, CFNotificationSuspensionBehaviorCoalesce);
    }
}
