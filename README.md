# KeywordSMSAlert

> iOS tweak for jailbroken devices (iPhone 12 / iOS 15.4.1 / arm64e, Dopamine RootHide "roothide").
> When an incoming SMS matches one of your keywords, it vibrates and plays an alert through the
> **ringer/alert volume channel** (so it is heard even with the media volume at 0), and pressing the
> **power button stops the alert instantly**. SMS detection runs read-only inside `imagent`; the alert
> engine and the event-driven physical power-button observer run in a **standalone mobile launchd
> service** (`ksaalertd`) — since **1.1.4 nothing is injected into SpringBoard at all**. A Preferences
> panel (Settings → KeywordSMSAlert) and a `ksactl` CLI are included.
>
> Repository: <https://github.com/CangWeiohh/KeywordSMSAlert> · Build: `make clean && make package FINALPACKAGE=1`
> (roothide/theos) · License: MIT. 中文文档见下。

> **1.1.4 架构变更（重要）**：早期版本把提醒引擎注入 SpringBoard，并在加载期/首次提醒时安装
> 电源键 Hook。实机 A/B 证明：与「电话助手 2.5.1（roothide）」共存时，**只要再往 SpringBoard 注入
> 任何 dylib（哪怕只有一个空构造器），用户空间重启就会持续黑屏**。因此 1.1.4 起：
> ① 包内**不再包含任何 SpringBoard dylib / filter plist**；② 提醒引擎迁到独立守护进程
> `ksaalertd`（`/Library/LaunchDaemons/com.keyword.smsalert.alertd.plist`，`UserName=mobile`）；
> ③ 电源键停止改为**只观察、不消费**的 IOHID 事件监听（`Consumer 0x0C / Power 0x30`，按下沿），
> 不 Hook、不注入、不轮询，也不改变系统原有的锁屏/唤醒/SOS 语义。


面向 **iPhone 12 / iOS 15.4.1 / arm64e / Dopamine RootHide 2.4.9.27（roothide）** 的
关键词短信提醒 Tweak。

> 收到短信 → 匹配关键词 → 震动 / 声音提醒 → 按电源键立即停止。

第一阶段：**纯 plist 配置，无 PreferenceBundle**，目标是核心功能稳定可用。

---

## 1. 目标环境

| 项 | 值 |
| --- | --- |
| 设备 | iPhone 12（`iPhone13,2`，arm64e） |
| 系统 | iOS 15.4.1 |
| 越狱 | Dopamine RootHide 2.4.9.27（roothide bootstrap） |
| 注入引擎 | roothide basebin（`libroothide.dylib` + `libsubstrate.dylib`） |
| 构建 | roothide/theos（`THEOS_PACKAGE_SCHEME = roothide`） |
| 产物 | `packages/KeywordSMSAlert_1.1.4_iphoneos-arm64e.deb` |

---

## 2. 可行性结论（先研究后编码的结论）

| 需求 | 结论 | 原因 / 证据 | 替代方案或说明 |
| --- | --- | --- | --- |
| 监听短信（Messages 未打开 / 后台 / 锁屏） | **可行** | 短信由常驻守护进程 `imagent`（`com.apple.imagent`）接收与落库，与 Messages UI、通知状态无关 | — |
| 关键词匹配（中文、多关键词、包含/完整/前缀、大小写） | **可行**（已用 host 单测验证 39 项） | 纯字符串匹配，无系统依赖 | `MatchMode = contains / exact / prefix` |
| 震动 N 秒、可配置间隔 | **可行（有物理限制）** | `AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)` 单次震动约 0.3–0.5 秒，iOS 无法一次震动 5 秒 | 用 GCD 定时器按 `VibrationInterval` 重复调用，直到 `VibrationDuration` 到期 |
| 声音：循环、时长、音量 | **部分可行** | 无公开 API 可读写“铃声通道音量”且不改动系统音量；媒体通道响度 = 媒体音量 × player 音量 | 两条通道都实现，见下一行 |
| **走铃声/提醒通道发声**（媒体音量为 0 也能听见） | **可行（默认）** | `AudioServicesCreateSystemSoundID` + `AudioServicesPlaySystemSound` 走**提醒（铃声）音量** | `SoundChannel = alert`（默认）；受静音拨片影响，仅支持未压缩 CAF/AIFF/WAV；想“静音也响”用 `SoundChannel = media` |
| 从系统提示音/铃声中选提醒音 | **可行** | 设置面板新增「从系统提示音 / 铃声中选」，运行时扫描 `/System/Library/Audio/UISounds`、`/Library/Ringtones` 等目录并列出候选 | m4r/mp3 铃声不支持提醒通道，会自动改走媒体通道播放（日志有说明） |
| 组合提醒 `AlertMode = 0/1/2/3` | **可行** | 两条通道独立启停 | `VibrationEnabled` / `SoundEnabled` 再叠加门控 |
| 电源键停止（按下去的瞬间，锁屏与唤醒两种状态都覆盖） | **可行（1.1.4 生产方案：独立守护进程 + IOHID 观察）** | `ksaalertd` 用 `IOHIDEventSystemClientCreate` + `IOHIDEventSystemClientRegisterEventCallback` **只观察** HID 事件流：键盘事件 `type=3`、字段 `UsagePage=0x30000 / Usage=0x30001 / Down=0x30002`，命中 `Consumer 页 0x0C / usage 0x30(Power)` 的**按下沿**即停止提醒。事件永不派发/消费/改写，锁屏、唤醒、SOS、Siri 语义完全不变 | 需要 `com.apple.private.hid.client.event-monitor` 等 entitlement（`Sources/Daemon/ksaalertd.entitlements`）；**不注入任何进程**，因此与其它 SpringBoard 插件共存安全 |
| 电源键停止（旧方案：SpringBoard Hook） | **已废弃（1.1.4 移除）** | 旧版在 `SBSleepWakeHardwareButtonInteraction -consumeInitialPressDown` 等处安装 Hook。实机证明与电话助手共存时会导致用户空间重启持续黑屏，故整个 SpringBoard 注入被删除 | 相关调研保留在 `docs/power-button-hook-research.md`，仅供历史参考；诊断构建变体见 Makefile 的 `KSA_BUILD_VARIANT` |
| 提醒引擎宿主 | **独立 mobile LaunchDaemon（1.1.4）** | `ksaalertd` 由 launchd 以 `mobile` 身份常驻（`RunAtLoad` + `KeepAlive`），链接 AVFoundation/AudioToolbox；SpringBoard 完全不参与 | 守护进程状态可在「设置 → KeywordSMSAlert → 提醒服务状态」查看（无需 SSH） |
| 电源键停止（**熄屏**状态下按键是否走同一 DOWN 链路） | **结构上高度可信，但需实机 5 分钟确认** | 该类对象既负责 sleep 又负责 wake，按键 DOWN 必然要被它咨询；但“屏幕全黑时 `buttonDown:`/`performInitialButtonDownActions` 是否也触发”没有公开证据可逐字证实 | 提供了探针流程（见 §10），若熄屏时确实完全不触发，才会退化为“按设定时长自动结束”；报告明确不建议走 IOHIDEventSystemClient（需要 HID entitlement，风险最高） |
| 提醒状态机 | **可行** | 串行队列 + 显式状态转移 | `restart` / `ignore` / `queue` |
| 防重复触发 | **可行**（已单测） | 以 GUID 为键，`DuplicateInterval`（默认 10 秒）窗口内抑制 | 无 GUID 时退化为 `sender hash + text hash` |
| 线程安全、不阻塞短信线程 | **可行** | hook 内只做字典取值 + 字符串匹配 + Darwin 通知投递（微秒级）；音频/定时器全部在 SpringBoard 自己的串行队列 | 不在 daemon 关键线程做 IO |
| 可控日志、默认不写短信正文 | **可行** | 默认只输出 `sender hash / message hash / length`；`DebugEnabled=1` 才输出正文 | `LogToFile=1` 可写文件日志（自动限 256 KB 轮转） |
| 不改短信内容/数据库/通知中心/Messages UI | **可行** | 全程只“读消息对象字段”，无任何 sqlite/数据库/通知写入代码 | 代码中不存在 sqlite 引用 |
| PreferenceBundle | 未做（第二阶段） | 本阶段按需求用 plist | 配置引擎已支持显式路径加载，便于后续接入设置面板 |
| 卸载 | **可行** | `dpkg -r` 删除 detector dylib、filter plist、`ksaalertd`、LaunchDaemon plist 与资源；`prerm` 会先 `launchctl bootout` 停止守护进程，无残留运行进程；配置文件保留 |

---

## 3. iOS 15.4.1 短信链路与注入目标（为什么是 C：多进程）

短信落库链路（公开资料 + 实机 trace 整理）：

```
Baseband → CommCenter (SMSCTServer)
        → imagent  (com.apple.imagent，/System/Library/PrivateFrameworks/IMCore.framework/imagent.app/imagent)
             加载 /System/Library/Messages/PlugIns/SMS.imservice/SMS  → SMSServiceSession
        → IMDaemonCore: IMDMessageStore / IMDChatRegistry → sms.db
        → IMDPersistence: IMDNotificationsController → UNNotificationRequest
        → 通知中心 / SpringBoard 横幅 / 锁屏
```

**结论：**

* **A. 只注入 SpringBoard —— 不选**。
  通知路径会受“静音 / 专注模式 / 前台抑制 / 通知权限”影响，无法满足“收到后立即检测、不依赖通知”。
* **B. 只注入短信 daemon —— 不够**。
  `imagent` 里没有可用的音频/震动会话管理，也无法观察物理电源键。
* **C. imagent 注入检测 + 独立守护进程提醒（1.1.4 采用）**：

| 组件 | 宿主 | 职责 | 链接的框架 |
| --- | --- | --- | --- |
| `KeywordSMSAlertDetector.dylib` | `com.apple.imagent`（注入） | 只读轮询 `sms.db`、匹配关键词、发 Darwin 通知 | Foundation / CoreFoundation / sqlite3 / libroothide |
| `ksaalertd`（可执行文件） | **launchd 独立守护进程（mobile）** | 提醒引擎（震动 + 铃声通道声音）、IOHID 电源键观察 | Foundation / CoreFoundation / AVFoundation / AudioToolbox / libroothide |

拆分原因：**① 不让短信 daemon 加载音频框架；② 完全不碰 SpringBoard**。
早期版本用 `KeywordSMSAlertAlert.dylib` 注入 SpringBoard，1.1.4 已彻底删除该组件（构建变体仍可复现用于诊断）。

* **D. 其他系统服务机制**：不需要。跨进程通信使用 Darwin 通知（`CFNotificationCenterGetDarwinNotifyCenter`），
  不传 payload、不写共享文件、不需要 XPC 服务和任何 entitlement，daemon 侧只做一次 `notify_post` 等价调用。

短信侧挂载点（按优先级）：

1. **`SMSServiceSession`（SMS.imservice 插件，最早最原始）**
   * `- (id)_convertCTMessageToDictionary:(id)message requiresUpload:(BOOL)requiresUpload`
   * `- (id)_receivedSMSDictionary:(id)message requiresUpload:(BOOL)requiresUpload isBeingReplayed:(BOOL)isBeingReplayed`
   * 选择器来自实机 trace（见 §10 证据等级）；运行时会先确认存在才挂载，不存在则在日志里说明。
   * 返回字典的键：`h` 发件人、`co` 收件人、`k` 正文分片（`data` + `type`）、`g` GUID、`m` 服务名。
2. **`IMDMessageStore`（IMDaemonCore，iOS 15 头文件签名验证过的兜底，必定触发）**
   * `-storeItem:forceReplace:`、`-storeMessage:forceReplace:modifyError:modifyFlags:flagMask:`（含 7/8 参数重载）
   * 载荷 `IMMessageItem`：`body`(NSAttributedString) / `plainBody`(NSString) / `guid` / `sender` / `service` / `isFromMe`。
   * 与通知状态、DND、前台与否完全无关，即使 Apple 改了 SMS 插件私有方法也还能工作。
3. **`IMDServiceSession -didReceiveMessage:forChat:style:account:fromIDSID:`**（通用兜底）

电源键链路（SpringBoard 侧，详见 `docs/power-button-hook-research.md`）：

```
UIPress(pressType Lock) → SBPressGestureRecognizer
   → SBLockHardwareButton        -buttonDown:                       (按下)
   → SBLockHardwareButtonActions -performInitialButtonDownActions    (按下)
   → SBSleepWakeHardwareButtonInteraction -consumeInitialPressDown   (按下，返回 BOOL)
   → -_performSleep / -_performWake
```

明确**不使用**的点：`SBHIDButtonStateArbiter`（属于相机快门/音量仲裁，不是电源键）、
`SBHIDEventDispatchController`（iOS 15 不存在，16.1 才出现）、`SBLockScreenManager -lockUIFromSource:`
（只覆盖锁屏，且会被 AssistiveTouch/远程锁屏触发）、`-singlePress:`（是抬起事件，且会被 SOS/Siri 抢占）。

**1.1.4 的电源键方案**：不再使用任何 Hook，改由独立守护进程 `ksaalertd` 通过
`IOHIDEventSystemClientCreate` / `IOHIDEventSystemClientScheduleWithRunLoop` /
`IOHIDEventSystemClientRegisterEventCallback` **只观察** HID 事件流，命中
`type=3` + `Consumer 0x0C / Power 0x30` 的按下沿即停止提醒；事件从不被派发、消费或改写，
因此锁屏/唤醒/SOS/Siri 行为与未安装插件时一致。该客户端需要
`com.apple.private.hid.client.event-monitor` 等 entitlement（见 `Sources/Daemon/ksaalertd.entitlements`）。
上面列出的 SpringBoard Hook 链路仅在诊断构建变体中保留。

方向判定：`-[CTMessage type] == 1`（incoming）或 `-[CTMessage isIncoming]`；`IMMessageItem.isFromMe == YES` 一律忽略。
服务过滤：`IMItem.service` 只接受包含 “sms” 的（`IncludeIMessage = 1` 时才评估 iMessage）。
多路重复事件由 GUID 去重合并。

---

## 4. roothide 兼容要点（与 rootful / 普通 rootless 的区别）

本项目的 roothide 处理方式均以 <https://github.com/roothide/Developer> 与 roothide/theos 源码为准：

| 主题 | roothide 的实际行为 | 本项目做法 |
| --- | --- | --- |
| 越狱根目录 | **不是固定的 `/var/jb`**，每次越狱是随机目录名的 `jbroot` | 所有越狱内路径都写成“以 `/` 为 jbroot”，再用 `jbroot()` 转换 |
| 路径 API | `#include <roothide.h>` 提供 `jbroot()` / `rootfs()` / `jbrand()` | `KSAPathInJB()` 统一封装；本仓库 `Sources/KSACommon.h` |
| 依赖库 | 依赖库 `install_name` 形如 `@loader_path/.jbroot/usr/lib/xxx.dylib` | Theos roothide scheme 自动生成；产物中可见 `@loader_path/.jbroot/...` |
| `.jbroot` 符号链接 | 每个含 Mach-O 的目录会有 `.jbroot → jbroot`（roothide 安装时生成） | 依赖它解析 `libroothide.dylib` / `libsubstrate.dylib`，无需手动创建 |
| 安装目录 | `<jbroot>/Library/MobileSubstrate/DynamicLibraries` | Theos roothide scheme 的默认安装路径（deb 内路径为 `Library/MobileSubstrate/...`，即 jbroot 相对） |
| 包架构 | roothide 使用 **`iphoneos-arm64e`** | `vendor/mod/roothide/package/deb.mk` 强制；deb 文件名 `KeywordSMSAlert_1.0.5_iphoneos-arm64e.deb` |
| 注入引擎 | Bootstrap 自带 `libroothide` + `libsubstrate`（CydiaSubstrate 兼容） | 因此 `Depends` 不需要写 `mobilesubstrate`，只写 `firmware (>= 15.0)` |
| entitlement | tweak 本身不需要额外 entitlement | `ldid` 签名，无 entitlements（可用 `ldid -e` 查看，为空） |
| 第三方 App 注入 | roothide 默认**不注入**第三方 App（App List 控制） | 本项目目标是 SpringBoard + imagent 系统进程，不受此限制 |

---

## 5. 目录结构

```
KeywordSMSAlert/
├── Makefile                        # roothide scheme，两个 TWEAK_NAME
├── control                         # Package: com.keyword.smsalert / iphoneos-arm64e
├── KeywordSMSAlertDetector.plist    # filter: com.apple.imagent
├── KeywordSMSAlertAlert.plist       # filter: com.apple.springboard
├── Resources/
│   ├── alert.caf                    # 生成的提醒音（CAF / 44.1kHz / 16bit / mono LPCM）
│   ├── make_alert_caf.py            # 音效生成脚本（可复现）
│   └── make_icon.py                 # 设置图标生成脚本（纯 stdlib PNG）
├── PrefsResources/                  # 设置 Bundle 的资源（= .bundle 内容）
│   ├── Info.plist  icon.png/@2x/@3x
│   ├── en.lproj/Localizable.strings
│   └── zh-Hans.lproj/Localizable.strings
├── Sources/
│   ├── KeywordSMSAlertDetector.xm   # imagent 全部 hook + 懒加载类挂载逻辑
│   ├── KeywordSMSAlertAlert.xm      # SpringBoard hook + 入口
│   ├── KSACommon.h/.m               # jbroot 路径、进程识别、哈希
│   ├── KSAConfig.h/.m               # 配置解析 + 关键词匹配
│   ├── Prefs/                       # 设置界面（PreferenceBundle，跑在「设置」App 内）
│   │   ├── KSARootListController.h/.m   # 根面板（开关/输入/选择/测试按钮）
│   │   ├── KSAListEditorController.h/.m # 关键词 / 忽略发件人 列表编辑
│   │   ├── KSAChoiceController.h/.m     # 单选（匹配方式/提醒方式/新短信策略）
│   │   ├── KSAPrefsStore.h/.m           # 配置读写（双写 + 通知重载）
│   │   └── KSAPrefsCommon.h             # 本地化与 specifier 属性键
│   ├── KSADedupCache.h/.m           # 去重缓存（TTL）
│   ├── KSAAlertManager.h/.m         # 状态机 + 提醒引擎（震动/声音）
│   ├── KSAPowerButton.h/.m          # 电源键监听（发现式挂载 + 诊断）
│   ├── KSASMSDetector.h/.m          # 短信解析/匹配/发通知
│   ├── KSATrigger.h/.m              # Darwin 通知通道
│   ├── KSALog.h/.m                  # 可控日志
│   └── KSAPrivateAPI.h              # 私有类/方法声明（仅编译期声明）
├── layout/
│   ├── Library/KeywordSMSAlert/alert.caf
│   ├── var/mobile/Library/Preferences/com.keyword.smsalert.plist
│   ├── Library/PreferenceLoader/Preferences/KeywordSMSAlert.plist  # 设置入口
│   └── DEBIAN/{postinst,conffiles}
├── docs/
│   ├── ios15-sms-hook-research.md   # iOS 15.4.1 短信链路/Hook 点调研报告（含证据等级）
│   └── power-button-hook-research.md# 电源键链路/Hook 点调研报告（含证据等级与探针流程）
└── tests/
    ├── host_tests.m                 # 39 项逻辑单测（配置/匹配/去重/音效路径）
    ├── shim/roothide.h              # host 测试用 jbroot 恒等映射
    └── run_host_tests.sh
```

---

## 6. 关键实现说明

### 6.1 状态机（KSAAlertManager）

```
IDLE ──匹配──▶ MATCHED ──▶ ALERTING ──(电源键/到时/打断)──▶ STOPPED ──▶ IDLE
```

* 所有状态迁移都在 `com.keyword.smsalert.alert` **串行队列**上执行。
* `ALERTING` 期间再次收到匹配短信：按 `OnNewMatchedSMS` 处理
  `restart`（默认，重新计时）/ `ignore` / `queue`（最多缓存 1 条，当前提醒结束后立即开始）。
* 到期时间 = `max(VibrationDuration, SoundDuration)`，并被 `180 秒`硬上限截断，防止定时器悬挂。
* 停止时统一：取消全部 `dispatch_source` 定时器 → 停止震动 → 停止播放 → 恢复 audio session → 回到 `IDLE`。

### 6.2 震动

`AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)` 立即触发一次，然后按
`VibrationInterval`（≥ 0.2 秒，防止高频调用）用 GCD 定时器重复，`VibrationDuration` 到期后自动停止。
不使用多线程轮询，不创建线程，全部复用同一个串行队列。

### 6.3 声音：两条通道（默认走铃声）

| `SoundChannel` | 实现 | 受控于 | 静音拨片 | 适用 |
| --- | --- | --- | --- | --- |
| `alert`（默认） | `AudioServicesCreateSystemSoundID` + `AudioServicesPlaySystemSound`，循环用定时器重复 | **铃声/提醒音量** | 静音时不响 | 日常媒体音量为 0 / 低，想“像短信提示音一样响” |
| `media` | `AVAudioSession(Playback + MixWithOthers)` + `AVAudioPlayer`（`numberOfLoops = -1`，`volume = SoundVolume`） | 媒体音量 | 忽略（仍会响） | 希望静音拨片下也能出声，或使用 m4r/mp3 铃声 |

- 提醒通道**不触碰 AVAudioSession**，也不修改任何系统音量；停止时 `AudioServicesDisposeSystemSoundID`。
- 提醒通道只接受未压缩 CAF/AIFF/WAV（< 30 秒）；选了 m4r/mp3/压缩 CAF 时，**引擎会先用 `ExtAudioFile` 自动转成
  16 bit PCM CAF**（缓存在 `<jbroot>/Library/KeywordSMSAlert/alert-<hash>.caf`），仍然走提醒通道；只有连转码也失败才回退媒体通道。
* SpringBoard 启动时会打一行 `alert engine ready (process SpringBoard, sound channel alert, sound file …)`，
  一眼就能看出当前实际用的是哪个音道与哪个文件。
- 重复间隔：`SoundRepeatInterval = 0` 时按音频文件时长自动计算（`SoundLoop = false` 时只播一次）。
- `SoundFile` 未配置时按顺序回退：jbroot 内 `Library/KeywordSMSAlert/alert.caf` →
  `/var/mobile/Library/KeywordSMSAlert/alert.caf` → 系统 `/System/Library/Audio/UISounds/sms-received1.caf` → 系统声音 id 1007。
- 设置面板「从系统提示音 / 铃声中选」会扫描 `/System/Library/Audio/UISounds`（含 New/Modern 子目录）、
  `/Library/Ringtones`、`/var/mobile/Media/Ringtones` 等目录；**点一下即选中并立刻试听**（用与提醒相同的通道，
  所以听到的就是提醒的实际效果），再点同一行或返回上一页即停止试听，带上 `✓` 标记当前选中项、`▶` 标记正在试听项。

### 6.4 电源键（重点功能）

**按优先级挂载（全部先做运行时存在性校验，缺哪个日志里写清楚）：**

1. `SBSleepWakeHardwareButtonInteraction - (BOOL)consumeInitialPressDown`
   → 观测到按下后停止提醒，然后 **`return %orig;`**（原样返回 iOS 的“是否消费本次按压”判断，
   绝不自作主张返回 YES/NO，因此 SOS/强制重启/Siri 等语义完全不变）。
2. `SBLockHardwareButtonActions - (void)performInitialButtonDownActions` → `%orig` 后观测。
3. `SBLockHardwareButton - (void)buttonDown:(id)press` → `%orig` 后观测（兜底）。
4. `SBLockScreenManager -lockUIFromSource:withOptions:` / `-lockUIFromSource:` → 补充观测（锁屏路径）。
5. ~~兜底发现式挂载~~ —— **1.1.3 已删除**。它原先会在运行时枚举 `SBLockHardwareButton` / `SBHardwareButton` /
   **`SBBacklightController`** 的真实方法列表，把名字匹配的**背光点亮类方法**也一并包一层。
   对「电源键停止提醒」它并非必需，却正好落在「屏幕亮不亮」这条链路上：实机表现为
   **单独装另一个同样在 dylib 加载时挂 hook 的 SpringBoard 插件时只是黑屏 1 秒；两个一起装就一直黑屏**。
   现在只保留上面 1–4 这四条**逐个验证过、且都把原实现原样放行**的 hook。

**稳定性约束（按调研结论执行）：**

* **1.1.3 起：SpringBoard 启动期零 hook。** `%ctor` 只做「进程判定 + 读应急标记 + 异步启动提醒引擎」，一个 hook 都不装——
  安装 hook（每次 `MSHookMessageEx` 都会让其他线程短暂挂起）恰恰是「用户空间重启」时 SpringBoard 早期最不该做的事。
  上述四条 hook 改为**第一个提醒真正开始播放时才安装**（见 `Sources/KSAHookInstaller.h`）：功能完全不变（按压总是发生在提醒开始之后），
  但本插件不再参与 SpringBoard 的启动过程。
* 四条 hook 现在**全部**是「先执行原实现、再观察」，包括 `consumeInitialPressDown`（1.1.2 之前是"先观察再 `%orig`"），
  因此即使与别的插件叠在同一条方法链上，本插件的存在也不会改变链的语义。

* hook 体内只做一件事：投递到提醒引擎的串行队列（微秒级），**绝不在 SpringBoard 按键处理线程上做音频/AudioToolbox 拆卸**——RemoteCompanion 的 changelog 记录过“电源键变卡顿/延迟”的正是这类错误；
* 无提醒时走最快路径：先看 `isAlerting`（原子读）直接返回，不读配置文件；
* 一次按压可能命中多个方法（DOWN/UP/SOS 多回调），0.25 秒窗口内只处理第一次，停止操作幂等；
* 完全**没有轮询**；不 hook 手势识别器内部、不碰 IOKit/HID；
* 原方法总是先执行，锁屏/唤醒/Siri/连按等原有行为不变。

### 6.5 设置界面（第二阶段已实现）

「设置 → KeywordSMSAlert」，由 `KeywordSMSAlertPrefs.bundle`（`PSListController`）+ PreferenceLoader
入口 plist 组成，**不依赖 Cephei 等第三方库**，只链接 `Preferences.framework`：

| 分组 | 内容 |
| --- | --- |
| 顶部 | 总开关（Enabled） |
| 关键词 | 关键词列表（＋新增 / 点按修改或删除）、匹配方式（包含/完整等于/以…开头）、忽略大小写、忽略的发件人列表 |
| 提醒 | 提醒方式 0/1/2/3、震动开关与时长/间隔、声音开关与时长/音量/循环/文件路径 |
| 行为 | 去重时间、提醒中又收到匹配短信（重新开始/忽略/排队）、是否同时匹配 iMessage |
| 诊断 | 详细日志、写日志文件、SpringBoard 加载后测试提醒、**立即测试提醒**（按钮）、当前配置文件路径（页脚） |

* 保存即生效：面板把配置写回 plist 后立即投递 `com.keyword.smsalert.reload` Darwin 通知，
  SpringBoard 与 imagent 会重新读取，**无需 respring**。
* 写入策略：优先写真实用户偏好文件 `/var/mobile/Library/Preferences/com.keyword.smsalert.plist`，
  同时尽力同步写入 jbroot 内的那份（两者都成功时以真实路径为准，见 §8 的优先级）。
* 面板刻意**不链接** libsubstrate/libroothide/AVFoundation：jailbreak 根目录由 bundle 自身路径推导，
  即使「设置」App 没有被注入也能加载。

### 6.6 去重

`KSADedupCache`：以 GUID（缺失则 `sender hash|text hash`）为键，`DuplicateInterval`（默认 10 秒）内重复事件直接忽略。
同一短信会先后经过 `_convertCTMessageToDictionary:`、`_receivedSMSDictionary:`、`IMDMessageStore` 多个入口，
但 GUID 相同 → 只提醒一次。缓存最多 128 条，超限自动清理一半。

### 6.7 日志

前缀统一 `[KeywordSMSAlert]`。

| 级别 | 内容 | 何时输出 |
| --- | --- | --- |
| 事件级 | `loaded into …` / `SMS received (sender hash=… message hash=… length=…)` / `keyword matched (keyword hash=…)` / `alert started` / `power button pressed - stopping alert` / `alert stopped (…)` | 默认 |
| 调试级 | 完整正文、发件人、GUID、候选方法名、状态迁移、audio session 细节 | `DebugEnabled = 1` |

`LogToFile = 1` 时另写 `<jbroot>/Library/KeywordSMSAlert/KeywordSMSAlert.log`（超过 256 KB 轮转为 `.1`）。

---

## 7. 安装 / 生效 / 卸载

```bash
# 1) 传 deb 到设备后
dpkg -i KeywordSMSAlert_1.0.5_iphoneos-arm64e.deb
#    或用 Sileo / Zebra 直接安装；也可在电脑上 make install（需 THEOS_DEVICE_IP）

# 2) 让 SpringBoard 加载 alert dylib（必须）
sbreload
#    如果你的环境没有 sbreload：
#    killall -9 SpringBoard        # 或使用 Dopamine 的 “Respring”
#    ldrestart                     # 更彻底，但耗时长

# 3) 让 imagent 加载 detector dylib（必须，短信检测在 imagent 内）
killall -9 imagent

# 4) 验证是否加载（可选）
log stream --predicate 'eventMessage CONTAINS "KeywordSMSAlert"' --style compact
#    或开启 LogToFile 后查看日志文件
```

* **不需要重启设备、不需要重新越狱，也不需要每次“用户空间重启”**：
  * **安装包会自动重启 `imagent`**（`postinst` 里 `killall -9 imagent`），所以 detector 侧始终是新的，无需手动操作；
  * 只剩 SpringBoard 需要重载一次：**Sileo 装完会弹「Respring」按钮，点一下即可**，或手动 `sbreload`；
  * 想一条命令搞定：`ksactl restart`（重启 imagent + SpringBoard）。
  * `killall -9 imagent` = 给短信守护进程发 SIGKILL，launchd 立即把它拉起来，用户完全无感。
  * 更省事的等价做法：**用户空间重启**（Dopamine 应用里的 Userspace Reboot，或 `ldrestart`）。
    它会把所有守护进程连同 SpringBoard 一起重启，两个 dylib 自然都加载，等于 `sbreload` + `killall imagent`。
    重启设备再进越狱同样有效。
  * 或者：`launchctl kickstart -k system/com.apple.imagent`。
* 设置入口：`设置 → KeywordSMSAlert`。**需要设备已安装 `preferenceloader`**（PreferenceLoader）。
  未安装时 Tweak 本体照常工作，只是设置入口不显示；`postinst` 会打印提示。
  装完 PreferenceLoader 后 `killall -9 Preferences`（或 respring）再打开「设置」。
* 没有 PreferenceLoader 也能改配置、能测试：包内附带命令行工具 `ksactl`（见 §8.3 与 §13）。
* 卸载：

```bash
dpkg -r com.keyword.smsalert     # conffiles 会保留你改过的配置
dpkg -P com.keyword.smsalert     # 彻底删除（含配置）
killall -9 imagent; sbreload
```

---

## 8. 配置

配置文件由 **`postinst` 首次安装时生成**，之后 dpkg 不再接管它 —— **升级永远不会提示、也不会覆盖你的设置**；
文件缺失时插件使用内置的同一套默认值，设置面板或 `ksactl` 第一次保存时也会创建它。

路径（jbroot 内，从 roothide bootstrap shell 看到的路径就是它）：

```
/var/mobile/Library/Preferences/com.keyword.smsalert.plist
```

**推荐直接用「设置 → KeywordSMSAlert」改**（保存立即生效，无需 respring）。

手动改文件时的查找顺序（第一个存在者生效，实际使用路径会打印在日志里、也显示在设置面板页脚）：

1. `/var/mobile/Library/Preferences/com.keyword.smsalert.plist` ← **设置面板写的就是这个，优先级最高**
2. `<jbroot>/var/mobile/Library/Preferences/com.keyword.smsalert.plist` ← 安装包提供的默认配置
3. `<jbroot>/Library/Preferences/com.keyword.smsalert.plist`

> 即：装完先用 jbroot 里的默认值；一旦你用设置面板保存过一次，真实 rootfs 那份就会生效并长期优先。
> 手动编辑时请编辑第 1 个路径，否则会被它遮蔽。

另外支持更简单的关键词文件（一行一个，`#` 开头为注释，覆盖 plist 里的 `Keywords`）：

```
/Library/KeywordSMSAlert/keywords.txt
```

⚠️ 配置必须是 **XML plist / 二进制 plist / JSON**。iOS 无法解析 OpenStep 风格
（`{ Enabled = 1; Keywords = ( "验证码" ); }`），遇到这种文件会打印明确提示并回落默认值。

改完配置后无需重装：`KSATrigger`/配置读取有 2 秒节流，收到下一条短信时自动生效；
也可手动触发重载：`notifyutil -p com.keyword.smsalert.reload`（若设备没有 notifyutil，`killall -9 imagent` 亦可）。

### 8.1 默认配置（安装包内提供）

```xml
<key>Enabled</key>              <true/>
<key>Keywords</key>             <array><string>验证码</string>…</array>
<key>MatchMode</key>            <string>contains</string>   <!-- contains / exact / prefix -->
<key>CaseInsensitive</key>      <true/>
<key>MinMessageLength</key>     <integer>1</integer>
<key>IgnoreSenders</key>        <array/>
<key>AlertMode</key>            <integer>3</integer>        <!-- 0关闭 1震动 2声音 3震动+声音 -->
<key>VibrationEnabled</key>     <true/>
<key>VibrationDuration</key>    <real>5</real>
<key>VibrationInterval</key>    <real>0.7</real>
<key>SoundEnabled</key>         <true/>
<key>SoundDuration</key>        <real>10</real>
<key>SoundVolume</key>          <real>0.8</real>
<key>SoundLoop</key>            <true/>
<key>SoundChannel</key>         <string>alert</string>   <!-- alert=铃声/提醒音量(默认) media=媒体音量 -->
<key>SoundRepeatInterval</key>  <real>0</real>           <!-- 0=按音频时长自动 -->
<key>SoundFile</key>            <string></string>
<key>DuplicateInterval</key>    <real>10</real>
<key>OnNewMatchedSMS</key>      <string>restart</string>    <!-- restart / ignore / queue -->
<key>HookMessageStoreBackstop</key>   <false/>  <!-- 1.0.7 起默认关闭；需要更强兜底时置 true -->
<key>HookServiceSessionBackstop</key> <false/>  <!-- 同上 -->
<key>DebugEnabled</key>         <false/>
<key>LogToFile</key>            <false/>
<key>TestAlertOnLoad</key>      <false/>
<key>IncludeIMessage</key>      <false/>
```

### 8.2 命令行工具 `ksactl`（不依赖 PreferenceLoader）

```bash
ksactl status                      # 显示配置文件路径 + 当前生效值
ksactl keywords list
ksactl keywords add 验证码         # 加关键词
ksactl keywords remove 支付
ksactl keywords clear              # 清空（清空后永不触发）
ksactl senders add 1069            # 忽略的发件人
ksactl get AlertMode
ksactl set AlertMode 2             # 0 关闭 / 1 震动 / 2 声音 / 3 两者
ksactl set SoundVolume 0.6
ksactl set DebugEnabled true
ksactl test                        # 立即发一次测试提醒
ksactl reload                      # 让 SpringBoard/imagent 重读配置
ksactl help
```

运行环境：设备上的终端（NewTerm 2 / SSH）或 Filza 的「执行命令」。在 roothide 的 bootstrap 里
`/` 就是 jbroot，所以工具会同时写两个位置：jbroot 内的副本
（`/var/mobile/Library/Preferences/…`）与真实用户偏好文件（`/rootfs/var/mobile/Library/Preferences/…`），
后者优先级最高，与设置面板一致。

### 8.3 常用改法

| 想做的事 | 怎么改 |
| --- | --- |
| 改关键词 | `Keywords` 数组加/删字符串（中文直接写；也可用 `keywords.txt` 一行一个） |
| 只要“完整等于”或“以…开头” | `MatchMode` 改 `exact` / `prefix` |
| 只震动 | `AlertMode = 1`（或 `SoundEnabled = false`） |
| 只声音 | `AlertMode = 2`（或 `VibrationEnabled = false`） |
| 媒体音量为 0 也要听得见 | `SoundChannel = alert`（默认，走铃声/提醒音量） |
| 静音拨片下也要响 | `SoundChannel = media`（走媒体音量） |
| 换系统提示音/铃声 | 设置面板「从系统提示音 / 铃声中选」，或 `SoundFile` 填绝对路径 |
| 震动 10 秒 | `VibrationDuration = 10`；想更“连”可以调小 `VibrationInterval`（≥0.2） |
| 声音 20 秒、音量 60% | `SoundDuration = 20`，`SoundVolume = 0.6` |
| 不循环，只播一次 | `SoundLoop = false`（文件本身约 1 秒，建议 `SoundDuration` 设小一点） |
| 换提醒音 | 把任意 `.caf`/`.aiff`/普通音频放到 `/Library/KeywordSMSAlert/alert.caf`，或 `SoundFile` 指定绝对路径 |
| 某号码/短号不提醒 | `IgnoreSenders` 加子串，如 `"1069"`、`"95533"` |
| 想更快/更省电的检测 | `PollInterval`（秒，0.5–30，默认 1）：**改完立即生效，无需重启**（设置面板里也有这一项） |
| 同一短信 30 秒内只提醒一次 | `DuplicateInterval = 30` |
| 排查问题 | `DebugEnabled = true`、`LogToFile = true` |
| 不装短信也能测提醒 | `TestAlertOnLoad = true`（SpringBoard 加载后 3 秒自动来一发提醒） |

---

## 9. 测试方案

| # | 测试 | 步骤 | 预期 |
| --- | --- | --- | --- |
| 1 | 普通短信 + 命中关键词 | 用另一台手机给自己发「您的验证码为 123456」 | 立即震动 + 声音；日志 `SMS received` → `keyword matched` → `alert started` |
| 2 | 普通短信 + 不命中 | 发「晚上一起吃饭」 | 无提醒；日志 `no keyword matched`（Debug 打开才有） |
| 3 | 锁屏状态收到 | 锁屏等短信 | 同上（imagent 与锁屏无关） |
| 4 | 后台/前台其他 App | 回到桌面或打开别的 App 再收 | 同上 |
| 5 | 连续两条匹配短信 | 5 秒内发两条不同内容 | 默认 `restart`：提醒重新计时，不叠加多个提醒 |
| 6 | 重复事件去重 | 只发一条，观察日志 | 只有一次 `alert started`，其余为 `duplicate callback … suppressed` |
| 7 | 提醒过程中按电源键 | 提醒时按右侧电源键 | 声音与震动立即停止，日志 `power button pressed - stopping alert` / `alert stopped (power button …)`；屏幕照常锁屏/唤醒 |
| 8 | 只震动 | `AlertMode = 1` + respring | 只有震动，无声音 |
| 9 | 只声音 | `AlertMode = 2` | 只有声音，无震动 |
| 10 | 震动 + 声音 | `AlertMode = 3` | 两者同时，且都在各自时长后停止 |
| 11 | 关闭插件 | `Enabled = false`，等下一条短信或 `killall -9 imagent` | 不再提醒；日志 `trigger ignored: plugin is disabled` |
| 12 | 卸载 | `dpkg -r com.keyword.smsalert` + `killall -9 imagent; sbreload` | 完全恢复原样，无残留进程、无残留 dylib |
| 14 | 音道切换 | `SoundChannel = alert`：把媒体音量拉到 0，触发提醒 | **仍有声音**（走铃声音量）；改成 `media` 后同样的操作无声 |
| 15 | 换铃声 + 试听 | 设置面板「从系统提示音 / 铃声中选」点几个（如 `Alarm`、`sms-received2`）| **每点一个当场出声**（与提醒同通道），`✓` 跟随选中、`▶` 标记正在播放；再点同一行或返回即停；`ksactl status` 中 `SoundFile` 显示 `[exists]`；选 m4r 时日志出现 `converted … to 16 bit PCM CAF` |
| 13 | 设置面板 | `设置 → KeywordSMSAlert`：改关键词、提醒方式、时长、音量，保存后发短信 | 面板显示中文、修改后**无需 respring** 即生效；页脚显示当前配置文件路径；「立即测试提醒」按钮能直接触发提醒 |

辅助命令：

```bash
# 手动触发一次提醒（验证提醒引擎 + 电源键，不依赖真实短信）
notifyutil -p com.keyword.smsalert.trigger
# 重载配置
notifyutil -p com.keyword.smsalert.reload
# 观察日志
log stream --predicate 'eventMessage CONTAINS "KeywordSMSAlert"' --style compact
# 或者：把 DebugEnabled / LogToFile 打开，然后
cat /var/jb/Library/KeywordSMSAlert/KeywordSMSAlert.log   # 在 bootstrap shell 中 / 即 jbroot
```

`TestAlertOnLoad = true` 也可以在完全没有短信的情况下验证“提醒 + 电源键停止”。

---

## 10. 已验证 / 未验证（诚实清单）

**本次会话中已实际执行验证：**

* 工具链可用：`~/theos`（roothide/theos）+ `iPhoneOS15.6.sdk`，`ldid 2.1.5`，无 Xcode（仅 Command Line Tools）也能交叉编译 iOS。
* `make clean && make package FINALPACKAGE=1` 成功，产物 `KeywordSMSAlert_1.0.5_iphoneos-arm64e.deb`。
* 产物结构校验：控制信息 / `postinst`(0755) / `conffiles` / 两个 dylib(0755) / 两个 filter plist / `alert.caf` / 默认配置。
* 二进制校验：两个 dylib 均为 `arm64 + arm64e` fat；`minos 15.4`；依赖
  `@loader_path/.jbroot/usr/lib/libroothide.dylib`、`@loader_path/.jbroot/usr/lib/libsubstrate.dylib`；
  detector 不含 AVFoundation/AudioToolbox（设计目标达成）；`ldid` 签名成功、无 entitlement。
* 提醒音 `Resources/alert.caf` 由脚本生成并用 macOS CoreAudio（`afinfo`/`afconvert`）验证可解析为 44100 Hz / 16bit / mono LPCM。
* **39 项 host 单测全部通过**（`tests/run_host_tests.sh`）：配置解析、AlertMode 推导、数值钳制、
  中文/大小写/包含/完整/前缀匹配、空关键词不触发、IgnoreSenders、声音路径解析、去重 TTL。
* 设置界面打包校验：`Library/PreferenceBundles/KeywordSMSAlertPrefs.bundle/`（可执行文件 arm64+arm64e +
  Info.plist + en/zh-Hans 本地化 + 三个尺寸图标）与 `Library/PreferenceLoader/Preferences/KeywordSMSAlert.plist`
  均在 deb 内；bundle 只依赖 Foundation/CoreFoundation/UIKit/Preferences（不含 substrate/roothide/AVFoundation）。

**尚未实机验证（需要你在设备上确认，日志会给出依据）：**

* `SMSServiceSession` 的两个选择器与字典键：来自公开的实机 trace（iOS 14.1 设备），
  iOS 15.4.1 上没有公开类转储可直接对照 —— 因此代码在运行时校验选择器存在性，
  并在缺失时打印 `diagnostics: SMSServiceSession … relevant: [...]`。
* `IMDMessageStore` 系列选择器：签名来自 iOS **15.6** 运行时头文件转储（公开 ktool dump），
  属于 iOS 15 系证据，但非 15.4.1 逐字对照；同样运行时校验。
* 电源键：类与 ivar 已在 iPhoneOS 15.2/15.6 SpringBoard 符号表中验证，方法名有 iOS 13.6/14.0 头文件与
  iOS 14–16 真实 tweak（含 roothide 构建的 RemoteCompanion）佐证；但**没有 iOS 15.4.1 的方法级类转储可逐字对照**，
  且“**屏幕全黑时是否也走 `-buttonDown:` / `-performInitialButtonDownActions`**”属于强结构推断而非已证事实。
  5 分钟实机探针（建议做，做完就能定论）：

  ```bash
  # 1) 打开 DebugEnabled=1，respring 后观察日志中的挂载结果，例如：
  #    hooked SBSleepWakeHardwareButtonInteraction -consumeInitialPressDown
  #    hooked SBLockHardwareButtonActions -performInitialButtonDownActions
  #    hooked SBLockHardwareButton -buttonDown:
  #    若某个显示 "not available"，说明该 build 换了名字（把 diagnostics 行发我即可补齐）
  # 2) 亮屏未锁屏按一次电源键 -> 期望看到 consumeInitialPressDown / performInitialButtonDownActions / buttonDown:
  # 3) 熄屏已锁屏按一次电源键（唤醒）-> 期望同样看到上述 DOWN 行
  # 4) 用“辅助触控 → 锁定屏幕”代替按键 -> 期望【不】出现 DOWN 行（证明没有误判）
  ```

  如果第 3 步确实一行都没有，那么熄屏唤醒只能退化为“按时长自动结束”；报告明确不建议改用
  IOHIDEventSystemClient（需要 HID entitlement，且是稳定性最差的方案）。
* 震动/声音在实机上的主观效果与响度（受系统媒体音量影响）。

---

## 11. 构建与复现

```bash
export THEOS=$HOME/theos          # roothide/theos
cd KeywordSMSAlert
make clean && make package FINALPACKAGE=1     # -> packages/KeywordSMSAlert_1.0.5_iphoneos-arm64e.deb
./tests/run_host_tests.sh                     # 39 项逻辑单测（macOS 本地）
```

`Makefile` 关键点：`THEOS_PACKAGE_SCHEME = roothide`、`ARCHS = arm64 arm64e`、
`TARGET = iphone:clang:latest:15.4`、`-lroothide`、两个 `TWEAK_NAME`。
`THEOS_PACKAGE_NAME = KeywordSMSAlert` 让 deb 文件名整洁（包标识仍是 `com.keyword.smsalert`）。

---

## 13. 设置入口没出现？排查清单

按顺序执行（在设备终端 / Filza）：

```bash
# 1) PreferenceLoader 到底装没装（这是最常见原因）
dpkg -l | grep -i preferenceloader
ls -l /Library/PreferenceLoader/            # bootstrap shell 里 / 即 jbroot
#    没装 -> Sileo 里搜 PreferenceLoader（roothide 源）安装，然后 killall -9 Preferences

# 2) 我们的入口 plist 与 bundle 是否就位
ls -l /Library/PreferenceLoader/Preferences/KeywordSMSAlert.plist
ls -l /Library/PreferenceBundles/KeywordSMSAlertPrefs.bundle/
cat /Library/PreferenceLoader/Preferences/KeywordSMSAlert.plist   # 应含 isController = 1

# 3) 重启「设置」App 让它重新扫描（安装时它可能已经在运行）
killall -9 Preferences

# 4) 看 PreferenceLoader 的日志（它会打印 processing / found an entry key / Discarding specifier…）
log stream --predicate 'eventMessage CONTAINS "PreferenceLoader"' --style compact
```

常见结果对照：

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 没有 `/Library/PreferenceLoader` 目录 | 未安装 PreferenceLoader | 装 `preferenceloader`，`killall -9 Preferences` |
| 日志出现 `Discarding specifier for missing isBundle bundle` | bundle 不在 `/Library/PreferenceBundles` | 重新安装本 deb |
| 入口在、bundle 在，但列表里没有 | 「设置」App 未重启 | `killall -9 Preferences` 或 respring |
| 列表里出现了但点进去空白/闪退 | 面板加载失败 | 把 `log stream` 中 `KeywordSMSAlert` 相关行发我 |
| 有 PreferenceLoader，仍不出现 | 入口 plist 未被扫描（权限/路径） | `chmod 644` 该 plist，并确认在 `…/Preferences/` 下 |
| **设置里换了声音，提醒音却没变** | 1.0.3 及更早：选择器行的「行标识」被当成配置键用，值写进了 `SoundPicker` 而不是 `SoundFile`（1.0.5 已修） | 装 1.0.5 → **重新选一次**（写入 `SoundFile`）→ `ksactl status` 看 `SoundFile` 是否 `[exists]`；历史误写的键可清掉：`ksactl set SoundPicker default` |

**兜底**：即使设置入口一直不可用，功能与配置也不受影响 —— 用 `ksactl`（§8.2）改配置、`ksactl test` 验证提醒。


---

## 14. 应急开关与写操作审计

### 14.0 从 1.1.3 及更早版本升级到 1.1.4（重要）

1.1.4 是一次**架构变更**：包内不再有 `KeywordSMSAlertAlert.dylib` 与它的 SpringBoard filter plist，
新增 `/usr/libexec/ksaalertd` 与 `/Library/LaunchDaemons/com.keyword.smsalert.alertd.plist`。

* 用 Sileo 直接覆盖安装即可（同包标识 `com.keyword.smsalert`），升级不会覆盖你的配置；
* `postinst` 会自动重启 imagent 并尽力 `launchctl bootstrap` 新守护进程；
* **升级后做一次 Dopamine「重启用户空间」**，让残留的旧 SpringBoard dylib 彻底不再被加载；
* 之后任何版本都不再需要 respring —— 提醒引擎是独立进程，改配置即时生效。

在「设置 → KeywordSMSAlert → 诊断 → 提醒服务状态」可以看到守护进程是否运行、电源键监听是否注册，
不需要 SSH 或终端。

### 14.1 一键停用（不需要卸载）

```bash
ksactl set Enabled false      # 关掉总开关（提醒引擎停止工作）
ksactl reload                 # 让守护进程与 imagent 立刻重读配置
```

`Enabled = false` 时 imagent 侧只读轮询直接返回（不查库、不匹配、不发通知），守护进程也停止提醒。
要彻底停止守护进程本身：

```bash
launchctl bootout system/com.keyword.smsalert.alertd   # 停止提醒守护进程（重启后仍会自动加载）
dpkg -r com.keyword.smsalert                           # 卸载：prerm 会先 bootout，无残留进程
```

**1.1.4 起不再有 SpringBoard 组件**，因此 `ksactl safemode`（1.1.3 的 SpringBoard hook 隔离开关）
已无实际作用，仅保留兼容。旧版 `safemode` 标记文件的存在不影响 1.1.4 的任何行为。

### 14.2 检测方式（1.1.2 起默认无 Hook）

| `DetectionMode` | 默认 | 机制 | 风险 / 代价 |
| --- | --- | --- | --- |
| **只读轮询 sms.db** | **唯一方式（1.1.2 起）** | 在 imagent 内只读轮询 `sms.db`（`SQLITE_OPEN_READONLY`，私有串行队列，`PollInterval` 默认 **1.0 s**） | **imagent 内零 Hook**（Hook 代码已从 dylib 中删除），不写库、不碰消息管线 → 不可能影响收信；代价约 1 秒延迟 |

> **事故记录（2026-10-05）**：1.0.x 默认使用 Hook 方案，真机上出现「完全收不到短信」，卸载 + 用户空间重启后恢复。
> 由于无法取得当时的崩溃栈，1.1.2 改为**默认不 Hook**的只读轮询方案：从机制上消除"插件影响收信"的可能。
> 想回到零延迟可显式设置 `DetectionMode = hooks`（自担风险），两个兜底 Hook 仍默认关闭。

| 配置键（仅 `hooks` 模式生效） | 默认 | 说明 |
| --- | --- | --- |
（`hooks` 模式与 `HookMessageStoreBackstop` / `HookServiceSessionBackstop` / `DetectionMode` 已在 1.1.2 **全部移除**：
1.0.x 的 Hook 方案会造成 imagent 崩溃循环，见 §14.2 事故记录）

### 14.3 这个插件会删除短信吗？——不会（写操作审计）

代码里**所有**会修改外部状态的调用只有三处，全部作用于本插件自己的文件，与短信、短信数据库、消息对象无关：

| 代码位置 | 写的是什么 |
| --- | --- |
| `KSAPrefsStore` / `ksactl` | 本插件的配置文件 `com.keyword.smsalert.plist` |
| `KSALog` | 本插件自己的日志文件（可选，超 256 KB 轮转） |
| `KSASoundConverter` / `KSASoundPickerController` | 试听/转码用的临时 `alert-*.caf`（在 `<jbroot>/Library/KeywordSMSAlert/` 或 Settings 沙箱） |

对短信侧，插件只做**只读**操作：

* 所有 Hook 都是 `id result = %orig;`（或 `%orig;`）→ **先执行系统原实现，参数一个都不改，返回值原样返回**，之后才读消息对象；
* 读消息只用 KVC（`valueForKey:` 取 `plainBody` / `body` / `guid` / `sender` / `service` / `isFromMe`），**没有任何 setter**；
* 源码中**不存在** `sqlite3`、`INSERT/UPDATE/DELETE`、`deleteMessage`、`removeItem`（针对 `sms.db`）等调用 —— 可用
  `grep -rnE "sqlite3|DELETE|deleteMessage|INSERT" Sources/` 自行复核（只会命中注释与 `ksactl db` 的只读查询）。

### 如果发现「有提醒，但信息里看不到这条短信」

按顺序排查（绝大多数是「信息」App 视图缓存或过滤，而不是短信被删）：

1. **强制退出「信息」App 再打开**。`postinst`/`ksactl restart` 会重启 imagent，正在运行的「信息」App 可能仍抱着旧视图/旧连接，看不到新到达的短信。
2. **检查过滤**：`设置 → 信息 → 过滤未知发件人`（未知短号/服务号会被分到「未知发件人」列表）；若有第三方短信过滤 App（腾讯/360 等）也会单独归类。
3. **直接用只读查询确认数据库里到底有没有**：

   ```bash
   ksactl db 20        # 只读(SQLITE_OPEN_READONLY) 列出 sms.db 最新 20 条 + 总条数
   ```
   * 能查到这条 → 短信**已入库**，只是「信息」App 没显示（回到第 1 步，或看第 2 步的过滤）。
   * 查不到 → 说明它从未入库，而插件不写库（见上面的审计），此时要看是不是第三方过滤/运营商侧问题，或安装过程中 imagent 正在重启那 1–2 秒内到达（`postinst` 会重启 imagent）。
4. **A/B 对照**（可选）：1.1.1 起检测侧已经**没有任何 Hook 可关**（`DetectionMode` / `HookMessageStoreBackstop` /
   `HookServiceSessionBackstop` 已全部删除，二进制里可 `strings | grep -c hooked` 验证为 0），所以现在的隔离手段是：

   ```bash
   ksactl safemode on        # SpringBoard 侧一个 hook 都不装
   dpkg -r com.keyword.smsalert && killall -9 imagent && killall -9 SpringBoard   # 彻底排除
   ```
   若问题依旧/消失都只是用来定位，不代表插件写数据（插件没有写数据的代码路径）。

## 12. 后续扩展

* ~~PreferenceBundle（设置面板）~~ —— **已完成**（Settings → KeywordSMSAlert）。
* iMessage 支持：`IncludeIMessage = 1` 已预留通路（判定逻辑已实现）。
* 电源键熄屏路径：按 §10 的探针确认是否已覆盖；若某 build 改名，据诊断日志补一个选择器即可。
* 提醒时点亮屏幕 / 自定义来电级全屏提醒（需要额外风险评估，暂不做）。

## 15. 版本记录

| 版本 | 要点 |
| --- | --- |
| **1.1.4** | **零 SpringBoard 注入 + 独立提醒守护进程**。实机 A/B（Diagnostic A/B/C）证明：与电话助手 2.5.1 共存时，只要再向 SpringBoard 注入任何 dylib（含只有一个空构造器的 probe）就会导致用户空间重启持续黑屏；禁用全部 hook 也无效，完全不注入则恢复为「黑约 1 秒后正常」。故：① 删除 `KeywordSMSAlertAlert.dylib` 与 SpringBoard filter plist；② 新增 `ksaalertd`（mobile LaunchDaemon）承载提醒引擎；③ 电源键停止改为 IOHID **只观察**监听（`type=3`、`Consumer 0x0C/Power 0x30` 按下沿，需 HID entitlement）；④ 设置面板新增「提醒服务状态」，无需 SSH 即可确认守护进程与按键监听状态；⑤ `TestAlertOnLoad` 语义改为「守护进程启动 3 秒后」 |
| **1.1.3** | **启动期零 hook**：`%ctor` 不装任何 hook，电源键/锁屏 hook 改为「第一个提醒开始时」按需安装；**删除兜底发现式挂载**（不再碰 `SBBacklightController`，这是与其它 SpringBoard 插件共存时的黑屏诱因）；`consumeInitialPressDown` 改为先 `%orig` 再观察；新增 `ksactl safemode on/off/status` 应急开关（标记文件存在则一个 hook 都不装） |
| 1.1.2 | `PollInterval` 改完立即生效（免重启）+ 加入设置面板「行为」分组（0.5–30 s，默认 1.0） |
| 1.1.1 | 彻底删除 `hooks` 模式与 `DetectionMode` / `HookMessageStoreBackstop` / `HookServiceSessionBackstop`；配置文件不再作为 dpkg conffile（`postinst` 首次生成）→ 升级无提示、不覆盖 |
| 1.1.0 | 检测改为**默认无 Hook 的只读轮询 sms.db**（修复真机「完全收不到短信」） |
| 1.0.7 | 安全默认值：`Enabled = false` 时 imagent 侧零 Hook；补应急说明 |
| 1.0.6 | `ksactl db`（只读查库）+ 兜底 Hook 开关 |
| 1.0.5 | 声音列表点按试听 |
| 1.0.4 | 修「选系统提示音不生效」（行标识误当配置键）+ m4r/mp3 自动转 CAF |
| 1.0.3 | 铃声/提醒音量通道（`SoundChannel = alert`）+ 声音选择器 + `postinst` 自动重启 imagent |
| 1.0.2 | 设置入口 `isController = 1` + `ksactl` 命令行兜底 |
| 1.0.0 | 首版：双 dylib（imagent 检测 / SpringBoard 提醒 + 电源键） |
