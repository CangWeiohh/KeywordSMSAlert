//
//  KSAAlertManager.h
//  KeywordSMSAlert
//
//  Alert state machine + alert engine (vibration / sound).
//
//      IDLE -> MATCHED -> ALERTING -> STOPPED -> IDLE
//
//  In the shipped build the whole engine runs inside imagent, in the same process as
//  the SMS detector, so a match never crosses a process boundary. The class is kept
//  process agnostic and uses no SpringBoard API.
//

#ifndef KSA_ALERT_MANAGER_H
#define KSA_ALERT_MANAGER_H

#import <Foundation/Foundation.h>
#import "KSAConfig.h"

typedef NS_ENUM(NSInteger, KSAAlertState) {
    KSAAlertStateIdle     = 0,
    KSAAlertStateMatched  = 1,
    KSAAlertStateAlerting = 2,
    KSAAlertStateStopping = 3,
};

/// Description of one matching SMS.
@interface KSAMatchEvent : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSString *sender;
@property (nonatomic, copy) NSString *keyword;
/// Best available identity. The database watcher passes "db-rowid-<n>", which is what
/// makes the duplicate suppression and the read-receipt stop source work.
@property (nonatomic, copy) NSString *identity;
/// Free form origin tag used for logging ("smsdb", "imagent self test", ...).
@property (nonatomic, copy) NSString *source;

@end

/// Posted (in-process, on the main queue) whenever the alert state actually changes.
/// The SMS watcher uses it to run a fast read-receipt check only while an alert plays.
FOUNDATION_EXPORT NSString *const KSAAlertStateDidChangeNotification;

@interface KSAAlertManager : NSObject

+ (instancetype)sharedInstance;

/// Reads the configuration and starts the alert engine. Safe to call from any
/// process; the shipped build calls it from imagent.
- (void)start;

/// Entry point used by the Darwin notification observer (any thread).
- (void)handleTriggerFromSource:(NSString *)source;

/// Entry point used when the alert process itself knows the message details.
- (void)handleMatchEvent:(KSAMatchEvent *)event;

/// Immediately stops a running alert (message marked as read, configuration change,
/// unload). Safe to call from any thread, including while not alerting.
- (void)stopAlertWithReason:(NSString *)reason;

/// YES while an alert is audible/haptic.
- (BOOL)isAlerting;

- (KSAAlertState)state;

/// Wall-clock time the most recent alert started (0 when none has run yet).
/// Diagnostic only: it is published to the runtime status file.
@property (atomic, readonly) NSTimeInterval lastAlertStartedAt;

@end

#endif /* KSA_ALERT_MANAGER_H */
