//
//  KSAHookInstallerDaemon.m
//  Standalone alert daemon never installs process hooks.
//

#import "KSAHookInstaller.h"

BOOL KSAPowerButtonHooksInstalled(void)
{
    // Tell the shared alert manager that its stop-event source is already supplied.
    // KSAHIDPowerButton observes physical events in this process without hooking.
    return YES;
}

void KSAInstallPowerButtonHooksIfNeeded(void)
{
    // Intentionally empty. Production 1.1.4 contains zero SpringBoard injection.
}
