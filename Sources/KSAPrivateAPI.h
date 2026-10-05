//
//  KSAPrivateAPI.h
//  KeywordSMSAlert
//
//  Compile time declarations of the private iOS classes/methods this project hooks.
//
//  These are *declarations only*: the real implementations are provided by iOS.
//  Nothing here is instantiated or linked against, which is why the project needs
//  no private framework headers and no entitlement.
//
//  Evidence for every entry (iOS 15.4.1 target):
//
//    IMDService / -loadServiceBundle
//        IMFoundation's service loader; hooked so that the lazily loaded SMS
//        service bundle gives us a signal to install the SMSServiceSession hooks.
//        Method shape (void, no arguments) confirmed by a device trace in
//        imagent: "IMDService loadServiceBundle".
//
//    SMSServiceSession
//        The class inside imagent (com.apple.imagent) that turns a received SMS
//        into a dictionary. Device trace of an incoming SMS shows, in order:
//            -[SMSServiceSession smsMessageReceived:msgID:]
//            -[SMSServiceSession _processSMSorMMSMessageReceivedWithContext:messageID:]
//            -[SMSServiceSession _convertCTMessageToDictionary:requiresUpload:]
//            -[SMSServiceSession _receivedSMSDictionary:requiresUpload:isBeingReplayed:]
//            -[SMSServiceSession _processReceivedDictionary:storageContext:]
//        This project hooks only the two entry points that receive the CTMessage,
//        because the CTMessage is what distinguishes an incoming SMS from an
//        outgoing one (-[CTMessage type] == 1 for incoming).
//
//    SBLockScreenManager / -lockUIFromSource:withOptions:
//        SpringBoard's lock screen manager. The selector is present in the public
//        SpringBoard header dumps shipped with Theos (vendor/include/SpringBoard/
//        SBLockScreenManager.h) and is the classic entry point used by jailbreak
//        tweaks for "screen was locked" events.
//
//  Every hook in KeywordSMSAlert.xm verifies at runtime that the class *and* the
//  selector exist before installing, and logs what it found (see
//  KSALogSMSServiceSessionDiagnostics, KSAPowerButton -logDiagnostics).
//

#ifndef KSA_PRIVATE_API_H
#define KSA_PRIVATE_API_H

#import <Foundation/Foundation.h>

#pragma mark - IMFoundation / IMDaemonCore (imagent)

@interface IMDService : NSObject
- (void)loadServiceBundle;
@end

@interface SMSServiceSession : NSObject
- (id)_convertCTMessageToDictionary:(id)message requiresUpload:(BOOL)requiresUpload;
- (id)_receivedSMSDictionary:(id)message requiresUpload:(BOOL)requiresUpload isBeingReplayed:(BOOL)isBeingReplayed;
@end

//  IMDMessageStore / IMDServiceSession
//      Header verified against the iOS 15.6 runtime header dump
//      (donato-fiore/iOS-Runtime-Headers, 15.6/PrivateFrameworks/IMDaemonCore).
//      -[IMDMessageStore storeItem:forceReplace:] and the three
//      -storeMessage:forceReplace:modifyError:modifyFlags:flagMask:... overloads
//      receive an IMMessageItem carrying body/plainBody (text) and guid (dedup id),
//      and they run for every stored message regardless of notification, DND or UI
//      state. They are used here as a backstop for the SMSServiceSession hooks.
@interface IMDMessageStore : NSObject
- (id)storeItem:(id)item forceReplace:(BOOL)forceReplace;
- (id)storeMessage:(id)message forceReplace:(BOOL)forceReplace modifyError:(BOOL)modifyError modifyFlags:(BOOL)modifyFlags flagMask:(NSUInteger)flagMask;
- (id)storeMessage:(id)message forceReplace:(BOOL)forceReplace modifyError:(BOOL)modifyError modifyFlags:(BOOL)modifyFlags flagMask:(NSUInteger)flagMask updateMessageCache:(BOOL)updateMessageCache calculateUnreadCount:(BOOL)calculateUnreadCount;
- (id)storeMessage:(id)message forceReplace:(BOOL)forceReplace modifyError:(BOOL)modifyError modifyFlags:(BOOL)modifyFlags flagMask:(NSUInteger)flagMask updateMessageCache:(BOOL)updateMessageCache calculateUnreadCount:(BOOL)calculateUnreadCount reindexMessage:(BOOL)reindexMessage;
@end

@interface IMDServiceSession : NSObject
- (void)didReceiveMessage:(id)message forChat:(id)chat style:(unsigned char)style account:(id)account fromIDSID:(id)fromIDSID;
- (void)didReceiveMessage:(id)message forChat:(id)chat style:(unsigned char)style fromIDSID:(id)fromIDSID;
@end

#pragma mark - SpringBoard: physical side / power button chain

//  Class and ivar layout verified in the iPhoneOS 15.2 / 15.6 SpringBoard symbol
//  tables; method names verified against iOS 13.6 / 14.0 runtime headers and against
//  shipping tweaks that run on iOS 14-16 (see docs/power-button-hook-research.md):
//
//    UIPress(Lock) -> SBPressGestureRecognizer -> SBLockHardwareButton -buttonDown:
//                  -> SBLockHardwareButtonActions -performInitialButtonDownActions
//                  -> SBSleepWakeHardwareButtonInteraction -consumeInitialPressDown
//                  -> _performSleep / _performWake
//
//  Every hook below is installed only when the class AND the selector exist at
//  runtime; -consumeInitialPressDown always returns the original value so the
//  "consume this press" decision of iOS itself is never altered.
@interface SBSleepWakeHardwareButtonInteraction : NSObject
- (BOOL)consumeInitialPressDown;
@end

@interface SBLockHardwareButtonActions : NSObject
- (void)performInitialButtonDownActions;
@end

@interface SBLockHardwareButton : NSObject
- (void)buttonDown:(id)press;
@end

#pragma mark - SpringBoard

@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstance;
- (void)lockUIFromSource:(NSUInteger)source withOptions:(NSDictionary *)options;
- (void)lockUIFromSource:(NSUInteger)source;
@end

#endif /* KSA_PRIVATE_API_H */
