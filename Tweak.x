#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static char kIOS26CCGlassEffectKey;

static BOOL IOS26CCIsTargetWindow(UIWindow *window) {
    return [NSStringFromClass(window.class) isEqualToString:@"SBControlCenterWindow"];
}

static void IOS26CCApplyGlassBackground(UIView *view) {
    if (objc_getAssociatedObject(view, &kIOS26CCGlassEffectKey)) {
        return;
    }

    UIVisualEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark];
    UIVisualEffectView *glassView = [[UIVisualEffectView alloc] initWithEffect:effect];
    glassView.frame = view.bounds;
    glassView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    glassView.userInteractionEnabled = NO;
    glassView.layer.cornerRadius = 24.0;
    glassView.layer.cornerCurve = kCACornerCurveContinuous;
    glassView.clipsToBounds = YES;

    [view insertSubview:glassView atIndex:0];
    view.backgroundColor = UIColor.clearColor;
    view.layer.cornerRadius = 24.0;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.borderWidth = 0.6;
    view.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;

    objc_setAssociatedObject(view, &kIOS26CCGlassEffectKey, glassView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void IOS26CCApplySoftControlStyle(UIView *view, CGFloat radius) {
    view.layer.cornerRadius = radius;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.borderWidth = 0.6;
    view.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;
    view.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
}

static void IOS26CCStyleTree(UIView *view) {
    if (!view || [view isKindOfClass:UIVisualEffectView.class]) {
        return;
    }

    NSString *className = NSStringFromClass(view.class);
    if ([className isEqualToString:@"CCUIContentModuleBackgroundView"]) {
        IOS26CCApplyGlassBackground(view);
    } else if ([className isEqualToString:@"CCUIHeaderPocketView"]) {
        IOS26CCApplySoftControlStyle(view, 24.0);
    } else if ([className isEqualToString:@"CCUIAccessoryButton"] ||
               [className isEqualToString:@"CCUIPowerButton"] ||
               [className isEqualToString:@"CCUIRoundButton"]) {
        IOS26CCApplySoftControlStyle(view, MIN(CGRectGetWidth(view.bounds), CGRectGetHeight(view.bounds)) * 0.5);
    }

    for (UIView *subview in [view.subviews copy]) {
        IOS26CCStyleTree(subview);
    }
}

static void IOS26CCScheduleStyle(UIWindow *window) {
    if (!IOS26CCIsTargetWindow(window)) {
        return;
    }

    __weak UIWindow *weakWindow = window;
    NSArray<NSNumber *> *delays = @[@0.12, @0.45, @0.9];
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
