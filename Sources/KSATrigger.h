//
//  KSATrigger.h
//  KeywordSMSAlert
//
//  Darwin notification helpers.
//
//  In the shipped build the SMS detector and the alert engine live in the same
//  process (imagent), so a match is handed over in-process and nothing here is on the
//  alert path. Two things still use this module:
//    * KSAReloadObserve - the Settings pane posts KSAReloadNotificationName after a
//      change so the running engine picks the new values up immediately;
//    * KSATriggerObserve - `ksactl test` posts KSATriggerNotificationName to ask for
//      a test alert without sending an SMS.
//
//  Design notes (iOS 15.4.1 / roothide):
//    * Darwin notifications carry no payload - CFNotificationCenterPostNotification
//      on the Darwin notify center is used with a nil object, which is the most
//      robust channel available to a sandboxed daemon;
//    * posting is non blocking and returns immediately, so the SMS receiving thread
//      is never delayed.
//

#ifndef KSA_TRIGGER_H
#define KSA_TRIGGER_H

#import <Foundation/Foundation.h>

/// Posted to ask for an alert right now (used by `ksactl test`).
FOUNDATION_EXPORT NSString *const KSATriggerNotificationName;

/// Posted to ask every process to re-read the configuration file.
FOUNDATION_EXPORT NSString *const KSAReloadNotificationName;

/// Post the "start alert" notification (safe to call from any thread).
FOUNDATION_EXPORT void KSATriggerPost(void);

/// Post the "reload configuration" notification.
FOUNDATION_EXPORT void KSAReloadPost(void);

typedef void (^KSANotificationHandler)(void);

/// Observe KSATriggerNotificationName. The handler runs on `queue`
/// (main queue when queue is NULL).
FOUNDATION_EXPORT void KSATriggerObserve(dispatch_queue_t queue, KSANotificationHandler handler);

/// Observe KSAReloadNotificationName.
FOUNDATION_EXPORT void KSAReloadObserve(dispatch_queue_t queue, KSANotificationHandler handler);

#endif /* KSA_TRIGGER_H */
