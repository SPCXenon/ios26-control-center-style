// IOS26CCStyle 0.6.0
// iOS 26 "Liquid Glass" look for the iOS 18 Control Center.
// Target: iOS 18.x · rootless (Dopamine / ElleKit) · arm64e · SpringBoard only.
//
// No CydiaSubstrate dependency: hooks are installed with the ObjC runtime
// (class_addMethod / method_setImplementation).

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <notify.h>

static NSString *const kPrefsDomain = @"com.codex.ios26ccstyle";
static NSString *const kReloadNotification = @"com.codex.ios26ccstyle/reload";

// MARK: - Preferences ---------------------------------------------------------

static BOOL    gEnabled, gSliderCapsule, gContinuous;
static BOOL    gStyleModules, gStyleHeader, gStyleButtons, gStyleSliders;
static CGFloat gMaxRadius, gHeaderRadius;   // corner radius caps (pt)
static CGFloat gRim, gRimWidth;             // rim light intensity 0…1, stroke width pt
static CGFloat gSheen, gTint;               // top sheen alpha, fill tint alpha
static UIColor *gRimColor, *gFillColor;
static NSUInteger gGeneration;              // bumped on every prefs reload

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
    gStyleHeader   = PrefBool(@"styleHeader", YES);
    gStyleButtons  = PrefBool(@"styleButtons", YES);
    gStyleSliders  = PrefBool(@"styleSliders", YES);
    gSliderCapsule = PrefBool(@"sliderCapsule", YES);
    gContinuous    = PrefBool(@"continuousCorners", YES);
    gMaxRadius     = (CGFloat)PrefDouble(@"maxRadius", 46.0, 16.0, 70.0);
    gHeaderRadius  = (CGFloat)PrefDouble(@"headerRadius", 38.0, 12.0, 70.0);
    gRim           = (CGFloat)PrefDouble(@"rimIntensity", 0.6, 0.0, 1.0);
    gRimWidth      = (CGFloat)PrefDouble(@"rimWidth", 0.8, 0.3, 2.5);
    gSheen         = (CGFloat)PrefDouble(@"sheen", 0.06, 0.0, 0.2);
    gTint          = (CGFloat)PrefDouble(@"fillTint", 0.04, 0.0, 0.3);
    gRimColor      = ColorNamed(PrefString(@"rimColor", @"white"));
    gFillColor     = ColorNamed(PrefString(@"fillColor", @"white"));
    gGeneration++;
}

// MARK: - Styling -------------------------------------------------------------

typedef NS_ENUM(NSInteger, CCKind) {
    CCKindModuleFill,   // CCUIContentModuleBackgroundView – owns the glass fill
    CCKindModule,       // module cards / control templates (pills, tiles)
    CCKindHeader,       // CCUIHeaderPocketView
    CCKindRound,        // circular buttons (+, power, accessories)
    CCKindSlider,       // brightness / volume sliders
};

static const void *kRimLayerKey   = &kRimLayerKey;
static const void *kSheenLayerKey = &kSheenLayerKey;
static const void *kSigKey        = &kSigKey;
static NSHashTable<UIView *> *gTracked;   // weak; used to restyle after a prefs change

static BOOL KindEnabled(CCKind kind) {
    switch (kind) {
        case CCKindModuleFill:
        case CCKindModule: return gStyleModules;
        case CCKindHeader: return gStyleHeader;
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
        case CCKindHeader: return MIN(half, gHeaderRadius);
        default:           return MIN(half, gMaxRadius);
    }
}

static void HideDecor(UIView *v) {
    CALayer *rim = objc_getAssociatedObject(v, kRimLayerKey);
    CALayer *sheen = objc_getAssociatedObject(v, kSheenLayerKey);
    rim.hidden = YES;
    sheen.hidden = YES;
}

