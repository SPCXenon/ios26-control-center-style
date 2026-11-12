#import <Preferences/PSListController.h>

@interface IOS26CCStyleRootListController : PSListController
@end

@implementation IOS26CCStyleRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

@end
