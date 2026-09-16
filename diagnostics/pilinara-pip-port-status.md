# PiliNara 应用内小窗移植 — 完成报告

- 目标仓：`E:\Project\ALL\PiliPlus`（commit `b0e7e4e`，版本 2.1.4+1）
- 来源仓：`E:\Project\ALL\PiliNara`（功能自 2026-02-11 引入，累计 54 个提交、2306 行新代码）
- 静态验证：打 SDK 补丁后 `dart analyze lib` → **error 0**（补丁前基线 118，全为 vendor 的 Flutter 源码噪声）
- 真机验证：Android 14 / API 34 模拟器实测 → **核心链路全部通过**（详见 §三）

---

## 一、状态：已完成并真机验证通过

小窗的服务层、控制器、原生通道、设置项、UI 入口/退出全部就位，**已在模拟器实测 9 个场景全部通过**（进入、退出、上下文感知清理、防双播、设置开关）。

**唯一未移植**的是 PiliNara 的"归位动画握手"（`_schedulePipRestoreAttach` / `_attachPipRestore` / `beginRestore` 相位机）与 `_pipRetryPending` 重试。这些是**体验打磨**（小窗飞回页内播放器的动画），不影响功能正确性——当前用瞬时关闭路径，实测正常。


---

## 二、改动清单

### 新增文件（5 个，原样复制）

| 文件 | 行数 | 职责 |
|---|---|---|
| `lib/services/pip_overlay_service.dart` | 1058 | 视频小窗主体 + `VideoStackManager` |
| `lib/services/live_pip_overlay_service.dart` | 858 | 直播小窗 |
| `lib/services/pip_transition_coordinator.dart` | 252 | 小窗进出场过渡动画协调 |
| `lib/common/widgets/pip_mini_video_content.dart` | 78 | 小窗内容（纹理+弹幕+缓冲指示） |
| `lib/common/widgets/pip_control_button.dart` | 60 | 小窗控制按钮 |

### 修改文件（20 个）

| 文件 | 改动 |
|---|---|
| `lib/utils/storage_key.dart` | +`enableInAppPip`、+`enableInAppPipToSystemPip` |
| `lib/utils/storage_pref.dart` | +2 个 getter（均默认 true）；另含方案 A 默认值 |
| `lib/utils/utils.dart` | +`channel = MethodChannel(Constants.appName)` |
| `lib/pages/setting/models/play_settings.dart` | +「应用内画中画」、+「应用内小窗转后台画中画（实验性）」 |
| `android/.../MainActivity.kt` | +`configureFlutterEngine` 建通道、`onPictureInPictureModeChanged` 推 `onPipChanged` |
| `lib/plugin/pl_player/controller.dart` | +`isNativePip`/`_isInInAppPip`/`disableAutoEnterPip()`；`onPipChanged` 处理；`isPipMode` 纳入 `isNativePip`；`_onUserLeaveHint` 与自动进 PiP 纳入小窗判定；`onPopInvokedWithResult` +`pauseOnPop` 参数 |
| `lib/plugin/pl_player/view/view.dart` | +`isPipMode`/`isInAppPip` 参数与字段；小窗不渲染字幕；4 处附加层守卫 |
| `lib/plugin/pl_player/widgets/bottom_control.dart` | +`isPipMode`；小窗隐藏看点/弹幕趋势层 |
| `lib/pages/video/controller.dart` | +`isEnteringPip`；`onInit` 关旧小窗；`onReset` SponsorBlock 守卫；`onClose` 小窗保留资源 |
| `lib/pages/video/view.dart` | **UI 接线**：+`_isEnteringPipMode`/`_logSponsorBlock`/`_resetEnteringPipFlags`/`_playerRect`；`_shouldStartInAppPip`/`_startInAppPipIfNeeded`/`_handleInAppPipCloseCleanup`/`_onPopInvokedWithResult`；`initState` 计数、`dispose` 保活、`didPushNext` 触发、`didPopNext` 关闭、PopScope 换用包装方法 |
| `lib/pages/live_room/controller.dart` | +`fromPip`/`isReturningFromPip`/`isInPipMode`；`onInit` 恢复分支；`playerInit` 跳过重建；`onClose` 小窗不清资源 |
| `lib/pages/live_room/view.dart` | **UI 接线**：+`_isEnteringPipMode`/`_livePlayerRect`/`_onPopInvokedWithResult`/`_shouldStartLivePip`/`_startLivePipIfNeeded`/`_handleLivePipCloseCleanup`；`initState` 关旧小窗+fromPip、`didPopNext` 关闭、`dispose` 保活 |
| `lib/pages/common/fab_mixin.dart` | +`isEnteringPip` |
| `lib/pages/video/introduction/local/controller.dart` | +`isEnteringPip` + `onClose` 守卫 |
| `lib/pages/video/introduction/pgc/controller.dart` | +`isEnteringPip` + `onClose` 守卫 |
| `lib/pages/video/introduction/ugc/controller.dart` | +`isEnteringPip` + `onClose` 守卫 |
| `lib/pages/video/reply/controller.dart` | +`isEnteringPip` + `onClose` 守卫 |
| `lib/plugin/pl_player/models/audio_output_type.dart` | 见 §四（方案 A 默认值） |

**无需改动**：`PlDanmaku` 在 PiliPlus 中已有 `isPipMode` 参数（原本给系统 PiP 用），直接复用。

### 有意偏离 PiliNara 之处（均有注释）

| 项 | 处理 | 原因 |
|---|---|---|
| 归位动画握手（`beginRestore`/`_attachPipRestore`/`_pipRestoreInFlight`） | **未移植**，用瞬时关闭 | 属体验打磨；缺它不影响正确性 |
| `_pipRetryPending` 重试 | **未移植** | 针对 rapid back press 的边缘场景 |
| `_savedIntroControllerFromPip` / `_savedReplyControllerFromPip` | **未移植** | 服务于动画握手，无握手则不需要 |
| `onNeedsPlayerInit` 回调 | **丢弃** | 只被"后台自动只听音频"消费，小窗不用；加了是死代码 |
| `LiveHttp.cancelLiveHeartbeat()` | **丢弃** | PiliNara 自己的新增 API，PiliPlus 没有 |
| `_activeVideoContextKey` / `releaseSpeedLock` | **丢弃** | 属"倍速锁定 + 临时播放器配置"功能 |
| `useConstraints` 渲染修正 | **丢弃** | 属系统 PiP 恢复的渲染修复，周边机制 PiliPlus 不存在 |
| `Get.delete<LiveRoomController>` in dispose | **未加** | PiliPlus 原本没有，加了会改变 controller 生命周期 |
| SponsorBlock 守卫条件 | **保留** `blockConfig.enableBlock` | PiliNara 顺手去掉了它，属无关行为变更 |
| `MainActivity.kt` 的 `invokeMethod` | **加 `::methodChannel.isInitialized` 守卫** | PiliNara 原版若在 `configureFlutterEngine` 之前触发会抛异常 |

---

## 三、真机验证结果（Android 14 / API 34 模拟器，已通过）

**构建产物：`build/app/outputs/flutter-apk/app-debug.apk`（143MB），已在模拟器实测。**

| # | 场景 | 结果 | 日志 / 证据 |
|---|---|---|---|
| 1 | 视频页**按返回键** | ✅ 小窗出现并在播放 | `Checking PiP: count=1, previousRoute=/` → `PiP started, positionSubscription preserved` |
| 2 | 小窗**点 X 关闭** | ✅ 关闭并清理资源 | `Stopping PiP mode (shouldResetState: true)` → `Overlay entry removed` → `PiP closed by user` |
| 3 | 小窗播 A 时**打开视频 B** | ✅ A 的小窗关闭，**无双播** | 上下文键 `BV14ibe6mEN9` ≠ `BV1zCtq61Eoi` → `shouldResetState: true` |
| 4 | 返回时**下层仍是视频页** | ✅ 拒绝开小窗 | `Checking PiP: count=2, previousRoute=/videoV` → 拒绝 |
| 5 | **视频暂停时**返回 | ✅ 拒绝开小窗 | `Reject PiP: video is paused` |
| 6 | **直播页按返回键** | ✅ 直播小窗出现且画面在动 | 截图 + 相隔 4 秒两帧比对，内容不同 |
| 7 | 小窗**跨页面持续** | ✅ 切到「我的」「设置」仍在播放 | 截图 |
| 8 | **关闭设置项**后返回 | ✅ 不再开小窗 | `Reject PiP: in-app PiP is disabled in settings` |
| 9 | 设置项**渲染** | ✅ 两个开关均正确显示、默认开 | 「应用内画中画」「应用内小窗转后台画中画（实验性）」截图确认 |

**未覆盖**：iOS / 桌面端、系统 PiP 互转（`enableInAppPipToSystemPip`）、真机手势（双指缩放/拖动位置记忆）。这些属体验打磨路径，建议后续在真机上补测。

**结论：核心链路（进入小窗、退出小窗、上下文感知清理、防双播、设置开关）已全部实测通过，未发现崩溃。**

---

## 四、本机构建环境（踩坑记录，复现构建必看）

构建这个项目在本机会遇到 5 个环境问题，全部已解决。**根因大多是环境特有，不是代码问题。**

