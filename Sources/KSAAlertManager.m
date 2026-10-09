//
//  KSAAlertManager.m
//  KeywordSMSAlert
//

#import "KSAAlertManager.h"
#import "KSACommon.h"
#import "KSADedupCache.h"
#import "KSAHookInstaller.h"
#import "KSALog.h"
#import "KSASoundConverter.h"
#import "KSATrigger.h"

#ifdef KSA_STANDALONE_ALERTD
#import "Daemon/KSARuntimeStatus.h"
#endif

#import <AudioToolbox/AudioToolbox.h>
#ifndef KSA_NO_MEDIA_CHANNEL
#import <AVFoundation/AVFoundation.h>
#endif

/// Hard safety cap: an alert can never stay alive longer than this, whatever the
/// configuration file says. Prevents a stuck timer from keeping the device awake.
static const NSTimeInterval kKSAMaxAlertLifetime = 180.0;

/// Interval used when only the built-in system sound id is available.
static const NSTimeInterval kKSASystemSoundRepeatInterval = 2.0;

#pragma mark - KSAMatchEvent

@implementation KSAMatchEvent

- (NSString *)description
{
    return [NSString stringWithFormat:@"<KSAMatchEvent source=%@ textHash=%@ senderHash=%@ keywordHash=%@>",
            self.source ?: @"?",
            KSAHashString(self.text) ?: @"-",
            KSAHashString(self.sender) ?: @"-",
            KSAHashString(self.keyword) ?: @"-"];
}

@end

#pragma mark - KSAAlertManager

#ifdef KSA_NO_MEDIA_CHANNEL
@interface KSAAlertManager ()
#else
@interface KSAAlertManager () <AVAudioPlayerDelegate>
#endif
@property (atomic, assign) KSAAlertState state;
@property (atomic, assign) NSTimeInterval lastAlertStartedAt;
@end

@implementation KSAAlertManager
{
    dispatch_queue_t _queue;

    KSADedupCache *_dedup;
    KSAMatchEvent *_pendingEvent;          // used by KSAOnNewMatchedSMSQueue
    BOOL _started;
    BOOL _vibrationRunning;

    dispatch_source_t _vibrationTimer;      // repeating vibration
    dispatch_source_t _vibrationStopTimer;  // ends the vibration phase
    dispatch_source_t _soundStopTimer;      // ends the sound phase
    dispatch_source_t _systemSoundTimer;    // fallback: repeating system sound
    dispatch_source_t _alertSoundTimer;     // alert (ringer) channel: repeating system sound id
    SystemSoundID _alertSoundID;            // > 0 while the alert channel is playing
    dispatch_source_t _endTimer;            // overall safety/lifetime timer

#ifdef KSA_NO_MEDIA_CHANNEL
    id _player;                        // always nil: media channel not compiled in
#else
    AVAudioPlayer *_player;
    NSString *_previousAudioCategory;
    NSString *_previousAudioMode;
    BOOL _audioSessionActivatedByUs;
#endif
}

+ (instancetype)sharedInstance
{
    static KSAAlertManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[KSAAlertManager alloc] init];
    });
    return instance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.keyword.smsalert.alert", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_queue, (__bridge const void *)self, (void *)1, NULL);
        _dedup = [[KSADedupCache alloc] init];
        _state = KSAAlertStateIdle;
    }
    return self;
}

- (BOOL)_isOnQueue
{
    return dispatch_get_specific((__bridge const void *)self) != NULL;
}

#pragma mark - Lifecycle

- (void)start
{
    if ([self _isOnQueue]) {
        [self _startOnQueue];
        return;
    }
    dispatch_async(_queue, ^{
        [self _startOnQueue];
    });
}

- (void)_startOnQueue
{
    if (_started) {
        return;
    }
    _started = YES;

    [[KSAConfig sharedInstance] forceReload];
    KSALogConfigure([KSAConfig sharedInstance].debugEnabled, [KSAConfig sharedInstance].logToFile);

    __weak typeof(self) weakSelf = self;
    KSATriggerObserve(_queue, ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self _handleTriggerOnQueueWithSource:@"imagent"];
    });

    KSAReloadObserve(_queue, ^{
        __strong typeof(weakSelf) self = weakSelf;
        [[KSAConfig sharedInstance] forceReload];
        KSALogConfigure([KSAConfig sharedInstance].debugEnabled, [KSAConfig sharedInstance].logToFile);
        KSAInfo(@"configuration reloaded on request");
        if (![KSAConfig sharedInstance].enabled) {
            [self _stopOnQueueWithReason:@"plugin disabled"];
        }
    });

