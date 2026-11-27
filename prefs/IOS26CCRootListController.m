#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <spawn.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>

extern char **environ;

@interface IOS26CCRootListController : PSListController
@end


// On-device log viewer: lets the logs be read, copied or saved without a computer.
@interface IOS26CCLogViewController : UIViewController
@property (nonatomic, copy) NSString *text;
@end

@implementation IOS26CCLogViewController {
    UITextView *_tv;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    if (!self.title) self.title = @"Logs";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _tv = [[UITextView alloc] initWithFrame:self.view.bounds];
    _tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tv.editable = NO;
    _tv.alwaysBounceVertical = YES;
    _tv.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    _tv.text = self.text;
    [self.view addSubview:_tv];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"Copy" style:UIBarButtonItemStylePlain target:self action:@selector(copyAll)],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(share:)],
    ];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)copyAll { UIPasteboard.generalPasteboard.string = self.text; }
- (void)share:(UIBarButtonItem *)item {
    UIActivityViewController *v = [[UIActivityViewController alloc] initWithActivityItems:@[self.text] applicationActivities:nil];
    v.popoverPresentationController.barButtonItem = item;
    [self presentViewController:v animated:YES completion:nil];
}
@end

static NSString *const kDomain = @"com.xenon.ios26ccstyle";
static NSString *const kLogDir = @"/var/mobile/Library/Logs/IOS26CCStyle/";

// The whole preference domain, so the Settings page can be copied to another device (or to me) and
// pasted back. Only this tweak's domain is read or written.
static NSDictionary *ReadPrefs(void) {
    CFStringRef dom = CFSTR("com.xenon.ios26ccstyle");
    CFPreferencesAppSynchronize(dom);
    NSDictionary *out = @{};
    CFArrayRef keys = CFPreferencesCopyKeyList(dom, CFSTR("mobile"), kCFPreferencesAnyHost);
    if (keys) {
        CFDictionaryRef d = CFPreferencesCopyMultiple(keys, dom, CFSTR("mobile"), kCFPreferencesAnyHost);
        if (d) out = (__bridge_transfer NSDictionary *)d;
        CFRelease(keys);
    }
    return out;
}

static void WritePrefs(NSDictionary *values) {
    CFStringRef dom = CFSTR("com.xenon.ios26ccstyle");
    for (NSString *k in values) {
        if (![k isKindOfClass:NSString.class]) continue;
        CFPreferencesSetAppValue((__bridge CFStringRef)k, (__bridge CFPropertyListRef)values[k], dom);
    }
    CFPreferencesAppSynchronize(dom);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.xenon.ios26ccstyle/reload"), NULL, NULL, YES);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("xenon.liquidglass/ParametersReloaded"), NULL, NULL, YES);
}

// Three named looks. “iOS 27 Clear” is the tuned reference state, “iOS 26 Frosted” the heavier
// frosted variant, “Old dark” the 0.4.x look (darker tiles, stronger rim).
static NSDictionary *PresetFor(NSString *name) {
    if ([name isEqualToString:@"ios27"]) return @{
        @"glassTint": @0.55, @"rimIntensity": @0.45, @"rimWidth": @0.7, @"sheen": @0.035,
        @"innerRim": @0.15, @"glow": @0.05, @"reflect": @0.6, @"edgeDark": @0.3,
        @"dispersion": @0.5, @"fillTint": @0.0, @"glassBlurRadius": @20 };
    if ([name isEqualToString:@"ios26"]) return @{
        @"glassTint": @0.80, @"rimIntensity": @0.60, @"rimWidth": @0.9, @"sheen": @0.07,
        @"innerRim": @0.25, @"glow": @0.09, @"reflect": @0.8, @"edgeDark": @0.45,
        @"dispersion": @0.7, @"fillTint": @0.04, @"glassBlurRadius": @12 };
    return @{
        @"glassTint": @0.55, @"rimIntensity": @0.7, @"rimWidth": @0.8, @"sheen": @0.06,
        @"innerRim": @0.2, @"glow": @0.12, @"reflect": @0.7, @"edgeDark": @0.35,
        @"dispersion": @0.6, @"fillTint": @0.0, @"glassBlurRadius": @14 };
}

@implementation IOS26CCRootListController

- (void)alertTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)applyPreset:(PSSpecifier *)spec {
    NSString *name = spec.properties[@"preset"] ?: @"olddark";
    WritePrefs(PresetFor(name));
    [self reloadSpecifiers];
    [self alertTitle:@"Preset applied" message:spec.properties[@"label"] ?: name];
}

- (void)exportSettings {
    NSData *d = [NSPropertyListSerialization dataWithPropertyList:ReadPrefs()
                                                           format:NSPropertyListXMLFormat_v1_0
                                                          options:0 error:NULL];
    NSString *s = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
    if (!s.length) { [self alertTitle:@"Nothing to copy" message:@"The preference domain is empty."]; return; }
    UIPasteboard.generalPasteboard.string = s;
    [self alertTitle:@"Settings copied" message:@"The whole iOS 26 CC Style domain is on the clipboard as an XML plist."];
}

- (void)importSettings {
    NSString *s = UIPasteboard.generalPasteboard.string;
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    id plist = d ? [NSPropertyListSerialization propertyListWithData:d options:NSPropertyListImmutable
                                                              format:NULL error:NULL] : nil;
    if (![plist isKindOfClass:NSDictionary.class]) {
        [self alertTitle:@"Nothing to paste" message:@"Copy an exported settings plist first, then tap this."];
        return;
    }
    WritePrefs(plist);
    [self reloadSpecifiers];
    [self alertTitle:@"Settings applied" message:[NSString stringWithFormat:@"%lu keys", (unsigned long)((NSDictionary *)plist).count]];
}