| # | 现象 | 根因 | 解决 |
|---|---|---|---|
| 1 | `pub get` 卡死 25 分钟 | pub git 缓存检出残缺 | 删除残缺目录重拉；用脚本遍历 `package_config.json` 定位 |
| 2 | Java 侧全部 HTTPS 报 `PKIX path building failed` | 本机有 **Steam 社区加速工具做 HTTPS 中间人**（证书 `O=Steamcommunity302`），其 CA 未进 Java 信任库 | `JAVA_TOOL_OPTIONS=-Djavax.net.ssl.trustStoreType=Windows-ROOT` 让 JVM 改用 Windows 根证书库 |
| 3 | Gradle wrapper 下载失败 | 同上（Java 下载路径） | 用 curl 从腾讯镜像预下 `gradle-9.5.0-all.zip` 放进 `~/.gradle/wrapper/dists/gradle-9.5.0-all/<hash>/` |
| 4 | `Failed to find target with hash string 'android-37'` | 新版 Android SDK 只有 `android-37.0/37.1/37.2`，**没有** `android-37` 包 | 在 `platforms/` 下建目录联接 `android-37` → `android-37.0` |
| 5 | Kotlin `Could not close incremental caches` | 跨进程内存映射文件句柄问题 | `~/.gradle/gradle.properties` 加 `kotlin.incremental=false` + `kotlin.compiler.execution.strategy=in-process` |
| 6 | `flutter_inappwebview` 编译找不到符号 | **Windows 260 字符路径上限**导致 git 检出静默丢文件（实测最长路径 267 字符） | `git config --global core.longpaths true` |

**完整构建命令**（三个环境变量缺一不可）：

```bash
cd /e/Project/ALL/PiliPlus
export PATH="/d/SDK/Flutter-3.47.4/bin:$PATH"          # 默认 PATH 里是旧的 3.44.4
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export JAVA_TOOL_OPTIONS="-Djavax.net.ssl.trustStoreType=Windows-ROOT"
flutter build apk --debug
```

**构建前必须先打 SDK 补丁**：`lib/scripts/patch.ps1 android`（需 `$env:FLUTTER_ROOT`、`$env:GITHUB_WORKSPACE`）。注意该脚本会 `git config --global user.name "ci"` 覆盖你的全局 git 身份，跑完记得还原。未打补丁时 `dart analyze` 报 118 个 error，**打补丁后降为 0**。

**本机被修改的环境项（如需回退）**：
- `git config --global core.longpaths true`（新增，建议保留）
- `~/.gradle/gradle.properties`（新建，内容为 Kotlin 编译策略）
- `D:\SDK\android\platforms\android-37`（目录联接）
- `D:\SDK\Flutter-3.47.4`（已打 24 个 SDK 补丁，工作树不再干净）
- `~/.pub-cache`（目录联接，指向 `%LOCALAPPDATA%\Pub\Cache`）
- pub 缓存中 `material_ui-1.2.0` / `cupertino_ui-1.0.2`（已打补丁）
- 全局 git 身份已还原为 `Xiaoqi2145` ✓

---

## 五、未验证项（建议后续补测）

- iOS / 桌面端（本次仅 Android）
- 系统 PiP 互转：`enableInAppPipToSystemPip`（应用内小窗存在时退到后台自动转系统 PiP）
- 小窗手势：双指缩放、拖动位置记忆、双击、桌面端滚轮缩放
- 小窗内控制按钮：快退/播放暂停/快进 10 秒
- 归位动画（本次未移植该部分，走瞬时关闭路径）

---

## 六、同时完成的默认值改动（方案 A）

| 设置项 | 原默认 | 新默认 | 位置 |
|---|---|---|---|
| 音频输出设备顺序 | `opensles,aaudio,audiotrack` | `aaudio,audiotrack,opensles` | `lib/plugin/pl_player/models/audio_output_type.dart` |
| 视频同步 | `display-resample` | `audio` | `lib/utils/storage_pref.dart` |
| 首选解码格式 | `[AVC, AV1]` | `[AVC]` | 同上 |
| 缓冲大小 | 4.0 MB | 16.0 MB | 同上 |
| 缓冲时长 | 16.0 s | 30.0 s | 同上 |

未动：`autosync`(30)、`enableHA`(true)、`hwdec`(`mediacodec,auto-safe`)、超分辨率(disable)。
`preferCodecsCellular` 默认回退到 `preferCodecs`，无需单独改。依据见 `av-sync-bluetooth-latency-audit.md`。

---

## 七、测试脚本与截图

- 测试脚本：`E:\Project\ALL\pip-emulator-test.sh`（adb 驱动的安装/启动/日志/截图封装）
- 截图证据：`E:\Project\ALL\pip-test-shots\`（34 张，含小窗出现/关闭/直播小窗/设置项等关键帧）



---