#ifndef KSA_NO_MEDIA_CHANNEL
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_audioSessionInterruption:)
                                                 name:AVAudioSessionInterruptionNotification
                                               object:nil];
#endif

    KSAConfig *config = [KSAConfig sharedInstance];
    KSAInfo(@"alert engine ready (process %@, sound channel %@, sound file %@)",
            KSAProcessName(), config.soundChannel,
            [config resolvedSoundPath] ?: @"(system default sound id)");
#ifdef KSA_STANDALONE_ALERTD
    KSARuntimeStatusUpdate(@{ @"AlertEngineReady": @YES });
#endif
}

#ifndef KSA_NO_MEDIA_CHANNEL
- (void)_audioSessionInterruption:(NSNotification *)notification
{
    NSNumber *type = notification.userInfo[AVAudioSessionInterruptionTypeKey];
    if (type.unsignedIntegerValue != AVAudioSessionInterruptionTypeBegan) {
        return;
    }
    [self stopAlertWithReason:@"audio interruption"];
}
#endif

#pragma mark - Public entry points (thread safe)

- (void)handleTriggerFromSource:(NSString *)source
{
    dispatch_async(_queue, ^{
        [self _handleTriggerOnQueueWithSource:source];
    });
}

- (void)handleMatchEvent:(KSAMatchEvent *)event
{
    if (event == nil) {
        return;
    }
    dispatch_async(_queue, ^{
        [self _handleMatchEventOnQueue:event];
    });
}

- (void)stopAlertWithReason:(NSString *)reason
{
    dispatch_async(_queue, ^{
        [self _stopOnQueueWithReason:reason];
    });
}

- (BOOL)isAlerting
{
    return self.state == KSAAlertStateAlerting;
}

#pragma mark - State machine

- (void)_setStateOnQueue:(KSAAlertState)state
{
    KSAAlertState previous = self.state;
    self.state = state;
    if (previous != state) {
        KSADebug(@"state %ld -> %ld", (long)previous, (long)state);
    }
}

- (void)_handleTriggerOnQueueWithSource:(NSString *)source
{
    KSAInfo(@"trigger received (source: %@)", source ?: @"?");
#ifdef KSA_STANDALONE_ALERTD
    KSARuntimeStatusUpdate(@{
        @"LastTriggerAt": @([[NSDate date] timeIntervalSince1970]),
        @"LastTriggerSource": source ?: @"?"
    });
#endif

    KSAConfig *config = [KSAConfig sharedInstance];
    [config reloadIfNeeded];

    if (!config.enabled) {
        KSAInfo(@"trigger ignored: plugin is disabled in the configuration file");
        return;
    }

    [self _acceptNewEventOnQueue:nil];
}

- (void)_handleMatchEventOnQueue:(KSAMatchEvent *)event
{
    KSAConfig *config = [KSAConfig sharedInstance];
    [config reloadIfNeeded];

    if (!config.enabled) {
        KSAInfo(@"event ignored: plugin is disabled in the configuration file");
        return;
    }

    NSString *identity = event.identity;
    if (identity.length == 0) {
        identity = [NSString stringWithFormat:@"%@|%@",
                    KSAHashString(event.sender) ?: @"-",
                    KSAHashString(event.text) ?: @"-"];
    }

    if ([_dedup isDuplicateKey:identity window:config.duplicateInterval]) {
        KSAInfo(@"duplicate event suppressed (identity hash %@)", KSAHashString(identity));
        return;
    }

    [self _acceptNewEventOnQueue:event];
}

- (void)_acceptNewEventOnQueue:(KSAMatchEvent *)event
{
    KSAConfig *config = [KSAConfig sharedInstance];

    if (self.state == KSAAlertStateAlerting) {
        switch (config.onNewMatchedSMS) {
            case KSAOnNewMatchedSMSIgnore:
                KSAInfo(@"new match while alerting: policy=ignore, keeping current alert");
                return;

            case KSAOnNewMatchedSMSQueue:
                KSAInfo(@"new match while alerting: policy=queue, starting after the current alert");
                _pendingEvent = event ?: [[KSAMatchEvent alloc] init];
                return;

            case KSAOnNewMatchedSMSRestart:
            default:
                KSAInfo(@"new match while alerting: policy=restart, restarting alert");
                [self _cancelTimersOnQueue];
                [self _teardownChannelsOnQueue];
                [self _setStateOnQueue:KSAAlertStateIdle];
                break;
        }
    }

    [self _startAlertOnQueue:event];
}

