#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <spawn.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <sys/utsname.h>

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
// Everything the tweak writes lives in its own directory under Apple's Logs. Only backboardd (root) can
// create it, and when a sandbox profile refuses it the tweak falls back to the old Accessibility
// directory, so the viewer asks the new path first and then the fallback, one file at a time.
static NSString *const kLogDir = @"/var/mobile/Library/Logs/IOS26CCStyle/";
static NSString *const kLegacyLogDir = @"/var/mobile/Library/Accessibility/";

static NSString *LGLogFile(NSString *name) {
    NSString *path = [kLogDir stringByAppendingString:name];
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) return path;
    NSString *legacy = [kLegacyLogDir stringByAppendingString:name];
    return [NSFileManager.defaultManager fileExistsAtPath:legacy] ? legacy : path;
}

// One list for the viewer and for the archive, so a file added to one is not missing from the other.
static NSArray<NSArray<NSString *> *> *LGLogEntries(void) {
    return @[
        @[@"crash report", @"xenonglass-crash.log"],
        @[@"previous session log", @"xenonglass-previous.log"],
        @[@"current session log", @"xenonglass.log"],
        @[@"renderer safe mode log", @"xenonglass-safemode.log"],
        @[@"view dump", @"ios26ccstyle-module-dump.txt"],
        @[@"tile chain", @"ios26ccstyle-tile-chain.txt"],
        @[@"page scroll", @"ios26ccstyle-scroll.txt"],
        @[@"edit mode", @"ios26ccstyle-edit.txt"],
        @[@"press", @"ios26ccstyle-press.txt"],
        @[@"now playing tree", @"ios26ccstyle-expanded-np.txt"],
        @[@"expanded module tree", @"ios26ccstyle-expanded-dump.txt"],
        @[@"stock animations", @"ios26ccstyle-anim-log.txt"],
        @[@"style report", @"ios26ccstyle-style.txt"],
        @[@"frame times", @"ios26ccstyle-perf.txt"],
        @[@"compatibility", @"ios26ccstyle-compat.txt"],
        @[@"hook report", @"ios26ccstyle-hooks.txt"],
        @[@"calibration", @"ios26ccstyle-calibrate.txt"],
        @[@"look migration", @"ios26ccstyle-migrated.txt"],
        @[@"launch breadcrumb", @"ios26ccstyle-launch.txt"],
        @[@"previous launch breadcrumb", @"ios26ccstyle-launch-previous.txt"],
        @[@"renderer breadcrumb", @"xenonglass-breadcrumb.txt"],
    ];
}

// The build a report came from, so a screenshot and its log are never separated from their version.
static NSString *LGFingerprint(void) {
    struct utsname info = {};
    uname(&info);
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    NSArray *names = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:kLogDir error:NULL]
                         sortedArrayUsingSelector:@selector(compare:)];
    return [NSString stringWithFormat:@"iOS 26 CC Style %@\ndevice: %s\niOS: %@\nlog dir: %@\nlogs: %@\n",
            version, info.machine[0] ? info.machine : "?", UIDevice.currentDevice.systemVersion, kLogDir,
            names.count ? [names componentsJoinedByString:@", "] : @"(unreadable)"];
}

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
    NSString *t = [NSString stringWithContentsOfFile:LGLogFile(@"ios26ccstyle-compat.txt")
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
    NSArray<NSArray<NSString *> *> *files = LGLogEntries();
    NSMutableString *all = [NSMutableString stringWithFormat:@"log directory: %@\n\n", kLogDir];
    for (NSArray<NSString *> *f in files) {
        NSString *path = LGLogFile(f[1]);
        NSString *t = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
        if (t.length > 40000) t = [@"...\n" stringByAppendingString:[t substringFromIndex:t.length - 40000]];
        [all appendFormat:@"===== %@ =====\n%@\n\n", f[0], t.length ? t : @"(missing, empty or not readable from Settings)"];
    }
    IOS26CCLogViewController *vc = [IOS26CCLogViewController new];
    vc.text = all;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

// Collecting a bug report used to mean copying a dozen files off the phone one at a time. This writes
// one archive file with every log in it and hands it to the share sheet (AirDrop, Files, mail), so a
// report is self-contained and complete instead of a trimmed transcript.
- (void)collectLogs {
    NSMutableString *all = [NSMutableString stringWithFormat:@"%@\n", LGFingerprint()];
    for (NSArray<NSString *> *entry in LGLogEntries()) {
        NSString *text = [NSString stringWithContentsOfFile:LGLogFile(entry[1])
                                                  encoding:NSUTF8StringEncoding error:NULL];
        if (text.length > 300000) text = [@"...\n" stringByAppendingString:[text substringFromIndex:text.length - 300000]];
        [all appendFormat:@"===== %@ (%@) =====\n%@\n\n", entry[0], entry[1],
            text.length ? text : @"(missing, empty or not readable)"];
    }
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"IOS26CCStyle-logs.txt"];
    if (![all writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]) {
        [self alertTitle:@"Could not write the archive" message:path];
        return;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]]
                                                                     applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.view;
    share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                                               CGRectGetMidY(self.view.bounds), 1.0, 1.0);
    [self presentViewController:share animated:YES completion:nil];
}

- (void)copyFingerprint {
    NSString *fingerprint = LGFingerprint();
    UIPasteboard.generalPasteboard.string = fingerprint;
    [self alertTitle:@"Fingerprint copied" message:fingerprint];
}

- (void)clearLogs {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Delete the logs?"
        message:@"Every dump, report and renderer log is removed. The crash-loop guard, the launch breadcrumbs and the migration note are kept, because they are what a boot that never came up leaves behind."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        NSFileManager *fm = NSFileManager.defaultManager;
        for (NSString *name in [fm contentsOfDirectoryAtPath:kLogDir error:NULL]) {
            if (![name hasPrefix:@"ios26ccstyle-"] && ![name hasPrefix:@"xenonglass-"]) continue;
            if ([name containsString:@"guard"] || [name containsString:@"crashloop"] ||
                [name containsString:@"launch"] || [name containsString:@"migrated"]) continue;
            [fm removeItemAtPath:[kLogDir stringByAppendingPathComponent:name] error:NULL];
        }
        [self alertTitle:@"Logs deleted" message:@"Guard, breadcrumbs and the migration note were kept."];
    }]];
    [self presentViewController:a animated:YES completion:nil];
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
