##############################################################################
# KeywordSMSAlert - Theos project for Dopamine RootHide (roothide) 2.4.9.27
#
#   Device        : iPhone 12 (arm64e), iOS 15.4.1
#   Jailbreak     : Dopamine RootHide 2.4.9.27 (roothide bootstrap)
#   Toolchain     : roothide/theos (https://github.com/roothide/theos)
#
# Build:
#   make clean && make package                 # debug package
#   make clean && make package FINALPACKAGE=1  # release package
#
# The roothide package scheme is REQUIRED. It is what makes Theos
#
#   * install into <jbroot>/Library/MobileSubstrate/DynamicLibraries
#     (roothide randomises its jailbreak root; it is NOT a fixed /var/jb),
#   * link the roothide API as "@loader_path/.jbroot/usr/lib/libroothide.dylib",
#   * emit "Architecture: iphoneos-arm64e", which is what roothide packages use.
#
# Do NOT build this project with a rootful or a plain rootless Theos setup.
#
# Two dylibs are produced on purpose (see README):
#
#   KeywordSMSAlertDetector -> com.apple.imagent     (SMS detection only: no audio
#                                                     or UI frameworks linked)
#   KeywordSMSAlertAlert    -> com.apple.springboard (alert engine + power button)
#
# A single combined dylib would force AVFoundation/AudioToolbox into the SMS
# daemon. Splitting keeps the daemon side minimal, which is a stability win.
##############################################################################

export ARCHS = arm64 arm64e
# minos = 15.4 (iOS 15.4.1); "latest" = newest iPhoneOS SDK found in $THEOS/sdks.
export TARGET = iphone:clang:latest:15.4

# roothide support that ships with roothide/theos (vendor/mod/roothide).
THEOS_PACKAGE_SCHEME = roothide

PACKAGE_VERSION = 1.1.0

include $(THEOS)/makefiles/common.mk

# Shared, framework free sources (compiled into both dylibs).
KSA_SHARED_FILES = \
	Sources/KSACommon.m \
	Sources/KSAConfig.m \
	Sources/KSADedupCache.m \
	Sources/KSALog.m \
	Sources/KSATrigger.m

KSA_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/Sources -Wno-unused-parameter

TWEAK_NAME = KeywordSMSAlertDetector KeywordSMSAlertAlert

# ---------------------------------------------------------------- detector ---
KeywordSMSAlertDetector_FILES = \
	Sources/KeywordSMSAlertDetector.xm \
	Sources/KSASMSDetector.m \
	Sources/KSASMSWatcher.m \
	$(KSA_SHARED_FILES)

KeywordSMSAlertDetector_CFLAGS = $(KSA_CFLAGS)
KeywordSMSAlertDetector_FRAMEWORKS = Foundation CoreFoundation
# jbroot() comes from libroothide.dylib (roothide API, see roothide/Developer).
KeywordSMSAlertDetector_LIBRARIES = sqlite3
KeywordSMSAlertDetector_LDFLAGS = -lroothide

# ------------------------------------------------------------------- alert ---
KeywordSMSAlertAlert_FILES = \
	Sources/KeywordSMSAlertAlert.xm \
	Sources/KSAAlertManager.m \
	Sources/KSASoundConverter.m \
	Sources/KSAPowerButton.m \
	$(KSA_SHARED_FILES)

KeywordSMSAlertAlert_CFLAGS = $(KSA_CFLAGS)
KeywordSMSAlertAlert_FRAMEWORKS = Foundation CoreFoundation AVFoundation AudioToolbox
KeywordSMSAlertAlert_LDFLAGS = -lroothide

include $(THEOS_MAKE_PATH)/tweak.mk

# ------------------------------------------------------- settings bundle ---
# Settings -> KeywordSMSAlert. Loaded by PreferenceLoader inside the Settings app;
# the root pane is registered by layout/Library/PreferenceLoader/Preferences/.
BUNDLE_NAME = KeywordSMSAlertPrefs

KeywordSMSAlertPrefs_FILES = \
	Sources/Prefs/KSARootListController.m \
	Sources/Prefs/KSAListEditorController.m \
	Sources/Prefs/KSAChoiceController.m \
	Sources/Prefs/KSASoundPickerController.m \
	Sources/Prefs/KSAPrefsStore.m \
	Sources/KSASoundConverter.m

KeywordSMSAlertPrefs_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/Sources -I$(THEOS_PROJECT_DIR)/Sources/Prefs -Wno-unused-parameter
KeywordSMSAlertPrefs_FRAMEWORKS = Foundation UIKit Preferences AudioToolbox
KeywordSMSAlertPrefs_INSTALL_PATH = /Library/PreferenceBundles
KeywordSMSAlertPrefs_RESOURCE_DIRS = PrefsResources

include $(THEOS_MAKE_PATH)/bundle.mk

# ------------------------------------------------------------------- tool ---
# Fallback configuration / test helper, independent of PreferenceLoader:
#   ksactl status | get <Key> | set <Key> <Value> | keywords add <text> | test | reload
TOOL_NAME = ksactl

ksactl_FILES = Sources/Tools/ksactl.m
ksactl_CFLAGS = -fobjc-arc -Wno-unused-parameter
ksactl_FRAMEWORKS = Foundation CoreFoundation
ksactl_LIBRARIES = sqlite3
ksactl_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk

# Picking up a freshly installed/updated tweak:
#   SpringBoard -> alert engine + power button watcher
#   imagent     -> SMS detector
INSTALL_TARGET_PROCESSES = SpringBoard imagent

# Keep the generated .deb name tidy (KeywordSMSAlert_<version>_<arch>.deb) while the
# Debian package identifier stays the conventional com.keyword.smsalert.
THEOS_PACKAGE_NAME = KeywordSMSAlert

after-install::
	install.exec "killall -9 imagent 2>/dev/null; true"
