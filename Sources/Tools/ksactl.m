//
//  ksactl.m
//  KeywordSMSAlert command line helper
//
//  Fallback that does NOT depend on PreferenceLoader: read/write the same
//  configuration plist the tweak uses, and fire a test alert.
//
//  Run it from a terminal (NewTerm / SSH) or from Filza on the device:
//
//      ksactl status
//      ksactl get AlertMode
//      ksactl set AlertMode 2
//      ksactl keywords add 验证码
//      ksactl keywords list
//      ksactl test
//      ksactl reload
//
//  Inside the roothide bootstrap shell "/" is the jailbreak root, therefore:
//    * the jailbreak copy of the preferences file lives at
//          /var/mobile/Library/Preferences/com.keyword.smsalert.plist
//    * the real iOS user preferences file lives at
//          /rootfs/var/mobile/Library/Preferences/com.keyword.smsalert.plist
//      (the tweak running inside SpringBoard/imagent sees it as
//       /var/mobile/Library/Preferences/com.keyword.smsalert.plist and it always
//       takes precedence - same rule as KSAConfig and the Settings pane).
//

#import <Foundation/Foundation.h>
#import <signal.h>
#import <string.h>
#import <stdlib.h>
#import <unistd.h>
#import <sqlite3.h>

static NSString *const KSADomainName = @"com.keyword.smsalert";
static NSString *const KSAReloadNotification = @"com.keyword.smsalert.reload";
static NSString *const KSATriggerNotification = @"com.keyword.smsalert.trigger";

static NSString *const KSAGreen = @"\033[32m";
static NSString *const KSARed = @"\033[31m";
static NSString *const KSAReset = @"\033[0m";

static NSArray<NSString *> *KSACandidatePaths(void)
{
    NSString *file = [KSADomainName stringByAppendingString:@".plist"];
    return @[
        [@"/rootfs/var/mobile/Library/Preferences" stringByAppendingPathComponent:file],
        [@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:file],
        [@"/Library/Preferences" stringByAppendingPathComponent:file],
    ];
}

static NSString *KSAActivePath(void)
{
    for (NSString *path in KSACandidatePaths()) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            return path;
        }
    }
    return nil;
}

static NSMutableDictionary *KSALoadConfiguration(void)
{
    NSString *path = KSAActivePath();
    if (path == nil) {
        return [NSMutableDictionary dictionary];
    }
    NSDictionary *dictionary = [NSDictionary dictionaryWithContentsOfFile:path];
    return [dictionary isKindOfClass:[NSDictionary class]] ? [dictionary mutableCopy]
                                                          : [NSMutableDictionary dictionary];
}

static void KSAPostNotification(NSString *name)
{
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    if (center != NULL) {
        CFNotificationCenterPostNotification(center, (__bridge CFNotificationName)name, NULL, NULL, true);
    }
}

static BOOL KSASaveConfiguration(NSDictionary *configuration)
{
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:configuration
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:NULL];
    if (data.length == 0) {
        return NO;
    }

    BOOL wroteAny = NO;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *path in KSACandidatePaths()) {
        NSString *directory = [path stringByDeletingLastPathComponent];
        if (![fileManager fileExistsAtPath:directory]) {
            continue;
        }
        if ([data writeToFile:path atomically:YES]) {
            printf("  wrote %s%s%s\n", KSAGreen.UTF8String, path.UTF8String, KSAReset.UTF8String);
            wroteAny = YES;
        } else {
            printf("  could not write %s%s%s\n", KSARed.UTF8String, path.UTF8String, KSAReset.UTF8String);
        }
    }

    KSAPostNotification(KSAReloadNotification);
    printf("  reload notification posted\n");
    return wroteAny;
}

static id KSAObjectForKey(NSDictionary *configuration, NSString *key)
{
    id value = configuration[key];
    if (value != nil) {
        return value;
    }
    for (NSString *candidate in configuration) {
        if ([[candidate lowercaseString] isEqualToString:key.lowercaseString]) {
            return configuration[candidate];
        }
    }
    return nil;
}

