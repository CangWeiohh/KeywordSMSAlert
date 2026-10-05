# Side/Power button hook research — iOS 15.4.1 / iPhone 12 / Dopamine-RootHide (SpringBoard tweak)

Goal: while our own alert (sound + vibration) plays, a physical press of the side/power button must
immediately stop the alert, the button must keep its normal lock/wake function, no polling, no
unstable private-API use.

Every claim below is labelled:

- `[VERIFIED-iOS15]` — evidence specific to iOS 15.x (iOS 15 class/ivar/symbol table, or a tweak that
  explicitly supports iOS 15)
- `[VERIFIED-GENERIC]` — evidence from another iOS version or a version-agnostic source
- `[UNVERIFIED]` — my inference; explicitly flagged, must be confirmed on device

---

## 0. Evidence base (and what I could NOT verify)

I could not obtain an iOS 15.4.1 method-level class-dump. `developer.limneos.net` is Cloudflare-gated
for every iOS version I tried (15.0/15.2.1/15.4/15.4.1/15.5/15.6) and no public "iOS 15 Runtime Headers"
dump is indexed anywhere I could reach. What I did obtain:

| Source | iOS version | What it proves | Label |
|---|---|---|---|
| [`xybp888/iOS-SDKs` iPhoneOS15.2.sdk SpringBoard.tbd](https://github.com/xybp888/iOS-SDKs/blob/master/iPhoneOS15.2.sdk/System/Library/PrivateFrameworks/SpringBoard.framework/SpringBoard.tbd) | **15.2** | exported class symbols + ObjC ivars | `[VERIFIED-iOS15]` |
| [`xybp888/iOS-SDKs` iPhoneOS15.6.sdk SpringBoard.tbd](https://github.com/xybp888/iOS-SDKs/blob/master/iPhoneOS15.6.sdk/System/Library/PrivateFrameworks/SpringBoard.framework/SpringBoard.tbd) (also [`theos/sdks`](https://github.com/theos/sdks)) | **15.6** | exported class symbols + ObjC ivars | `[VERIFIED-iOS15]` |
| [`SparkDev97/iOS14-Runtime-Headers`](https://github.com/SparkDev97/iOS14-Runtime-Headers) (iOS 14.0 18A373, iPhone SE) | 14.0 | full method lists | `[VERIFIED-GENERIC]` (adjacent) |
| [`LeoNatan/Apple-Runtime-Headers` SpringBoard](https://github.com/LeoNatan/Apple-Runtime-Headers/blob/master/iOS/PrivateFrameworks/SpringBoard.framework/SBLockHardwareButton.h) (Xcode 11.6, iOS 13.6) | 13.6 | full method lists | `[VERIFIED-GENERIC]` |
| [`maximehip/Springboard`](https://github.com/maximehip/Springboard/blob/master/SBLockHardwareButton.h) | iOS 13 | full method lists | `[VERIFIED-GENERIC]` |
| [`MTACS/iOS-17-Runtime-Headers`](https://github.com/MTACS/iOS-17-Runtime-Headers/blob/main/PrivateFrameworks/SpringBoard.framework/SBSleepWakeHardwareButtonInteraction.h) | 17.x | method persistence | `[VERIFIED-GENERIC]` (newer) |
| Real tweaks (Lock-Master, RemoteCompanion, NineLS, GateToFreedom, PullOver-Pro, LittleXS, Neptune, LockButtonX) | 11 – 16 | what actually ships and works | see §2 |

**Practical consequence:** class existence + instance variables are verified on iOS 15.2 and 15.6
(iOS 15.4.1 sits between them, so structural drift is very unlikely). *Exact method signatures* on
15.4.1 are verified only indirectly (iOS 13.6 / 14.0 / 17.0 dumps all agree, and the 15.6 ivar set is
byte-for-byte consistent with the 14.0 ivar set). Every method name below should be re-confirmed with
`class-dump` of the device's SpringBoard if you want 100% certainty — the deliverable flags exactly
where that matters.

---

## 1. The real side/power-button chain in iOS 15 SpringBoard

### 1.1 Verified skeleton (unchanged from iOS 13 → 17)

```
IOHIDEvent (kernel) → backboardd / BackBoardServices
      ↓ UIKit UIPress (pressType Lock = 104)
SBPressGestureRecognizer  (UIGestureRecognizer subclass, -pressesBegan:withEvent:)
      ↓ target/action
SBLockHardwareButton            ← owns all the gesture recognizers
      - buttonDown:            (press DOWN)
      - singlePress: / doublePress: / triplePress: / quadruplePress: / longPress:  (press UP / hold)
      ↓
SBLockHardwareButtonActions     ← the policy/action object
      - performInitialButtonDownActions   (DOWN)
      - performSecondButtonDownActions    (2nd DOWN in a sequence)
      - performInitialButtonUpActions / performButtonUpPreActions / performFinalButtonUpActions (UP)
      - performSinglePressAction / performSinglePressDidFailActions / performDoublePressActions /
        performTriplePressActions / performLongPressActions / performLongPressCancelledActions
      - performSOSGestureBeganActions / performSOSGestureEndedActions / performForceResetSequenceBeganActions
      ↓ (sub-interactions consulted per press, protocol SBHardwareButtonInteraction)
SBSleepWakeHardwareButtonInteraction   ← sleep/wake policy
      - (BOOL)consumeInitialPressDown   (DOWN, every press)
      - (BOOL)consumeSinglePressUp      (UP)
      - (void)_performSleep  /  - (void)_performWake
      - (void)_playLockSound  /  - (BOOL)reverseSleepIfNeededAndPossible
      ↓
SBLockScreenManager  - (void)lockUIFromSource:(int)withOptions:(id)      … lock (sleep)
SBBacklightController - screenIsOn / turnOnScreenFullyWithBacklightSource: / turnOnScreenIsUserAction: … wake
SBScreenWakeAnimationController / SBSoundController                      … side effects
```

Class/ivar evidence on **iOS 15** (`[VERIFIED-iOS15]`, iPhoneOS15.2 + 15.6 SpringBoard.tbd):

- `SBLockHardwareButton` — 18 ivars, incl. `_buttonDownGestureRecognizer`, `_singlePressGestureRecognizer`,
  `_doublePressGestureRecognizer`, `_triplePressGestureRecognizer`, `_quadruplePressGestureRecognizer`,
  `_longPressGestureRecognizer`, `_shutdownGestureRecognizer`, `_screenshotGestureRecognizer`,
  `_currentPressCount`, `_configuredMaximumPressCount`, `_lastPressDownReferenceTime`, `_buttonActions`.
- `SBLockHardwareButtonActions` — 15 ivars, incl. `_sleepWakeButtonInteraction`, `_siriButtonInteraction`,
  `_accessibilityButtonInteraction`, `_proximitySensorButtonInteraction`, `_sosManager`, `_isButtonDown`,
  `_lastLockButtonEventRecipient`, `_hardwareButtonService`.
- `SBSleepWakeHardwareButtonInteraction` — 13 ivars, **identical set to the iOS 14.0 header**:
  `_backlightController`, `_lockScreenManager`, `_screenWakeAnimationController`, `_soundController`,
  `_HIDInterface`, `_SBApp`, `_inhibitNextSinglePressUp`, `_SOSGestureActive`,
  `_fadeOutInProgressFromLockButtonWhileUnlocked`, `_undidFadeOutFromLockButton`, `_didPlayLockSound`,
  `_multiplePressTimeInterval`, `_deferOrientationUpdatesAssertion`.
- `SBDoubleClickSleepWakeHardwareButtonInteraction` also present in 15.2/15.6.
- `SBPressGestureRecognizer`, `SBPressCollector`, `SBCameraHardwareButton`,
  `SBHIDValueModifyingButtonSetArbiter` present.

Method evidence (`[VERIFIED-GENERIC]`, identical in iOS 13.6, 14.0 and 17.x dumps):

```objc
// SBLockHardwareButton (iOS 14.0 header, methods)
- (void)buttonDown:(id)sender;          // DOWN
- (void)singlePress:(id)sender;         // UP (single click recognised)
- (void)doublePress:(id)sender;  - (void)triplePress:(id)sender;
- (void)quadruplePress:(id)sender; - (void)longPress:(id)sender;
- (BOOL)isButtonDown;

// SBLockHardwareButtonActions (iOS 14.0 header, methods)
- (void)performInitialButtonDownActions;
- (void)performSecondButtonDownActions;
- (void)performInitialButtonUpActions;
- (BOOL)performButtonUpPreActions;
- (void)performFinalButtonUpActions;
- (void)performSinglePressAction;
- (void)performLongPressActions;
- (BOOL)disallowsSinglePressForReason:(id *)reason;

// SBSleepWakeHardwareButtonInteraction (iOS 14.0 header, methods)
- (BOOL)consumeInitialPressDown;
- (BOOL)consumeSinglePressUp;
- (void)_performWake;
- (void)_performSleep;
- (void)_playLockSound;
- (BOOL)reverseSleepIfNeededAndPossible;

// SBLockScreenManager
- (void)lockUIFromSource:(int)source withOptions:(id)options;                 // iOS 14.0
- (void)lockUIFromSource:(int)source withOptions:(id)options completion:(id)completion; // iOS 13.6
- (BOOL)unlockUIFromSource:(int)source withOptions:(id)options;
- (void)remoteLock:(BOOL)remote;  - (void)activateLostModeForRemoteLock:(BOOL)remote;
```

### 1.2 DOWN vs UP, and screen on vs screen off

| Method | Fires when | Screen ON (sleep case) | Screen OFF (wake case) |
|---|---|---|---|
| `SBLockHardwareButton -buttonDown:` | press **down** | yes | yes `[UNVERIFIED]` (gesture recognizer is state-agnostic) |
| `SBLockHardwareButtonActions -performInitialButtonDownActions` | press **down** | yes | yes — **supported** by RemoteCompanion's own suppression comment, see below |
| `SBSleepWakeHardwareButtonInteraction -consumeInitialPressDown` | press **down** | yes | yes `[UNVERIFIED]`, strongly implied: this is the object that *performs the wake*, so it must be consulted on the down event while the display is off |
| `… -consumeSinglePressUp` / `_performSleep` | press **up** (single click) | `_performSleep` | `_performWake` `[UNVERIFIED]` (same class, same call site) |
| `… -_performWake` | press down/up (the wake) | no | yes |
| `SBLockScreenManager -lockUIFromSource:withOptions:` | when the UI locks | **yes** | **no** — waking does not "lock UI"; the wake path goes to `SBBacklightController`/`SBScreenWakeAnimationController` (`[UNVERIFIED]` inference from the class split, but no evidence anywhere that `lockUIFromSource:` is used to wake) |
| `SBBacklightController -turnOnScreenIsUserAction:` | screen turns on | no | yes (also tap-to-wake / raise-to-wake) |

The strongest *third-party* statement about the down-hook covering both directions is in
`saihgupr/remotecompanion` (a modern Activator replacement, `TARGET := iphone:clang:latest:14.0`,
README "Supported: iOS 15+", Makefile supports `THEOS_PACKAGE_SCHEME=roothide`), which hooks
`SBLockHardwareButtonActions -performInitialButtonDownActions` for its power-button triggers and writes:

> "SUPPRESSION: If a multi-click sequence is in progress, swallow the DOWN event for 2nd click onwards.
> **This stops the phone from waking/locking on subsequent clicks while allowing single-tap %orig.**"
> — [`Tweak/Tweak.x:10895-10900`](https://github.com/saihgupr/remotecompanion/blob/main/Tweak/Tweak.x)

and in its changelog:

> "restoring immediate native `%orig` handling when unassigned … Power long press handling now checks
> whether `power_long_press` is actively enabled before intercepting `performLongPressActions`, allowing
> standard lock and system behavior to proceed without latency or sensor blocking."
> — [`CHANGELOG.md`](https://github.com/saihgupr/remotecompanion/blob/main/CHANGELOG.md)

i.e. suppressing `%orig` in that one method suppresses **both** waking and locking → the method is on
the path in **both** screen states. `[VERIFIED-GENERIC]` (iOS 14–16 code; the class+ivars are
`[VERIFIED-iOS15]`).

### 1.3 Corrections to the hypotheses in the brief

- **`SBHIDButtonStateArbiter` is not on the side-button path.** In the iOS 13.6 and iOS 14.0 dumps the
  *only* conformers of `SBHIDButtonStateDelegate` are `SBCameraHardwareButton` (`_buttonArbiter`) and
  `SBHIDValueModifyingButtonSetArbiter`. The iOS 15.6 symbol table shows the same ivars
  (`SBCameraHardwareButton._buttonArbiter`, `SBHIDValueModifyingButtonSetArbiter._currentDownButton`).
  It is the camera-shutter / value-modifying (volume) arbiter, not the lock button. `[VERIFIED-iOS15]`
  (ivar proof) + `[VERIFIED-GENERIC]` (protocol conformers).
- **`SBHIDEventDispatchController` does not exist on iOS 15.** `grep` of the iPhoneOS**15.2** and
  **15.6** SpringBoard symbol tables returns 0 hits; it first appears in **iPhoneOS16.1.sdk**. It cannot
  be used on 15.4.1. `[VERIFIED-iOS15]`
- **`SBUIController` is not the lock-button entry point** on iOS 13/14 (only home-button handling,
  reachability, charging chime). The pre-iOS-11 `SBUIController`/`SBAwayController` route is gone.
- **There is no `SBLockSourcePowerButton`-style public constant to switch on**; `lockUIFromSource:`
  takes a raw `int`, and `SBLockScreenUnlockRequest.source` is a raw `int` too (iOS 13.6/14.0 headers).

---

## 2. Real tweak source code that reacts to the side/power button

| Tweak | iOS target | exact Logos hook | URL |
|---|---|---|---|
| **Lock-Master** (leminlimez, 2024, active) | `TARGET := iphone:clang:15.0:14.0`, README "Supports iOS 14.0+", `INSTALL_TARGET_PROCESSES = SpringBoard` | `%hook SBSleepWakeHardwareButtonInteraction` → `- (void)_playLockSound` | [Tweak.x:241](https://github.com/leminlimez/Lock-Master/blob/main/Tweak.x) |
| **RemoteCompanion** (saihgupr, roothide+rootless, "modern Activator replacement") | `TARGET := iphone:clang:latest:14.0`, README "Supported: iOS 15+", control `Depends: mobilesubstrate` | `%hook SBLockHardwareButtonActions` → `performInitialButtonDownActions`, `performButtonUpPreActions`, `performLongPressActions`, `performDoublePressActions`; also `%hook SBLockHardwareButton` → `- (void)doublePress:` | [Tweak.x:10835](https://github.com/saihgupr/remotecompanion/blob/main/Tweak/Tweak.x) |
| **NineLS** (minh-ton) | `TARGET := iphone:clang::13.3` | `%hook SBSleepWakeHardwareButtonInteraction` → `- (void)_playLockSound` | [NineLS.xm:1381](https://github.com/minh-ton/NineLS/blob/main/NineLS.xm) |
| **CustomSounds13** (moj3ve) | iOS 13 | `%hook SBSleepWakeHardwareButtonInteraction` → `- (void)_playLockSound` | [Tweak.xm:88](https://github.com/moj3ve/CustomSounds13/blob/master/Tweak.xm) |
| **JellyLock-Reborn** (MegaDevIOS) | `TARGET=iphone:clang:13.3:13.3` | declares `@interface SBSleepWakeHardwareButtonInteraction` with `-(void)_performSleep; -(void)_performWake;` | [headers.h:25](https://github.com/MegaDevIOS/JellyLock-Reborn/blob/master/headers.h) |
| **LockButtonX** (NightwindDev, Swift + Orion, 2024) | `TARGET := iphone:clang:latest:12.2`, `ARCHS = arm64 arm64e` | `ClassHook<SBLockHardwareButtonActions>` → `performLongPressActions` | [Tweak.x.swift](https://github.com/NightwindDev/LockButtonX/blob/main/Sources/LockButtonX/Tweak.x.swift) |
| **GateToFreedom** (pixelomer) | iOS 11.2 | `%hook SBLockHardwareButton` → `- (void)singlePress:(id)` | [Tweak.xm:182](https://github.com/pixelomer/GateToFreedom/blob/master/Tweak.xm) |
| **PullOver-Pro** (c1d3rdev) | iOS 13/14 | `%hook SBLockHardwareButton` → `- (void)singlePress:(id)` | [PullOverPro.xm:102](https://github.com/c1d3rdev/PullOver-Pro/blob/main/PullOverPro/PullOverPro.xm) |
| **LittleXS / Neptune / Little11 / Little12 / HalFiPad** | iOS 11–14 | `%hook SBLockHardwareButtonActions` (init remap), `%hook SBLockHardwareButton` (`initWithScreenshotGestureRecognizer:…`) | [LittleXS](https://github.com/alexcpr/LittleXS/blob/master/Tweak.xm), [Neptune](https://github.com/duraidabdul/Neptune/blob/master/neptune/Tweak.xm) |
| **libactivator** (headers only — Activator's own source is not public) | — | event names only: `LAEventNameLockHoldShort`, `LAEventNameLockHoldLong`, `LAEventNameLockPressDouble`, `LAEventNameLockPressWithMenu` — **note: there is no `…LockPressSingle`**, i.e. Activator deliberately never claims a plain single press | [LAEvent.h:25-28](https://github.com/rpetrich/libactivator/blob/headers/LAEvent.h) |

Note what the ecosystem converges on: for the *power button*, working tweaks hook
`SBSleepWakeHardwareButtonInteraction` (side-effect observation) or
`SBLockHardwareButtonActions` (press observation) — not `SBHIDButtonStateArbiter`, not the raw HID path.
`GateToFreedom`'s README also documents that a `SBLockHardwareButton -singlePress:` hook can be
bypassed ("The user can escape the setup by either pressing power button 5 times in a row if SOS is
enabled or by holding the power button") — a warning against single-method, high-level hooks.

---

## 3. Safest hook that fires on every physical press, both screen states

**Primary recommendation: `SBSleepWakeHardwareButtonInteraction - (BOOL)consumeInitialPressDown`.**

Why:

1. It is called on the **down** event for **every** press (it is an `SBHardwareButtonInteraction`
   protocol member, polled by `SBLockHardwareButtonActions -performInitialButtonDownActions`; see the
   protocol in [SBHardwareButtonInteraction.h (iOS 14.0)](https://github.com/SparkDev97/iOS14-Runtime-Headers/blob/master/PrivateFrameworks/SpringBoard.framework/SBHardwareButtonInteraction.h)).
   The same protocol's other members (`consumeSinglePressUp`, `consumeLongPress`, `consumeTriplePressUp`
   …) are the up/sequence variants.
2. It is the **same object** that implements `_performWake` and `_performSleep`
   ([iOS 14.0 header](https://github.com/SparkDev97/iOS14-Runtime-Headers/blob/master/PrivateFrameworks/SpringBoard.framework/SBSleepWakeHardwareButtonInteraction.h),
   [iOS 13.6 header](https://github.com/LeoNatan/Apple-Runtime-Headers/blob/master/iOS/PrivateFrameworks/SpringBoard.framework/SBLockHardwareButton.h),
   [iOS 17 header](https://github.com/MTACS/iOS-17-Runtime-Headers/blob/main/PrivateFrameworks/SpringBoard.framework/SBSleepWakeHardwareButtonInteraction.h),
   class+13 ivars `[VERIFIED-iOS15]` in 15.2/15.6). Since the side button *must* be able to wake the
   display while the display is off, and this class owns `_performWake`, the class is consulted in the
   screen-off case too. **That is the single strongest structural argument that the high-level button
   path is not skipped while asleep** — but it remains an inference (`[UNVERIFIED]`) until measured.
3. It returns `BOOL`; `return %orig;` keeps the native consume/no-consume decision → zero behaviour
   change, so lock/wake is untouched.

**Equally safe and even better attested in the wild: `SBLockHardwareButtonActions -performInitialButtonDownActions`.**
RemoteCompanion drives its whole power-button trigger set from exactly this method on iOS 14–16
(including roothide), and its changelog documents both the wake/lock suppression effect and the
latency bug you must avoid.

**Also fine: `SBLockHardwareButton - (void)buttonDown:`** — the gesture-recognizer action for down.
It exists in every dump from iOS 13 through iOS 17 and its recognizer ivar
(`_buttonDownGestureRecognizer`, an `SBPressGestureRecognizer`) is present in the iOS 15.6 symbol
table, so the recognizer is still wired on 15.x. Because it is the *button-down recognizer* (not the
click recognizer) it is not subject to the "single press disallowed" logic (see §4).

**What to avoid for this requirement:**

- `SBLockScreenManager -lockUIFromSource:withOptions:` — fires only for the **sleep/lock** case, misses
  the wake case entirely, and fires for non-physical locks (see §4).
- `SBLockHardwareButton -singlePress:` — fires on press **up** (less immediate) and can be disallowed or
  consumed by SOS / Siri / accessibility / a registered foreground app. GateToFreedom's README
  documents a real bypass of this hook.
- `SBHIDButtonStateArbiter -processEvent:` — wrong button family (camera/volume arbiter) and requires
  decoding raw `IOHIDEvent` values.
- `SBHIDEventDispatchController` — **does not exist on iOS 15**.
- `IOHIDEventSystemClient` observation from SpringBoard — requires HID client entitlements and is the
  route most likely to hit sandbox/entitlement failures or instability; RemoteCompanion uses
  `IOHIDEventSystemClient` only to *inject* events, never to observe the power button (it uses the ObjC
  hook instead).

---

## 4. Reacting without consuming the event, and known pitfalls

**Do not consume.**
- `void` hooks (`buttonDown:`, `performInitialButtonDownActions`): do your work, then call `%orig`.
- `BOOL` hooks (`consumeInitialPressDown`, `consumeSinglePressUp`): do your work, then `return %orig;`.
- Never return `YES`/`NO` by hand from a `consume*` method — that *is* the consumption decision.

**Pitfalls, with evidence:**

1. **Multiple invocations per press.** A press produces down + up, and possibly several gesture
   recognizers firing (`buttonDown:`, then `singlePress:`/`doublePress:` …). SOS presses
   (`performSOSGestureBeganActions`, ivar `_SOSGestureActive` on 15.6) and force-reset
   (`performForceResetSequenceBeganActions`) go through the same objects. Make "stop the alert"
   idempotent and throttle it (one stop per N ms).
2. **Latency = broken lock/wake.** If your hook is slow, the native action is delayed. RemoteCompanion's
   changelog records exactly this class of bug ("pressing the power button to lock the screen was
   unresponsive or delayed", "restoring immediate native `%orig` handling"). Do the minimum inside the
   hook; `dispatch_async` heavier teardown.
3. **Threading.** `SBPressGestureRecognizer` is a `UIGestureRecognizer` subclass, so its target/actions
   (`buttonDown:`, `singlePress:`) run on the **main thread**, and `SBLockHardwareButtonActions` /
   `SBSleepWakeHardwareButtonInteraction` are invoked synchronously from there. That is an inference
   from the class hierarchy (`[UNVERIFIED]` for guaranteed threading) — RemoteCompanion calls
   `NSTimer scheduledTimerWithTimeInterval:` and its trigger code directly from inside these hooks,
   which only works reliably on a run-loop thread. Treat it as main-thread, but if you stop audio with
   AVFoundation/AudioToolbox, do it on the main queue and keep it non-blocking.
4. **Non-physical locks route elsewhere.** `lockUIFromSource:withOptions:` is also called by
   Accessibility/AssistiveTouch: `AXSBLockScreenManager - (void)lockUIFromSource:(int)withOptions:(id)`
   exists in `AXSpringBoardServerInstance.framework`
   ([iOS 14.0 header](https://github.com/SparkDev97/iOS14-Runtime-Headers/blob/master/PrivateFrameworks/AXSpringBoardServerInstance.framework/AXSBLockScreenManager.h)) —
   so a `SBLockScreenManager` hook fires on an AssistiveTouch "Lock Screen" tap, which is not a
   hardware press. Remote lock / Find My has its own entries (`-remoteLock:`,
   `-activateLostModeForRemoteLock:`, iOS 14.0 header). Good news: the button-level hooks in §3 do not
   fire for those.
5. **Presses can be claimed by other parties.** Apps can register for lock-button events
   (`SBLockHardwareButtonActions -_sendButtonDownToRegisteredApp`, `SBHardwareButtonService`
   `-consumeLockButtonSinglePressUpWithPriority:` / `-hasConsumersForLockButtonPresses`, and the
   exported constant `_SBApplicationsRegisteredForLockButtonEventsChangedNotification` present in the
   iOS 15.2/15.6 symbol tables). Siri (`_siriButtonInteraction`), accessibility
   (`_accessibilityButtonInteraction`) and SOS (`_sosManager`) can also claim the press. This is why
   `singlePress:` is the least reliable hook and the **down** hooks are the right ones.
6. **Apple Pencil / AssistiveTouch back-tap / remote-lock** never go through `SBLockHardwareButton*`;
   do not rely on these hooks to catch them (and you don't need to).
7. **`SBHIDInterface` UI lock.** SpringBoard can suspend multitouch/proximity while the display is off
   (`SBHIDInterface -suspendMultitouchForSource:reason:`, `-suspendProximityDetectionAndMultitouchForSource:`),
   which is *not* a button-event suspension — another reason the button path keeps working while asleep
   (`[UNVERIFIED]`, but consistent with the class split).

---

## 5. Notification-based observation (no hook)?

**Darwin notifications (cross-process, observable from the tweak):**

| Name | Meaning | Press-down? |
|---|---|---|
| `com.apple.springboard.hasBlankedScreen` | carries a blank/unblank state; H5GG annotates it "黑屏" (screen off); the AXe test asserts state `1` after a side-button press | no — fires on blank state change only |
| `com.apple.springboard.lockstate` (+`lockcomplete`, `com.apple.springboard.DeviceLockStatusChanged`) | lock state changed | no |
| `com.apple.iokit.hid.displayStatus` | display status | no |

Sources: [The Apple Wiki — SpringBoard notifications](https://theapplewiki.com/wiki/Dev:SpringBoard.app/Notifications)
(these names are documented from iOS 2.0 onward, i.e. they persist), the
[H5GG `Tweak.mm` comment block](https://github.com/H5GG/H5GG/blob/master/Tweak.mm), and the
[AXe side-button test](https://github.com/cameroncooke/AXe/blob/main/Tests/ButtonTests.swift)
("A short side-button press should blank the simulator display", `hasBlankedScreen == 1`).

**NSNotifications exported by the iOS 15.2 and 15.6 SpringBoard binary** `[VERIFIED-iOS15]` (grep of the
symbol tables): `SBBlankScreenStateChangeNotification`, `SBLockScreenUIDidLockNotification`,
`SBLockScreenUIWillLockNotification` (+`…AnimatedKey`), `SBLockScreenUIRelockedNotification`,
`SBLockScreenDimmedNotification`, `SBLockScreenUndimmedNotification`,
`SBAggregateLockStateDidChangeNotification` (+`SBAggregateLockStateKey`),
`SBWorkspaceDidWakeFromSleepNotification`, `SBDeferredScreenUnblankCompletedNotification`,
`SBApplicationsRegisteredForLockButtonEventsChangedNotification`.

**Answer: there is no notification for the physical press itself.** In the iOS 15.2/15.6 SpringBoard
symbol tables the only lock-button-related notification is
`SBApplicationsRegisteredForLockButtonEventsChangedNotification` (fired when an app *registers* for
button events, not when the button is pressed). Also verified absent: any `…LockButtonPressed…` /
`…PowerButton…` notification constant.

**Closest hook-free observation path** (state change, not press): register as an observer on
`SBBacklightController` — `- (void)addObserver:(id)` with the
[`SBBacklightControllerObserver`](https://github.com/SparkDev97/iOS14-Runtime-Headers/blob/master/PrivateFrameworks/SpringBoard.framework/SBBacklightControllerObserver.h)
protocol (`backlightController:willAnimateBacklightToFactor:source:` / `didAnimateBacklightToFactor:source:`),
which is invoked with a backlight **source** value. It fires for sleep and wake but also for
idle auto-lock, tap-to-wake and raise-to-wake, so it cannot distinguish "power button" from "screen
changed for another reason". Same limitation as `hasBlankedScreen`.

Conclusion: for *"stop the alert on a power-button press"* a notification-only approach is possible
only if you accept "any screen state change" as the trigger; otherwise you must hook (§3).

---

## 6. SpringBoard stability / known crashes

Honest result: **I found no published crash report that names any of these hooks.** Searches for
`"SBLockHardwareButton" crash`, Safe-Mode reports and a `ActivatorCrashFix` source turned up nothing
verifiable; treat the "ActivatorCrashFix14" tweak (which exists for an iOS 14 Activator crash) as an
**unverified lead** — I could not show it involves the lock-button path.

What the available evidence does support:

- `SBLockHardwareButtonActions -performInitialButtonDownActions`, `SBLockHardwareButton -buttonDown:`
  and `SBSleepWakeHardwareButtonInteraction` hooks **ship in real tweaks on iOS 14–16** (RemoteCompanion
  roothide+rootless, Lock-Master, NineLS, CustomSounds13, JellyLock-Reborn, GateToFreedom,
  PullOver-Pro). The failure modes their changelogs describe are *latency and event suppression*, not
  crashes.
- Highest practical risk is **not** the hook itself but (a) blocking the main thread inside the hook
  (delays lock/wake → user-visible breakage), (b) returning a hand-picked `BOOL` from a `consume*`
  method (changes event routing), (c) hooking gesture-recognizer internals
  (`SBPressGestureRecognizer`, `SBClickGestureRecognizer`) or the HID/IOKit layer.
- Because `SBSleepWakeHardwareButtonInteraction` and `SBLockHardwareButtonActions` are singletons owned
  by SpringBoard and their methods are called on the main thread on every press, a crash inside them
  would make the device un-lockable/un-wakeable — which is precisely why the recommendation is to do
  the absolute minimum inside the hook and `dispatch_async` the teardown.
- Your environment (Dopamine **roothide** 2.4.9.27) is the same class of environment RemoteCompanion
  explicitly builds for (`THEOS_PACKAGE_SCHEME=roothide` in its Makefile), which is the closest
  real-world compatibility signal I could find.

---

## 7. Ranked recommendation table

| # | Approach | exact hook | Evidence | Fires on wake? | Fires on sleep? | Risk | URL |
|---|---|---|---|---|---|---|---|
| **1** | `SBSleepWakeHardwareButtonInteraction` — *observe the press, don't consume* | `%hook SBSleepWakeHardwareButtonInteraction`<br>`- (BOOL)consumeInitialPressDown { /* stop alert */ return %orig; }` | iOS 14.0 + iOS 17 + iOS 13.6 headers list the method; class + all 13 ivars identical in iPhoneOS**15.2** and **15.6** symbol tables; the same object owns `_performWake`/`_performSleep` | **yes** `[UNVERIFIED]` (inference: it is the wake owner, so it must be consulted on down while display is off) | **yes** (same mechanism) | **Very low** — BOOL but `%orig` preserved; `[VERIFIED-GENERIC]` for names, `[VERIFIED-iOS15]` for class/ivars | [hdr](https://github.com/SparkDev97/iOS14-Runtime-Headers/blob/master/PrivateFrameworks/SpringBoard.framework/SBSleepWakeHardwareButtonInteraction.h) · [15.6 tbd](https://github.com/xybp888/iOS-SDKs/blob/master/iPhoneOS15.6.sdk/System/Library/PrivateFrameworks/SpringBoard.framework/SpringBoard.tbd) |
| **2** | `SBLockHardwareButtonActions` — press-down action (best attested) | `%hook SBLockHardwareButtonActions`<br>`- (void)performInitialButtonDownActions { /* stop alert */ %orig; }` | Method in iOS 14.0 & iOS 17 headers; **shipped and working in RemoteCompanion** (iOS 14–16, roothide+rootless) whose changelog says suppressing `%orig` here stops *"waking/locking"*; class + 15 ivars `[VERIFIED-iOS15]` | **yes** (explicit third-party statement about waking) | **yes** | **Very low** | [Tweak.x:10835](https://github.com/saihgupr/remotecompanion/blob/main/Tweak/Tweak.x) · [hdr](https://github.com/SparkDev97/iOS14-Runtime-Headers/blob/master/PrivateFrameworks/SpringBoard.framework/SBLockHardwareButtonActions.h) |
| **3** | `SBLockHardwareButton` — button-down recognizer action | `%hook SBLockHardwareButton`<br>`- (void)buttonDown:(id)s { /* stop alert */ %orig; }` | Method in iOS 13 / 13.6 / 14.0 / 17 dumps; `_buttonDownGestureRecognizer` (SBPressGestureRecognizer) present in the iOS 15.6 symbol table → wiring unchanged on 15.x | probably yes `[UNVERIFIED]` | yes | **Low** | [14.0 hdr](https://github.com/SparkDev97/iOS14-Runtime-Headers/blob/master/PrivateFrameworks/SpringBoard.framework/SBLockHardwareButton.h) · [15.6 tbd](https://github.com/xybp888/iOS-SDKs/blob/master/iPhoneOS15.6.sdk/System/Library/PrivateFrameworks/SpringBoard.framework/SpringBoard.tbd) |
| 4 | `SBSleepWakeHardwareButtonInteraction` — observe the *effect* | `- (void)_performWake` **and** `- (void)_performSleep` (call `%orig`) | iOS 14.0/17/13.6 headers; declared in [JellyLock-Reborn headers.h](https://github.com/MegaDevIOS/JellyLock-Reborn/blob/master/headers.h); class hooked by [Lock-Master (iOS 14–15 SDK)](https://github.com/leminlimez/Lock-Master/blob/main/Tweak.x) and NineLS | yes | yes | **Very low** | [hdr](https://github.com/SparkDev97/iOS14-Runtime-Headers/blob/master/PrivateFrameworks/SpringBoard.framework/SBSleepWakeHardwareButtonInteraction.h) |
| 5 | Notification-only, no hook | Darwin `com.apple.springboard.hasBlankedScreen` / NSNotification `SBBlankScreenStateChangeNotification`, or `SBBacklightController -addObserver:` | Notification names documented since iOS 2.0 ([Apple Wiki](https://theapplewiki.com/wiki/Dev:SpringBoard.app/Notifications)); `_SBBlankScreenStateChangeNotification` exported in iPhoneOS**15.2** and **15.6** tbds | likely (state 0) `[UNVERIFIED]` | yes | **None** (no hook) | [AXe test](https://github.com/cameroncooke/AXe/blob/main/Tests/ButtonTests.swift) · [15.2 tbd](https://github.com/xybp888/iOS-SDKs/blob/master/iPhoneOS15.2.sdk/System/Library/PrivateFrameworks/SpringBoard.framework/SpringBoard.tbd) |
| 6 | `SBLockScreenManager` — the lock action | `%hook SBLockScreenManager`<br>`- (void)lockUIFromSource:(int)src withOptions:(id)o { … %orig; }` | Signature in iOS 13.6/14.0 headers; **wrong semantics for this use case** | **NO** (wake is not a "lock UI" action) `[UNVERIFIED]` but no contrary evidence | yes | Low, but **false positives**: also fires for AssistiveTouch (`AXSBLockScreenManager -lockUIFromSource:withOptions:`, iOS 14 header) and other programmatic locks | [14.0 hdr](https://github.com/SparkDev97/iOS14-Runtime-Headers/blob/master/PrivateFrameworks/SpringBoard.framework/SBLockScreenManager.h) · [AX hdr](https://github.com/SparkDev97/iOS14-Runtime-Headers/blob/master/PrivateFrameworks/AXSpringBoardServerInstance.framework/AXSBLockScreenManager.h) |
| 7 | `SBLockHardwareButton -singlePress:` | `- (void)singlePress:(id)` | Used by [GateToFreedom](https://github.com/pixelomer/GateToFreedom/blob/master/Tweak.xm) and [PullOver-Pro](https://github.com/c1d3rdev/PullOver-Pro/blob/main/PullOverPro/PullOverPro.xm) | unverified | yes | **Medium** — fires on press **up**, can be disallowed/consumed (`disallowsSinglePressForReason:`, SOS, Siri, registered apps); GateToFreedom README documents a bypass | [14.0 hdr](https://github.com/SparkDev97/iOS14-Runtime-Headers/blob/master/PrivateFrameworks/SpringBoard.framework/SBLockHardwareButton.h) |
| 8 | `SBHIDButtonStateArbiter -processEvent:` | `- (void)processEvent:(__IOHIDEvent *)e` | **Wrong path**: conformers are `SBCameraHardwareButton` and `SBHIDValueModifyingButtonSetArbiter` only (iOS 13.6/14.0), same ivars on 15.6 | n/a — not the side button | n/a | **Medium** (raw IOHIDEvent decoding) | [14.0 hdr](https://github.com/SparkDev97/iOS14-Runtime-Headers/blob/master/PrivateFrameworks/SpringBoard.framework/SBHIDButtonStateDelegate.h) |
| 9 | `SBHIDEventDispatchController` | — | **Does not exist on iOS 15**: 0 hits in iPhoneOS 15.2 and 15.6 SpringBoard tbds; first appears in iPhoneOS16.1.sdk | n/a | n/a | n/a — unusable | [15.6 tbd](https://github.com/xybp888/iOS-SDKs/blob/master/iPhoneOS15.6.sdk/System/Library/PrivateFrameworks/SpringBoard.framework/SpringBoard.tbd) |
| 10 | IOHIDEventSystemClient / BKHIDEvent observation in SpringBoard | — | No real tweak found doing this on iOS 15; the only iOS-15-era reference use is *injection*, not observation ([RemoteCompanion](https://github.com/saihgupr/remotecompanion/blob/main/Tweak/Tweak.x)); HID client access needs entitlements | unknown | unknown | **High** — exactly the "unstable private API" the brief wants to avoid | — |

**Recommended implementation: hook #1 *and* #2** (both are cheap, idempotent observers; if one is ever
skipped on a future firmware the other still fires), with #4 as a trivially safe third net if you also
want the sleep/wake effects.

---

## 8. Concrete Theos/Logos sketch (with the caveats above)

```objc
// Tweak.x  — SpringBoard
#import <Foundation/Foundation.h>

// --- private interface declarations (names evidence-cited above) ---
@interface SBSleepWakeHardwareButtonInteraction : NSObject
- (BOOL)consumeInitialPressDown;          // iOS 13.6 / 14.0 / 17 dumps; class verified on 15.2 + 15.6
@end

@interface SBLockHardwareButtonActions : NSObject
- (void)performInitialButtonDownActions;  // iOS 14.0 / 17 dumps; shipped hook in RemoteCompanion (iOS 14–16)
@end

extern void StopOurAlertOnHardwareButton(void);   // your own fast, idempotent, thread-safe stopper

%hook SBSleepWakeHardwareButtonInteraction
- (BOOL)consumeInitialPressDown {
    StopOurAlertOnHardwareButton();   // must be fast; dispatch_async heavier teardown
    return %orig;                     // never change the consume decision
}
%end

%hook SBLockHardwareButtonActions
- (void)performInitialButtonDownActions {
    StopOurAlertOnHardwareButton();
    %orig;                            // keep lock/wake exactly as-is
}
%end
```

Rules for `StopOurAlertOnHardwareButton()`:

1. no-op unless our alert is currently playing (idempotent, re-entrant-safe);
2. throttle to one stop per ~250 ms (a press fires down + up + possibly SOS/double-press paths);
3. `dispatch_async(dispatch_get_main_queue(), ^{ … })` for anything that touches AVFoundation,
   AudioToolbox or UI; keep the hook body itself µs-scale so lock/wake is never delayed;
4. wrap in `@try/@catch` — the method is on the lock/wake critical path.

### How to close the remaining `[UNVERIFIED]` items on the device (5 minutes)

Add temporary `NSLog` (or append to `/var/mobile/…/probe.log`) at the top of #1, #2, #3 and #4
(`_performWake` / `_performSleep`), then:

| Test | Expected |
|---|---|
| screen ON, unlocked, press side button once | #2 down-log, #3 down-log, #4 `_performSleep`, #1 twice |
| screen OFF (locked), press side button once | #2 down-log, #3 down-log (wake direction), #4 `_performWake` |
| screen ON, locked (cover sheet), press once | down-logs + `_performSleep` |
| AssistiveTouch → Lock Screen | **no** button logs (only `SBLockScreenManager -lockUIFromSource:` if you also probe it) |

That table answers "does the high-level hook miss the wake case" definitively for your exact
build — which is the one thing neither I nor any public source can settle without the device.
