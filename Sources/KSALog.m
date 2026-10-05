//
//  KSALog.m
//  KeywordSMSAlert
//

#import "KSALog.h"
#import "KSACommon.h"

#import <stdarg.h>

static const char *const kKSALogPrefix = "[KeywordSMSAlert]";

/// Maximum log file size before it is truncated (the .1 rotation is kept).
static const unsigned long long kKSALogFileMaxBytes = 256 * 1024;

static BOOL sKSALogDebugEnabled = NO;
static BOOL sKSALogFileEnabled = NO;
static dispatch_queue_t sKSALogQueue = NULL;

static NSString *KSALogResolvePath(void)
{
    NSArray<NSString *> *candidates = @[
        KSAPathInJB(@"/Library/KeywordSMSAlert/KeywordSMSAlert.log"),
        @"/var/mobile/Library/KeywordSMSAlert/KeywordSMSAlert.log",
    ];
    for (NSString *candidate in candidates) {
        if (candidate.length == 0) {
            continue;
        }
        NSString *directory = [candidate stringByDeletingLastPathComponent];
        if ([[NSFileManager defaultManager] fileExistsAtPath:directory]) {
            return candidate;
        }
    }
    return nil;
}

NSString *KSALogFilePath(void)
{
    static NSString *path = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        path = KSALogResolvePath();
    });
    return path;
}

void KSALogConfigure(BOOL debugEnabled, BOOL fileLoggingEnabled)
{
    sKSALogDebugEnabled = debugEnabled;
    sKSALogFileEnabled = fileLoggingEnabled;

    if (fileLoggingEnabled && sKSALogQueue == NULL) {
        sKSALogQueue = dispatch_queue_create("com.keyword.smsalert.log", DISPATCH_QUEUE_SERIAL);
    }
}

BOOL KSALogDebugEnabled(void)
{
    return sKSALogDebugEnabled;
}

static void KSALogWrite(NSString *line)
{
    NSLog(@"%s %@", kKSALogPrefix, line);

    if (!sKSALogFileEnabled || sKSALogQueue == NULL) {
        return;
    }

    // File logging is strictly best effort: it happens off the caller's thread and
    // any failure silently disables it so that a read-only container can never
    // wedge message handling.
    dispatch_async(sKSALogQueue, ^{
        NSString *path = KSALogFilePath();
        if (path == nil) {
            return;
        }

        @try {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSDictionary<NSString *, id> *attributes = [fm attributesOfItemAtPath:path error:NULL];
            unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
            if (size > kKSALogFileMaxBytes) {
                NSString *rotated = [path stringByAppendingString:@".1"];
                [fm removeItemAtPath:rotated error:NULL];
                [fm moveItemAtPath:path toPath:rotated error:NULL];
            }

            NSString *timestamped = [NSString stringWithFormat:@"%.3f %@\n", KSANow(), line];
            NSData *data = [timestamped dataUsingEncoding:NSUTF8StringEncoding];
            if (data == nil) {
                return;
            }

            if (![fm fileExistsAtPath:path]) {
                [data writeToFile:path atomically:NO];
                return;
            }

            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
            if (handle == nil) {
                return;
            }
            @try {
                [handle seekToEndOfFile];
                [handle writeData:data];
            } @finally {
                [handle closeFile];
            }
        } @catch (__unused NSException *exception) {
            sKSALogFileEnabled = NO;
        }
    });
}

static NSString *KSALogFormat(NSString *format, va_list arguments)
{
    if (format == nil) {
        return @"";
    }
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    return message ?: @"";
}

void KSAInfo(NSString *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    NSString *message = KSALogFormat(format, arguments);
    va_end(arguments);

    KSALogWrite(message);
}

void KSADebug(NSString *format, ...)
{
    if (!sKSALogDebugEnabled) {
        return;
    }

    va_list arguments;
    va_start(arguments, format);
    NSString *message = KSALogFormat(format, arguments);
    va_end(arguments);

    KSALogWrite([@"(debug) " stringByAppendingString:message]);
}

void KSADebugSensitive(NSString *format, ...)
{
    if (!sKSALogDebugEnabled) {
        return;
    }

    va_list arguments;
    va_start(arguments, format);
    NSString *message = KSALogFormat(format, arguments);
    va_end(arguments);

    KSALogWrite([@"(debug) " stringByAppendingString:message]);
}
