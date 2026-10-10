//
//  KSAAlertManager.h
//  KeywordSMSAlert
//
//  Alert state machine + alert engine (vibration / sound).
//
//      IDLE -> MATCHED -> ALERTING -> STOPPED -> IDLE
//
//  The engine only runs inside SpringBoard. The detector (imagent) never plays
//  sound or vibrates; it only posts a Darwin notification (KSATriggerPost()).
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

/// Description of one matching SMS. Only `source` is required outside the daemon.
@interface KSAMatchEvent : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSString *sender;
@property (nonatomic, copy) NSString *keyword;
/// Best available identity (message GUID when the daemon exposes one).
@property (nonatomic, copy) NSString *identity;
/// Free form origin tag used for logging ("sms-dict", "trigger", "test", ...).
@property (nonatomic, copy) NSString *source;

@end

/// Posted (in-process, on the main queue) whenever the alert state actually changes.
/// The SMS watcher uses it to run a fast read-receipt check only while an alert plays.
FOUNDATION_EXPORT NSString *const KSAAlertStateDidChangeNotification;

@interface KSAAlertManager : NSObject

+ (instancetype)sharedInstance;

/// Reads the configuration and starts observing cross process triggers.
/// Must be called from the SpringBoard process.
- (void)start;

/// Entry point used by the Darwin notification observer (any thread).
- (void)handleTriggerFromSource:(NSString *)source;

/// Entry point used when the alert process itself knows the message details.
- (void)handleMatchEvent:(KSAMatchEvent *)event;

/// Immediately stops a running alert (power button, configuration change, unload).
/// Safe to call from any thread, including while not alerting.
- (void)stopAlertWithReason:(NSString *)reason;

/// YES while an alert is audible/haptic.
- (BOOL)isAlerting;

- (KSAAlertState)state;

/// Wall-clock time the most recent alert started (0 when none has run yet). Used by
/// the display-state stop source to tell the SMS notification waking the lock screen
/// apart from a real power-button press.
@property (atomic, readonly) NSTimeInterval lastAlertStartedAt;

@end

#endif /* KSA_ALERT_MANAGER_H */
