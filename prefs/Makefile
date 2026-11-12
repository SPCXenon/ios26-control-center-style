TARGET := iphone:clang:16.5:15.0
ARCHS := arm64e
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = IOS26CCStylePrefs

IOS26CCStylePrefs_FILES = IOS26CCRootListController.m
IOS26CCStylePrefs_FRAMEWORKS = UIKit
IOS26CCStylePrefs_PRIVATE_FRAMEWORKS = Preferences
IOS26CCStylePrefs_INSTALL_PATH = /Library/PreferenceBundles
IOS26CCStylePrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
