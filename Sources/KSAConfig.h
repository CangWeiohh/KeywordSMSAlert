//
//  KSAConfig.h
//  KeywordSMSAlert
//
//  Configuration file (stage 1: a plain plist, no PreferenceBundle required).
//
//  Default location (jbroot based, i.e. "@" = jailbreak root):
//      /var/mobile/Library/Preferences/com.keyword.smsalert.plist
//
//  Additional locations are also accepted so the file stays reachable on every
//  roothide/rootless layout; see KSAConfigCandidatePaths().
//

#ifndef KSA_CONFIG_H
#define KSA_CONFIG_H

#import <Foundation/Foundation.h>

/// 0 = off, 1 = vibrate, 2 = sound, 3 = vibrate + sound
typedef NS_ENUM(NSInteger, KSAAlertMode) {
    KSAAlertModeOff     = 0,
    KSAAlertModeVibrate = 1,
    KSAAlertModeSound   = 2,
    KSAAlertModeBoth    = 3,
};

typedef NS_ENUM(NSInteger, KSAMatchMode) {
    KSAMatchModeContains = 0,   // message contains the keyword (default)
    KSAMatchModeExact    = 1,   // message equals the keyword
    KSAMatchModePrefix   = 2,   // message starts with the keyword
};

/// Behaviour when a new matching SMS arrives while an alert is already running.
typedef NS_ENUM(NSInteger, KSAOnNewMatchedSMS) {
    KSAOnNewMatchedSMSRestart = 0,  // default: restart / refresh the running alert
    KSAOnNewMatchedSMSIgnore  = 1,  // keep the running alert untouched
    KSAOnNewMatchedSMSQueue   = 2,  // remember it and start right after the current one
};

@interface KSAConfig : NSObject

+ (instancetype)sharedInstance;

/// Re-reads the configuration file, but at most once every 2 seconds.
/// Safe to call from any thread, from any process. Never blocks for long.
- (void)reloadIfNeeded;

/// Re-reads the configuration file unconditionally.
- (void)forceReload;

/// Loads configuration from an explicit path instead of the candidate list.
/// Pass nil to go back to automatic discovery.
- (void)forceReloadFromPath:(NSString *)path;

// --- Configuration values (always non-nil / safe defaults) ------------------
@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly, copy) NSArray<NSString *> *keywords;
@property (nonatomic, readonly) KSAMatchMode matchMode;
@property (nonatomic, readonly) BOOL caseInsensitive;
@property (nonatomic, readonly) NSUInteger minMessageLength;
@property (nonatomic, readonly, copy) NSArray<NSString *> *ignoreSenders;

/// NO (default): only SMS is evaluated. YES: iMessage service messages are also
/// evaluated by the same keyword rules (the detector ignores outgoing messages
/// either way).
@property (nonatomic, readonly) BOOL includeIMessage;

@property (nonatomic, readonly) KSAAlertMode alertMode;
@property (nonatomic, readonly) BOOL vibrationEnabled;
@property (nonatomic, readonly) NSTimeInterval vibrationDuration;
@property (nonatomic, readonly) NSTimeInterval vibrationInterval;

@property (nonatomic, readonly) BOOL soundEnabled;
@property (nonatomic, readonly) NSTimeInterval soundDuration;
@property (nonatomic, readonly) float soundVolume;
@property (nonatomic, readonly) BOOL soundLoop;
@property (nonatomic, readonly, copy) NSString *soundFileConfigurationValue;

/// Which iOS volume channel the alert uses:
///   "alert" (default) -> system sound path, heard at the RINGER/alert volume and
///                        silenced by the ring/silent switch;
///   "media"           -> AVAudioPlayer, heard at the MEDIA volume and audible even
///                        when the ring/silent switch is muted.
@property (nonatomic, readonly, copy) NSString *soundChannel;

/// Repeat interval used by the alert (ringer) channel while SoundLoop = YES.
/// 0 = derive it from the sound file length.
@property (nonatomic, readonly) NSTimeInterval soundRepeatInterval;

@property (nonatomic, readonly) NSTimeInterval duplicateInterval;
@property (nonatomic, readonly) KSAOnNewMatchedSMS onNewMatchedSMS;

@property (nonatomic, readonly) BOOL debugEnabled;
@property (nonatomic, readonly) BOOL logToFile;

/// Test aid: when YES, SpringBoard fires one alert ~3 seconds after it loads with
/// this tweak. Lets the alert engine and the power button stop be verified without
/// sending a real SMS. Off by default.
@property (nonatomic, readonly) BOOL testAlertOnLoad;

/// Safety switches for the two "backstop" hook families in imagent. Both default to
/// YES. Setting one to NO and restarting imagent leaves only the (SMS specific)
/// SMSServiceSession hooks active - useful to isolate behaviour if a message ever
/// seemed to be missing.
/// "db"   (default) - passive, hook free: poll sms.db read only (latency = PollInterval)
/// "hooks"          - hook the imagent message pipeline (instant, but touches the
///                    daemon's own code path; only enable if you accept that risk)
@property (nonatomic, readonly, copy) NSString *detectionMode;
@property (nonatomic, readonly) NSTimeInterval pollInterval;

@property (nonatomic, readonly) BOOL messageStoreBackstop;
@property (nonatomic, readonly) BOOL serviceSessionBackstop;

/// Path of the configuration file that is currently in use (may be nil).
@property (nonatomic, readonly, copy) NSString *activeConfigPath;

/// Returns the configured keyword that matches `text`, or nil when none matches.
/// This is a fast in-memory scan; it is intentionally synchronous and cheap.
- (NSString *)matchedKeywordInText:(NSString *)text;

/// Returns YES when the sender must be ignored (ignore list substring match).
- (BOOL)shouldIgnoreSender:(NSString *)sender;

/// Resolved absolute path of the alert sound file, or nil when none was found.
- (NSString *)resolvedSoundPath;

/// Hash-only description used for logging (never exposes raw keywords).
- (NSString *)debugDescription;

@end

#endif /* KSA_CONFIG_H */
