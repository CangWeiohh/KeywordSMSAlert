//
//  KSASMSWatcher.m
//  KeywordSMSAlert
//

#import "KSASMSWatcher.h"
#import "KSACommon.h"
#import "KSAConfig.h"
#import "KSALog.h"
#import "KSASMSDetector.h"
#import "KSARuntimeStatus.h"

#ifdef KSA_ALERT_IN_DETECTOR
// The alert engine lives in this same process (imagent), so the watcher can stop a
// running alert directly - using the database it already reads.
#import "KSAAlertManager.h"
#endif

#import <sqlite3.h>

/// Cap per poll so a large backlog can never stall the queue.
static const int KSASMSWatcherBatchSize = 25;

@implementation KSASMSWatcher
{
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    sqlite3 *_database;
    long long _highWaterRowID;
    BOOL _started;
    NSUInteger _failures;
    NSTimeInterval _scheduledInterval;
    // Diagnostics. Everything here is touched only on _queue and is published to the
    // Settings pane through the runtime status file (never through a hook).
    BOOL _baselineEstablished;
    BOOL _stopped;
    NSUInteger _pollCount;
    NSUInteger _databaseOpenCount;
    NSTimeInterval _lastPollAt;
    NSTimeInterval _lastStatusPublish;
    NSString *_lastError;
#ifdef KSA_ALERT_IN_DETECTOR
    NSMutableArray<NSNumber *> *_alertingRowIDs;
    dispatch_source_t _readWatchTimer;
#endif
}

+ (instancetype)sharedInstance
{
    static KSASMSWatcher *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[KSASMSWatcher alloc] init];
    });
    return instance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.keyword.smsalert.smswatch", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

#pragma mark - Database

/// The real user database. imagent runs outside the jailbreak root, so this plain
/// rootfs path is the one it uses itself.
- (NSString *)_databasePath
{
    for (NSString *candidate in @[ @"/var/mobile/Library/SMS/sms.db",
                                   KSAPathInJB(@"/var/mobile/Library/SMS/sms.db") ]) {
        if (candidate.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
            return candidate;
        }
    }
    return nil;
}

- (BOOL)_openDatabaseIfNeeded
{
    if (_database != NULL) {
        return YES;
    }

    NSString *path = [self _databasePath];
    if (path == nil) {
        return NO;
    }

    // Strictly READ ONLY: this process must never be able to modify the SMS store.
    sqlite3 *database = NULL;
    int rc = sqlite3_open_v2(path.UTF8String, &database, SQLITE_OPEN_READONLY, NULL);
    if (rc != SQLITE_OK) {
        // Copy the message out BEFORE closing: sqlite3_errmsg() on a handle that has
        // already been closed (or on a NULL handle) is not a legal call.
        NSString *reason = @"unknown";
        if (database != NULL) {
            const char *message = sqlite3_errmsg(database);
            if (message != NULL) {
                reason = @(message);
            }
            // close_v2 never leaves a leaked handle behind, even if a statement is
            // still outstanding somewhere.
            sqlite3_close_v2(database);
        } else {
            reason = [NSString stringWithFormat:@"sqlite3_open_v2 returned %d", rc];
        }
        [self _noteError:[NSString stringWithFormat:@"sqlite3_open_v2 failed: %@", reason]];
        return NO;
    }
    sqlite3_busy_timeout(database, 500);
    _database = database;
    _databaseOpenCount += 1;
    if (_databaseOpenCount == 1) {
        KSAInfo(@"SMS watcher attached to the database (read only): %@", path);
    } else {
        // Re-attaching after an error must not become a log flood.
        KSADebug(@"SMS watcher re-attached to the database (%lu times)", (unsigned long)_databaseOpenCount);
    }
    return YES;
}

- (void)_closeDatabase
{
    if (_database != NULL) {
        // sqlite3_close() fails with SQLITE_BUSY when a statement was never finalised,
        // which would leak the handle a little more on every failure. close_v2 is the
        // documented "close now, free when the last statement goes away" variant.
        sqlite3_close_v2(_database);
        _database = NULL;
    }
}

/// Records the last database problem for the Settings pane, and logs it at most once
/// per transition so a persistent error cannot fill the log file.
- (void)_noteError:(NSString *)message
{
    BOOL changed = (_lastError == nil) || ![_lastError isEqualToString:message];
    _lastError = message;
    if (changed) {
        KSAInfo(@"SMS watcher database problem: %@", message);
    }
}

- (long long)_currentMaxRowID
{
    sqlite3_stmt *statement = NULL;
    long long maximum = -1;
    if (sqlite3_prepare_v2(_database, "SELECT MAX(ROWID) FROM message", -1, &statement, NULL) == SQLITE_OK) {
        if (sqlite3_step(statement) == SQLITE_ROW) {
            maximum = sqlite3_column_int64(statement, 0);
        }
        sqlite3_finalize(statement);
    }
    return maximum;
}