- (void)_startAlertOnQueue:(KSAMatchEvent *)event
{
    KSAConfig *config = [KSAConfig sharedInstance];

    if (!config.enabled) {
        return;
    }

    // The shared manager supports both the legacy SpringBoard diagnostic target and
    // the production standalone daemon. In production the linked daemon stub reports
    // the stop-event source ready, so this branch never installs a process hook.
    if (!KSAPowerButtonHooksInstalled()) {
        KSAInfo(@"installing power button hooks now (legacy/diagnostic target)");
        KSAInstallPowerButtonHooksIfNeeded();
    }

    BOOL useVibration = config.vibrationEnabled;
    BOOL useSound = config.soundEnabled;

    if (!useVibration && !useSound) {
        KSAInfo(@"match accepted but AlertMode is 0 (off): nothing to do");
        [self _setStateOnQueue:KSAAlertStateIdle];
        return;
    }

    [self _setStateOnQueue:KSAAlertStateMatched];
    KSAInfo(@"keyword matched, starting alert (mode=%ld vibration=%d sound=%d)",
            (long)config.alertMode, useVibration, useSound);

    if (event != nil) {
        KSADebug(@"event details: %@ text=%@ sender=%@ keyword=%@",
                 event, event.text ?: @"-", event.sender ?: @"-", event.keyword ?: @"-");
    }

    if (useVibration) {
        [self _startVibrationOnQueue:config];
    }
    if (useSound) {
        [self _startSoundOnQueue:config];
    }

    NSTimeInterval lifetime = 0;
    if (useVibration) {
        lifetime = MAX(lifetime, config.vibrationDuration);
    }
    if (useSound) {
        lifetime = MAX(lifetime, config.soundDuration);
    }
    lifetime = MIN(MAX(lifetime, 0.1), kKSAMaxAlertLifetime);

    __weak typeof(self) weakSelf = self;
    _endTimer = [self _scheduleTimerWithDelay:lifetime
                                     interval:0
                                      handler:^{
        __strong typeof(weakSelf) self = weakSelf;
        [self _stopOnQueueWithReason:@"duration elapsed"];
    }];

    [self _setStateOnQueue:KSAAlertStateAlerting];
    self.lastAlertStartedAt = [[NSDate date] timeIntervalSince1970];
    KSAInfo(@"alert started (lifetime %.1fs)", lifetime);
#ifdef KSA_STANDALONE_ALERTD
    KSARuntimeStatusUpdate(@{
        @"Alerting": @YES,
        @"LastAlertStartedAt": @([[NSDate date] timeIntervalSince1970])
    });
#endif
}

- (void)_stopOnQueueWithReason:(NSString *)reason
{
    KSAAlertState state = self.state;
    if (state == KSAAlertStateIdle) {
        KSADebug(@"stop requested without an active alert (%@)", reason);
        return;
    }

    [self _setStateOnQueue:KSAAlertStateStopping];
    [self _cancelTimersOnQueue];
    [self _teardownChannelsOnQueue];
    [self _setStateOnQueue:KSAAlertStateIdle];
    KSAInfo(@"alert stopped (%@)", reason ?: @"?");
#ifdef KSA_STANDALONE_ALERTD
    KSARuntimeStatusUpdate(@{
        @"Alerting": @NO,
        @"LastAlertStoppedAt": @([[NSDate date] timeIntervalSince1970]),
        @"LastStopReason": reason ?: @"?"
    });
#endif

    if (_pendingEvent != nil) {
        KSAMatchEvent *pending = _pendingEvent;
        _pendingEvent = nil;
        KSAInfo(@"starting queued match");
        [self _startAlertOnQueue:pending];
    }
}

#pragma mark - Alert (ringer) channel helpers

/// Length of the sound file, used to repeat it seamlessly on the alert channel.
- (NSTimeInterval)_durationOfSoundFileAtPath:(NSString *)path
{
#ifdef KSA_NO_MEDIA_CHANNEL
    // The alert channel repeats on a fixed interval in this build; no probe needed.
    (void)path;
    return 0.0;
#else
    NSError *error = nil;
    AVAudioPlayer *probe = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path]
                                                                  error:&error];
    NSTimeInterval duration = probe.duration;
    if (duration <= 0.05) {
        return 0.0;
    }
    return duration + 0.25;
