TARGET := iphone:clang:16.5:15.0
ARCHS := arm64e
THEOS_PACKAGE_SCHEME := rootless

INSTALL_TARGET_PROCESSES := SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := IOS26CCStyle
IOS26CCStyle_FILES := Tweak.m
IOS26CCStyle_FRAMEWORKS := UIKit QuartzCore
IOS26CCStyle_CFLAGS := -fobjc-arc -Wno-deprecated-declarations

SUBPROJECTS += prefs backboardd

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