- (void)showCompatReport {
    NSString *t = [NSString stringWithContentsOfFile:[kLogDir stringByAppendingString:@"ios26ccstyle-compat.txt"]
                                            encoding:NSUTF8StringEncoding error:NULL];
    IOS26CCLogViewController *vc = [IOS26CCLogViewController new];
    vc.title = @"Compatibility";
    vc.text = t.length ? t : @"No report yet. Open Control Center once after installing, then come back.";
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)respring {
    pid_t pid;
    const char *sbreload[] = { "sbreload", NULL };
    if (posix_spawn(&pid, "/var/jb/usr/bin/sbreload", NULL, NULL, (char *const *)sbreload, environ) != 0) {
        const char *killall[] = { "killall", "-9", "SpringBoard", NULL };
        posix_spawn(&pid, "/var/jb/usr/bin/killall", NULL, NULL, (char *const *)killall, environ);
    }
}


static BOOL RunTool(NSArray<NSString *> *paths, NSArray<NSString *> *args) {
    for (NSString *path in paths) {
        if (access(path.fileSystemRepresentation, X_OK) != 0) continue;
        const char *argv[8] = { path.fileSystemRepresentation };
        NSUInteger n = 1;
        for (NSString *a in args) if (n < 7) argv[n++] = a.UTF8String;
        argv[n] = NULL;
        pid_t pid;
        if (posix_spawn(&pid, path.fileSystemRepresentation, NULL, NULL, (char *const *)argv, environ) == 0) return YES;
    }
    return NO;
}

// backboardd only loads tweaks when it starts, so the renderer needs it restarted.
- (void)restartBackboardd {
    BOOL ok = RunTool(@[@"/var/jb/usr/bin/killall", @"/usr/bin/killall"], @[@"-9", @"backboardd"]);
    if (!ok) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Could not restart backboardd"
            message:@"killall was not found. Do a userspace reboot from Dopamine instead."
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }
}

- (void)viewLogs {
    NSString *dir = @"/var/mobile/Library/Logs/IOS26CCStyle/";
    NSArray<NSArray<NSString *> *> *files = @[
        @[@"crash report", [dir stringByAppendingString:@"xenonglass-crash.log"]],
        @[@"previous session log", [dir stringByAppendingString:@"xenonglass-previous.log"]],
        @[@"current session log", [dir stringByAppendingString:@"xenonglass.log"]],
        @[@"view dump", [dir stringByAppendingString:@"ios26ccstyle-module-dump.txt"]],
        @[@"tile chain", [dir stringByAppendingString:@"ios26ccstyle-tile-chain.txt"]],
        @[@"page scroll", [dir stringByAppendingString:@"ios26ccstyle-scroll.txt"]],
        @[@"edit mode", [dir stringByAppendingString:@"ios26ccstyle-edit.txt"]],
        @[@"press", [dir stringByAppendingString:@"ios26ccstyle-press.txt"]],
        @[@"now playing tree", [dir stringByAppendingString:@"ios26ccstyle-expanded-np.txt"]],
        @[@"expanded module tree", [dir stringByAppendingString:@"ios26ccstyle-expanded-dump.txt"]],
        @[@"stock animations", [dir stringByAppendingString:@"ios26ccstyle-anim-log.txt"]],
        @[@"style report", [dir stringByAppendingString:@"ios26ccstyle-style.txt"]],
        @[@"frame times", [dir stringByAppendingString:@"ios26ccstyle-perf.txt"]],
        @[@"compatibility", [dir stringByAppendingString:@"ios26ccstyle-compat.txt"]],
        @[@"launch breadcrumb", [dir stringByAppendingString:@"ios26ccstyle-launch.txt"]],
        @[@"previous launch breadcrumb", [dir stringByAppendingString:@"ios26ccstyle-launch-previous.txt"]],
        @[@"renderer breadcrumb", [dir stringByAppendingString:@"xenonglass-breadcrumb.txt"]],
    ];
    NSMutableString *all = [NSMutableString string];
    for (NSArray<NSString *> *f in files) {
        NSString *t = [NSString stringWithContentsOfFile:f[1] encoding:NSUTF8StringEncoding error:NULL];
        if (t.length > 40000) t = [@"...\n" stringByAppendingString:[t substringFromIndex:t.length - 40000]];
        [all appendFormat:@"===== %@ =====\n%@\n\n", f[0], t.length ? t : @"(missing, empty or not readable from Settings)"];
    }
    IOS26CCLogViewController *vc = [IOS26CCLogViewController new];
    vc.text = all;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)resetDefaults {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Reset to defaults?"
        message:@"All settings of this tweak return to their default values."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        CFStringRef dom = CFSTR("com.xenon.ios26ccstyle");
        CFArrayRef keys = CFPreferencesCopyKeyList(dom, CFSTR("mobile"), kCFPreferencesAnyHost);
        if (keys) {
            CFPreferencesSetMultiple(NULL, keys, dom, CFSTR("mobile"), kCFPreferencesAnyHost);
            CFRelease(keys);
        }
        CFPreferencesSynchronize(dom, CFSTR("mobile"), kCFPreferencesAnyHost);
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR("com.xenon.ios26ccstyle/reload"), NULL, NULL, YES);
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR("xenon.liquidglass/ParametersReloaded"), NULL, NULL, YES);
        [self reloadSpecifiers];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
