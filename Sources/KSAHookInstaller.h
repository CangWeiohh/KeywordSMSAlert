//
//  KSAHookInstaller.h
//  KeywordSMSAlert
//
//  The SpringBoard hooks exist for exactly one reason: while an alert is playing,
//  a press of the physical side/power button must stop it.
//
//  Because that is only needed *after* an alert started, the hooks are installed
//  LAZILY - the first time an alert actually begins - and never at dylib load time.
//  See the "no work during SpringBoard's early boot" note in README (1.1.3).
//

#ifndef KSA_HOOK_INSTALLER_H
#define KSA_HOOK_INSTALLER_H

#import <Foundation/Foundation.h>

/// Installs the power-button / lock-screen hooks if they are not installed yet.
/// Safe to call from any thread and any number of times. A no-op when:
///   * the host process is not SpringBoard, or
///   * the emergency kill switch marker exists (KSASafeModeEnabled()).
FOUNDATION_EXPORT void KSAInstallPowerButtonHooksIfNeeded(void);

/// YES once the hooks were installed in this process.
FOUNDATION_EXPORT BOOL KSAPowerButtonHooksInstalled(void);

#endif /* KSA_HOOK_INSTALLER_H */
