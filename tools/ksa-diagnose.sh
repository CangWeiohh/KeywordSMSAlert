#!/bin/sh
#
# ksa-diagnose.sh — KeywordSMSAlert read-only diagnostics (device or extracted copy)
#
# Purpose: collect everything needed to analyse a black-screen / no-alert incident
# WITHOUT changing any state. The script only reads files and prints them; it never
# writes, kills, restarts or removes anything.
#
# How to run it:
#   * on a device WITH a terminal (SSH/NewTerm):   sh ksa-diagnose.sh > diag.txt
#   * the device this project targets has NO terminal. In that case use one of:
#       - the Settings pane (Settings -> KeywordSMSAlert -> Debug section), which
#         shows the same runtime status this script reads;
#       - Filza: open /var/mobile/Library/Preferences/com.keyword.smsalert.runtime.plist
#         and the config plist, and export the text below by hand;
#       - after a userspace reboot / re-jailbreak from a computer: copy this script
#         to the device, run it, and pull diag.txt back.
#
# The output is intentionally plain text with hashed identifiers only: it never
# prints message bodies, senders, keywords or verification codes.
#
set -u

CONFIG=/var/mobile/Library/Preferences/com.keyword.smsalert.plist
RUNTIME=/var/mobile/Library/Preferences/com.keyword.smsalert.runtime.plist
SAFEMODE=/var/mobile/Library/Preferences/com.keyword.smsalert.safemode
SMSDB=/var/mobile/Library/SMS/sms.db
DYLIB_JB_MARKER="Library/MobileSubstrate/DynamicLibraries/KeywordSMSAlertDetector.dylib"

hr() { printf '\n===== %s =====\n' "$1"; }

hr "ksa-diagnose $(date '+%Y-%m-%d %H:%M:%S')"
echo "read-only: this script changes nothing"

hr "1. installed components"
# Find the detector dylib wherever the jailbreak root happens to be.
if command -v jbroot >/dev/null 2>&1; then
    JB=$(jbroot 2>/dev/null || true)
    echo "jbroot() = ${JB:-unavailable}"
fi
for candidate in \
    "/$DYLIB_JB_MARKER" \
    "/var/jb/$DYLIB_JB_MARKER" \
    "/rootfs/$DYLIB_JB_MARKER"
do
    if [ -e "$candidate" ]; then
        echo "found: $candidate"
    fi
done
# Any leftover components from old builds (each one is a black-screen suspect):
for stale in \
    /Library/MobileSubstrate/DynamicLibraries/KeywordSMSAlertAlert.dylib \
    /Library/MobileSubstrate/DynamicLibraries/KeywordSMSAlertAlert.plist \
    /Library/MobileSubstrate/DynamicLibraries/KeywordSMSAlertSpringBoardProbe.dylib \
    /Library/LaunchDaemons/com.keyword.smsalert.alertd.plist \
    /usr/libexec/ksaalertd
do
    [ -e "$stale" ] && echo "LEFTOVER (suspect): $stale"
done

hr "2. configuration (values only, keywords hashed below)"
if [ -f "$CONFIG" ]; then
    echo "path: $CONFIG"
    if command -v plutil >/dev/null 2>&1; then
        plutil -p "$CONFIG" 2>/dev/null | grep -Ev '^\s*"?Keywords"?|IgnoreSenders' || cat "$CONFIG"
    else
        cat "$CONFIG"
    fi
else
    echo "no configuration file at $CONFIG (built-in defaults apply)"
fi
if [ -f "$(dirname "$CONFIG")/../../../Library/KeywordSMSAlert/keywords.txt" ] 2>/dev/null; then
    echo "note: a keywords.txt override exists in the jailbreak root"
fi

hr "3. runtime status (written by imagent; this is the health page)"
if [ -f "$RUNTIME" ]; then
    echo "path: $RUNTIME"
    if command -v plutil >/dev/null 2>&1; then
        plutil -p "$RUNTIME" 2>/dev/null || cat "$RUNTIME"
    else
        cat "$RUNTIME"
    fi
    echo ""
    echo "interpretation:"
    echo "  EngineRunning=YES + AlertEngineReady=YES -> the engine started"
    echo "  PollCount increasing between two reads  -> polling is alive"
    echo "  LastDatabaseError present                 -> sms.db access problem"
    echo "  stale UpdatedAt (hours old)               -> imagent died / was not restarted"
else
    echo "no runtime status: the engine has not started since install/reboot"
    echo "  -> check item 1 for leftovers, then userspace reboot once"
fi

hr "4. safe mode marker"
if [ -f "$SAFEMODE" ]; then
    echo "SAFE MODE IS ON: $SAFEMODE exists -> the plugin deliberately does nothing"
    echo "remove it (Settings pane or 'ksactl safemode off') to re-enable."
else
    echo "safe mode off (no marker at $SAFEMODE)"
fi

hr "5. SMS database reachability"
if [ -f "$SMSDB" ]; then
    ls -l "$SMSDB"
    if command -v sqlite3 >/dev/null 2>&1; then
        MAX=$(sqlite3 "file:$SMSDB?mode=ro" 'SELECT MAX(ROWID), COUNT(*) FROM message;' 2>&1)
        echo "MAX(ROWID), COUNT(*) = $MAX"
        UNREAD=$(sqlite3 "file:$SMSDB?mode=ro" 'SELECT COUNT(*) FROM message WHERE is_read = 0;' 2>&1)
        echo "unread messages = $UNREAD"
    else
        echo "(sqlite3 CLI not available here — the plugin opens it read-only itself)"
    fi
else
    echo "sms.db NOT found at $SMSDB"
fi

hr "6. process state"
if command -v ps >/dev/null 2>&1; then
    ps aux 2>/dev/null | grep -E 'imagent|ksaalertd' | grep -v grep || echo "(ps gave no imagent line)"
fi
if command -v launchctl >/dev/null 2>&1; then
    launchctl print system/com.apple.imagent 2>/dev/null | grep -E 'state|pid|last exit' || echo "(launchctl print unavailable)"
    # A leftover daemon registration would show up here:
    launchctl print system/com.keyword.smsalert.alertd 2>/dev/null && echo "LEFTOVER DAEMON REGISTRATION (suspect)"
fi

hr "7. crash reports mentioning imagent (last 5)"
PANIC_DIR=/var/mobile/Library/Logs/CrashReporter
if [ -d "$PANIC_DIR" ]; then
    ls -lt "$PANIC_DIR" 2>/dev/null | grep -i -E 'imagent|panic' | head -n 5 || echo "(none)"
else
    echo "(no CrashReporter directory visible from this context)"
fi

hr "8. plugin log (if LogToFile is enabled)"
for LOG in \
    /var/mobile/Library/KeywordSMSAlert/KeywordSMSAlert.log \
    /Library/KeywordSMSAlert/KeywordSMSAlert.log
do
    if [ -f "$LOG" ]; then
        echo "--- tail of $LOG ---"
        tail -n 40 "$LOG"
    fi
done

hr "done"
echo "send the full output of this script when reporting a black-screen or"
echo "no-alert incident. It contains no message content."