#pragma mark - Polling

- (void)start
{
    if (_started || _stopped) {
        return;
    }
    _started = YES;

    // Emergency kill switch: while the marker file exists the watcher does nothing at
    // all - no timer, no database handle, no alert. See ksactl safemode / the Settings
    // pane. This is the only switch that survives a broken configuration file.
    if (KSASafeModeEnabled()) {
        KSAInfo(@"safe mode is ON (%@): the SMS watcher is not started", KSASafeModeMarkerPath());
        return;
    }

#ifdef KSA_ALERT_IN_DETECTOR
    // Latency note: the read check must not wait for the (possibly 5 s) detection poll.
    // While an alert is playing a 0.5 s timer performs the single primary-key lookup, so
    // opening the SMS stops the alert almost immediately. It runs ONLY during an alert.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                            selector:@selector(_ksaAlertStateChanged:)
                                                name:KSAAlertStateDidChangeNotification
                                              object:nil];
#endif

    dispatch_async(_queue, ^{
        [self _scheduleNextPoll];
    });
}

/// Cancels both timers. MUST run on `_queue`: `_timer` and `_readWatchTimer` are queue
/// state, and cancelling them from another thread while `_scheduleNextPoll` reassigns
/// `_timer` would race on the ivar.
- (void)_cancelTimersOnQueue
{
    if (_timer != NULL) {
        dispatch_source_cancel(_timer);
        _timer = NULL;
    }
#ifdef KSA_ALERT_IN_DETECTOR
    if (_readWatchTimer != NULL) {
        dispatch_source_cancel(_readWatchTimer);
        _readWatchTimer = NULL;
    }
    [_alertingRowIDs removeAllObjects];
#endif
}

- (void)stop
{
    _stopped = YES;
    _started = NO;

#ifdef KSA_ALERT_IN_DETECTOR
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                   name:KSAAlertStateDidChangeNotification
                                                 object:nil];
#endif

    // All timer state lives on the queue, so the cancellation is handed to it rather
    // than done here. _poll checks _stopped, so a tick that is already in flight
    // cannot resurrect the watcher.
    dispatch_async(_queue, ^{
        [self _cancelTimersOnQueue];
        [self _closeDatabase];
    });
}

- (void)_scheduleNextPoll
{
    if (_stopped) {
        return;
    }

    KSAConfig *config = [KSAConfig sharedInstance];
    NSTimeInterval interval = MAX(config.pollInterval, 0.5);
    _scheduledInterval = interval;

    if (_timer != NULL) {
        dispatch_source_cancel(_timer);
        _timer = NULL;
    }

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    if (timer == NULL) {
        // Cannot happen in practice, but a NULL source must never be resumed or stored.
        KSAInfo(@"could not create the poll timer");
        return;
    }
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
                              (uint64_t)(interval * NSEC_PER_SEC),
                              // Generous leeway: the poll is not latency critical, and a
                              // wide window lets the kernel coalesce this wake-up with
                              // whatever else the device is already doing (battery).
                              (uint64_t)(400 * NSEC_PER_MSEC));
    // __weak: the source is stored in self's own ivar, so a strong capture would keep
    // self alive for as long as the source lives (retain cycle on the singleton).
    __weak KSASMSWatcher *weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf _poll];
    });
    dispatch_resume(timer);
    _timer = timer;
}

- (void)_poll
{
    @autoreleasepool {
        @try {
            // stop() sets this before the cancellation reaches the queue.
            if (_stopped) {
                return;
            }
            _pollCount += 1;
            _lastPollAt = KSANow();

            KSAConfig *config = [KSAConfig sharedInstance];
            [config reloadIfNeeded];

            // PollInterval is picked up live: if the configuration asks for a different
            // interval the timer is rebuilt here, so no imagent restart is needed.
            NSTimeInterval desiredInterval = MAX(config.pollInterval, 0.5);
            if (fabs(desiredInterval - _scheduledInterval) > 0.01) {
                KSAInfo(@"poll interval changed: %.1fs -> %.1fs", _scheduledInterval, desiredInterval);
                [self _scheduleNextPoll];
                return;
            }

            if (!config.enabled) {
                return;   // nothing to do while disabled; the timer keeps ticking cheaply
            }

            if (![self _openDatabaseIfNeeded]) {
                return;
            }

#ifdef KSA_ALERT_IN_DETECTOR
            // While an alert is playing, first check whether the user has read the message:
            // opening the SMS in Messages marks it read, which is the stop gesture in the
            // stable build (it costs one primary-key lookup per poll, and only while
            // alerting).
            if ([self _stopAlertIfTrackedMessageWasRead]) {
                return;
            }
#endif

            // The very first successful pass establishes the baseline: messages that
            // already exist are never alerted on. This is a separate flag (not
            // "_highWaterRowID == 0") because an empty mailbox also has ROWID 0 as its
            // maximum, and the first SMS arriving after an empty mailbox must still alert.
            long long maximum = [self _currentMaxRowID];
            if (maximum < 0) {
                [self _noteError:@"SELECT MAX(ROWID) FROM message failed"];
                [self _closeDatabase];
                return;
            }
            if (!_baselineEstablished) {
                _baselineEstablished = YES;
                _highWaterRowID = maximum;
                KSAInfo(@"SMS watcher baseline established at ROWID %lld", maximum);
                [self _publishStatusWithConfig:config];
                return;
            }
            if (maximum <= _highWaterRowID) {
                return;
            }

            [self _processNewMessagesWithConfig:config];
            _failures = 0;
            _lastError = nil;
            [self _publishStatusWithConfig:config];
        } @catch (NSException *exception) {
            // An Objective-C exception inside a dispatch timer handler would otherwise
            // terminate imagent. Swallow it, drop the handle and keep polling.
            _failures += 1;
            [self _noteError:[NSString stringWithFormat:@"exception: %@", exception.reason]];
            [self _closeDatabase];
        }
    }
}