#endif
}

- (BOOL)_startAlertChannelSoundOnQueue:(KSAConfig *)config path:(NSString *)path
{
    // No AVAudioSession is touched here: AudioServices plays through the system
    // alert (ringer) volume, which is the channel the user actually hears when the
    // media volume is low, and it never modifies the user's volume settings.
    SystemSoundID soundID = 0;
    OSStatus status = AudioServicesCreateSystemSoundID((__bridge CFURLRef)[NSURL fileURLWithPath:path],
                                                       &soundID);
    if (status != kAudioServicesNoError || soundID == 0) {
        KSAInfo(@"alert channel rejected %@ (OSStatus %d); falling back to the media channel",
                path.lastPathComponent, (int)status);
        return NO;
    }

    _alertSoundID = soundID;
    AudioServicesPlaySystemSound(_alertSoundID);

    NSTimeInterval repeatInterval = config.soundRepeatInterval;
    if (repeatInterval <= 0.0) {
        repeatInterval = [self _durationOfSoundFileAtPath:path];
    }
    if (repeatInterval <= 0.0) {
        repeatInterval = 1.6;
    }
    repeatInterval = MIN(MAX(repeatInterval, 0.3), 10.0);

    NSTimeInterval duration = MAX(config.soundDuration, 0.1);
    __weak typeof(self) weakSelf = self;

    if (config.soundLoop) {
        _alertSoundTimer = [self _scheduleTimerWithDelay:repeatInterval
                                                interval:repeatInterval
                                                 handler:^{
            __strong typeof(weakSelf) self = weakSelf;
            if (self->_alertSoundID != 0) {
                AudioServicesPlaySystemSound(self->_alertSoundID);
            }
        }];
    }

    _soundStopTimer = [self _scheduleTimerWithDelay:duration
                                           interval:0
                                            handler:^{
        __strong typeof(weakSelf) self = weakSelf;
        [self _stopAlertChannelSoundOnQueue];
        KSADebug(@"alert channel sound phase finished");
    }];

    KSADebug(@"alert channel sound started (%@, %.1fs, repeat %.2fs, loop=%d)",
             path.lastPathComponent, duration, repeatInterval, config.soundLoop);
    return YES;
}

- (void)_stopAlertChannelSoundOnQueue
{
    if (_alertSoundTimer != NULL) {
        dispatch_source_cancel(_alertSoundTimer);
        _alertSoundTimer = NULL;
    }
    if (_alertSoundID != 0) {
        AudioServicesDisposeSystemSoundID(_alertSoundID);
        _alertSoundID = 0;
    }
}

#pragma mark - Timers

- (dispatch_source_t)_scheduleTimerWithDelay:(NSTimeInterval)delay
                                    interval:(NSTimeInterval)interval
                                     handler:(dispatch_block_t)handler
{
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    if (timer == NULL) {
        return NULL;
    }

    uint64_t delayNanoseconds = (uint64_t)(MAX(delay, 0.0) * NSEC_PER_SEC);
    // A repeat interval of 0 is avoided on purpose: use DISPATCH_TIME_FOREVER for
    // one-shot timers, which is the documented "fire once" value.
    uint64_t intervalNanoseconds = (interval > 0.0)
        ? (uint64_t)(interval * NSEC_PER_SEC)
        : DISPATCH_TIME_FOREVER;
    uint64_t leewayNanoseconds = (uint64_t)(50 * NSEC_PER_MSEC);
    if (intervalNanoseconds != DISPATCH_TIME_FOREVER &&
        leewayNanoseconds > intervalNanoseconds) {
        leewayNanoseconds = intervalNanoseconds / 4;
    }

    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)delayNanoseconds),
                              intervalNanoseconds,
                              leewayNanoseconds);
    dispatch_source_set_event_handler(timer, handler);
    dispatch_resume(timer);
    return timer;
}

