THEOS_PACKAGE_SCHEME = roothide
TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SneakyCam

SneakyCam_FILES = Tweak.x
SneakyCam_CFLAGS = -fobjc-arc
SneakyCam_FRAMEWORKS = UIKit AVFoundation CoreMedia Photos AudioToolbox

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += SneakyCamPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk

before-package::
	chmod -R 0755 $(THEOS_STAGING_DIR)

after-install::
	install.exec "killall -9 SpringBoard mediaserverd"