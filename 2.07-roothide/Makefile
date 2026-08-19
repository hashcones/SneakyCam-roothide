THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:clang:latest:15.0

# 1. Compile clean 64-bit binary (prevents Exec format error)
ARCHS = arm64

# 2. Label the Debian package for Sileo / RootHide compatibility
THEOS_PACKAGE_ARCH = iphoneos-arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SneakyCam

SneakyCam_FILES = Tweak.x
SneakyCam_CFLAGS = -fobjc-arc -target arm64-apple-ios15.0 -miphoneos-version-min=15.0
SneakyCam_LDFLAGS = -target arm64-apple-ios15.0 -miphoneos-version-min=15.0
SneakyCam_FRAMEWORKS = UIKit AVFoundation CoreMedia

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += SneakyCamPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk

before-package::
	chmod -R 0755 $(THEOS_STAGING_DIR)

after-install::
	install.exec "killall -9 SpringBoard mediaserverd"