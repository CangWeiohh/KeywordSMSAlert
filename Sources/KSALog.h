//
//  KSALog.h
//  KeywordSMSAlert
//
//  Controlled logging.
//
//  Policy (see project requirements):
//    * by default only event level lines are emitted, and they never contain raw
//      message bodies - only hashes / lengths / matched keyword hashes;
//    * full details (message text, sender) are only emitted when DebugEnabled = 1;
//    * logging must never block a message-receiving thread: everything is
//      formatted on the caller's thread but file writing is asynchronous.
//

#ifndef KSA_LOG_H
#define KSA_LOG_H

#import <Foundation/Foundation.h>

FOUNDATION_EXPORT void KSALogConfigure(BOOL debugEnabled, BOOL fileLoggingEnabled);

/// YES when DebugEnabled is set in the configuration file.
FOUNDATION_EXPORT BOOL KSALogDebugEnabled(void);

/// Always emitted (unless logging is fully disabled). Format: "[KeywordSMSAlert] ..."
FOUNDATION_EXPORT void KSAInfo(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/// Only emitted while DebugEnabled = 1.
FOUNDATION_EXPORT void KSADebug(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/// Debug-gated, and additionally omitted when the string is nil.
FOUNDATION_EXPORT void KSADebugSensitive(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/// Best effort log file location (nil when file logging is unavailable).
FOUNDATION_EXPORT NSString *KSALogFilePath(void);

#endif /* KSA_LOG_H */
