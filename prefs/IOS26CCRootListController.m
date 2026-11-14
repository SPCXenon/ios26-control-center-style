#import <Preferences/PSListController.h>
#import <spawn.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>

extern char **environ;

@interface IOS26CCRootListController : PSListController
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
