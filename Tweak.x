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

static char kIOS26CCSurfaceSheenKey;
static char kIOS26CCSpecularRimKey;

static CGFloat IOS26CCCardRadiusForView(UIView *view) {
    CGFloat width = CGRectGetWidth(view.bounds);
    CGFloat height = CGRectGetHeight(view.bounds);
    return MIN(22.0, MIN(width, height) * 0.18);
}

static CAGradientLayer *IOS26CCSurfaceSheenForView(UIView *view) {
    CAGradientLayer *sheen = objc_getAssociatedObject(view, &kIOS26CCSurfaceSheenKey);
    if (!sheen) {
        sheen = [CAGradientLayer layer];
        sheen.startPoint = CGPointMake(0.5, 0.0);
        sheen.endPoint = CGPointMake(0.5, 1.0);
        sheen.locations = @[@0.0, @0.52, @1.0];
        sheen.colors = @[
            (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.70].CGColor,
            (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.10].CGColor,
            (__bridge id)[UIColor colorWithWhite:0.0 alpha:0.34].CGColor,
        ];
        [view.layer insertSublayer:sheen atIndex:0];
        objc_setAssociatedObject(view, &kIOS26CCSurfaceSheenKey, sheen, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (sheen.superlayer != view.layer) {
        [view.layer insertSublayer:sheen atIndex:0];
    }

    sheen.frame = view.bounds;
    sheen.cornerRadius = view.layer.cornerRadius;
    sheen.cornerCurve = kCACornerCurveContinuous;
    sheen.masksToBounds = YES;
    return sheen;
}

static CAGradientLayer *IOS26CCSpecularRimForView(UIView *view) {
    CAGradientLayer *rim = objc_getAssociatedObject(view, &kIOS26CCSpecularRimKey);
    if (!rim) {
        rim = [CAGradientLayer layer];
        rim.startPoint = CGPointMake(0.0, 0.0);
        rim.endPoint = CGPointMake(1.0, 1.0);
        rim.locations = @[@0.0, @0.20, @0.62, @1.0];
        rim.colors = @[
            (__bridge id)[UIColor colorWithWhite:1.0 alpha:1.0].CGColor,
            (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.35].CGColor,
            (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.12].CGColor,
            (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.72].CGColor,
        ];

        CAShapeLayer *mask = [CAShapeLayer layer];
        mask.fillColor = UIColor.clearColor.CGColor;
        mask.strokeColor = UIColor.whiteColor.CGColor;
        mask.lineWidth = 0.7;
        mask.lineJoin = kCALineJoinRound;
        rim.mask = mask;
        [view.layer addSublayer:rim];
        objc_setAssociatedObject(view, &kIOS26CCSpecularRimKey, rim, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (rim.superlayer != view.layer) {
        [view.layer addSublayer:rim];
    }

    rim.frame = view.bounds;
    return rim;
}

static void IOS26CCApplyGlass(UIView *view, CGFloat radius, CGFloat sheenOpacity, CGFloat rimOpacity) {
    if (CGRectGetWidth(view.bounds) <= 0.0 || CGRectGetHeight(view.bounds) <= 0.0) {
        return;
    }

    view.layer.cornerRadius = radius;
    view.layer.cornerCurve = kCACornerCurveContinuous;

    CAGradientLayer *sheen = IOS26CCSurfaceSheenForView(view);
    sheen.opacity = sheenOpacity;

    CAGradientLayer *rim = IOS26CCSpecularRimForView(view);
    rim.opacity = rimOpacity;
    CAShapeLayer *mask = (CAShapeLayer *)rim.mask;
    mask.frame = rim.bounds;
    CGRect rimBounds = CGRectInset(mask.bounds, 0.45, 0.45);
    CGFloat rimRadius = MAX(0.0, radius - 0.45);
    mask.path = [UIBezierPath bezierPathWithRoundedRect:rimBounds cornerRadius:rimRadius].CGPath;
}

static void IOS26CCStyleView(UIView *view) {
    NSString *className = NSStringFromClass(view.class);

    CGFloat minimumDimension = MIN(CGRectGetWidth(view.bounds), CGRectGetHeight(view.bounds));

    if ([className isEqualToString:@"CCUIHeaderPocketView"]) {
        CGFloat radius = MIN(18.0, CGRectGetHeight(view.bounds) * 0.16);
        IOS26CCApplyGlass(view, radius, 0.035, 0.24);
    } else if ([className isEqualToString:@"CCUIContentModuleBackgroundView"] ||
               [className isEqualToString:@"CCUIButtonModuleView"]) {
        IOS26CCApplyGlass(view, IOS26CCCardRadiusForView(view), 0.045, 0.30);
    } else if ([className isEqualToString:@"CCUIAccessoryButton"] ||
               [className isEqualToString:@"CCUIPowerButton"] ||
               [className isEqualToString:@"CCUIRoundButton"]) {
        IOS26CCApplyGlass(view, minimumDimension * 0.5, 0.055, 0.34);
    } else if ([className isEqualToString:@"CCUIContinuousSliderView"] ||
               [className isEqualToString:@"CCUISteppedSliderView"]) {
        IOS26CCApplyGlass(view, minimumDimension * 0.5, 0.0, 0.25);
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
