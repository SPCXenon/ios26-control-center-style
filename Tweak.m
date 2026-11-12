// IOS26CCStyle 0.4.0
// iOS 26 "Liquid Glass" look for the iOS 18 Control Center.
// Target: iOS 18.x · rootless (Dopamine / ElleKit) · arm64e · SpringBoard only.
//
// No CydiaSubstrate dependency: hooks are installed with the ObjC runtime
// (class_addMethod / method_setImplementation), so nothing but the tweak
// injector itself is needed.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <notify.h>

static NSString *const kPrefsDomain = @"com.codex.ios26ccstyle";
static const char *const kReloadNotification = "com.codex.ios26ccstyle/reload";

// MARK: - Preferences ---------------------------------------------------------

static struct {
    BOOL    enabled;
    BOOL    sliderCapsule;
    CGFloat maxRadius;     // upper bound for module / template corner radius
    CGFloat headerRadius;  // top pocket (+ / battery / power)
    CGFloat rim;           // 0…1 intensity of the glass rim light
    CGFloat tint;          // 0…0.15 white fill behind module backgrounds
} cfg;

static double PrefDouble(NSString *key, double def, double lo, double hi) {
    double out = def;
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)kPrefsDomain);
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
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)kPrefsDomain);
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

static void LoadPrefs(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPrefsDomain);
    cfg.enabled       = PrefBool(@"enabled", YES);
    cfg.sliderCapsule = PrefBool(@"sliderCapsule", YES);
    cfg.maxRadius     = (CGFloat)PrefDouble(@"maxRadius", 46.0, 16.0, 70.0);
    cfg.headerRadius  = (CGFloat)PrefDouble(@"headerRadius", 38.0, 12.0, 70.0);
    cfg.rim           = (CGFloat)PrefDouble(@"rimIntensity", 0.6, 0.0, 1.0);
    cfg.tint          = (CGFloat)PrefDouble(@"fillTint", 0.04, 0.0, 0.15);
}

// MARK: - Styling -------------------------------------------------------------

typedef NS_ENUM(NSInteger, CCKind) {
    CCKindModuleFill,   // CCUIContentModuleBackgroundView – owns the glass fill
    CCKindModule,       // module containers / control templates (pills, tiles)
    CCKindHeader,       // CCUIHeaderPocketView
    CCKindRound,        // circular buttons (+, power, accessories)
    CCKindSlider,       // brightness / volume sliders
};

static const void *kRimLayerKey = &kRimLayerKey;
static const void *kRimSigKey   = &kRimSigKey;
static NSHashTable<UIView *> *gTracked;   // weak; used to restyle after a prefs change

static CGFloat TargetRadius(CCKind kind, CGSize size) {
    CGFloat half = MIN(size.width, size.height) / 2.0;
    switch (kind) {
        case CCKindRound:  return half;
        case CCKindSlider: return cfg.sliderCapsule ? half : MIN(half, cfg.maxRadius);
        case CCKindHeader: return MIN(half, cfg.headerRadius);
        default:           return MIN(half, cfg.maxRadius);
    }
}

// Liquid-glass rim: a 0.8pt stroke whose brightness peaks at the top-left and
// bottom-right corners (the way a lit glass edge looks) and dims in between.
static void ApplyRim(UIView *v, CGRect b, CGFloat radius) {
    CAGradientLayer *rim = objc_getAssociatedObject(v, kRimLayerKey);

    if (cfg.rim <= 0.001) {
        rim.hidden = YES;
        return;
    }

    if (!rim) {
        rim = [CAGradientLayer layer];
        rim.name = @"IOS26CCRim";
        rim.startPoint = CGPointMake(0.0, 0.0);
        rim.endPoint   = CGPointMake(1.0, 1.0);
        rim.locations  = @[@0.0, @0.32, @0.68, @1.0];
        rim.zPosition  = 1000;                       // above module content (layers never take touches)
        rim.mask = [CAShapeLayer layer];
        objc_setAssociatedObject(v, kRimLayerKey, rim, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (rim.superlayer != v.layer) {
        [v.layer addSublayer:rim];
    }
    rim.hidden = NO;

    NSString *sig = [NSString stringWithFormat:@"%.1f|%.1f|%.2f|%.2f",
                     b.size.width, b.size.height, radius, cfg.rim];
    if ([objc_getAssociatedObject(v, kRimSigKey) isEqualToString:sig]) return;
    objc_setAssociatedObject(v, kRimSigKey, sig, OBJC_ASSOCIATION_COPY_NONATOMIC);

    const CGFloat lw = 0.8;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    rim.frame = b;
    rim.colors = @[
        (id)[UIColor colorWithWhite:1.0 alpha:0.60 * cfg.rim].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:0.07 * cfg.rim].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:0.07 * cfg.rim].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:0.34 * cfg.rim].CGColor,
    ];

    CAShapeLayer *mask = (CAShapeLayer *)rim.mask;
    mask.frame = rim.bounds;
    mask.fillColor = NULL;
    mask.strokeColor = [UIColor blackColor].CGColor;
    mask.lineWidth = lw;
    CGRect inset = CGRectInset(rim.bounds, lw / 2.0, lw / 2.0);
    mask.path = [UIBezierPath bezierPathWithRoundedRect:inset
                                           cornerRadius:MAX(0.0, radius - lw / 2.0)].CGPath;

    [CATransaction commit];
}

static void ApplyStyle(UIView *v, CCKind kind) {
    if (!cfg.enabled || !v.window) return;

    CGRect b = v.bounds;
    if (b.size.width < 4.0 || b.size.height < 4.0) return;

    CGFloat r = TargetRadius(kind, b.size);

    CALayer *layer = v.layer;
    layer.cornerCurve  = kCACornerCurveContinuous;
    layer.cornerRadius = r;
    layer.masksToBounds = YES;
    layer.borderWidth  = 0.0;            // the rim layer replaces the flat border

    if (kind == CCKindModuleFill) {
        v.backgroundColor = cfg.tint > 0.001
            ? [UIColor colorWithWhite:1.0 alpha:cfg.tint] : nil;
    }

    ApplyRim(v, b, r);

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

DEFINE_HOOKS(ModuleFill, CCKindModuleFill)
DEFINE_HOOKS(Container,  CCKindModule)
DEFINE_HOOKS(Template,   CCKindModule)
DEFINE_HOOKS(Header,     CCKindHeader)
DEFINE_HOOKS(Accessory,  CCKindRound)
DEFINE_HOOKS(Power,      CCKindRound)
DEFINE_HOOKS(Round,      CCKindRound)
DEFINE_HOOKS(Slider,     CCKindSlider)

// MARK: - Live reload ---------------------------------------------------------

static void PrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                         const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LoadPrefs();
        for (UIView *v in gTracked.allObjects) {
            // Invalidate the cached rim signature and relayout.
            objc_setAssociatedObject(v, kRimSigKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
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

        Install_ModuleFill("CCUIContentModuleBackgroundView");
        Install_Container ("CCUIContentModuleContentContainerView");
        Install_Template  ("CCUIControlTemplateView");
        Install_Header    ("CCUIHeaderPocketView");
        Install_Accessory ("CCUIAccessoryButton");
        Install_Power     ("CCUIPowerButton");
        Install_Round     ("CCUIRoundButton");
        Install_Slider    ("CCUIContinuousSliderView");

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        PrefsChanged,
                                        (__bridge CFStringRef)@(kReloadNotification),
                                        NULL, CFNotificationSuspensionBehaviorCoalesce);
    }
}
