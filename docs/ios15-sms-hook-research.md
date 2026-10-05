# Incoming SMS on iOS 15.4.1 (iPhone 12, arm64e, Dopamine RootHide) — real process/class/method chain

Target: iOS 15.4.1, arm64e, Dopamine RootHide 2.4.9.27 (roothide bootstrap).
Goal: detect an incoming **SMS** (not iMessage) as soon as it arrives, app closed, device locked.

Evidence levels used (as requested):
- **[VERIFIED-iOS15]** — from an iOS 15.x artefact (15.2.1 runtime-header listing, 15.6 runtime headers/SDK `.tbd`).
- **[VERIFIED-GENERIC]** — other iOS version or generic source.
- **[UNVERIFIED]** — my inference; explicitly flagged.

Primary sources used
- iOS **15.6** full runtime-header dump (ktool): <https://github.com/donato-fiore/iOS-Runtime-Headers> (browser: <https://headers.dfiore.xyz>). Raw path form: `15.6/PrivateFrameworks/<FW>.framework/Headers/<H>.h`.
- iOS **15.2.1** framework/class listing: <https://developer.limneos.net/index.php?ios=15.2.1&framework=IMDaemonCore.framework> (individual header pages are behind a Cloudflare Turnstile challenge and could not be fetched).
- iOS **15.6 / 15.2** SDK symbol lists: <https://github.com/theos/sdks>, <https://github.com/xybp888/iOS-SDKs>.
- Tweak sources: SMSNinja <https://github.com/iosre/SMSNinja>, NineLS <https://github.com/minh-ton/NineLS>, WebMessage <https://github.com/sgtaziz/WebMessage-Tweak>.
- Mach-O dumps: <https://github.com/blacktop/ipsw-diffs>.

---

## 1. Which process receives/stores an incoming SMS on iOS 15.4.1?

Chain (oldest → newest evidence in brackets):

| Stage | Process | Mechanism |
|---|---|---|
| baseband → raw SMS | **CommCenter** | class `SMSCTServer`, `- (void)_ingestIncomingCTMessage:(CTMessage *)` — tweak hook exists, comment `// incoming SMS` **[VERIFIED-GENERIC]** (iOS 5–8) |
| SMS service plugin | **imagent** | loads `/System/Library/Messages/PlugIns/SMS.imservice/SMS` via `-[IMDService loadServiceBundle]`; `SMSServiceSession : IMDServiceSession` handles it **[VERIFIED-GENERIC]**, plugin path still present on iOS 18/26 **[VERIFIED-GENERIC]** |
| message model / store | **imagent** | `IMDMessageStore`, `IMDChatRegistry`, `IMDChat` (IMDaemonCore framework) — all present in iOS 15.6 headers **[VERIFIED-iOS15]** |
| DB (`sms.db`) write | **imagent** | `IMDMessageStore -storeMessage:…` → IMDPersistence **[VERIFIED-iOS15]** for the class/methods; which exact process writes is **[UNVERIFIED]** but imagent owns the message pipeline |
| notification generation | **imagent** (in-process, IMDPersistence) | `IMDNotificationsController` posts `UNNotificationRequest` through `UNUserNotificationCenter` **[VERIFIED-iOS15]** |
| notification UI | **SpringBoard** | `NCBulletinNotificationSource` (BBObserverDelegate) converts `BBBulletin` → `NCNotificationRequest` **[VERIFIED-iOS15]** |

Candidate-by-candidate verdict:

| Candidate | Verdict | Identity evidence |
|---|---|---|
| **imagent** | **CONFIRMED** — receives *and* stores SMS | bundle id `com.apple.imagent` (label "Instant Message Agent") <https://theapplewiki.com/wiki/Services>; launchd job `/System/Library/LaunchDaemons/com.apple.imagent.plist` **[VERIFIED-GENERIC]** <https://github.com/quarkslab/iMITMProtect/tree/master/override/iOS6/System/Library/LaunchDaemons>; binary path `/System/Library/PrivateFrameworks/IMCore.framework/imagent.app/imagent` (class-dump "Image Source" on iOS 8.3 <https://github.com/ichitaso/iOS-iphoneheaders/blob/master/iOS8.3/System/Library/PrivateFrameworks/IMCore.framework/imagent.app/IMDaemon.h>, identical path on iOS 18/26 <https://github.com/blacktop/ipsw-diffs/blob/main/iOS/18_5_22F76__vs_26_0_23A5260n/MACHOS/imagent.md>). **Note: I found no iOS 15.4.1-specific filesystem listing**; `/usr/libexec/imagent` is *not* evidenced anywhere for iOS (0 code-search hits) — do not use that path. |
| **com.apple.imagent** (bundle id) | CONFIRMED as the imagent job label | as above |
| `/usr/libexec/imagent` | **REJECT** | no evidence found |
| **SMSd** | **REJECT / not found** | no such daemon found in any iOS source I checked |
| **commcenter** | REAL but not the SMS *store*: it is the telephony daemon that ingests the raw `CTMessage` (`SMSCTServer -_ingestIncomingCTMessage:`) before imagent | **[VERIFIED-GENERIC]** SMSNinja |
| **chatd** | Not evidenced on iOS 15 (referenced on macOS 13+/iOS 16+ only); nothing found tying it to SMS on 15.4.1 | **[UNVERIFIED]** — reject for this target |
| **IMDPersistenceAgent** | REAL XPC service, but it *serves the DB to clients* (ChatKit/Spotlight), not the SMS receiver: `com.apple.imdpersistence.IMDPersistenceAgent`, `/System/Library/PrivateFrameworks/IMDPersistence.framework/XPCServices/IMDPersistenceAgent.xpc/IMDPersistenceAgent` **[VERIFIED-GENERIC]** <https://github.com/PacktPublishing/Fuzzing-Against-the-Machine/blob/master/Chapter_10/setup-ios/launchd.plist> |
| **usernotificationsd** | Plausible broker for `UNNotificationRequest`, but **I could not verify its exact path/bundle id on iOS 15** | **[UNVERIFIED]** |
| **SpringBoard** | CONFIRMED it *renders* the notification (bulletin path, §3). It does **not** receive the raw SMS text first. | **[VERIFIED-iOS15]** for the classes |

**Who sees the raw text first:** CommCenter (`SMSCTServer`) → imagent (`SMSServiceSession`). On 15.4.1 the practical "first text + first store" process for a tweak is **imagent**.

Evidence that the plugin lives in imagent:
- SO answer: "imagent is started, he's loading several plugins. The one that we need is located in `/System/Library/Messages/PlugIns/SMS.imservice/` — this is where `SMSServiceSession` is implemented" <https://stackoverflow.com/questions/16219799/block-sms-on-ios6> **[VERIFIED-GENERIC]**
- `SMS.imservice/SMS` links `CoreTelephony`, references `_OBJC_CLASS_$_IMDServiceSession`, defines `LegacySMSServiceSession`/`SMSServiceSession` <https://github.com/blacktop/ipsw-diffs/blob/main/iOS/18_5_22F76__vs_26_0_23A5260n/MACHOS/SMS.md> **[VERIFIED-GENERIC]**
- iOS 7/8 headers: `@interface SMSServiceSession : IMDServiceSession` <https://github.com/ichitaso/iOS-iphoneheaders/blob/master/iOS8.2/System/Library/Messages/PlugIns/SMS.imservice/SMSServiceSession.h> **[VERIFIED-GENERIC]**

---

## 2. Concrete classes / selectors inside the SMS-receiving daemon

### 2a. SMS-specific (SMS.imservice plugin)

**There is no public iOS 15 dump of `SMS.imservice/SMS`** — this plugin is not in the dyld shared cache dump used by the 15.6 header repo (only `Frameworks/` and `PrivateFrameworks/` were dumped). So for the plugin's internals the best public evidence is old-iOS tweak code:

`%hook SMSServiceSession` (real tweak, real SMS text extraction) — SMSNinja, `libsmsninja/Deprecated.xm` line 227, package declares `firmware (>= 5.0)`:
```objc
%hook SMSServiceSession
- (void)_processReceivedMessage:(CTMessage *)message // incoming SMS
{
    id sender = message.sender;
    ...
    NSArray *items = message.items;
    for (CTMessagePart *part in items) {
        if ([part.contentType isEqualToString:@"text/plain"]) {
            NSString *string = [[NSString alloc] initWithData:part.data encoding:NSUTF8StringEncoding];
            text = [[text stringByAppendingString:string] stringByAppendingString:@" "];
        } ...
    }
    if (ActionOfTextFunctionWithInfo(addressArray, text, pictureArray, NO) == 0) %orig;
}
%end
```
<https://github.com/iosre/SMSNinja/blob/master/libsmsninja/Deprecated.xm> **[VERIFIED-GENERIC]** (iOS 5–8 era; file is literally called "Deprecated").

- `SMSServiceSession -_processReceivedMessage:` → holder of the incoming `CTMessage` with `sender`, `items` (`CTMessagePart.contentType` / `.data`).
- iOS 15.6 still ships the `CTMessage` model and `CTMessageCenter` with `allIncomingMessages`, `incomingMessageWithId:`, `simulateSmsReceived:` — <https://github.com/donato-fiore/iOS-Runtime-Headers/blob/main/15.6/Frameworks/CoreTelephony.framework/Headers/CTMessageCenter.h> **[VERIFIED-iOS15]**. So `CTMessage`-based ingestion is *still* the mechanism in 15.x (the selector name `_processReceivedMessage:` on 15.4.1 itself is **[UNVERIFIED]**).

> ⚠️ **On your current source**: `KSASMSDetector.m` / `KeywordSMSAlert.xm` hook `SMSServiceSession -_convertCTMessageToDictionary:requiresUpload:` and `-_receivedSMSDictionary:requiresUpload:isBeingReplayed:` and read a dictionary with keys `h/co/g/k/m/w`. **I could not corroborate either selector or those keys in any public dump** (iOS 15.6 has no SMS.imservice dump; SMSNinja-era dumps only show `_processReceivedMessage:`). If those came from your own on-device tracing, they are *your* evidence, not public evidence — treat them as **[UNVERIFIED by external sources]**. The method-name-string scan in `KSALogSMSServiceSessionDiagnostics()` is the right way to confirm them on the device.

### 2b. Shared daemon pipeline (IMDaemonCore / IMDPersistence) — **iOS 15.6-verified signatures**

`IMDMessageStore` (IMDaemonCore) — the store writes, called for **both** SMS and iMessage:
```objc
+ (id)sharedInstance;
- (BOOL)canStoreMessage:(id)arg0 onService:(id)arg1;
- (BOOL)canStoreItem:(id)arg0 onService:(id)arg1;
- (id)storeItem:(id)arg0 forceReplace:(BOOL)arg1;
- (id)storeMessage:(id)arg0 forceReplace:(BOOL)arg1 modifyError:(BOOL)arg2 modifyFlags:(BOOL)arg3 flagMask:(NSUInteger)arg4;
- (id)storeMessage:(id)arg0 forceReplace:(BOOL)arg1 modifyError:(BOOL)arg2 modifyFlags:(BOOL)arg3 flagMask:(NSUInteger)arg4 updateMessageCache:(BOOL)arg5 calculateUnreadCount:(BOOL)arg6;
- (id)storeMessage:(id)arg0 forceReplace:(BOOL)arg1 modifyError:(BOOL)arg2 modifyFlags:(BOOL)arg3 flagMask:(NSUInteger)arg4 updateMessageCache:(BOOL)arg5 calculateUnreadCount:(BOOL)arg6 reindexMessage:(BOOL)arg7;
```
<https://github.com/donato-fiore/iOS-Runtime-Headers/blob/main/15.6/PrivateFrameworks/IMDaemonCore.framework/Headers/IMDMessageStore.h> **[VERIFIED-iOS15]**

`IMDServiceSession` (IMDaemonCore) — incoming-message delegation:
```objc
- (void)didReceiveMessage:(id)arg0 forChat:(id)arg1 style:(unsigned char)arg2 account:(id)arg3 fromIDSID:(id)arg4;
- (void)didReceiveMessage:(id)arg0 forChat:(id)arg1 style:(unsigned char)arg2 fromIDSID:(id)arg3;
- (BOOL)didReceiveMessages:(id)arg0 forChat:(id)arg1 style:(unsigned char)arg2 account:(id)arg3 fromIDSID:(id)arg4;
- (void)_blastDoorProcessingWithIMMessageItem:… (very long iOS 15 signature) ;
```
<https://github.com/donato-fiore/iOS-Runtime-Headers/blob/main/15.6/PrivateFrameworks/IMDaemonCore.framework/Headers/IMDServiceSession.h> **[VERIFIED-iOS15]**
Real tweak usage of that entry point (iMessage *and* SMS on iOS 5–8): SMSNinja `%hook IMDServiceSession - (void)didReceiveMessage:(id)message forChat:(NSString *)arg2 style:(unsigned char)arg3`, casting to `IMMessageItem`, reading `-body`, `-sender`, `-fileTransferGUIDs` <https://github.com/iosre/SMSNinja/blob/master/libsmsninja/Hook.xm> **[VERIFIED-GENERIC]**
Also `%hook IMDaemon - (void)_loadServices { %orig; %init(...); }` — the pattern for installing service-session hooks after the plugin loads. **[VERIFIED-GENERIC]**

`IMDChat` (IMDaemonCore) — useful for identifying an SMS chat, and it exposes the message:
```objc
@property (copy) NSString *chatIdentifier;
@property (retain) IMMessageItem *lastMessage;
- (BOOL)isSMS;
- (BOOL)isSMSSpam;
```
<https://github.com/donato-fiore/iOS-Runtime-Headers/blob/main/15.6/PrivateFrameworks/IMDaemonCore.framework/Headers/IMDChat.h> **[VERIFIED-iOS15]**

`IMItem` / `IMMessageItem` (IMSharedUtilities) — the payload you get in `storeMessage:`:
```objc
// IMItem
@property (retain) NSString *guid;      @property (retain) NSString *sender;
@property (retain) NSString *service;   @property (retain) NSDate *time;
@property (readonly) BOOL isFromMe;     @property NSInteger messageID;
// IMMessageItem : IMItem
@property (retain) NSAttributedString *body;   @property (retain) NSString *plainBody;
@property (retain) NSString *subject;          @property (readonly) NSArray *messageParts;
```
<https://github.com/donato-fiore/iOS-Runtime-Headers/blob/main/15.6/PrivateFrameworks/IMSharedUtilities.framework/Headers/IMItem.h> ·
<https://github.com/donato-fiore/iOS-Runtime-Headers/blob/main/15.6/PrivateFrameworks/IMSharedUtilities.framework/Headers/IMMessageItem.h> **[VERIFIED-iOS15]**
→ body text **and** a stable `guid` in one object.

`IMDNotificationsController` (IMDPersistence) — generates the user notification (see §3):
```objc
+ (id)sharedInstance;
- (void)postNotificationsWithContext:(id)arg0;
- (void)_registerUserNotificationsForMessageRecords:(id)arg0 newerThanDate:(NSInteger)arg1 areUrgentMessages:(BOOL)arg2 isCarouselUITriggered:(BOOL)arg3 isMostActiveDevice:(BOOL)arg4;
- (BOOL)_shouldPostNotificationForChat:(id)arg0 messageDictionary:(id)arg1;
- (id)_messageDictionaryForMessageRecord:(?)arg0;
```
<https://github.com/donato-fiore/iOS-Runtime-Headers/blob/main/15.6/PrivateFrameworks/IMDPersistence.framework/Headers/IMDNotificationsController.h> **[VERIFIED-iOS15]**; class symbol also in the iPhoneOS 15.2 and 15.6 SDKs: <https://github.com/theos/sdks/blob/master/iPhoneOS15.6.sdk/System/Library/PrivateFrameworks/IMDPersistence.framework/IMDPersistence.tbd> **[VERIFIED-iOS15]**

### 2c. Tweak sources searched for iOS 14/15 SMS hooks (result of the requested survey)
- `%hook IMDaemonCore` — **no such class**. `IMDaemonCore` is a *framework*, not a class (0 hits for a class of that name in the 15.6 dump/limneos listing). Do not hook it.
- `%hook IMDMessageStore` — **no public tweak found** (0 code-search hits). Only SMSNinja hooks the neighbouring `IMDChatRegistry`/`IMDChatStore`.
- `%hook IMChat` / `IMChatRegistry` (IMCore, client side, not the daemon): WebMessage tweak <https://github.com/sgtaziz/WebMessage-Tweak/blob/master/libwebmessage/Tweak.x> (`__kIMChatMessageReceivedNotification`, userInfo key `__kIMChatValueKey`, `IMMessage`), WebMessage only works in a process that has an IMCore chat registry. **[VERIFIED-GENERIC]**
- Spam-filter / forwarder tweaks found: **SMSNinja** (real `SMSServiceSession` / `IMDServiceSession` hooks, iOS 5–8) <https://github.com/iosre/SMSNinja>; **WifiSMS** (iOS 6) <https://github.com/jlippold/WifiSMS>; **smserver** (iOS 13/14, IMCore-based send/receive documented in its `docs/`) <https://github.com/itsjunetime/smserver>. Modern "SMS forwarder" tweaks (TrollForwarder, VE Enhanced) are notification-forwarders, not daemon SMS hooks. **I found no tweak in the wild that hooks an iOS 14/15 SMS daemon entry point with published source.**

