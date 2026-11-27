#import <Preferences/PSListController.h>
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
    self.title = @"Logs";
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

@implementation IOS26CCRootListController

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