static void KSAPrintUsage(void)
{
    printf("ksactl - KeywordSMSAlert helper\n\n"
           "  ksactl status                     show paths and effective settings\n"
           "  ksactl get <Key>                  print one raw value\n"
           "  ksactl set <Key> <Value>          set Enabled/AlertMode/DebugEnabled/...\n"
           "  ksactl keywords list              list keywords\n"
           "  ksactl keywords add <text>        add a keyword\n"
           "  ksactl keywords remove <text>     remove a keyword\n"
           "  ksactl keywords clear             remove all keywords (never triggers)\n"
           "  ksactl senders  list|add|remove|clear   same for IgnoreSenders\n"
           "  ksactl test                       fire a test alert now\n"
           "  ksactl reload                     ask the tweak to reload the file\n"
           "  ksactl restart                    restart imagent + SpringBoard (apply an update)\n"
           "  ksactl db [n]                     list the newest n SMS from sms.db (READ ONLY)\n\n"
           "Common keys: Enabled AlertMode Keywords MatchMode VibrationDuration SoundDuration\n"
           "             SoundVolume DuplicateInterval DebugEnabled LogToFile TestAlertOnLoad\n");
}

/// The SMS database, seen from the bootstrap shell: "/" is the jailbreak root, so the
/// real iOS database is below /rootfs. The second candidate covers running outside the
/// bootstrap.
static NSString *KSASMSDatabasePath(void)
{
    for (NSString *candidate in @[ @"/rootfs/var/mobile/Library/SMS/sms.db",
                                   @"/var/mobile/Library/SMS/sms.db" ]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
            return candidate;
        }
    }
    return nil;
}

/// Prints the newest messages from sms.db. Opened strictly READ ONLY - this tool (and
/// the tweak) never writes to the message database.
static void KSACommandDatabase(NSArray<NSString *> *arguments)
{
    NSInteger limit = arguments.count > 0 ? [arguments[0] integerValue] : 10;
    if (limit <= 0 || limit > 200) {
        limit = 10;
    }

    NSString *path = KSASMSDatabasePath();
    if (path == nil) {
        printf("sms.db not found (checked /rootfs/var/mobile/Library/SMS/ and /var/mobile/Library/SMS/)\n");
        return;
    }
    printf("database : %s\nread only: yes (KeywordSMSAlert never writes to it)\n", path.UTF8String);

    sqlite3 *database = NULL;
    if (sqlite3_open_v2(path.UTF8String, &database, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        printf("cannot open: %s\n", database != NULL ? sqlite3_errmsg(database) : "unknown error");
        if (database != NULL) {
            sqlite3_close(database);
        }
        return;
    }
    sqlite3_busy_timeout(database, 1500);

    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM message", -1, &statement, NULL) == SQLITE_OK) {
        if (sqlite3_step(statement) == SQLITE_ROW) {
            printf("messages : %lld in total\n", sqlite3_column_int64(statement, 0));
        }
        sqlite3_finalize(statement);
        statement = NULL;
    }

    const char *sqlWithService =
        "SELECT m.date, m.is_from_me, m.service, m.text, h.id, m.guid FROM message m "
        "LEFT JOIN handle h ON m.handle_id = h.ROWID ORDER BY m.date DESC LIMIT ?";
    const char *sqlNoService =
        "SELECT m.date, m.is_from_me, NULL, m.text, h.id, m.guid FROM message m "
        "LEFT JOIN handle h ON m.handle_id = h.ROWID ORDER BY m.date DESC LIMIT ?";

    if (sqlite3_prepare_v2(database, sqlWithService, -1, &statement, NULL) != SQLITE_OK) {
        statement = NULL;
        sqlite3_prepare_v2(database, sqlNoService, -1, &statement, NULL);
    }
    if (statement == NULL) {
        printf("cannot read the message table: %s\n", sqlite3_errmsg(database));
        sqlite3_close(database);
        return;
    }

    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"MM-dd HH:mm:ss";
    });

    sqlite3_bind_int(statement, 1, (int)limit);
    printf("\nnewest %ld message(s):\n", (long)limit);
    while (sqlite3_step(statement) == SQLITE_ROW) {
        double appleEpoch = sqlite3_column_double(statement, 0);
        NSDate *date = [NSDate dateWithTimeIntervalSinceReferenceDate:appleEpoch];
        int fromMe = sqlite3_column_int(statement, 1);

        const unsigned char *service = sqlite3_column_text(statement, 2);
        const unsigned char *text = sqlite3_column_text(statement, 3);
        const unsigned char *handle = sqlite3_column_text(statement, 4);
        const unsigned char *guid = sqlite3_column_text(statement, 5);

        printf("  %s  %s  service=%-6s  %s  text=%s\n",
               [formatter stringFromDate:date].UTF8String,
               fromMe ? "me ->   " : "<- them ",
               service != NULL ? (const char *)service : "?",
               handle != NULL ? (const char *)handle : "(no handle)",
               text != NULL ? (const char *)text : "(no text column - iMessage stores it in attributedBody)");
        if (guid != NULL && strlen((const char *)guid) > 8) {
            printf("            guid: %s\n", (const char *)guid);
        }
    }
    sqlite3_finalize(statement);
    sqlite3_close(database);
}

