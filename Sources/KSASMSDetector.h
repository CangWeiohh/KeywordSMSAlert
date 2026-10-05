//
//  KSASMSDetector.h
//  KeywordSMSAlert
//
//  Incoming SMS detection inside the daemon that actually owns SMS delivery:
//  imagent (bundle id com.apple.imagent).
//
//  The daemon side never plays sound, never vibrates and never touches the
//  Messages UI: it only extracts sender/text, matches the configured keywords and
//  posts a Darwin notification to SpringBoard (see KSATrigger).
//
//  Hooked methods live in KeywordSMSAlert.xm; this class holds the logic.
//

#ifndef KSA_SMS_DETECTOR_H
#define KSA_SMS_DETECTOR_H

#import <Foundation/Foundation.h>

@interface KSASMSDetector : NSObject

+ (instancetype)sharedInstance;

/// Called once from the tweak constructor inside imagent.
- (void)start;

/// Hook entry point for the SMSServiceSession dictionary path. `message` is the
/// CTMessage (may be nil). Must be fast and must never throw.
- (void)handleCTMessage:(id)message
             dictionary:(NSDictionary *)dictionary
                 source:(NSString *)source;

/// Hook entry point for the IMDMessageStore / IMDServiceSession path: `item` is an
/// IMMessageItem (iOS 15.x verified), from which body/plainBody/sender/guid/service
/// /isFromMe are read. Must be fast and must never throw.
- (void)handleMessageItem:(id)item source:(NSString *)source;

/// Human readable summary of what was detected / hooked so far.
- (NSString *)diagnostics;

@end

/// On-device diagnostics: logs the SMSServiceSession selectors that actually exist
/// in this process (and, in debug mode, every runtime class whose name contains
/// "SMS"). Used to verify the hook targets on a specific iOS build without a
/// debugger: if a selector ever changes on a future iOS version, this log says so
/// instead of silently doing nothing.
FOUNDATION_EXPORT void KSALogSMSServiceSessionDiagnostics(void);

#endif /* KSA_SMS_DETECTOR_H */
