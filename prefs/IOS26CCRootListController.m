#import <Preferences/PSListController.h>
#import <spawn.h>

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

@end
