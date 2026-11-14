// IOS26CCStyle 0.2.0
// iOS 26 "Liquid Glass" look for the iOS 18 Control Center.
// Target: iOS 18.x · rootless (Dopamine / ElleKit) · arm64e · SpringBoard only.
//
// No CydiaSubstrate dependency: hooks are installed with the ObjC runtime
// (class_addMethod / method_setImplementation). Only selected Control Center
// view classes are hooked; UIView's layout methods are never hooked globally.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <notify.h>
#include <stdlib.h>
#include <unistd.h>
#import <objc/message.h>

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
static NSUInteger gGeneration;      // prefs/background diagnostics generation
static NSUInteger gStyleGeneration; // bumped only when a visual setting changes
static NSString *gLastStyleSignature;

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
    gRefract       = PrefBool(@"refraction", YES);
    NSString *rimColorName = PrefString(@"rimColor", @"white");
    NSString *fillColorName = PrefString(@"fillColor", @"white");
    gRimColor      = ColorNamed(rimColorName);
    gFillColor     = ColorNamed(fillColorName);

    // This settings-only signature avoids invalidating per-view caches for
    // diagnostic-only preference changes such as toggling the view-tree dump.
    NSString *styleSignature = [NSString stringWithFormat:
        @"%d|%d|%d|%d|%d|%d|%d|%d|%d|%.4f|%.4f|%.4f|%.4f|%.4f|%.4f|%.4f|%.4f|%.4f|%.4f|%.4f|%.4f|%.4f|%.4f|%.4f|%@|%@",
        gEnabled, gStyleModules, gStyleButtons, gStyleSliders, gStyleMenus,
        gSliderCapsule, gContinuous, gExtraBlur, gRefract, gMaxRadius, gRim, gRimWidth,
        gSheen, gTint, gInner, gHot, gGlass, gMatAlpha, gEffTint, gRimMul,
        gReflect, gEdgeDark, gBgBlur, gDisp, rimColorName, fillColorName];
    if (![gLastStyleSignature isEqualToString:styleSignature]) {
        gLastStyleSignature = [styleSignature copy];
        gStyleGeneration++;
    }
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

@interface CCViewCache : NSObject
@property (nonatomic) BOOL decorValid;
@property (nonatomic) CGSize decorSize;
@property (nonatomic) CGFloat decorRadius;
@property (nonatomic) BOOL decorDark;
@property (nonatomic) NSUInteger decorGeneration;
@property (nonatomic) BOOL styleValid;
@property (nonatomic) CGSize styleSize;
@property (nonatomic) CGSize styleWindowSize;
@property (nonatomic) CGFloat styleAppliedRadius;
@property (nonatomic) NSInteger styleKind;
@property (nonatomic) BOOL styleDark;
@property (nonatomic) BOOL styleEnabled;
@property (nonatomic) NSUInteger styleGeneration;
@end

@implementation CCViewCache
@end

typedef NS_OPTIONS(NSUInteger, CCClassFlags) {
    CCClassMaterialView = 1 << 0,
    CCClassBackgroundExcluded = 1 << 1,
    CCClassBackgroundNamed = 1 << 2,
    CCClassBackdropLayer = 1 << 3,
};

static NSMapTable<Class, NSNumber *> *gClassFlagCache;

// Runtime class names are inspected only on the first encounter with each class.
static CCClassFlags FlagsForClass(Class cls) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gClassFlagCache = [NSMapTable strongToStrongObjectsMapTable];
    });

    // All callers are UIKit layout/window callbacks on SpringBoard's main thread.
    NSNumber *cached = [gClassFlagCache objectForKey:cls];
    if (cached) return (CCClassFlags)cached.unsignedIntegerValue;

    NSString *name = NSStringFromClass(cls);
    CCClassFlags flags = 0;
    if ([name containsString:@"MaterialView"]) flags |= CCClassMaterialView;
    if ([name hasPrefix:@"CCUI"] || [name containsString:@"IconList"] ||
        [name containsString:@"ScrollView"]) flags |= CCClassBackgroundExcluded;
    if ([name containsString:@"Material"] || [name containsString:@"Backdrop"] ||
        [name containsString:@"Blur"] || [name containsString:@"Background"] ||
        cls == UIVisualEffectView.class) flags |= CCClassBackgroundNamed;
    if ([name containsString:@"Backdrop"]) flags |= CCClassBackdropLayer;

    [gClassFlagCache setObject:@(flags) forKey:cls];
    return flags;
}

