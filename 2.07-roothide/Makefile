THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:clang:latest:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SneakyCam

SneakyCam_FILES = Tweak.x
SneakyCam_CFLAGS = -fobjc-arc
SneakyCam_FRAMEWORKS = UIKit AVFoundation CoreMedia

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += SneakyCamPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 SpringBoard mediaserverd"