THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:clang:latest:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = SneakyCamPrefs

SneakyCamPrefs_FILES = SneakyCamRootListController.m
SneakyCamPrefs_FRAMEWORKS = UIKit Foundation
SneakyCamPrefs_PRIVATE_FRAMEWORKS = Preferences
SneakyCamPrefs_INSTALL_PATH = /Library/PreferenceBundles
SneakyCamPrefs_CFLAGS = -fobjc-arc -target arm64-apple-ios15.0 -miphoneos-version-min=15.0
SneakyCamPrefs_LDFLAGS = -target arm64-apple-ios15.0 -miphoneos-version-min=15.0

include $(THEOS_MAKE_PATH)/bundle.mk