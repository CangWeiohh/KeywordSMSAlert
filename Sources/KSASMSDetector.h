//
//  KSASMSDetector.h
//  KeywordSMSAlert
//
//  Incoming SMS detection inside the daemon that actually owns SMS delivery:
//  imagent (bundle id com.apple.imagent).
//
//  Detection is hook free. The only live entry point is handlePlainText:, called by
//  KSASMSWatcher after it reads a new row out of sms.db. This class never touches the
//  Messages UI and never plays sound: a match is handed to KSAAlertManager, which
//  runs in this same process.
//

#ifndef KSA_SMS_DETECTOR_H
#define KSA_SMS_DETECTOR_H

#import <Foundation/Foundation.h>

@interface KSASMSDetector : NSObject

+ (instancetype)sharedInstance;

/// Called once from the tweak constructor inside imagent.
- (void)start;

/// Entry point for the hook free database watcher: already extracted plain values.
/// Returns YES only when this call is the one that handed a match to the alert
/// engine (i.e. the message matched, was not ignored and was not a duplicate). The
/// caller uses that to remember the ROWID whose read receipt should stop the alert.
- (BOOL)handlePlainText:(NSString *)text
                 sender:(NSString *)sender
               identity:(NSString *)identity
                service:(NSString *)service
                 source:(NSString *)source;

/// Human readable summary of what was detected so far.
- (NSString *)diagnostics;

@end

#endif /* KSA_SMS_DETECTOR_H */
