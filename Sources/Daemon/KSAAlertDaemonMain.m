//
//  KSAAlertDaemonMain.m
//  Production alert host (launchd, UserName=mobile, no SpringBoard injection).
//

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <signal.h>
#import <unistd.h>

#import "KSAAlertManager.h"
#import "KSAConfig.h"
#import "KSALog.h"
#import "KSAHIDPowerButton.h"
#import "KSARuntimeStatus.h"

int main(int argc, char *argv[])
{
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);

        KSARuntimeStatusReset();
        KSARuntimeStatusUpdate(@{ @"Version": @"1.1.4" });

        // Load persisted preferences before evaluating TestAlertOnLoad. The shared
        // manager reloads once more on its own queue, which is harmless and keeps the
        // component safe when reused elsewhere.
        [[KSAConfig sharedInstance] forceReload];
        [[KSAAlertManager sharedInstance] start];
        [[KSAHIDPowerButton sharedInstance] start];

        KSAInfo(@"standalone alert daemon started (pid %d, zero SpringBoard injection)", getpid());

        // Preserve the existing optional self-test semantics, but run it in this
        // independent process instead of during SpringBoard startup.
        if ([KSAConfig sharedInstance].testAlertOnLoad) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                KSAMatchEvent *event = [[KSAMatchEvent alloc] init];
                event.source = @"daemon self test";
                event.text = @"KeywordSMSAlert self test";
                event.keyword = @"self test";
                [[KSAAlertManager sharedInstance] handleMatchEvent:event];
            });
        }

        CFRunLoopRun();
    }
    return 0;
}