/// Reads every message newer than the high water mark. The statement is always
/// finalised, including when a detector callback throws.
- (void)_processNewMessagesWithConfig:(KSAConfig *)config
{
    const char *sql =
        "SELECT m.ROWID, m.text, m.is_from_me, m.service, h.id FROM message m "
        "LEFT JOIN handle h ON m.handle_id = h.ROWID "
        "WHERE m.ROWID > ? ORDER BY m.ROWID ASC LIMIT ?";

    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_database, sql, -1, &statement, NULL) != SQLITE_OK) {
        [self _noteError:[NSString stringWithFormat:@"prepare failed: %s", sqlite3_errmsg(_database)]];
        [self _closeDatabase];
        return;
    }

    long long newest = _highWaterRowID;
    @try {
        sqlite3_bind_int64(statement, 1, _highWaterRowID);
        sqlite3_bind_int(statement, 2, KSASMSWatcherBatchSize);

        while (sqlite3_step(statement) == SQLITE_ROW) {
            long long rowID = sqlite3_column_int64(statement, 0);
            if (rowID > newest) {
                newest = rowID;
            }

            int fromMe = sqlite3_column_int(statement, 2);
            if (fromMe != 0) {
                continue;
            }

            const unsigned char *serviceBytes = sqlite3_column_text(statement, 3);
            NSString *service = serviceBytes != NULL ? @((const char *)serviceBytes) : nil;
            if (![self _serviceIsAcceptable:service config:config]) {
                continue;
            }

            const unsigned char *textBytes = sqlite3_column_text(statement, 1);
            if (textBytes == NULL) {
                // iMessage keeps its body in attributedBody; nothing to match here.
                continue;
            }
            NSString *text = @((const char *)textBytes);
            if (text.length == 0) {
                continue;
            }

            const unsigned char *handleBytes = sqlite3_column_text(statement, 4);
            NSString *sender = handleBytes != NULL ? @((const char *)handleBytes) : nil;

            BOOL handedToAlertEngine =
                [[KSASMSDetector sharedInstance] handlePlainText:text
                                                          sender:sender
                                                        identity:[NSString stringWithFormat:@"db-rowid-%lld", rowID]
                                                         service:service
                                                          source:@"smsdb"];
#ifdef KSA_ALERT_IN_DETECTOR
            // Only rows that actually started an alert are worth watching for a read
            // receipt: tracking every incoming message would let an unrelated message
            // the user happened to read stop the alert.
            if (handedToAlertEngine) {
                [self _rememberAlertedRowID:rowID];
            }
#else
            (void)handedToAlertEngine;
#endif
        }
    } @finally {
        sqlite3_finalize(statement);
    }

    _highWaterRowID = newest;
}

/// Publishes the poll counters to the runtime status file. This is what the Settings
/// pane reads, and it is the only way to see the detector's health without a terminal.
/// Throttled: the poll loop may tick every second, but a synchronous plist write is
/// only worth doing at most once every 30 seconds (and immediately on error changes).
- (void)_publishStatusWithConfig:(KSAConfig *)config
{
    NSTimeInterval now = KSANow();
    BOOL errorJustChanged = (_lastError.length > 0);
    if (!errorJustChanged && _lastStatusPublish > 0 && (now - _lastStatusPublish) < 30.0) {
        return;
    }
    _lastStatusPublish = now;

    NSMutableDictionary *status = [NSMutableDictionary dictionary];
    status[@"PollCount"] = @(_pollCount);
    status[@"LastPollAt"] = @(_lastPollAt);
    status[@"HighWaterRowID"] = @(_highWaterRowID);
    status[@"DatabaseOpenCount"] = @(_databaseOpenCount);
    status[@"DatabaseAttached"] = @(_database != NULL);
    status[@"PollInterval"] = @(MAX(config.pollInterval, 0.5));
    if (_lastError.length > 0) {
        status[@"LastDatabaseError"] = _lastError;
    }
    KSARuntimeStatusUpdate(status);
}

