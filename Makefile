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
# The roothide package scheme is REQUIRED: it installs into the (randomised)
# jbroot, links libroothide as "@loader_path/.jbroot/usr/lib/libroothide.dylib"
# and emits "Architecture: iphoneos-arm64e".
#
# ---------------------------------------------------------------------------
# ARCHITECTURE (1.2.0) - "imagent only, zero extra processes"
#
#   KeywordSMSAlertDetector -> com.apple.imagent
#     * read-only polling of sms.db (no hooks),
#     * keyword matching,
#     * the alert engine itself (vibration + ringer/alert-channel sound),
#     * an event-driven stop source (display/lock Darwin notifications).
#
#   Nothing is injected into SpringBoard and no launchd service is installed.
#   This is the only configuration that survived on-device A/B testing against
#   CallAssist 2.5.1:
#
#     detector only                      -> userspace restart OK
#     + SpringBoard dylib (any content)  -> permanent black screen
#     + standalone launchd daemon        -> permanent black screen
#
#   Linking note: the alert channel (AudioServicesCreateSystemSoundID /
#   AudioServicesPlaySystemSound) and vibration live in AudioToolbox, so imagent
#   does NOT link AVFoundation here (KSA_NO_MEDIA_CHANNEL). The AVAudioPlayer
#   "media channel" therefore only exists in the diagnostic builds.
#
# ---------------------------------------------------------------------------
# DIAGNOSTIC BUILD VARIANTS (kept for reproducibility, NOT for users):
#   KSA_BUILD_VARIANT=no-hooks            SpringBoard alert dylib, hooks disabled
#   KSA_BUILD_VARIANT=no-springboard      detector only (no alerting at all)
#   KSA_BUILD_VARIANT=minimal-springboard inert SpringBoard probe dylib
#   KSA_BUILD_VARIANT=daemon              separate launchd alert daemon
##############################################################################

export ARCHS = arm64 arm64e
# minos = 15.4 (iOS 15.4.1); "latest" = newest iPhoneOS SDK found in $THEOS/sdks.
export TARGET = iphone:clang:latest:15.4

# roothide support that ships with roothide/theos (vendor/mod/roothide).
THEOS_PACKAGE_SCHEME = roothide

PACKAGE_VERSION = 1.2.9

KSA_BUILD_VARIANT ?= imagent

ifeq ($(KSA_BUILD_VARIANT),no-hooks)
PACKAGE_VERSION = 1.2.0~diagA
KSA_ALERT_VARIANT_CFLAGS = -DKSA_DIAGNOSTIC_NO_HOOKS=1
else ifeq ($(KSA_BUILD_VARIANT),no-springboard)
PACKAGE_VERSION = 1.2.0~diagB
else ifeq ($(KSA_BUILD_VARIANT),minimal-springboard)
PACKAGE_VERSION = 1.2.0~diagC
else ifeq ($(KSA_BUILD_VARIANT),daemon)
PACKAGE_VERSION = 1.2.0~diagD
endif

include $(THEOS)/makefiles/common.mk

# Shared, framework free sources.
KSA_SHARED_FILES = \
	Sources/KSACommon.m \
	Sources/KSAConfig.m \
	Sources/KSADedupCache.m \
	Sources/KSALog.m \
	Sources/KSATrigger.m

KSA_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/Sources -Wno-unused-parameter

# ------------------------------------------------------------------ targets ---
ifeq ($(KSA_BUILD_VARIANT),no-hooks)
TWEAK_NAME = KeywordSMSAlertDetector KeywordSMSAlertAlert
else ifeq ($(KSA_BUILD_VARIANT),minimal-springboard)
TWEAK_NAME = KeywordSMSAlertDetector KeywordSMSAlertSpringBoardProbe
else
TWEAK_NAME = KeywordSMSAlertDetector
endif

# ---------------------------------------------------------------- detector ---
ifeq ($(KSA_BUILD_VARIANT),imagent)
KSA_DETECTOR_ALERT_FILES = \
	Sources/KSAAlertManager.m \
	Sources/KSASoundConverter.m \
	Sources/Daemon/KSAHookInstallerDaemon.m \
	Sources/Daemon/KSADisplayStateStop.m \
	Sources/Daemon/KSAHIDPowerButton.m \
	Sources/Daemon/KSAHIDEventMatcher.c \
	Sources/Daemon/KSARuntimeStatus.m
KSA_DETECTOR_ALERT_CFLAGS = -DKSA_ALERT_IN_DETECTOR=1 -DKSA_NO_MEDIA_CHANNEL=1 -DKSA_STANDALONE_ALERTD=1
KSA_DETECTOR_ALERT_FRAMEWORKS = AudioToolbox
else
KSA_DETECTOR_ALERT_FILES =
KSA_DETECTOR_ALERT_CFLAGS =
KSA_DETECTOR_ALERT_FRAMEWORKS =
endif

KeywordSMSAlertDetector_FILES = \
	Sources/KeywordSMSAlertDetector.xm \
	Sources/KSASMSDetector.m \
	Sources/KSASMSWatcher.m \
	$(KSA_DETECTOR_ALERT_FILES) \
	$(KSA_SHARED_FILES)