---

## 3. SpringBoard / bulletin (notification) path

Verified iOS 15.6 facts:

- `BBBulletin` carries **both the body text and a stable identity plus the section id**:
  `@property (copy) NSString *sectionID; @property (copy) NSString *message; @property (copy) NSString *title; @property (copy) NSString *subtitle; @property (copy) NSString *bulletinID; @property (copy) NSString *publisherBulletinID; @property (copy) NSString *threadID; @property (retain) NSDate *date;`
  <https://github.com/donato-fiore/iOS-Runtime-Headers/blob/main/15.6/PrivateFrameworks/BulletinBoard.framework/Headers/BBBulletin.h> **[VERIFIED-iOS15]**
- `NCBulletinNotificationSource` (UserNotificationsUIKit) implements `BBObserverDelegate` and is what turns bulletins into notification requests in the UI process:
  ```objc
  - (void)observer:(id)arg0 addBulletin:(id)arg1 forFeed:(NSUInteger)arg2;
  - (void)observer:(id)arg0 addBulletin:(id)arg1 forFeed:(NSUInteger)arg2 playLightsAndSirens:(BOOL)arg3 withReply:(id)arg4;
  - (void)observer:(id)arg0 modifyBulletin:(id)arg1 forFeed:(NSUInteger)arg2;
  - (id)_notificationRequestForBulletin:… (private helpers around sectionInfoById / uuidsToRequests)
  ```
  <https://github.com/donato-fiore/iOS-Runtime-Headers/blob/main/15.6/PrivateFrameworks/UserNotificationsUIKit.framework/Headers/NCBulletinNotificationSource.h> **[VERIFIED-iOS15]**; class symbol present in the iPhoneOS 15.2/15.6 SDKs (`UserNotificationsUIKit.tbd`) **[VERIFIED-iOS15]**; it appears as a SpringBoard entitlement `com.apple.springboard.NCBulletinNotificationSource` in Serotonin's SpringBoard entitlements <https://github.com/SerotoninApp/Serotonin/blob/main/RootHelperSample/launchdshim/generalhook/SpringBoardEnts.plist> **[VERIFIED-GENERIC]**
- `UNNotificationRequest` / `UNUserNotificationCenter` exist in the 15.6 SDK <https://github.com/donato-fiore/iOS-Runtime-Headers/blob/main/15.6/Frameworks/UserNotifications.framework/Headers/UNNotificationRequest.h> **[VERIFIED-iOS15]**, and `IMDNotificationsController` holds a `UNUserNotificationCenter` — i.e. iOS 15 posts messages notifications through the UserNotifications path, not only raw BBDataProvider.
- **Section id for Messages**: `com.apple.MobileSMS` is the Messages bundle identifier. The only public code I found that uses it *as a bulletin sectionID* is NineLS (a banner/lock-screen emulation tweak):
  ```objc
  bulletin.sectionID = sectionID;                 // @"com.apple.MobileSMS"
  bulletin.publisherBulletinID = [[NSProcessInfo processInfo] globallyUniqueString];
  [bbServer publishBulletin:bulletin destinations:15];
  ```
  <https://github.com/minh-ton/NineLS/blob/main/NineLS.xm> **[VERIFIED-GENERIC]**. I did **not** find an iOS 15 SMS-specific dump proving the exact section id string of a real SMS bulletin; treat "section id == com.apple.MobileSMS" as **[VERIFIED-GENERIC]/high confidence**, not iOS-15-verified.
- **Legacy/older SpringBoard classes** (`SBBulletinBannerController`, `SBBulletinListController`, `SBLockScreenBulletinViewController`, `SBNotificationCenterController`, `SBBulletinBannerController -observer:addBulletin:forFeed:`) are documented in iOS 8/9 SpringBoard header dumps and ~2013–2015 notification tweaks (ColorBanners, HaptikCenter, Roundification) — **[VERIFIED-GENERIC]**. **No iOS 15 header dump of SpringBoard.app was available to me** (SpringBoard is not in the shared-cache framework dumps), so I cannot give you iOS-15-verified SpringBoard method signatures. Do not hard-code them; discover them at runtime.
- Does it fire when locked / screen off? Bulletins are delivered to the BBObserver regardless of lock state (that is what the lock-screen bulletin UI consumes). **[UNVERIFIED]** for the *general* statement; the existence of `allowsAddingToLockScreenWhenUnlocked` / `inertWhenLocked` / `coalescesWhenLocked` on `BBBulletin` **[VERIFIED-iOS15]** shows lock-screen delivery is a first-class bulletin property.
- Does it fire when silenced / app open? Risk: **no**. `IMDNotificationsController -_shouldPostNotificationForChat:messageDictionary:` gates on DND/chat-mute/unknown-sender filtering, and when the conversation is on screen no user notification is produced — so no bulletin reaches SpringBoard. If the user turns Messages notifications off, or is inside the conversation, the bulletin hook silently misses the SMS. **[UNVERIFIED]** for the exact behaviour of every branch (the gating *methods* are iOS 15.6-verified; the conclusion that a suppressed notification means no bulletin is inference).
- **No tweak source was found that hooks bulletins for real SMS on iOS 14/15** — the bulletin approach is documented but unproven for this target.

---

## 4. Per-candidate assessment

| Hook point | Text? | Stable id for dedup? | Fires locked / app closed? | Risk |
|---|---|---|---|---|
| imagent `SMSServiceSession -_processReceivedMessage:` (CTMessage) | yes (`CTMessagePart.data`, contentType `text/plain`) | sender + `CTMessage` id (unsigned int), **no GUID** | yes | low–medium; selector **[UNVERIFIED]** for 15.4.1 |
| imagent `SMSServiceSession -_convertCTMessageToDictionary:requiresUpload:` / `-_receivedSMSDictionary:…` (your current hooks) | yes (dict `k`) | yes (dict `g` = GUID) | yes | low–medium; **selectors/keys unverified publicly** |
| imagent `IMDMessageStore -storeMessage:…` | yes (`IMMessageItem.body`/`plainBody`) | **yes** (`IMItem.guid`, `messageID`) | yes — independent of notification settings | medium (long signature, runs for every message; must filter `isFromMe` / `IMDChat.isSMS`) |
| imagent `IMDServiceSession -didReceiveMessage:forChat:style:…` | yes (`IMMessageItem`) | yes (`guid`) | yes | medium — may be overridden by `SMSServiceSession`; catch-all for iMessage+SMS |
| imagent `IMDNotificationsController -_registerUserNotificationsForMessageRecords:…` | yes (record) | yes (record id) | **only if a notification is actually posted** | medium; misses muted/foreground/filtered |
| SpringBoard `NCBulletinNotificationSource -observer:addBulletin:forFeed:` | yes (`BBBulletin.message`) | yes (`bulletinID`) | yes when a bulletin exists; **no bulletin ⇒ no hit** | medium–high (private, SpringBoard crash = respring) |
| SpringBoard banner/lock-screen controllers (UI level) | maybe (previews can be hidden) | yes | yes when shown | high (UI internals churn; missed when suppressed) |
| CommCenter `SMSCTServer -_ingestIncomingCTMessage:` | yes (rawest) | no GUID (`CTMessage` id) | yes | high (telephony daemon; class may have changed on 15.x) |
| Messages.app (`MobileSMS`) IMCore/ChatKit | yes | yes | **no** (app must run) | reject — violates your requirement |

---

## 5. Recommendation (ranked)

1. **imagent, `IMDMessageStore` (`-storeMessage:…` / `-storeItem:forceReplace:`)** — the only hook point that is *simultaneously* iOS-15-verified by signature, guaranteed to fire for every stored message regardless of notification/DND/UI state, and carries both `body` (text) and `guid` (dedup). Filter with `[item isFromMe] == NO` and either `item.service`/chat `-isSMS` (or `style == 45`) to exclude iMessage. Hook **all** `storeMessage:` overloads and dedup by `guid`, because the daemon may funnel through a different arity.
2. **Keep your existing `SMSServiceSession` hooks** (rawest, earliest text, gives GUID from the dictionary) **but verify the two selectors + dictionary keys on-device first**, and add the `IMDMessageStore` hook as a backstop — if Apple renamed the private SMS helpers in 15.4.1 they will silently never fire, and `KSALogSMSServiceSessionDiagnostics()` output is your ground truth.
3. **imagent, `IMDServiceSession -didReceiveMessage:forChat:style:account:fromIDSID:`** — good general backstop for both SMS and iMessage; be aware a subclass override could bypass a superclass hook.
4. **SpringBoard `NCBulletinNotificationSource -observer:addBulletin:forFeed:`** — acceptable as a *secondary* trigger (e.g. to play the alert sound in SpringBoard), **not** as the primary detector: it inherits all notification-suppression semantics.
5. Avoid: CommCenter/SMSCTServer (critical daemon, unverified class), SpringBoard UI/banner controllers, Messages.app hooks.

Why audio must stay in SpringBoard (already the design in your Makefile/plist): imagent owns no audio session; SpringBoard is the process that can play audio/vibrate and observe the hardware side button. The current split (detect in `imagent`, alert in `SpringBoard` via Darwin notification) is the correct architecture.

Two practical checks for the existing project (both **[UNVERIFIED]** — I had no device/ElleKit docs in this session):
- The filter plist currently uses `Filter → Bundles → com.apple.imagent`. For a daemon process the more robust key is usually `Filter → Executables → imagent` (or both). Verify that the tweak actually loads in imagent (`KSAInfo(@"loaded into %@", …)` log).
- `INSTALL_TARGET_PROCESSES = SpringBoard imagent` + `killall -9 imagent` will also kill the SMS/IM connection briefly; expect iMessage to reconnect after re-launch — that is normal.

---

## Final table

| Hook point (process) | class | method | evidence level | URL | gives text? | gives id? | locked/background? | risk |
|---|---|---|---|---|---|---|---|---|
| imagent | `SMSServiceSession` | `_processReceivedMessage:` (CTMessage) | VERIFIED-GENERIC (iOS 5–8 tweak; CTMessage model still in 15.6) | [SMSNinja Deprecated.xm](https://github.com/iosre/SMSNinja/blob/master/libsmsninja/Deprecated.xm) · [CTMessageCenter.h 15.6](https://github.com/donato-fiore/iOS-Runtime-Headers/blob/main/15.6/Frameworks/CoreTelephony.framework/Headers/CTMessageCenter.h) | yes | partial (CTMessage id, no GUID) | yes | low–med |
| imagent | `SMSServiceSession` | `_convertCTMessageToDictionary:requiresUpload:` | UNVERIFIED (your on-device tracing; not in any public dump) | — | yes | yes (`g`) | yes | low–med |
| imagent | `SMSServiceSession` | `_receivedSMSDictionary:requiresUpload:isBeingReplayed:` | UNVERIFIED (same) | — | yes | yes (`g`) | yes | low–med |
| imagent | `IMDServiceSession` | `didReceiveMessage:forChat:style:account:fromIDSID:` | VERIFIED-iOS15 (signature) + VERIFIED-GENERIC (tweak hook) | [IMDServiceSession.h 15.6](https://github.com/donato-fiore/iOS-Runtime-Headers/blob/main/15.6/PrivateFrameworks/IMDaemonCore.framework/Headers/IMDServiceSession.h) · [SMSNinja Hook.xm](https://github.com/iosre/SMSNinja/blob/master/libsmsninja/Hook.xm) | yes | yes (`IMItem.guid`) | yes | medium |
| imagent | `IMDMessageStore` | `storeMessage:forceReplace:modifyError:modifyFlags:flagMask:[updateMessageCache:calculateUnreadCount:[reindexMessage:]]:` · `storeItem:forceReplace:` | VERIFIED-iOS15 | [IMDMessageStore.h 15.6](https://github.com/donato-fiore/iOS-Runtime-Headers/blob/main/15.6/PrivateFrameworks/IMDaemonCore.framework/Headers/IMDMessageStore.h) | yes (`IMMessageItem.body`/`plainBody`) | yes (`guid`, `messageID`) | yes | medium |
| imagent | `IMDChat` | `isSMS`, `lastMessage` (filter/context) | VERIFIED-iOS15 | [IMDChat.h 15.6](https://github.com/donato-fiore/iOS-Runtime-Headers/blob/main/15.6/PrivateFrameworks/IMDaemonCore.framework/Headers/IMDChat.h) | (context) | yes | yes | low |
| imagent (IMDPersistence) | `IMDNotificationsController` | `_registerUserNotificationsForMessageRecords:…`, `_shouldPostNotificationForChat:messageDictionary:` | VERIFIED-iOS15 | [IMDNotificationsController.h 15.6](https://github.com/donato-fiore/iOS-Runtime-Headers/blob/main/15.6/PrivateFrameworks/IMDPersistence.framework/Headers/IMDNotificationsController.h) · [15.6 SDK tbd](https://github.com/theos/sdks/blob/master/iPhoneOS15.6.sdk/System/Library/PrivateFrameworks/IMDPersistence.framework/IMDPersistence.tbd) | yes | yes (record id) | only when a notification is posted | medium |
| SpringBoard | `NCBulletinNotificationSource` | `observer:addBulletin:forFeed:` / `…playLightsAndSirens:withReply:` | VERIFIED-iOS15 (class+methods) | [NCBulletinNotificationSource.h 15.6](https://github.com/donato-fiore/iOS-Runtime-Headers/blob/main/15.6/PrivateFrameworks/UserNotificationsUIKit.framework/Headers/NCBulletinNotificationSource.h) | yes (`BBBulletin.message`) | yes (`bulletinID`) | yes iff a bulletin exists | med–high |
| SpringBoard | `SBBulletinBannerController` / `SBLockScreenBulletinViewController` / `SBBulletinListController` | `observer:addBulletin:forFeed:` etc. | VERIFIED-GENERIC (iOS 8/9 dumps + 2013-15 tweaks); **not** iOS-15 verified | [SBBulletinBannerController iOS9](https://github.com/CPDigitalDarkroom/iOS9-SpringBoard-Headers/blob/master/System/Library/CoreServices/SpringBoard/SBBulletinBannerController.h) · [ColorBanners](https://github.com/andrewwiik/Tweaks/blob/master/ColorBanners/Tweak.xm) | yes | yes | yes iff shown | high |
| CommCenter | `SMSCTServer` | `_ingestIncomingCTMessage:` | VERIFIED-GENERIC (iOS 5–8) | [SMSNinja Hook.xm](https://github.com/iosre/SMSNinja/blob/master/libsmsninja/Hook.xm) | yes | no GUID | yes | high |
| Messages.app | `IMChat`/`IMChatRegistry` | `__kIMChatMessageReceivedNotification` | VERIFIED-GENERIC | [WebMessage Tweak.x](https://github.com/sgtaziz/WebMessage-Tweak/blob/master/libwebmessage/Tweak.x) | yes | yes | **no** (app must run) | reject |

---

## Explicit unknowns / things I could not verify

1. No iOS 15.4.1 (or 15.x) dump of `SMS.imservice/SMS` exists publicly that I could find → the SMS plugin's exact 15.4.1 selector set is unverified.
2. `SMS.imservice` presence on iOS 15.4.1 is inferred from iOS 8 (headers) and iOS 18/26 (Mach-O path) — not from an iOS 15 image listing.
3. imagent's iOS 15 executable path is inferred (iOS 8.3 class-dump "Image Source" + iOS 18/26 ipsw path); no iOS 15 filesystem listing was available. `/usr/libexec/imagent` is not evidenced.
4. `usernotificationsd` path/bundle id on iOS 15: not verified.
5. SpringBoard.app class/method signatures for iOS 15: not available in any dump I could reach (limneos SpringBoard header pages are Turnstile-protected; the donato dump covers frameworks only). Discover them at runtime.
6. The exact bulletin section identifier of a real iOS 15 SMS notification: only `com.apple.MobileSMS` used as a *fabricated* sectionID in a third-party tweak (NineLS).
7. Whether a suppressed/muted notification produces any bulletin at all: inferred (no bulletin when no notification request is made).