static const void *kRimKey    = &kRimKey;     // outer specular rim
static const void *kEdgeKey   = &kEdgeKey;    // second, refracted inner rim
static const void *kGlowKey   = &kGlowKey;    // inner edge glow (glass thickness)
static const void *kSheenKey  = &kSheenKey;   // top sheen
static const void *kHotTLKey  = &kHotTLKey;   // corner highlight, top-left
static const void *kHotBRKey  = &kHotBRKey;   // corner highlight, bottom-right
static const void *kBlurKey   = &kBlurKey;    // optional extra blur view
static const void *kViewCacheKey = &kViewCacheKey;
static const void *kOutlineKey = &kOutlineKey; // dark hairline at the very edge
static const void *kBevelAKey = &kBevelAKey;  // soft bevel highlight, inner (wide)
static const void *kBevelBKey = &kBevelBKey;  // soft bevel highlight, outer (narrow)
static const void *kStreakKey  = &kStreakKey;  // diagonal reflection band
static const void *kShadeKey   = &kShadeKey;   // top-lit sphere shading (circles)
static const void *kBgTimerKey = &kBgTimerKey; // on the window: backdrop re-check pending
static const void *kBgTargetKey = &kBgTargetKey; // on the backdrop view: alpha we set
static const void *kStyledKey = &kStyledKey; // set on views styled through a class hook
static const void *kMenuKey   = &kMenuKey;   // set on views decorated by the menu walk
static const void *kLastRKey  = &kLastRKey;  // corner radius we applied last
static const void *kSysRKey   = &kSysRKey;   // corner radius the system had set
static NSHashTable<UIView *> *gTracked;       // weak; used to restyle after a prefs change

static CCViewCache *ViewCache(UIView *v) {
    CCViewCache *cache = objc_getAssociatedObject(v, kViewCacheKey);
    if (!cache) {
        cache = [CCViewCache new];
        objc_setAssociatedObject(v, kViewCacheKey, cache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return cache;
}

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

static void HideDecor(UIView *v) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    const void *keys[] = { kRimKey, kEdgeKey, kGlowKey, kSheenKey, kHotTLKey, kHotBRKey,
                           kOutlineKey, kStreakKey, kShadeKey, kBevelAKey, kBevelBKey };
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        CALayer *l = objc_getAssociatedObject(v, keys[i]);
        l.hidden = YES;
    }
    UIView *blur = objc_getAssociatedObject(v, kBlurKey);
    blur.hidden = YES;
    CCViewCache *cache = objc_getAssociatedObject(v, kViewCacheKey);
    cache.decorValid = NO;
    [CATransaction commit];
}

