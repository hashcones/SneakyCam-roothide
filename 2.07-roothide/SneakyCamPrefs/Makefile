TARGET := iphone:clang:latest:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = SneakyCamPrefs

SneakyCamPrefs_FILES = SneakyCamRootListController.m
SneakyCamPrefs_FRAMEWORKS = UIKit
SneakyCamPrefs_PRIVATE_FRAMEWORKS = Preferences
SneakyCamPrefs_INSTALL_PATH = /Library/PreferenceBundles
SneakyCamPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk