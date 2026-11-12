#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

static BOOL IOS26CCIsTargetWindow(UIWindow *window) {
    return [NSStringFromClass(window.class) isEqualToString:@"SBControlCenterWindow"];
}

static void IOS26CCApplyModuleGlass(UIView *view) {
    UIColor *tint = [UIColor colorWithWhite:1.0 alpha:0.13];
    view.backgroundColor = tint;
    view.layer.backgroundColor = tint.CGColor;
    view.layer.cornerRadius = 26.0;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.borderWidth = 0.7;
    view.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.2].CGColor;
}

static void IOS26CCApplySoftControlStyle(UIView *view, CGFloat radius) {
    view.layer.cornerRadius = radius;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.borderWidth = 0.6;
    view.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;
    view.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
}

static void IOS26CCStyleTree(UIView *view) {
    if (!view) {
        return;
    }

    NSString *className = NSStringFromClass(view.class);
    if ([className isEqualToString:@"CCUIContentModuleBackgroundView"]) {
        IOS26CCApplyModuleGlass(view);
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

- (void)didMoveToWindow {
    %orig;

    UIWindow *window = self.window;
    if (window && IOS26CCIsTargetWindow(window)) {
        IOS26CCScheduleStyle(window);
    }
}

%end