- (void)_cancelTimersOnQueue
{
    if (_vibrationTimer != NULL) {
        dispatch_source_cancel(_vibrationTimer);
        _vibrationTimer = NULL;
    }
    if (_vibrationStopTimer != NULL) {
        dispatch_source_cancel(_vibrationStopTimer);
        _vibrationStopTimer = NULL;
    }
    if (_soundStopTimer != NULL) {
        dispatch_source_cancel(_soundStopTimer);
        _soundStopTimer = NULL;
    }
    if (_systemSoundTimer != NULL) {
        dispatch_source_cancel(_systemSoundTimer);
        _systemSoundTimer = NULL;
    }
    if (_alertSoundTimer != NULL) {
        dispatch_source_cancel(_alertSoundTimer);
        _alertSoundTimer = NULL;
    }
    if (_endTimer != NULL) {
        dispatch_source_cancel(_endTimer);
        _endTimer = NULL;
    }
}

#pragma mark - Vibration

- (void)_startVibrationOnQueue:(KSAConfig *)config
{
    NSTimeInterval interval = MAX(config.vibrationInterval, 0.2);
    NSTimeInterval duration = MAX(config.vibrationDuration, 0.1);

    // First burst immediately, then repeat until the vibration phase ends.
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
    _vibrationRunning = YES;

    __weak typeof(self) weakSelf = self;
    _vibrationTimer = [self _scheduleTimerWithDelay:interval
                                           interval:interval
                                            handler:^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self->_vibrationRunning) {
            return;
        }
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
    }];

    _vibrationStopTimer = [self _scheduleTimerWithDelay:duration
                                               interval:0
                                                handler:^{
        __strong typeof(weakSelf) self = weakSelf;
        self->_vibrationRunning = NO;
        if (self->_vibrationTimer != NULL) {
            dispatch_source_cancel(self->_vibrationTimer);
            self->_vibrationTimer = NULL;
        }
        KSADebug(@"vibration phase finished");
    }];

    KSADebug(@"vibration started (%.1fs, every %.2fs)", duration, interval);
}

#pragma mark - Sound

- (void)_startSoundOnQueue:(KSAConfig *)config
{
    NSString *path = [config resolvedSoundPath];
    NSTimeInterval duration = MAX(config.soundDuration, 0.1);
    __weak typeof(self) weakSelf = self;

    // Default: the alert (ringer) channel, so the reminder is heard even when the
    // media volume is turned all the way down. SoundChannel = media switches back to
    // AVAudioPlayer (media volume, audible while the ring/silent switch is muted).
    if ([config.soundChannel isEqualToString:@"alert"]) {
        if (path.length > 0) {
            // 1) straight to the system sound path when the format allows it ...
            if (KSASoundFileSupportsAlertChannel(path) &&
                [self _startAlertChannelSoundOnQueue:config path:path]) {
                return;
            }
            // 2) ... otherwise convert (m4r ringtones, mp3, compressed CAF, ...) to a
            //    PCM CAF and use that, so the chosen sound is still heard at the
            //    ringer volume instead of falling back to the (possibly mute) media path.
            // Cache the conversion where this process can actually write it: imagent may not
            // be able to create files inside the jailbreak root, but /var/mobile/Library
            // is where its own configuration lives.
            NSString *cacheDirectory = @"/var/mobile/Library/KeywordSMSAlert";
            [[NSFileManager defaultManager] createDirectoryAtPath:cacheDirectory
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:NULL];
            NSString *converted = KSAPCMCopyOfSoundFileInDirectory(path, cacheDirectory);
            if (converted.length > 0 &&
                [self _startAlertChannelSoundOnQueue:config path:converted]) {
                if (![converted isEqualToString:path]) {
                    KSAInfo(@"converted %@ to 16 bit PCM CAF so it can be played on the alert channel",
                            path.lastPathComponent);
                }
                return;
            }
            KSAInfo(@"%@ could not be used on the alert channel; using the media channel instead",
                    path.lastPathComponent);
        }
    }

    if (path.length == 0) {
        // No audio file at all: fall back to a stock system sound id. This is a
        // last resort because volume and looping cannot be controlled that way.
        KSAInfo(@"no sound file found; using the system SMS sound id (volume/loop settings ignored)");
        AudioServicesPlaySystemSound(1007);
        _systemSoundTimer = [self _scheduleTimerWithDelay:kKSASystemSoundRepeatInterval
                                                 interval:kKSASystemSoundRepeatInterval
                                                  handler:^{
            AudioServicesPlaySystemSound(1007);
        }];
        _soundStopTimer = [self _scheduleTimerWithDelay:duration
                                               interval:0
                                                handler:^{
            __strong typeof(weakSelf) self = weakSelf;
            if (self->_systemSoundTimer != NULL) {
                dispatch_source_cancel(self->_systemSoundTimer);
                self->_systemSoundTimer = NULL;
            }
            KSADebug(@"system sound phase finished");
        }];
        return;
    }

#ifdef KSA_NO_MEDIA_CHANNEL
    // This build links AudioToolbox only: the alert (ringer) channel above is the
    // only sound path. Nothing to do if it was rejected.
    KSAInfo(@"media channel is not part of this build; alert channel unavailable for %@",
            path.lastPathComponent);
    return;
#else
    [self _configureAudioSessionWithError:NULL];

    NSError *error = nil;
    NSURL *url = [NSURL fileURLWithPath:path];
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&error];
    if (player == nil) {
        KSAInfo(@"sound file could not be loaded (%@): %@", path.lastPathComponent,
                error.localizedDescription ?: @"unknown error");
        return;
    }

    player.delegate = self;
    player.numberOfLoops = config.soundLoop ? -1 : 0;
    player.volume = config.soundVolume;
    [player prepareToPlay];
    if (![player play]) {
        KSAInfo(@"sound playback could not start (%@)", path.lastPathComponent);
        return;
    }
    _player = player;

    _soundStopTimer = [self _scheduleTimerWithDelay:duration
                                           interval:0
                                            handler:^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self->_player != nil) {
            [self->_player stop];
            self->_player = nil;
        }
        KSADebug(@"sound phase finished");
    }];

    KSADebug(@"sound started (%@, %.1fs, volume %.2f, loop=%d)",
             path.lastPathComponent, duration, config.soundVolume, config.soundLoop);
