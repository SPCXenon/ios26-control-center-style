#!/usr/bin/env python3
"""Patch for ios26-control-center-style (branch liquid-glass-0.5.0, 0.1.4).

Usage (from the repo root):
    python3 apply_patch.py [Tweak.m] [prefs/Resources/Root.plist]

Every edit must match exactly once, otherwise nothing is written.
Backups are saved as <file>.orig.
"""
import re, sys, shutil, pathlib

tweak = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "Tweak.m")
plist = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else "prefs/Resources/Root.plist")

def edit(src, name, pattern, repl, flags=0):
    out, n = re.subn(pattern, repl, src, count=0, flags=flags)
    if n != 1:
        sys.exit(f"[FAIL] {name}: expected exactly 1 match, found {n}. Nothing was written.")
    print(f"[ ok ] {name}")
    return out

t = tweak.read_text(encoding="utf-8")

# 1) Reduce Transparency switches the effect off (like "Enabled" = off).
t = edit(t, "reduce transparency in LoadPrefs",
    r'(gEnabled\s+= PrefBool\(@"enabled", YES\))(;)',
    r'\1 && !UIAccessibilityIsReduceTransparencyEnabled()\2')

# 2) "Enabled" off must also restore the stock wallpaper blur (bgBlur ignored it before).
t = edit(t, "EffBgBlur helper",
    r'(static NSString \*const kRadiusKeys\[\])',
    'static inline CGFloat EffBgBlur(void) { return gEnabled ? gBgBlur : 1.0; }\n\n' + r'\1')
t = edit(t, "filter radius uses EffBgBlur",
    r'double want = orig\.doubleValue \* gBgBlur;',
    'double want = orig.doubleValue * EffBgBlur();')
# two occurrences of "gBgBlur < 0.999" live in ScaleBackdrop
n_before = t.count("gBgBlur < 0.999")
if n_before != 2:
    sys.exit(f"[FAIL] ScaleBackdrop: expected 2 occurrences of 'gBgBlur < 0.999', found {n_before}.")
t = t.replace("gBgBlur < 0.999", "EffBgBlur() < 0.999")
print("[ ok ] ScaleBackdrop uses EffBgBlur (2 places)")

# 3) Debounced live reload (slider drags post many notifications).
new_reload = '''static void ReloadAndRestyle(void) {
    LoadPrefs();
    for (UIView *v in gTracked.allObjects) {
        if (objc_getAssociatedObject(v, kMenuKey) && !objc_getAssociatedObject(v, kStyledKey)) {
            ApplyMenuDecor(v);
        }
        [v setNeedsLayout];
        [v layoutIfNeeded];
    }
}

// Dragging a slider posts a burst of notifications. Coalesce each burst into one reload.
static BOOL gReloadPending;   // main thread only
static void ScheduleReload(void) {
    if (gReloadPending) return;
    gReloadPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        gReloadPending = NO;
        ReloadAndRestyle();
    });
}

static void PrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                         const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        ScheduleReload();
    });
}
'''
t = edit(t, "debounced PrefsChanged",
    r'static void PrefsChanged\(.*?\n\}\n', lambda m: new_reload, flags=re.DOTALL)

# 4) Hierarchy diagnostic + Reduce Transparency observer in the constructor.
hier = '''// A hooked class that inherits from another hooked class runs both hooks (and may restyle twice).
// Log such pairs once at startup so they are visible in the syslog.
static void LogHookHierarchy(void) {
    const char *names[] = {
        "CCUIContentModuleBackgroundView", "CCUIContentModuleContentContainerView",
        "CCUIControlTemplateView", "CCUIButtonModuleView", "CCUIHeaderPocketView",
        "CCUIAccessoryButton", "CCUIPowerButton", "CCUIRoundButton",
        "CCUIContinuousSliderView", "CCUISteppedSliderView",
    };
    size_t n = sizeof(names) / sizeof(names[0]);
    for (size_t i = 0; i < n; i++) {
        Class sub = objc_getClass(names[i]);
        for (size_t j = 0; sub && j < n; j++) {
            Class sup = objc_getClass(names[j]);
            if (i == j || !sup) continue;
            for (Class c = class_getSuperclass(sub); c; c = class_getSuperclass(c)) {
                if (c == sup) {
                    NSLog(@"[IOS26CCStyle] %s inherits from hooked %s; both styling hooks run",
                          names[i], names[j]);
                    break;
                }
            }
        }
    }
}

'''
t = edit(t, "LogHookHierarchy definition",
    r'(__attribute__\(\(constructor\)\))', lambda m: hier + m.group(1))
t = edit(t, "LogHookHierarchy call",
    r'(Install_Stepped\s*\("CCUISteppedSliderView"\);)',
    r'\1\n        LogHookHierarchy();')
t = edit(t, "Reduce Transparency observer",
    r'(CFNotificationSuspensionBehaviorCoalesce\);)\n',
    r'''\1

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIAccessibilityReduceTransparencyStatusDidChangeNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
            ScheduleReload();
        }];
''' + "\n")

# 5) Settings default for "sheen" was 0.1 in the UI but 0.07 in code.
p = plist.read_text(encoding="utf-8")
p = edit(p, "Root.plist sheen default 0.1 -> 0.07",
    r'(<key>default</key>\s*<real>)0\.1(</real>(?:(?!</dict>).)*?<key>key</key>\s*<string>sheen</string>)',
    r'\g<1>0.07\g<2>', flags=re.DOTALL)

# sanity: balanced braces in the result
for ch_open, ch_close in ("{}", "()", "[]"):
    if t.count(ch_open) != t.count(ch_close):
        sys.exit(f"[FAIL] unbalanced {ch_open}{ch_close} after patch. Nothing was written.")

shutil.copy(tweak, str(tweak) + ".orig")
shutil.copy(plist, str(plist) + ".orig")
tweak.write_text(t, encoding="utf-8")
plist.write_text(p, encoding="utf-8")
print("Done. Backups: Tweak.m.orig, Root.plist.orig")
