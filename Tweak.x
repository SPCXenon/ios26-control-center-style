#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static BOOL IOS26CCIsTargetWindow(UIWindow *window) {
    if (!window) {
        return NO;
    }

    static Class controlCenterWindowClass = Nil;
    if (!controlCenterWindowClass) {
        controlCenterWindowClass = objc_getClass("SBControlCenterWindow");
    }
    return controlCenterWindowClass && [window isKindOfClass:controlCenterWindowClass];
}

static char kIOS26CCGlassViewKey;

static UIVisualEffectView *IOS26CCGlassViewFor(UIView *view) {
    UIVisualEffectView *glassView = objc_getAssociatedObject(view, &kIOS26CCGlassViewKey);
    if (!glassView) {
        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark];
        glassView = [[UIVisualEffectView alloc] initWithEffect:blur];
        glassView.userInteractionEnabled = NO;
        glassView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [view insertSubview:glassView atIndex:0];
        objc_setAssociatedObject(view, &kIOS26CCGlassViewKey, glassView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    glassView.frame = view.bounds;
    return glassView;
}

static CGFloat IOS26CCCardRadiusForView(UIView *view) {
    CGFloat width = CGRectGetWidth(view.bounds);
    CGFloat height = CGRectGetHeight(view.bounds);
    return MIN(24.0, MIN(width, height) * 0.18);
}

static void IOS26CCApplyGlass(UIView *view, CGFloat tintAlpha, CGFloat radius, BOOL drawsBorder) {
    if (CGRectGetWidth(view.bounds) <= 0.0 || CGRectGetHeight(view.bounds) <= 0.0) {
        return;
    }

    UIVisualEffectView *glassView = IOS26CCGlassViewFor(view);
    glassView.layer.cornerRadius = radius;
    glassView.layer.cornerCurve = kCACornerCurveContinuous;
    glassView.clipsToBounds = YES;
    glassView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:tintAlpha];

    view.layer.cornerRadius = radius;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.borderWidth = drawsBorder ? 0.25 : 0.0;
    view.layer.borderColor = drawsBorder ? [UIColor colorWithWhite:1.0 alpha:0.12].CGColor : UIColor.clearColor.CGColor;
    view.opaque = NO;
}

static void IOS26CCStyleView(UIView *view) {
    NSString *className = NSStringFromClass(view.class);

    CGFloat minimumDimension = MIN(CGRectGetWidth(view.bounds), CGRectGetHeight(view.bounds));

    if ([className isEqualToString:@"CCUIHeaderPocketView"]) {
        CGFloat radius = MIN(20.0, CGRectGetHeight(view.bounds) * 0.16);
        IOS26CCApplyGlass(view, 0.08, radius, YES);
    } else if ([className isEqualToString:@"CCUIContentModuleBackgroundView"] ||
               [className isEqualToString:@"CCUIButtonModuleView"]) {
        IOS26CCApplyGlass(view, 0.08, IOS26CCCardRadiusForView(view), YES);
    } else if ([className isEqualToString:@"CCUIControlTemplateView"]) {
        // Templates often sit directly over a same-sized module background; keep their glass,
        // but let the background view provide the single visible outline.
        IOS26CCApplyGlass(view, 0.05, IOS26CCCardRadiusForView(view), NO);
    } else if ([className isEqualToString:@"CCUIAccessoryButton"] ||
               [className isEqualToString:@"CCUIPowerButton"] ||
               [className isEqualToString:@"CCUIRoundButton"]) {
        IOS26CCApplyGlass(view, 0.12, minimumDimension * 0.5, YES);
    } else if ([className isEqualToString:@"CCUIContinuousSliderView"] ||
               [className isEqualToString:@"CCUISteppedSliderView"]) {
        IOS26CCApplyGlass(view, 0.08, minimumDimension * 0.5, YES);
    }
}

static void IOS26CCStyleTree(UIView *view) {
    if (!view) {
        return;
    }

    IOS26CCStyleView(view);

    for (UIView *subview in [view.subviews copy]) {
        IOS26CCStyleTree(subview);
    }
}

static void IOS26CCScheduleStyle(UIWindow *window) {
    if (!IOS26CCIsTargetWindow(window)) {
        return;
    }

    static CFTimeInterval lastScheduled = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - lastScheduled < 0.2) {
        return;
    }
    lastScheduled = now;

    __weak UIWindow *weakWindow = window;
    NSArray<NSNumber *> *delays = @[@0.12, @0.4];
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIWindow *strongWindow = weakWindow;
            if (IOS26CCIsTargetWindow(strongWindow)) {
                IOS26CCStyleTree(strongWindow);
            }
        });
    }
}

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    UIWindow *window = self.view.window;
    if (window && IOS26CCIsTargetWindow(window)) {
        IOS26CCScheduleStyle(window);
    }
}

%end

%hook UIView

- (void)layoutSubviews {
    %orig;

    UIWindow *window = self.window;
    if (window && IOS26CCIsTargetWindow(window)) {
        IOS26CCStyleView(self);
    }
}

- (void)didMoveToWindow {
    %orig;

    UIWindow *window = self.window;
    if (window && IOS26CCIsTargetWindow(window)) {
        IOS26CCScheduleStyle(window);
    }
}

%end