#ifdef KSA_ALERT_IN_DETECTOR
#pragma mark - Fast read check while alerting

- (void)_ksaAlertStateChanged:(NSNotification *)notification
{
    BOOL alerting = [[KSAAlertManager sharedInstance] isAlerting];
    dispatch_async(_queue, ^{
        if (alerting) {
            [self _startReadWatch];
        } else {
            [self _stopReadWatch];
        }
    });
}

/// 0.5 s repeating timer, active only while an alert is playing.
- (void)_startReadWatch
{
    if (_readWatchTimer != NULL) {
        return;
    }
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    if (timer == NULL) {
        return;
    }
    uint64_t interval = (uint64_t)(0.5 * NSEC_PER_SEC);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval),
                              interval,
                              (uint64_t)(100 * NSEC_PER_MSEC));
    // __weak (the source is stored in self's own ivar) and @try: this handler runs on a
    // dispatch queue, and an uncaught ObjC exception there would terminate imagent.
    __weak KSASMSWatcher *weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        @autoreleasepool {
            @try {
                [weakSelf _stopAlertIfTrackedMessageWasRead];
            } @catch (NSException *exception) {
                KSAInfo(@"read check failed (%@); the alert keeps running", exception.reason);
            }
        }
    });
    dispatch_resume(timer);
    _readWatchTimer = timer;
    KSADebug(@"fast read check started (0.5s, only while alerting)");
}

- (void)_stopReadWatch
{
    // The tracked rows describe "the messages that may have started the alert that is
    // running right now". Once no alert is running the list is stale, and keeping it
    // would let a message the user read minutes ago stop the NEXT alert.
    [_alertingRowIDs removeAllObjects];

    if (_readWatchTimer != NULL) {
        dispatch_source_cancel(_readWatchTimer);
        _readWatchTimer = NULL;
        KSADebug(@"fast read check stopped");
    }
}

#pragma mark - Stop when the message is read

/// Remembers a row that may have started an alert, so the next polls can watch it.
- (void)_rememberAlertedRowID:(long long)rowID
{
    if (_alertingRowIDs == nil) {
        _alertingRowIDs = [NSMutableArray array];
    }
    [_alertingRowIDs addObject:@(rowID)];
    // Only the most recent messages are worth watching (and only while an alert runs).
    while (_alertingRowIDs.count > 8) {
        [_alertingRowIDs removeObjectAtIndex:0];
    }
}

/// Stopping by "the user read the SMS": iOS sets message.is_read as soon as the message
/// is opened (or its notification is acted on). This needs NOTHING but the read-only
/// database handle we already hold - no HID client, no Darwin observer, no extra process -
/// which is why it is the stop method that ships in the stable build.
///
/// Returns YES when the alert was stopped.
- (BOOL)_stopAlertIfTrackedMessageWasRead
{
    if (_alertingRowIDs.count == 0 || _database == NULL) {
        return NO;
    }
    if (![[KSAAlertManager sharedInstance] isAlerting]) {
        return NO;
    }

    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_database, "SELECT is_read FROM message WHERE ROWID = ?", -1,
                           &statement, NULL) != SQLITE_OK) {
        // Do not tear the handle down here: this runs during an alert, and a transient
        // failure would turn into a closed database mid-alert. Report and try again on
        // the next tick.
        [self _noteError:[NSString stringWithFormat:@"read check prepare failed: %s",
                          sqlite3_errmsg(_database)]];
        return NO;
    }

    long long readRowID = -1;
    @try {
        for (NSNumber *rowID in _alertingRowIDs) {
            sqlite3_reset(statement);
            sqlite3_clear_bindings(statement);
            sqlite3_bind_int64(statement, 1, rowID.longLongValue);
            if (sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) != 0) {
                readRowID = rowID.longLongValue;
                break;
            }
        }
    } @finally {
        sqlite3_finalize(statement);
    }

    if (readRowID < 0) {
        return NO;
    }

    KSAInfo(@"message ROWID %lld was marked read - stopping the alert", readRowID);
    [_alertingRowIDs removeAllObjects];
    [[KSAAlertManager sharedInstance] stopAlertWithReason:@"SMS marked as read"];
    return YES;
}
#endif

- (BOOL)_serviceIsAcceptable:(NSString *)service config:(KSAConfig *)config
{
    if (service.length == 0) {
        return YES;
    }
    if ([service rangeOfString:@"sms" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return YES;
    }
    return config.includeIMessage;
}

@end
