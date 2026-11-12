TARGET := iphone:clang:latest:18.5
ARCHS := arm64e
THEOS_PACKAGE_SCHEME := rootless

INSTALL_TARGET_PROCESSES := SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := IOS26CCStyle
IOS26CCStyle_FILES := Tweak.x
IOS26CCStyle_CFLAGS := -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