static CAGradientLayer *EnsureGradient(UIView *v, const void *key, NSString *name,
                                       CGFloat z, BOOL stroke, BOOL radial, BOOL want) {
    CAGradientLayer *l = objc_getAssociatedObject(v, key);
    if (want && !l) {
        l = [CAGradientLayer layer];
        l.name = name;
        l.zPosition = z;
        if (radial) l.type = kCAGradientLayerRadial;
        if (stroke) l.mask = [CAShapeLayer layer];
        objc_setAssociatedObject(v, key, l, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    l.hidden = !want;
    if (l && l.superlayer != v.layer) [v.layer addSublayer:l];
    return l;
}

static void KeepRimOnTop(UIView *v) {
    CAGradientLayer *rim = objc_getAssociatedObject(v, kRimKey);
    CALayer *parent = v.layer;
    if (!rim || rim.superlayer != parent) return;

    CGFloat highestZ = -CGFLOAT_MAX;
    for (CALayer *sibling in parent.sublayers) {
        if (sibling != rim) highestZ = MAX(highestZ, sibling.zPosition);
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    rim.zPosition = MAX(1000.0, highestZ + 1.0);
    if (parent.sublayers.lastObject != rim) {
        [rim removeFromSuperlayer];
        [parent addSublayer:rim];
    }
    [CATransaction commit];
}

// A gradient layer masked to a rounded-rect outline (a lit glass edge).
static void ConfigureStroke(CAGradientLayer *g, CGRect b, CGFloat radius, CGFloat inset, CGFloat width,
                            NSArray *colors, CGPoint start, CGPoint end) {
    g.frame = b;
    g.startPoint = start;
    g.endPoint = end;
    g.locations = @[@0.0, @0.32, @0.68, @1.0];
    g.colors = colors;
    CAShapeLayer *mask = (CAShapeLayer *)g.mask;
    mask.frame = g.bounds;
    mask.fillColor = NULL;
    mask.strokeColor = [UIColor blackColor].CGColor;
    mask.lineWidth = width;
    CGRect ir = CGRectInset(g.bounds, inset + width / 2.0, inset + width / 2.0);
    mask.path = [UIBezierPath bezierPathWithRoundedRect:ir
                                           cornerRadius:MAX(0.0, radius - inset - width / 2.0)].CGPath;
}

static id RimColor(CGFloat alpha) {
    return (__bridge id)[gRimColor colorWithAlphaComponent:MAX(0.0, MIN(1.0, alpha))].CGColor;
}

// Rim colour with a slight cool / warm fringe (glass chromatic dispersion).
static id RimColorD(CGFloat alpha, int warm) {
    CGFloat r = 1, g = 1, b = 1, a = 1;
    [gRimColor getRed:&r green:&g blue:&b alpha:&a];
    CGFloat k = 0.30 * gDisp;
    CGFloat tr = warm > 0 ? 1.0 : (warm < 0 ? 0.70 : r);
    CGFloat tg = warm > 0 ? 0.82 : (warm < 0 ? 0.90 : g);
    CGFloat tb = warm > 0 ? 0.68 : (warm < 0 ? 1.00 : b);
    UIColor *c = [UIColor colorWithRed:r + (tr - r) * k green:g + (tg - g) * k blue:b + (tb - b) * k
                                 alpha:MAX(0.0, MIN(1.0, alpha))];
    return (__bridge id)c.CGColor;
}

// Liquid-glass decoration, modelled on the iOS 26 reference and the iOS 27 refinements
// ("darkened edge" + "brighter specular highlights"):
//  · dark hairline at the very edge, bright specular rim just inside it
//  · second, refracted inner rim · inner edge glow (bevel) · top sheen
//  · diagonal reflection streak · corner highlights · top-lit shading on circles
// Every piece is a plain CALayer (they never take touches).
// System appearance of the view (Control Center follows light/dark mode).
static BOOL IsDarkUI(UIView *v) {
    UIUserInterfaceStyle st = v.window.traitCollection.userInterfaceStyle;
    if (st == UIUserInterfaceStyleUnspecified) st = v.traitCollection.userInterfaceStyle;
    return st != UIUserInterfaceStyleLight;
}

static void ApplyDecor(UIView *v, CGRect b, CGFloat radius) {
    BOOL dark = IsDarkUI(v);
    CCViewCache *cache = ViewCache(v);
    if (cache.decorValid && cache.decorGeneration == gStyleGeneration &&
        CGSizeEqualToSize(cache.decorSize, b.size) &&
        fabs(cache.decorRadius - radius) < 0.01 && cache.decorDark == dark) {
        KeepRimOnTop(v);
        return;
    }

    CGFloat shortSide = MIN(b.size.width, b.size.height);
    BOOL circle = fabs(b.size.width - b.size.height) < 2.0 && radius >= shortSide / 2.0 - 0.5;
    CGFloat rs   = gReflect * 2.0;                 // 0…2, 1 = neutral
    CGFloat rimE = MIN(1.0, gRim * gRimMul);
    CGFloat pk   = MIN(1.0, 0.6 + 0.4 * rs);       // specular peak strength

    BOOL wantRim     = gRim > 0.001;
    BOOL wantEdge    = wantRim;
    BOOL wantOutline = gEdgeDark > 0.001;
    BOOL wantGlow    = gInner > 0.001;
    BOOL wantSheen   = gSheen > 0.001 && gReflect > 0.001;
    BOOL wantHot     = gHot > 0.001 && gReflect > 0.001;
    BOOL wantStreak  = gReflect > 0.001;
    BOOL wantShade   = circle;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    CAGradientLayer *rim    = EnsureGradient(v, kRimKey,    @"IOS26CCRim",    1000, YES, NO,  wantRim);
    CAGradientLayer *bevA   = EnsureGradient(v, kBevelAKey, @"IOS26CCBevelA",  996, YES, NO,  wantRim);
    CAGradientLayer *bevB   = EnsureGradient(v, kBevelBKey, @"IOS26CCBevelB",  995, YES, NO,  wantRim);
    CAGradientLayer *edge   = EnsureGradient(v, kEdgeKey,   @"IOS26CCEdge",    990, YES, NO,  wantEdge);
    CAGradientLayer *hotTL  = EnsureGradient(v, kHotTLKey,  @"IOS26CCHotTL",   910, NO,  YES, wantHot);
    CAGradientLayer *hotBR  = EnsureGradient(v, kHotBRKey,  @"IOS26CCHotBR",   910, NO,  YES, wantHot);
    CAGradientLayer *streak = EnsureGradient(v, kStreakKey, @"IOS26CCStreak",  905, NO,  NO,  wantStreak);
    CAGradientLayer *sheen  = EnsureGradient(v, kSheenKey,  @"IOS26CCSheen",   900, NO,  NO,  wantSheen);
    CAGradientLayer *shade  = EnsureGradient(v, kShadeKey,  @"IOS26CCShade",   880, NO,  NO,  wantShade);

    CAShapeLayer *outline = objc_getAssociatedObject(v, kOutlineKey);
    if (wantOutline && !outline) {
        outline = [CAShapeLayer layer];
        outline.name = @"IOS26CCOutline";
        outline.zPosition = 985;
        outline.fillColor = NULL;
        objc_setAssociatedObject(v, kOutlineKey, outline, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    outline.hidden = !wantOutline;
    if (outline && outline.superlayer != v.layer) [v.layer addSublayer:outline];

    CAShapeLayer *glow = objc_getAssociatedObject(v, kGlowKey);
    if (wantGlow && !glow) {
        glow = [CAShapeLayer layer];
        glow.name = @"IOS26CCGlow";
        glow.zPosition = 800;
        glow.fillRule = kCAFillRuleEvenOdd;
        glow.fillColor = [UIColor blackColor].CGColor;   // lies outside the view; the parent clips it
        glow.shadowOffset = CGSizeZero;
        objc_setAssociatedObject(v, kGlowKey, glow, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    glow.hidden = !wantGlow;
    if (glow && glow.superlayer != v.layer) [v.layer addSublayer:glow];

    CGFloat rimInset = wantOutline ? 0.7 : 0.0;

    if (wantOutline) {
        outline.frame = b;
        outline.strokeColor = [UIColor colorWithWhite:0.0 alpha:MIN(0.6, (dark ? 0.38 : 0.20) * gEdgeDark)].CGColor;
        outline.lineWidth = 0.7;
        outline.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(outline.bounds, 0.35, 0.35)
                                                  cornerRadius:MAX(0.0, radius - 0.35)].CGPath;
    }

    if (wantRim) {
        // Bright at the top-left and bottom-right, but never dark all the way around:
        // the reference keeps a continuous thin light edge.
        // Same recipe as LiquidAss: a thin specular line, strong at two opposite corners,
        // nearly clear in between ...
        ConfigureStroke(rim, b, radius, rimInset, gRimWidth,
                        @[RimColorD(1.0 * pk * rimE, -1), RimColor(0.16 * rimE), RimColor(0.16 * rimE), RimColorD(0.85 * pk * rimE, 1)],
                        CGPointMake(0.0, 0.0), CGPointMake(1.0, 1.0));
        // ... backed by two softer, wider strokes so the highlight fades inward like a bevel.
        CGFloat bw = MIN(shortSide * 0.12, 7.0);
        ConfigureStroke(bevA, b, radius, rimInset, MAX(2.0, bw * 0.55),
                        @[RimColorD(0.40 * rs * rimE, -1), RimColor(0.0), RimColor(0.0), RimColorD(0.30 * rs * rimE, 1)],
                        CGPointMake(0.0, 0.0), CGPointMake(1.0, 1.0));
        ConfigureStroke(bevB, b, radius, rimInset, MAX(3.5, bw),
                        @[RimColorD(0.17 * rs * rimE, -1), RimColor(0.0), RimColor(0.0), RimColorD(0.12 * rs * rimE, 1)],
                        CGPointMake(0.0, 0.0), CGPointMake(1.0, 1.0));
        // Second, fainter line just inside, lit from the opposite diagonal (edge refraction).
        ConfigureStroke(edge, b, radius, rimInset + gRimWidth + 1.1, 0.55,
                        @[RimColor(0.05 * rimE), RimColor(0.28 * rimE), RimColor(0.28 * rimE), RimColor(0.05 * rimE)],
                        CGPointMake(1.0, 0.0), CGPointMake(0.0, 1.0));
    }

    if (wantGlow) {
        glow.frame = b;
        UIBezierPath *p = [UIBezierPath bezierPathWithRect:CGRectInset(glow.bounds, -60.0, -60.0)];
        [p appendPath:[UIBezierPath bezierPathWithRoundedRect:glow.bounds cornerRadius:radius]];
        glow.path = p.CGPath;
        glow.shadowPath = p.CGPath;
        glow.shadowColor = gRimColor.CGColor;
        glow.shadowRadius = MIN(10.0, MAX(3.0, shortSide * 0.16));
        glow.shadowOpacity = (float)(0.45 * gInner);
    }

    if (wantShade) {
        // Top-lit sphere: clear at the top, darker toward the bottom.
        shade.frame = b;
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
        sheen.frame = b;
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
        // Soft diagonal reflection band across the upper-left of the glass.
        CGFloat a = MIN(0.30, (dark ? 0.05 : 0.14) * rs);
        CGColorRef clear = [UIColor colorWithWhite:1.0 alpha:0.0].CGColor;
        streak.frame = b;
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
        hotTL.frame = b;
        hotTL.locations = @[@0.0, @1.0];
        hotTL.colors = cols;
        hotTL.startPoint = CGPointMake(0.06, 0.04);
        hotTL.endPoint = CGPointMake(0.62, 0.70);
        hotBR.frame = b;
        hotBR.locations = @[@0.0, @1.0];
        hotBR.colors = cols;
        hotBR.startPoint = CGPointMake(0.94, 0.96);
        hotBR.endPoint = CGPointMake(0.38, 0.30);
    }

    KeepRimOnTop(v);
    [CATransaction commit];
    cache.decorSize = b.size;
    cache.decorRadius = radius;
    cache.decorDark = dark;
    cache.decorGeneration = gStyleGeneration;
    cache.decorValid = YES;
}

// Optional extra backdrop blur behind the module fill (experimental, off by default).
static void ApplyExtraBlur(UIView *v, CGRect b) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    UIVisualEffectView *blur = objc_getAssociatedObject(v, kBlurKey);
    if (!gExtraBlur) {
        blur.hidden = YES;
        [CATransaction commit];
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
    [CATransaction commit];
}

// MARK: - Material clarity (iOS 27-style Clear ↔ Tinted) ----------------------

// Dims the system blur material behind a view so the wallpaper shows through.
static void SetMaterialAlphaRecursive(UIView *root, int depth, CGFloat alpha) {
    if (depth > 3) return;
    for (UIView *s in root.subviews) {
        if (FlagsForClass(s.class) & CCClassMaterialView) {
            if (fabs(s.alpha - alpha) > 0.001) s.alpha = alpha;
            continue;
        }
        SetMaterialAlphaRecursive(s, depth + 1, alpha);
    }
}

static void SetMaterialAlpha(UIView *root, int depth, CGFloat alpha) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    SetMaterialAlphaRecursive(root, depth, alpha);
    [CATransaction commit];
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
static const void *kBgOrigKey = &kBgOrigKey;   // on the filter: stock radius
static const void *kBgSetKey  = &kBgSetKey;    // on the filter: radius we wrote last

static NSString *const kRadiusKeys[] = { @"inputRadius", @"radius", @"inputBlurRadius", @"blurRadius" };

static BOOL ScaleFilterRadius(id filter) {
    BOOL changed = NO;
    for (size_t i = 0; i < sizeof(kRadiusKeys) / sizeof(kRadiusKeys[0]); i++) {
        id cur = nil;
        @try { cur = [filter valueForKey:kRadiusKeys[i]]; } @catch (__unused NSException *e) { continue; }
        if (![cur respondsToSelector:@selector(doubleValue)]) continue;
        double now = [cur doubleValue];
        NSNumber *lastSet = objc_getAssociatedObject(filter, kBgSetKey);
        NSNumber *orig = objc_getAssociatedObject(filter, kBgOrigKey);
        if (!orig || !lastSet || fabs(now - lastSet.doubleValue) > 0.01) {
            orig = @(now);   // first sight, or the system changed it: this is the stock value
            objc_setAssociatedObject(filter, kBgOrigKey, orig, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        double want = orig.doubleValue * gBgBlur;
        if (fabs(now - want) > 0.01) {
            @try { [filter setValue:@(want) forKey:kRadiusKeys[i]]; changed = YES; }
            @catch (__unused NSException *e) {}
        }
        objc_setAssociatedObject(filter, kBgSetKey, @(want), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return changed;
}

static void ScaleLayerBlur(CALayer *layer, int depth) {
    if (!layer || depth > 6) return;
    NSArray *f = layer.filters;
    BOOL ch = NO;
    for (id flt in f) ch |= ScaleFilterRadius(flt);
    if (ch) layer.filters = f;
    @try {
        NSArray *bf = [layer valueForKey:@"backgroundFilters"];
        if ([bf isKindOfClass:NSArray.class]) {
            BOOL c2 = NO;
            for (id flt in bf) c2 |= ScaleFilterRadius(flt);
            if (c2) [layer setValue:bf forKey:@"backgroundFilters"];
        }
    } @catch (__unused NSException *e) {}
    for (CALayer *sub in layer.sublayers) ScaleLayerBlur(sub, depth + 1);
}

static void ScaleBackdrop(UIView *s) {
    BOOL flagged = objc_getAssociatedObject(s, kBgTargetKey) != nil;
    if (gBgBlur < 0.999 || flagged) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        ScaleLayerBlur(s.layer, 0);
        [CATransaction commit];
        objc_setAssociatedObject(s, kBgTargetKey, gBgBlur < 0.999 ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL IsBgCandidate(UIView *s, UIWindow *w) {
    CGSize ws = w.bounds.size;
    if (s.bounds.size.width < ws.width * 0.9 || s.bounds.size.height < ws.height * 0.9) return NO;
    CCClassFlags flags = FlagsForClass(s.class);
    if (flags & CCClassBackgroundExcluded) return NO;
    if (flags & CCClassBackgroundNamed) return YES;
    return (FlagsForClass(s.layer.class) & CCClassBackdropLayer) != 0;
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
            ScaleBackdrop(s);
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

static BOOL StyleCacheMatches(CCViewCache *cache, UIView *v, CCKind kind,
                              CGSize size, BOOL enabled, BOOL dark) {
    return cache.styleValid && cache.styleGeneration == gStyleGeneration &&
           cache.styleKind == kind && cache.styleEnabled == enabled && cache.styleDark == dark &&
           CGSizeEqualToSize(cache.styleSize, size) &&
           CGSizeEqualToSize(cache.styleWindowSize, v.window.bounds.size) &&
           fabs(cache.styleAppliedRadius - v.layer.cornerRadius) < 0.01;
}

static void RememberStyle(CCViewCache *cache, UIView *v, CCKind kind,
                          BOOL enabled, BOOL dark) {
    cache.styleSize = v.bounds.size;
    cache.styleWindowSize = v.window.bounds.size;
    cache.styleAppliedRadius = v.layer.cornerRadius;
    cache.styleKind = kind;
    cache.styleEnabled = enabled;
    cache.styleDark = dark;
    cache.styleGeneration = gStyleGeneration;
    cache.styleValid = YES;
}

static void ApplyStyle(UIView *v, CCKind kind) {
    if (!v.window) return;
    ApplyBackground(v);
    CGRect b = v.bounds;
    if (b.size.width < 4.0 || b.size.height < 4.0) return;

    BOOL enabled = gEnabled && KindEnabled(kind);
    BOOL darkUI = IsDarkUI(v);
    CALayer *layer = v.layer;
    CCViewCache *cache = ViewCache(v);
    if (StyleCacheMatches(cache, v, kind, b.size, enabled, darkUI)) {
        KeepRimOnTop(v);
        NSNumber *lastR = objc_getAssociatedObject(v, kLastRKey);
        if (lastR) SyncGlass(v, kind, lastR.doubleValue, darkUI, enabled);
        // Expanded modules can receive late-arriving menu subviews without
        // changing their own geometry, so keep discovering those cheaply.
        if (kind == CCKindContainer) DecorateMenus(v);
        return;
    }

    if (!enabled) {
        HideDecor(v);
        SyncGlass(v, kind, 0.0, darkUI, NO);
        SetMaterialAlpha(v, 0, 1.0);
        if (kind == CCKindContainer && gEnabled) DecorateMenus(v);
        RememberStyle(cache, v, kind, enabled, darkUI);
        return;
    }

    // Skip the full-page wrapper so no outline is drawn around the whole page.
    if ((kind == CCKindModule || kind == CCKindModuleFill || kind == CCKindContainer) &&
        b.size.height > v.window.bounds.size.height * 0.72) {
        HideDecor(v);
        if (kind == CCKindContainer) DecorateMenus(v);
        RememberStyle(cache, v, kind, enabled, darkUI);
        return;
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

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.cornerCurve   = gContinuous ? kCACornerCurveContinuous : kCACornerCurveCircular;
    layer.cornerRadius  = r;
    layer.masksToBounds = YES;
    layer.borderWidth   = 0.0;

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
    [CATransaction commit];
    RememberStyle(cache, v, kind, enabled, darkUI);
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

// class_getInstanceMethod() may return a method inherited from a superclass.
// Enumerate this class's own method list so method_setImplementation() is never
// accidentally applied to an inherited Method and changes the superclass.
static Method OwnInstanceMethod(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method own = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) {
            own = methods[i];
            break;
        }
    }
    free(methods);
    return own;
}

static Class ResolveHookClass(const char *className) {
    Class cls = objc_getClass(className);
    if (!cls) {
        NSLog(@"[IOS26CCStyle] Optional Control Center class %s is unavailable; skipping its hooks.",
              className);
    }
    return cls;
}

static BOOL InstallHook(Class cls, SEL sel, IMP replacement, IMP *original) {
    if (!cls) return NO;

    Method own = OwnInstanceMethod(cls, sel);
    IMP orig = NULL;
    if (own) {
        // This selector belongs to the target class, so replace only its own IMP.
        orig = method_setImplementation(own, replacement);
    } else {
        // The selector is inherited. Add an override to this class and leave the
        // superclass's Method untouched.
        Method inherited = class_getInstanceMethod(cls, sel);
        if (!inherited) return NO;
        if (class_addMethod(cls, sel, replacement, method_getTypeEncoding(inherited))) {
            orig = method_getImplementation(inherited);
        } else {
            // If another installer added the override between the checks, re-read
            // only this class's method list. Never mutate the inherited Method.
            own = OwnInstanceMethod(cls, sel);
            if (!own) return NO;
            orig = method_setImplementation(own, replacement);
        }
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
    static void Install_##TAG(const char *className) {                                \
        Class targetClass = ResolveHookClass(className);                             \
        if (!targetClass) return;                                                    \
        IMP o1 = NULL, o2 = NULL;                                                   \
        if (InstallHook(targetClass, @selector(layoutSubviews),                    \
                        (IMP)new_layout_##TAG, &o1)) {                              \
            orig_layout_##TAG = (void (*)(UIView *, SEL))o1;                        \
        }                                                                           \
        if (InstallHook(targetClass, @selector(didMoveToWindow),                   \
                        (IMP)new_window_##TAG, &o2)) {                              \
            orig_window_##TAG = (void (*)(UIView *, SEL))o2;                        \
        }                                                                           \
    }

DEFINE_HOOKS(ModuleFill,   CCKindModuleFill)
DEFINE_HOOKS(Container,    CCKindContainer)
DEFINE_HOOKS(Template,     CCKindModule)
DEFINE_HOOKS(ButtonModule, CCKindModule)
DEFINE_HOOKS(HeaderPocket, CCKindRound)
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
        Install_HeaderPocket("CCUIHeaderPocketView");
        Install_Accessory   ("CCUIAccessoryButton");
        Install_Power       ("CCUIPowerButton");
        Install_Round       ("CCUIRoundButton");
        Install_Slider      ("CCUIContinuousSliderView");
        Install_Stepped     ("CCUISteppedSliderView");

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        PrefsChanged,
                                        (__bridge CFStringRef)kReloadNotification,
                                        NULL, CFNotificationSuspensionBehaviorCoalesce);
    }
}
