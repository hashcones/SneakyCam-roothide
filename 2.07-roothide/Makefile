THEOS_PACKAGE_SCHEME = roothide
TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SneakyCam

SneakyCam_FILES = Tweak.x
SneakyCam_CFLAGS = -fobjc-arc
SneakyCam_FRAMEWORKS = UIKit Foundation AVFoundation Photos CoreMedia AudioToolbox

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += SneakyCamPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk