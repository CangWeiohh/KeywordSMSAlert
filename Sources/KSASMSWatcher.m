//
//  KSASMSWatcher.m
//  KeywordSMSAlert
//

#import "KSASMSWatcher.h"
#import "KSACommon.h"
#import "KSAConfig.h"
#import "KSALog.h"
#import "KSASMSDetector.h"

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
#ifdef KSA_ALERT_IN_DETECTOR
    NSMutableArray<NSNumber *> *_alertingRowIDs;
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
    if (sqlite3_open_v2(path.UTF8String, &database, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        if (database != NULL) {
            sqlite3_close(database);
        }
        return NO;
    }
    sqlite3_busy_timeout(database, 500);
    _database = database;
    KSAInfo(@"SMS watcher attached to the database (read only): %@", path);
    return YES;
}

- (void)_closeDatabase
{
    if (_database != NULL) {
        sqlite3_close(_database);
        _database = NULL;
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
    if (_started) {
        return;
    }
    _started = YES;

    dispatch_async(_queue, ^{
        [self _scheduleNextPoll];
    });
}

- (void)stop
{
    if (_timer != NULL) {
        dispatch_source_cancel(_timer);
        _timer = NULL;
    }
    dispatch_async(_queue, ^{
        [self _closeDatabase];
    });
}

- (void)_scheduleNextPoll
{
    KSAConfig *config = [KSAConfig sharedInstance];
    NSTimeInterval interval = MAX(config.pollInterval, 0.5);
    _scheduledInterval = interval;

    if (_timer != NULL) {
        dispatch_source_cancel(_timer);
        _timer = NULL;
    }

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
                              (uint64_t)(interval * NSEC_PER_SEC),
                              (uint64_t)(200 * NSEC_PER_MSEC));
    dispatch_source_set_event_handler(timer, ^{
        [self _poll];
    });
    dispatch_resume(timer);
    _timer = timer;
}

- (void)_poll
{
    @autoreleasepool {
        @try {
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

            // First successful pass establishes the baseline: messages that already
            // exist are never alerted on.
            long long maximum = [self _currentMaxRowID];
            if (maximum < 0) {
                [self _closeDatabase];
                return;
            }
            if (_highWaterRowID == 0) {
                _highWaterRowID = maximum;
                KSAInfo(@"SMS watcher baseline established at ROWID %lld", maximum);
                return;
            }
            if (maximum <= _highWaterRowID) {
                return;
            }

            const char *sql =
                "SELECT m.ROWID, m.text, m.is_from_me, m.service, h.id FROM message m "
                "LEFT JOIN handle h ON m.handle_id = h.ROWID "
                "WHERE m.ROWID > ? ORDER BY m.ROWID ASC LIMIT ?";

            sqlite3_stmt *statement = NULL;
            if (sqlite3_prepare_v2(_database, sql, -1, &statement, NULL) != SQLITE_OK) {
                [self _closeDatabase];
                return;
            }

            sqlite3_bind_int64(statement, 1, _highWaterRowID);
            sqlite3_bind_int(statement, 2, KSASMSWatcherBatchSize);

            long long newest = _highWaterRowID;
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

                [[KSASMSDetector sharedInstance] handlePlainText:text
                                                          sender:sender
                                                        identity:[NSString stringWithFormat:@"db-rowid-%lld", rowID]
                                                         service:service
                                                          source:@"smsdb"];
#ifdef KSA_ALERT_IN_DETECTOR
                [self _rememberAlertedRowID:rowID];
#endif
            }
            sqlite3_finalize(statement);
            _highWaterRowID = newest;
            _failures = 0;
        } @catch (NSException *exception) {
            KSAInfo(@"SMS watcher exception (ignored): %@", exception.reason);
            [self _closeDatabase];
        }
    }
}

#ifdef KSA_ALERT_IN_DETECTOR
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
        return NO;
    }

    long long readRowID = -1;
    for (NSNumber *rowID in _alertingRowIDs) {
        sqlite3_reset(statement);
        sqlite3_bind_int64(statement, 1, rowID.longLongValue);
        if (sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) != 0) {
            readRowID = rowID.longLongValue;
            break;
        }
    }
    sqlite3_finalize(statement);

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
