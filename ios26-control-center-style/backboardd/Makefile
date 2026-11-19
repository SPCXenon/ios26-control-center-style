ARCHS = arm64e
TARGET := iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = IOS26CCBackboardd

IOS26CCBackboardd_FILES      = IOS26CCBackboardd.mm LGSymbolResolver.mm
IOS26CCBackboardd_CFLAGS     = -fobjc-arc -std=c++17 -fno-objc-arc-exceptions
IOS26CCBackboardd_FRAMEWORKS = Metal QuartzCore CoreFoundation
IOS26CCBackboardd_LDFLAGS    = -lc++

include $(THEOS_MAKE_PATH)/tweak.mk