// Rim light + top sheen. Both are plain CALayers (they never take touches).
static void ApplyDecor(UIView *v, CGRect b, CGFloat radius) {
    BOOL wantRim = gRim > 0.001;
    BOOL wantSheen = gSheen > 0.001;

    CAGradientLayer *rim = objc_getAssociatedObject(v, kRimLayerKey);
    CAGradientLayer *sheen = objc_getAssociatedObject(v, kSheenLayerKey);

    if (wantRim && !rim) {
        rim = [CAGradientLayer layer];
        rim.name = @"IOS26CCRim";
        rim.startPoint = CGPointMake(0.0, 0.0);
        rim.endPoint   = CGPointMake(1.0, 1.0);
        rim.locations  = @[@0.0, @0.32, @0.68, @1.0];
        rim.zPosition  = 1000;
        rim.mask = [CAShapeLayer layer];
        objc_setAssociatedObject(v, kRimLayerKey, rim, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (wantSheen && !sheen) {
        sheen = [CAGradientLayer layer];
        sheen.name = @"IOS26CCSheen";
        sheen.startPoint = CGPointMake(0.5, 0.0);
        sheen.endPoint   = CGPointMake(0.5, 1.0);
        sheen.locations  = @[@0.0, @0.45, @1.0];
        sheen.zPosition  = 900;
        objc_setAssociatedObject(v, kSheenLayerKey, sheen, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    rim.hidden = !wantRim;
    sheen.hidden = !wantSheen;
    if (rim && rim.superlayer != v.layer)     [v.layer addSublayer:rim];
    if (sheen && sheen.superlayer != v.layer) [v.layer addSublayer:sheen];

    NSString *sig = [NSString stringWithFormat:@"%lu|%.1f|%.1f|%.2f",
                     (unsigned long)gGeneration, b.size.width, b.size.height, radius];
    if ([objc_getAssociatedObject(v, kSigKey) isEqualToString:sig]) return;
    objc_setAssociatedObject(v, kSigKey, sig, OBJC_ASSOCIATION_COPY_NONATOMIC);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    if (wantRim) {
        rim.frame = b;
        rim.colors = @[
            (__bridge id)[gRimColor colorWithAlphaComponent:0.60 * gRim].CGColor,
            (__bridge id)[gRimColor colorWithAlphaComponent:0.07 * gRim].CGColor,
            (__bridge id)[gRimColor colorWithAlphaComponent:0.07 * gRim].CGColor,
            (__bridge id)[gRimColor colorWithAlphaComponent:0.34 * gRim].CGColor,
        ];
        CAShapeLayer *mask = (CAShapeLayer *)rim.mask;
        mask.frame = rim.bounds;
        mask.fillColor = NULL;
        mask.strokeColor = [UIColor blackColor].CGColor;
        mask.lineWidth = gRimWidth;
        CGRect inset = CGRectInset(rim.bounds, gRimWidth / 2.0, gRimWidth / 2.0);
        mask.path = [UIBezierPath bezierPathWithRoundedRect:inset
                                               cornerRadius:MAX(0.0, radius - gRimWidth / 2.0)].CGPath;
    }

    if (wantSheen) {
        sheen.frame = b;
        sheen.colors = @[
            (__bridge id)[UIColor colorWithWhite:1.0 alpha:gSheen].CGColor,
            (__bridge id)[UIColor colorWithWhite:1.0 alpha:gSheen * 0.25].CGColor,
            (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
        ];
    }

    [CATransaction commit];
}

static void ApplyStyle(UIView *v, CCKind kind) {
    if (!v.window) return;
    if (!gEnabled || !KindEnabled(kind)) { HideDecor(v); return; }

    CGRect b = v.bounds;
    if (b.size.width < 4.0 || b.size.height < 4.0) return;

    // Skip the full-page wrapper so no outline is drawn around the whole page.
    if ((kind == CCKindModule || kind == CCKindModuleFill) &&
        b.size.height > v.window.bounds.size.height * 0.72) {
        HideDecor(v);
        return;
    }

    CGFloat r = TargetRadius(kind, b.size);

    CALayer *layer = v.layer;
    layer.cornerCurve   = gContinuous ? kCACornerCurveContinuous : kCACornerCurveCircular;
    layer.cornerRadius  = r;
    layer.masksToBounds = YES;
    layer.borderWidth   = 0.0;

    if (kind == CCKindModuleFill) {
        v.backgroundColor = gTint > 0.001 ? [gFillColor colorWithAlphaComponent:gTint] : nil;
    }

    ApplyDecor(v, b, r);

    if (!gTracked) gTracked = [NSHashTable weakObjectsHashTable];
    [gTracked addObject:v];
}

// CCUI occasionally resets its own corner radius right after the view lands in a
// window, so re-apply once shortly afterwards.
static void ScheduleReapply(UIView *v, CCKind kind) {
    if (!v.window) return;
    __weak UIView *weak = v;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *strong = weak;
        if (strong) ApplyStyle(strong, kind);
    });
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
DEFINE_HOOKS(Container,    CCKindModule)
DEFINE_HOOKS(Template,     CCKindModule)
DEFINE_HOOKS(ButtonModule, CCKindModule)
DEFINE_HOOKS(Header,       CCKindHeader)
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
        Install_Header      ("CCUIHeaderPocketView");
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