KeywordSMSAlertDetector_CFLAGS = $(KSA_CFLAGS) $(KSA_DETECTOR_ALERT_CFLAGS)
KeywordSMSAlertDetector_FRAMEWORKS = Foundation CoreFoundation $(KSA_DETECTOR_ALERT_FRAMEWORKS)
# jbroot() comes from libroothide.dylib (roothide API, see roothide/Developer).
KeywordSMSAlertDetector_LIBRARIES = sqlite3
KeywordSMSAlertDetector_LDFLAGS = -lroothide

# ------------------------------------------- legacy/diagnostic SpringBoard ---
ifeq ($(KSA_BUILD_VARIANT),no-hooks)
KeywordSMSAlertAlert_FILES = \
	Sources/KeywordSMSAlertAlert.xm \
	Sources/KSAAlertManager.m \
	Sources/KSASoundConverter.m \
	Sources/KSAPowerButton.m \
	$(KSA_SHARED_FILES)

KeywordSMSAlertAlert_CFLAGS = $(KSA_CFLAGS) $(KSA_ALERT_VARIANT_CFLAGS)
KeywordSMSAlertAlert_FRAMEWORKS = Foundation CoreFoundation AVFoundation AudioToolbox
KeywordSMSAlertAlert_LDFLAGS = -lroothide
endif

# ------------------------------------------------ minimal SpringBoard probe ---
ifeq ($(KSA_BUILD_VARIANT),minimal-springboard)
KeywordSMSAlertSpringBoardProbe_FILES = Sources/KeywordSMSAlertSpringBoardProbe.m
KeywordSMSAlertSpringBoardProbe_CFLAGS = -fobjc-arc -Wno-unused-parameter
KeywordSMSAlertSpringBoardProbe_LDFLAGS = -lroothide
endif

include $(THEOS_MAKE_PATH)/tweak.mk

# ------------------------------------------------------- settings bundle ---
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

# ------------------------------------------------------------------ tools ---
# ksactl is a GUI-independent maintenance helper and is always installed.
# ksaalertd (the launchd alert host) only exists in the diagnostic "daemon" build:
# on this device that architecture reproduced the CallAssist black screen.
TOOL_NAME = ksactl

ksactl_FILES = Sources/Tools/ksactl.m
ksactl_CFLAGS = -fobjc-arc -Wno-unused-parameter
ksactl_FRAMEWORKS = Foundation CoreFoundation
ksactl_LIBRARIES = sqlite3
ksactl_INSTALL_PATH = /usr/bin

ifeq ($(KSA_BUILD_VARIANT),daemon)
TOOL_NAME += ksaalertd

ksaalertd_FILES = \
	Sources/Daemon/KSAAlertDaemonMain.m \
	Sources/Daemon/KSAHIDPowerButton.m \
	Sources/Daemon/KSAHIDEventMatcher.c \
	Sources/Daemon/KSARuntimeStatus.m \
	Sources/Daemon/KSAHookInstallerDaemon.m \
	Sources/KSAAlertManager.m \
	Sources/KSASoundConverter.m \
	$(KSA_SHARED_FILES)
ksaalertd_CFLAGS = $(KSA_CFLAGS) -DKSA_STANDALONE_ALERTD=1
ksaalertd_FRAMEWORKS = Foundation CoreFoundation AVFoundation AudioToolbox
ksaalertd_LDFLAGS = -lroothide
ksaalertd_INSTALL_PATH = /usr/libexec
ksaalertd_CODESIGN_FLAGS = -SSources/Daemon/ksaalertd.entitlements
endif

include $(THEOS_MAKE_PATH)/tool.mk

# The daemon variant additionally installs its launchd job. It is deliberately kept
# OUTSIDE layout/ so the normal package can never install a launchd service.
ifeq ($(KSA_BUILD_VARIANT),daemon)
after-stage::
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/LaunchDaemons"
	@cp Sources/Daemon/LaunchDaemon/com.keyword.smsalert.alertd.plist \
		"$(THEOS_STAGING_DIR)/Library/LaunchDaemons/com.keyword.smsalert.alertd.plist"
	@chmod 644 "$(THEOS_STAGING_DIR)/Library/LaunchDaemons/com.keyword.smsalert.alertd.plist"
endif

# Picking up a freshly installed/updated tweak: only imagent needs restarting.
# SpringBoard is never touched by this package.
INSTALL_TARGET_PROCESSES = imagent

# Keep the generated .deb name tidy while the Debian package identifier stays the
# conventional com.keyword.smsalert.
ifeq ($(KSA_BUILD_VARIANT),no-hooks)
THEOS_PACKAGE_NAME = KeywordSMSAlert_DiagnosticA_NoHooks
else ifeq ($(KSA_BUILD_VARIANT),no-springboard)
THEOS_PACKAGE_NAME = KeywordSMSAlert_DiagnosticB_NoSpringBoard
else ifeq ($(KSA_BUILD_VARIANT),minimal-springboard)
THEOS_PACKAGE_NAME = KeywordSMSAlert_DiagnosticC_MinimalSpringBoard
else ifeq ($(KSA_BUILD_VARIANT),daemon)
THEOS_PACKAGE_NAME = KeywordSMSAlert_DiagnosticD_LaunchDaemon
else
THEOS_PACKAGE_NAME = KeywordSMSAlert
endif

after-install::
	install.exec "killall -9 imagent 2>/dev/null; true"
