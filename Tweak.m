// IOS26CCStyle 0.1.3
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

static const void *kRimKey    = &kRimKey;     // outer specular rim
static const void *kEdgeKey   = &kEdgeKey;    // second, refracted inner rim
static const void *kGlowKey   = &kGlowKey;    // inner edge glow (glass thickness)
static const void *kSheenKey  = &kSheenKey;   // top sheen
static const void *kHotTLKey  = &kHotTLKey;   // corner highlight, top-left
static const void *kHotBRKey  = &kHotBRKey;   // corner highlight, bottom-right
static const void *kBlurKey   = &kBlurKey;    // optional extra blur view
static const void *kSigKey    = &kSigKey;
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
    const void *keys[] = { kRimKey, kEdgeKey, kGlowKey, kSheenKey, kHotTLKey, kHotBRKey,
                           kOutlineKey, kStreakKey, kShadeKey, kBevelAKey, kBevelBKey };
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        CALayer *l = objc_getAssociatedObject(v, keys[i]);
        l.hidden = YES;
    }
    UIView *blur = objc_getAssociatedObject(v, kBlurKey);
    blur.hidden = YES;
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

    NSString *sig = [NSString stringWithFormat:@"%lu|%.1f|%.1f|%.2f|%d",
                     (unsigned long)gGeneration, b.size.width, b.size.height, radius, dark];
    if ([objc_getAssociatedObject(v, kSigKey) isEqualToString:sig]) return;
    objc_setAssociatedObject(v, kSigKey, sig, OBJC_ASSOCIATION_COPY_NONATOMIC);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

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
        ScaleLayerBlur(s.layer, 0);
        objc_setAssociatedObject(s, kBgTargetKey, gBgBlur < 0.999 ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
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

static void ApplyStyle(UIView *v, CCKind kind) {
    if (!v.window) return;
    ApplyBackground(v);
    if (!gEnabled || !KindEnabled(kind)) {
        HideDecor(v);
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

    if (kind == CCKindModuleFill) {
        CGFloat ft = darkUI ? gEffTint * 0.2 : gEffTint * 0.85;
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

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        PrefsChanged,
                                        (__bridge CFStringRef)kReloadNotification,
                                        NULL, CFNotificationSuspensionBehaviorCoalesce);
    }
}
