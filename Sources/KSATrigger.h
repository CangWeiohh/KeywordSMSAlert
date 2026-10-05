//
//  KSATrigger.h
//  KeywordSMSAlert
//
//  Cross process signalling between the SMS detecting process (imagent) and the
//  alerting process (SpringBoard).
//
//  Design notes (iOS 15.4.1 / roothide):
//    * Darwin notifications carry no payload - CFNotificationCenterPostNotification
//      on the Darwin notify center is used with a nil object, which is the most
//      robust cross process channel available to both sandboxed daemons and
//      SpringBoard;
//    * the daemon therefore only has to say "a matching SMS arrived", and the
//      SpringBoard side runs the alert engine. No shared file, no XPC service and
//      no entitlement is required;
//    * posting is non blocking and returns immediately, so the SMS receiving
//      thread is never delayed.
//

#ifndef KSA_TRIGGER_H
#define KSA_TRIGGER_H

#import <Foundation/Foundation.h>

/// Posted by the detector when a matching SMS arrives.
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
