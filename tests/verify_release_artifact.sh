#!/bin/sh
#
# KeywordSMSAlert release artifact verification
#
# Static invariant checks for the RELEASE package. Run it after every
# `make package FINALPACKAGE=1` and BEFORE publishing a .deb:
#
#     sh tests/verify_release_artifact.sh
#
# These invariants encode the hard lessons of this project:
#   - ANY additional dylib injected into SpringBoard turned the ~1 s boot
#     black screen (caused by a co-installed tweak) into a PERMANENT one.
#   - A new always-on daemon was equally implicated.
#   - IOHID / display-state observation caused intermittent black screens.
# The stable architecture therefore is: exactly ONE dylib, injected into
# imagent ONLY, no hooks, no HID, no display/lock observers, no daemon.
#
# The script is read-only: it never modifies the repo or the package.
#
set -u

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
STAGE="$REPO_ROOT/.theos/_"
DYLIB="$STAGE/Library/MobileSubstrate/DynamicLibraries/KeywordSMSAlertDetector.dylib"
FILTER="$STAGE/Library/MobileSubstrate/DynamicLibraries/KeywordSMSAlertDetector.plist"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

check() { # check <description> <command...>
    desc="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

check_not() { # check_not <description> <command...> — passes when the command FAILS
    desc="$1"; shift
    if "$@" >/dev/null 2>&1; then bad "$desc"; else ok "$desc"; fi
}

count_strings() { # count_strings <pattern> <file>
    strings "$2" 2>/dev/null | grep -c "$1" || true
}

assert_symbol_absent() { # assert_symbol_absent <symbol>
    n=$(count_strings "$1" "$DYLIB")
    if [ "$n" = "0" ]; then
        ok "symbol absent: $1"
    else
        bad "symbol PRESENT ($n): $1"
    fi
}

echo "== KeywordSMSAlert release artifact verification =="
echo "repo: $REPO_ROOT"
echo ""

# ---------------------------------------------------------------- layout ---
echo "[1] staging layout"
[ -d "$STAGE" ] && ok "staging directory exists (.theos/_)" || bad "staging directory missing — run make package first"
[ -f "$DYLIB" ] && ok "detector dylib present" || bad "detector dylib missing"
[ -f "$FILTER" ] && ok "detector filter plist present" || bad "detector filter plist missing"

check_not "no SpringBoard dylib in package"     test -e "$STAGE/Library/MobileSubstrate/DynamicLibraries/KeywordSMSAlertAlert.dylib"
check_not "no SpringBoard filter in package"    test -e "$STAGE/Library/MobileSubstrate/DynamicLibraries/KeywordSMSAlertAlert.plist"
check_not "no SpringBoard probe dylib"          test -e "$STAGE/Library/MobileSubstrate/DynamicLibraries/KeywordSMSAlertSpringBoardProbe.dylib"
check_not "no SpringBoard probe filter"         test -e "$STAGE/Library/MobileSubstrate/DynamicLibraries/KeywordSMSAlertSpringBoardProbe.plist"
check_not "no LaunchDaemon plist in package"    test -e "$STAGE/Library/LaunchDaemons/com.keyword.smsalert.alertd.plist"
check_not "no ksaalertd binary in package"      test -e "$STAGE/usr/libexec/ksaalertd"
check     "settings bundle present"             test -d "$STAGE/Library/PreferenceBundles/KeywordSMSAlertPrefs.bundle"
check     "PreferenceLoader entry present"      test -f "$STAGE/Library/PreferenceLoader/Preferences/KeywordSMSAlert.plist"
check     "ksactl present"                      test -f "$STAGE/usr/bin/ksactl"
check     "DEBIAN/control present"              test -f "$STAGE/DEBIAN/control"
check     "DEBIAN/postinst present"             test -f "$STAGE/DEBIAN/postinst"
check     "DEBIAN/prerm present"                test -f "$STAGE/DEBIAN/prerm"

# --------------------------------------------------------- injection scope ---
echo ""
echo "[2] injection scope (must be imagent ONLY)"
if [ -f "$FILTER" ]; then
    if plutil -convert xml1 -o - "$FILTER" 2>/dev/null | grep -q "com.apple.imagent"; then
        ok "filter targets com.apple.imagent"
    else
        bad "filter does not target com.apple.imagent"
    fi
    if plutil -convert xml1 -o - "$FILTER" 2>/dev/null | grep -q "com.apple.springboard"; then
        bad "filter mentions com.apple.springboard"
    else
        ok "filter never mentions com.apple.springboard"
    fi
    if plutil -convert xml1 -o - "$FILTER" 2>/dev/null | grep -q "com.apple.backboardd"; then
        bad "filter mentions com.apple.backboardd"
    else
        ok "filter never mentions com.apple.backboardd"
    fi
else
    bad "cannot inspect filter plist (missing)"
fi

# ------------------------------------------------------------- binary scan ---
echo ""
echo "[3] forbidden APIs in the detector dylib"
if [ -f "$DYLIB" ]; then
    # Hooking / substrate
    assert_symbol_absent "MSHookMessageEx"
    assert_symbol_absent "%hook"
    # HID event system (caused intermittent black screens in 1.2.8/1.2.9)
    assert_symbol_absent "IOHIDEventSystemClientCreate"
    assert_symbol_absent "IOHIDEventSystemClientCopyServices"
    assert_symbol_absent "IOHIDEventGetType"
    assert_symbol_absent "IOHIDServiceClient"
    # Display / lock / backlight control (must never be touched)
    assert_symbol_absent "SBLockScreenManager"
    assert_symbol_absent "SBBacklightController"
    assert_symbol_absent "turnOnBacklight"
    assert_symbol_absent "backlightOn"
    assert_symbol_absent "noteScreenWillTurnOn"
    assert_symbol_absent "noteScreenDidTurnOff"
    # Power/lock button hook entry points
    assert_symbol_absent "consumeInitialPressDown"
    assert_symbol_absent "performInitialButtonDownActions"
    assert_symbol_absent "lockUIFromSource"
    # Darwin notify observers (display/lock state inference removed in 1.3.1)
    assert_symbol_absent "notify_register_dispatch"
    assert_symbol_absent "notify_register_check"
    assert_symbol_absent "com.apple.iokit.hid.displayStatus"
    assert_symbol_absent "com.apple.springboard.lockstate"

    # ------------------------------------------------------ linked frameworks
    echo ""
    echo "[4] linked libraries"
    LINKS=$(otool -L "$DYLIB" 2>/dev/null)
    if printf '%s' "$LINKS" | grep -q "AVFoundation"; then
        bad "dylib links AVFoundation (media channel must be compiled out)"
    else
        ok "AVFoundation not linked (KSA_NO_MEDIA_CHANNEL effective)"
    fi
    if printf '%s' "$LINKS" | grep -q "MediaPlayer"; then
        bad "dylib links MediaPlayer"
    else
        ok "MediaPlayer not linked"
    fi
    if printf '%s' "$LINKS" | grep -q "AudioToolbox"; then
        ok "AudioToolbox linked (vibration + alert channel)"
    else
        bad "AudioToolbox missing — vibration/sound would not work"
    fi
    if printf '%s' "$LINKS" | grep -q "libsqlite3"; then
        ok "libsqlite3 linked (read-only sms.db poll)"
    else
        bad "libsqlite3 missing — sms detection would not work"
    fi
    if printf '%s' "$LINKS" | grep -q "libroothide"; then
        ok "libroothide linked via @loader_path/.jbroot (roothide scheme)"
    else
        bad "libroothide not linked — roothide path resolution broken"
    fi
else
    bad "cannot scan dylib (missing)"
fi

# ------------------------------------------------------- scripts and control
echo ""
echo "[5] package scripts and control file"
CONTROL="$STAGE/DEBIAN/control"
if [ -f "$CONTROL" ]; then
    if grep -q "^Architecture: iphoneos-arm64e" "$CONTROL"; then
        ok "control: Architecture iphoneos-arm64e"
    else
        bad "control: wrong architecture"
    fi
    if grep -qi "power.button" "$CONTROL"; then
        bad "control: still claims a power-button feature (removed in 1.2.7)"
    else
        ok "control: no stale power-button claim"
    fi
fi
POSTINST="$STAGE/DEBIAN/postinst"
if [ -f "$POSTINST" ]; then
    if grep -q "killall.*SpringBoard" "$POSTINST"; then
        bad "postinst kills SpringBoard"
    else
        ok "postinst never touches SpringBoard"
    fi
    if grep -q "killall -9 imagent" "$POSTINST" && ! grep -q "launchctl kickstart" "$POSTINST"; then
        bad "postinst uses SIGKILL as the first resort (kickstart/TERM preferred)"
    else
        ok "postinst imagent restart is graceful-first"
    fi
fi
PRERM="$STAGE/DEBIAN/prerm"
if [ -f "$PRERM" ]; then
    if grep -q "ksaalertd" "$PRERM"; then
        bad "prerm still references the removed ksaalertd daemon"
    else
        ok "prerm has no ksaalertd reference"
    fi
fi

# ------------------------------------------------------------- version sync
echo ""
echo "[6] version consistency"
MAKEFILE_VERSION=$(sed -n 's/^PACKAGE_VERSION = //p' "$REPO_ROOT/Makefile" | head -n 1 | tr -d '[:space:]')
CONTROL_VERSION=$(sed -n 's/^Version: //p' "$STAGE/DEBIAN/control" | head -n 1 | tr -d '[:space:]')
CODE_VERSION=$(grep -o 'return @"[0-9][0-9.]*"' "$REPO_ROOT/Sources/KSACommon.m" 2>/dev/null | head -n 1 | tr -d '@";return ')
echo "  Makefile PACKAGE_VERSION = ${MAKEFILE_VERSION:-?}"
echo "  control Version          = ${CONTROL_VERSION:-?}"
echo "  KSAVersionString()       = ${CODE_VERSION:-?}"
if [ -n "$MAKEFILE_VERSION" ] && [ "$MAKEFILE_VERSION" = "$CONTROL_VERSION" ] && [ "$MAKEFILE_VERSION" = "$CODE_VERSION" ]; then
    ok "all three version strings agree ($MAKEFILE_VERSION)"
else
    bad "version strings disagree (Makefile / control / KSACommon.m)"
fi
case "$MAKEFILE_VERSION" in
    *diag*) bad "PACKAGE_VERSION is a diagnostic variant — this is not a release build" ;;
    "")     bad "PACKAGE_VERSION not found" ;;
    *)      ok "release version number (not a diagnostic variant)" ;;
esac

# ----------------------------------------------------------------- summary
echo ""
echo "== result: $PASS passed, $FAIL failed =="
if [ "$FAIL" -gt 0 ]; then
    echo "DO NOT publish this package."
    exit 1
fi
echo "All release invariants hold."
exit 0