#endif
}

#ifndef KSA_NO_MEDIA_CHANNEL
- (void)_configureAudioSessionWithError:(NSError **)errorOut
{
    // A dedicated playback session is used so the alert is audible even with the
    // ring/silent switch set to silent, without ever touching the user's system
    // volume. The previous category/mode is remembered and restored on stop.
    AVAudioSession *session = [AVAudioSession sharedInstance];
    _previousAudioCategory = session.category;
    _previousAudioMode = session.mode;

    NSError *error = nil;
    BOOL configured = [session setCategory:AVAudioSessionCategoryPlayback
                                      mode:AVAudioSessionModeDefault
                                   options:AVAudioSessionCategoryOptionMixWithOthers
                                     error:&error];
    if (configured) {
        configured = [session setActive:YES error:&error];
    }

    if (configured) {
        _audioSessionActivatedByUs = YES;
    } else {
        KSADebug(@"audio session setup failed: %@", error.localizedDescription ?: @"unknown");
    }

    if (errorOut != NULL) {
        *errorOut = error;
    }
}

- (void)_restoreAudioSessionOnQueue
{
    if (!_audioSessionActivatedByUs) {
        return;
    }
    _audioSessionActivatedByUs = NO;

    @try {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        if (_previousAudioCategory.length > 0) {
            [session setCategory:_previousAudioCategory
                            mode:_previousAudioMode ?: AVAudioSessionModeDefault
                         options:0
                           error:NULL];
        }
        [session setActive:NO
               withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                     error:NULL];
    } @catch (__unused NSException *exception) {
        KSADebug(@"audio session restore failed");
    }

    _previousAudioCategory = nil;
    _previousAudioMode = nil;
}
#endif

#pragma mark - Teardown

- (void)_teardownChannelsOnQueue
{
    _vibrationRunning = NO;
    [self _stopAlertChannelSoundOnQueue];

#ifndef KSA_NO_MEDIA_CHANNEL
    if (_player != nil) {
        @try {
            [_player stop];
        } @catch (__unused NSException *exception) {
            // ignored: tearing down must never throw
        }
        _player.delegate = nil;
        _player = nil;
    }

    [self _restoreAudioSessionOnQueue];
#endif
}

#ifndef KSA_NO_MEDIA_CHANNEL
#pragma mark - AVAudioPlayerDelegate

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag
{
    dispatch_async(_queue, ^{
        if (self.state != KSAAlertStateAlerting) {
            return;
        }
        if (self->_vibrationRunning) {
            // Vibration continues until its own timer ends the alert.
            return;
        }
        [self _stopOnQueueWithReason:@"sound finished"];
    });
}
#endif

@end
