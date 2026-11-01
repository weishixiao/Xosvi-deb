THEOS_PACKAGE_SCHEME=rootless
TARGET = iphone:clang:latest:14.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = FruitSlot-mobile

TWEAK_NAME = NoAdsSlot
NoAdsSlot_FILES = Tweak.x
NoAdsSlot_CFLAGS = -fobjc-arc

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk