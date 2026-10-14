# Sources/Diagnostics — 诊断专用文件（绝不进入默认构建）

本目录存放历史诊断构建变体使用的 MobileSubstrate 过滤 plist：

| 文件 | 过滤目标 | 用途 |
|---|---|---|
| `KeywordSMSAlertAlert.plist` | `com.apple.springboard` | 1.1.x 时代 Alert dylib 注入 SpringBoard 的过滤器（诊断 A/B 用） |
| `KeywordSMSAlertSpringBoardProbe.plist` | `com.apple.springboard` | 诊断 C：最小 SpringBoard probe 的过滤器 |

## 为什么从仓库根目录移到这里

这两个文件**不属于**当前架构（1.2.0 起只注入 `com.apple.imagent`，无任何
SpringBoard 组件）。留在根目录有两个风险：

1. 视觉上误导排查者以为插件仍注入 SpringBoard；
2. 被诊断变体的 `after-stage` 通配规则意外拷入发布包。

**本设备已实测确认：任何额外注入 SpringBoard 的 dylib 都会把电话助手约 1 秒的
启动黑屏放大为永久黑屏**（诊断 A/C 均复现）。因此默认构建严禁出现这两个文件。

## 默认构建不受影响

默认变体（`KSA_BUILD_VARIANT = imagent`）只 stage：

- `Library/MobileSubstrate/DynamicLibraries/KeywordSMSAlertDetector.dylib` + `.plist`（仅 `com.apple.imagent`）
- `Library/PreferenceBundles/KeywordSMSAlertPrefs.bundle`
- `Library/PreferenceLoader/Preferences/KeywordSMSAlert.plist`
- `usr/bin/ksactl`
- `Library/KeywordSMSAlert/alert.caf`

仅当显式使用诊断变体（`KSA_BUILD_VARIANT = minimal-springboard` 等）时，
对应的诊断过滤器才会被 `after-stage` 拷贝进包。发布前必须用
`tests/verify_release_artifact.sh` 核验产物内无 SpringBoard 组件。