static void KSACommandStatus(void)
{
    printf("%sKeywordSMSAlert status%s\n", KSAGreen.UTF8String, KSAReset.UTF8String);
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *path in KSACandidatePaths()) {
        BOOL exists = [fileManager fileExistsAtPath:path];
        printf("  %s %s\n", exists ? "found   " : "missing ", path.UTF8String);
    }

    NSString *active = KSAActivePath();
    printf("  active  : %s\n", active ? active.UTF8String : "(built-in defaults)");

    NSDictionary *configuration = KSALoadConfiguration();
    printf("\n%sEffective settings%s\n", KSAGreen.UTF8String, KSAReset.UTF8String);
    NSArray<NSString *> *keys = @[ @"Enabled", @"AlertMode", @"Keywords", @"MatchMode", @"CaseInsensitive",
                                   @"VibrationEnabled", @"VibrationDuration", @"VibrationInterval",
                                   @"SoundEnabled", @"SoundDuration", @"SoundVolume", @"SoundLoop", @"SoundFile",
                                   @"DuplicateInterval", @"OnNewMatchedSMS", @"IgnoreSenders", @"IncludeIMessage",
                                   @"DebugEnabled", @"LogToFile", @"TestAlertOnLoad" ];
    for (NSString *key in keys) {
        id value = KSAObjectForKey(configuration, key);
        NSString *description = value != nil ? [value description] : @"(default)";
        if ([key isEqualToString:@"SoundFile"] && [value isKindOfClass:[NSString class]] && [value length] > 0) {
            BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:value];
            description = [description stringByAppendingFormat:@"   [%s]", exists ? "exists" : "MISSING"];
        }
        printf("  %-20s = %s\n", key.UTF8String, description.UTF8String);
    }
}

static void KSACommandKeywords(NSArray<NSString *> *arguments, NSString *key)
{
    NSMutableDictionary *configuration = KSALoadConfiguration();
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    id existing = KSAObjectForKey(configuration, key);
    if ([existing isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)existing) {
            if ([item isKindOfClass:[NSString class]]) {
                [items addObject:item];
            }
        }
    }

    NSString *action = arguments.count > 0 ? arguments[0].lowercaseString : @"list";
    if ([action isEqualToString:@"list"]) {
        printf("%s (%lu):\n", key.UTF8String, (unsigned long)items.count);
        for (NSString *item in items) {
            printf("  %s\n", item.UTF8String);
        }
        return;
    }

    if ([action isEqualToString:@"clear"]) {
        configuration[key] = @[];
        KSASaveConfiguration(configuration);
        return;
    }

    if (arguments.count < 2) {
        printf("missing value\n");
        return;
    }
    NSString *value = arguments[1];

    if ([action isEqualToString:@"add"]) {
        if (![items containsObject:value]) {
            [items addObject:value];
        }
    } else if ([action isEqualToString:@"remove"]) {
        [items removeObject:value];
    } else {
        printf("unknown action %s\n", action.UTF8String);
        return;
    }

    configuration[key] = items;
    KSASaveConfiguration(configuration);
    printf("%s now (%lu):\n", key.UTF8String, (unsigned long)items.count);
    for (NSString *item in items) {
        printf("  %s\n", item.UTF8String);
    }
}

static id KSAParsedValue(NSString *raw)
{
    NSString *lowercase = raw.lowercaseString;
    if ([lowercase isEqualToString:@"true"] || [lowercase isEqualToString:@"yes"] || [lowercase isEqualToString:@"on"]) {
        return @YES;
    }
    if ([lowercase isEqualToString:@"false"] || [lowercase isEqualToString:@"no"] || [lowercase isEqualToString:@"off"]) {
        return @NO;
    }
    if ([lowercase isEqualToString:@"null"] || [lowercase isEqualToString:@"default"]) {
        return nil;
    }
    NSScanner *scanner = [NSScanner scannerWithString:raw];
    double number = 0;
    if ([scanner scanDouble:&number] && scanner.isAtEnd) {
        return @(number);
    }
    return raw;
}

// libproc entry points (exported by libSystem). Declared locally because the public
// iOS SDK does not ship libproc.h.
extern int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize);
extern int proc_name(int pid, void *buffer, uint32_t buffersize);
#define KSA_PROC_ALL_PIDS 1

/// Sends a signal to every process with the given name (the process is restarted by
/// launchd immediately). No external tool required.
static void killall(const char *processName, int signalNumber)
{
    int count = proc_listpids(KSA_PROC_ALL_PIDS, 0, NULL, 0);
    if (count <= 0) {
        return;
    }
    pid_t *pids = (pid_t *)calloc((size_t)count / (int)sizeof(pid_t) + 16, sizeof(pid_t));
    if (pids == NULL) {
        return;
    }
    count = proc_listpids(KSA_PROC_ALL_PIDS, 0, pids, count);
    int pidCount = count / (int)sizeof(pid_t);
    for (int index = 0; index < pidCount; index++) {
        pid_t pid = pids[index];
        if (pid <= 0) {
            continue;
        }
        char name[2 * MAXCOMLEN] = {0};
        if (proc_name(pid, name, sizeof(name)) <= 0) {
            continue;
        }
        if (strcmp(name, processName) == 0) {
            kill(pid, signalNumber);
        }
    }
    free(pids);
}

int main(int argc, char *argv[])
{
    @autoreleasepool {
        NSArray<NSString *> *arguments = [[NSProcessInfo processInfo] arguments];
        NSMutableArray<NSString *> *rest = [arguments mutableCopy];
        if (rest.count > 0) {
            [rest removeObjectAtIndex:0];
        }
        NSString *command = rest.count > 0 ? rest[0].lowercaseString : @"status";
        NSArray<NSString *> *parameters = rest.count > 1 ? [rest subarrayWithRange:NSMakeRange(1, rest.count - 1)] : @[];

        if ([command isEqualToString:@"status"]) {
            KSACommandStatus();
        } else if ([command isEqualToString:@"keywords"]) {
            KSACommandKeywords(parameters, @"Keywords");
        } else if ([command isEqualToString:@"senders"]) {
            KSACommandKeywords(parameters, @"IgnoreSenders");
        } else if ([command isEqualToString:@"get"]) {
            if (parameters.count < 1) {
                printf("usage: ksactl get <Key>\n");
                return 1;
            }
            id value = KSAObjectForKey(KSALoadConfiguration(), parameters[0]);
            printf("%s\n", value ? [[value description] UTF8String] : "(unset)");
        } else if ([command isEqualToString:@"set"]) {
            if (parameters.count < 2) {
                printf("usage: ksactl set <Key> <Value>\n");
                return 1;
            }
            NSMutableDictionary *configuration = KSALoadConfiguration();
            id value = KSAParsedValue(parameters[1]);
            if (value == nil) {
                [configuration removeObjectForKey:parameters[0]];
            } else {
                configuration[parameters[0]] = value;
            }
            KSASaveConfiguration(configuration);
        } else if ([command isEqualToString:@"db"] || [command isEqualToString:@"sms"]) {
            KSACommandDatabase(parameters);
        } else if ([command isEqualToString:@"test"]) {
            KSAPostNotification(KSATriggerNotification);
            printf("test alert requested (the phone should vibrate / play the sound now)\n");
        } else if ([command isEqualToString:@"restart"]) {
            printf("restarting imagent and SpringBoard in 1 second...\n");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                killall("imagent", SIGKILL);
                killall("SpringBoard", SIGKILL);
                _exit(0);
            });
        } else if ([command isEqualToString:@"reload"]) {
            KSAPostNotification(KSAReloadNotification);
            printf("reload requested\n");
        } else {
            KSAPrintUsage();
            return [command isEqualToString:@"help"] || [command isEqualToString:@"-h"] ? 0 : 1;
        }
    }
    return 0;
}
