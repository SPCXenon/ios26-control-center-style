// IOS26CCStyle 0.2.1
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

// MARK: - Preferences ---------------------------------------------------------

static BOOL    gEnabled, gSliderCapsule, gContinuous, gExtraBlur;
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
    return MAX(lo, MIN(hi, out));
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
    gDebugDump     = PrefBool(@"debugDump", NO);
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
static const void *kBgTimerKey = &kBgTimerKey; // on the window: backdrop re-check pending
static const void *kBgTargetKey = &kBgTargetKey; // on the backdrop view: alpha we set
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
static void ApplyDecor(UIView *v, CGRect b, CGFloat radius) {
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

static void ApplyMenuDecor(UIView *v) {
    if (!v.window) return;
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
static const void *kGlassKey = &kGlassKey;   // on the MTMaterialView: its XCGlassView

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
        if (access("/var/mobile/Library/Accessibility/xenonglass-gaussian-identity-state.bin", F_OK) == 0) {
            @try { [filter setValue:@1.0 forKey:@"inputRadius"]; } @catch (__unused NSException *e) {}
        }
        layer.filters = @[filter];
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
            if (g.superview != root) [root insertSubview:g aboveSubview:s];
            if (!CGRectEqualToRect(g.frame, s.frame)) g.frame = s.frame;
            g.layer.cornerCurve = kCACornerCurveContinuous;
            g.layer.cornerRadius = radius;
            g.layer.masksToBounds = YES;
            g.glassRadius = radius;
            g.glassDark = dark;
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

static void ApplyStyle(UIView *v, CCKind kind) {
    if (!v.window) return;
    ApplyBackground(v);
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

    ApplyDecor(v, b, r);

    if (!gTracked) gTracked = [NSHashTable weakObjectsHashTable];
    [gTracked addObject:v];

    if (kind == CCKindContainer) DecorateMenus(v);
}

// CCUI occasionally resets its own corner radius right after the view lands in a
// window, so re-apply once shortly afterwards.
static void ScheduleReapply(UIView *v, CCKind kind) {
    if (!v.window) return;
    __weak UIView *weak = v;
    const double delays[] = { 0.12, 0.45 };   // second pass catches menu content added after expansion
    for (int i = 0; i < 2; i++) {
        if (i == 1 && kind != CCKindContainer) break;
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

DEFINE_HOOKS(ModuleFill,   CCKindModuleFill)
DEFINE_HOOKS(Container,    CCKindContainer)
DEFINE_HOOKS(Template,     CCKindModule)
DEFINE_HOOKS(ButtonModule, CCKindModule)
DEFINE_HOOKS(Accessory,    CCKindRound)
DEFINE_HOOKS(Power,        CCKindRound)
DEFINE_HOOKS(Round,        CCKindRound)
DEFINE_HOOKS(Slider,       CCKindSlider)
DEFINE_HOOKS(Stepped,      CCKindSlider)

// MARK: - Live reload ---------------------------------------------------------

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

__attribute__((constructor))
static void IOS26CCStyleInit(void) {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;

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
        InstallHook("MTMaterialView", @selector(setAlpha:), (IMP)hook_setAlpha, (IMP *)&orig_setAlpha);

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        PrefsChanged,
                                        (__bridge CFStringRef)kReloadNotification,
                                        NULL, CFNotificationSuspensionBehaviorCoalesce);
    }
}
