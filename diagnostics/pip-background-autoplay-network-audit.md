# 应用内小窗后台自动切集卡顿 — 检查与修复

- 目标仓：`E:\Projects\PiliPlus`，分支 `main`
- 用户报告：**播放器后台运行时，播放结束后自动切集会卡网络；尤其是以应用内小窗进入后台的时候。**
- 审查方式：**静态审查 + 单元测试**。App 源码 + 依赖源码（`getx` git fork、`media_kit` git fork、`audio_service` git fork）。
- 未做真机复现；凡属"运行时行为"的推断都在文中标注了依据。
- 静态验证：`dart analyze lib test` → **0 error / 0 warning**（41 条 info，与修复前基线一致）；`flutter test --no-pub` → **34/34 通过**（新增 10 条）。

---

## 0. 结论摘要

**问：后台播放结束自动切集为什么会卡网络？为什么小窗进入后台时尤其明显？**

> **存在两条独立缺陷，都会让"播完自动切集"整条链路断掉；小窗场景同时踩中两条。**

| # | 缺陷 | 触发条件 | 后果 |
|---|---|---|---|
| **A** | 视频页 `dispose()` **无条件摘掉播放状态监听** | 以应用内小窗进入后台（小窗由 pop 视频页开启，页面必然销毁） | `stream.completed` 无人接收 → 无人调用 `nextPlay()` → **播放停在片尾**；过渡态兜底到期后前台服务与唤醒锁一起被回收 |
| **B** | WBI 签名密钥的**失败结果被永久钉在静态字段** | 后台弱网/切网抖动让密钥请求抛异常 | 之后**所有** WBI 签名请求立刻复用同一个失败结果，**完全不再发网络请求** → playurl 全灭 |

两者叠加的解释力：

- **A** 解释了"以应用内小窗进入后台时尤其明显"——普通后台（`didPushNext`）路径有保活注释护着，而 pop 路径没有；小窗恰恰是 pop 开启的。
- **B** 解释了"卡网络"这一措辞——不是慢，而是**根本不发请求**。

还有第三条（C）与 A 同源：即使监听被保住，被小窗托管的 controller 在路由销毁后 `isClosed == true`，会让切集链路上的多个守卫**静默丢弃**地址请求。A 与 C 必须一起修，否则监听保住了、链路仍是断的。

---

## 1. 链路全景：小窗期间"播完"到底该由谁驱动

```
mpv stream.completed = true
  └─ PlPlayerController._startListeners  (pl_player/controller.dart:1076)
       ├─ videoPlayerServiceHandler.beginTransition()      ← 保前台服务/唤醒锁
       ├─ playerStatus.value = .completed
       └─ for (listener in _statusListeners) listener(.completed)
            └─ ★ view.dart playerListener(status)           ← 唯一的连播驱动
                 └─ if (status.isCompleted) introController.nextPlay()
                      └─ ugc/pgc onChangeEpisode → queryVideoUrl()
```

**关键事实：整条链路上，能调用 `nextPlay()` 的 `PlayerStatus` 监听者只有一个**——视频页 State 的 `playerListener`。全量枚举 `addStatusLister` 调用点：

| 位置 | 是否会在 completed 时连播 |
|---|---|
| `pages/video/view.dart:481/510/618/850` | **是**（`playerListener`，`:543` 判定 `isCompleted`） |
| `pages/danmaku/view.dart:64` | 否（只暂停/恢复弹幕画布） |
| `pages/live_room/view.dart:144/234` | 否（仅直播） |
| `common/widgets/pip_mini_video_content.dart` | **未注册任何状态监听**（只有纹理 + 弹幕 + 缓冲指示） |

小窗内容刻意做得极轻（与页面副本解耦），因此**它自己不会驱动连播**。小窗里的连播完全依赖"页面那份监听仍在"。

---

## 2. 缺陷 A：页面销毁时把连播驱动一起摘掉了

### 2.1 代码事实

小窗由 **pop** 触发（`view.dart:319 _onPopInvokedWithResult(didPop=true)` → `:328 _startInAppPipIfNeeded()`），页面随后被销毁，`dispose()` 执行（修复前 `view.dart:638-640`）：

```dart
@override
void dispose() {
  VideoStackManager.decrement();
  final isInAppPip = PipOverlayService.isInPipMode;

  plPlayerController
    ?..removeStatusLister(playerListener)        // ← 无条件摘除
    ..removePositionListener(positionListener);
  ...
```

同一文件 `didPushNext()`（push 路径）却专门为小窗保活（`:726-733`）：

```dart
if (shouldKeepAlive) {
  // The hidden video page remains the owner of automatic list playback
  // while the in-app PiP overlay is active. Keep the listeners attached
  // so completion can still call introController.nextPlay() in the
  // background; removing them here leaves the PiP player stuck at EOF.
  if (willStartPip) _startInAppPipIfNeeded();
}
```

**注释描述的意图（保留监听以便后台连播）是对的，但 pop 路径没有同步实现它。** 小窗恰恰走 pop，于是"保住监听"的设计在实际路径上被 `dispose()` 推翻。

### 2.2 后果链

监听被摘 → `stream.completed` 到达时 `_statusListeners` 为空 → 无人 `nextPlay()`。与此同时：

- `audio_handler.beginTransition()`（`:202`）已经把状态推成 `buffering`，并起了 `_kTransitionTimeout = 45s` 的兜底定时器；
- 无人调用 `extendTransition()` 续命（续命点在 `_getVideoUrlWithRetry` 与 `_recoverStreamAfterError`，都因没有下一集请求而不会执行）；
- 定时器到点 → `endTransition(playing: false)` → `processingState: idle` → audio_service `_stop()` → 退出前台服务 → 释放 `PARTIAL_WAKE_LOCK`（`AudioService.java:715-724`）。

于是后台既没有下一集、也不再持有 CPU 锁——用户看到的正是"播完卡住 / 卡网络"。

### 2.3 修复

**把监听移交给小窗会话保管**，由 `stopPip` 统一摘除，而不是让它在页面销毁时消失。

`lib/services/pip_overlay_service.dart` 新增：

```dart
static ValueChanged<PlayerStatus>? _adoptedStatusListener;
static ValueChanged<Duration>? _adoptedPositionListener;

/// 页面销毁时是否把播放监听移交给小窗会话。
static bool shouldHandOverListeners({
  required bool inPipMode,
  required bool savedControllerMatches,
  required bool hasPlayer,
}) => inPipMode && savedControllerMatches && hasPlayer;

static void adoptPlaybackListeners({...}) { ... }
static void releaseAdoptedPlaybackListeners() { ... }
```

`lib/pages/video/view.dart` `dispose()`：

```dart
if (PipOverlayService.shouldHandOverListeners(
  inPipMode: PipOverlayService.isInPipMode,
  savedControllerMatches:
      PipOverlayService.isSavedVideoController(videoDetailController),
  hasPlayer: plPlayerController != null,
)) {
  PipOverlayService.adoptPlaybackListeners(
    plPlayerController: plPlayerController!,
    onStatus: playerListener,
    onPosition: positionListener,
  );
} else {
  plPlayerController
    ?..removeStatusLister(playerListener)
    ..removePositionListener(positionListener);
}
```

释放点接在 `stopPip` 里、**清空 `_savedPlayerController` 之前**（释放需要它取实例）：

```dart
releaseAdoptedPlaybackListeners();
_savedController = null;
_savedPlayerController = null;
```

三个条件缺一不可的理由：

- `inPipMode`：不在小窗时保持原语义，普通返回不会留下悬挂监听；
- `savedControllerMatches`：小窗托管的可能是**别的**视频（从列表点开了新视频），此时本页必须摘掉自己的监听，否则会去驱动别人的播放；
- `hasPlayer`：播放器实例为空则无从挂载。

**为什么不会重复挂载**：同视频恢复时，新页面的 `didPopNext()`（`view.dart:849-851`）挂监听发生在 `stopPip` **之后**，此时旧监听已被摘除。

**兜底**：`startPip` 的 overlay 插入失败分支（`pip_overlay_service.dart:389-403`）也补了 `releaseAdoptedPlaybackListeners()`——否则小窗没建起来、页面又已销毁，监听会被留在一个已清空的会话里，无人摘除。

---

## 3. 缺陷 C：被托管的 controller 被 `isClosed` 静默拦住

### 3.1 代码事实

GetX 的 `SmartManagement.full`（默认值）在路由 dispose 时删除该路由注册的依赖：

```
default_route.dart:16  PageRouteReportMixin.dispose() → RouterReportManager.reportRouteDispose(this)
router_report.dart:46  reportRouteDispose → _removeDependencyByRoute
get_instance.dart:392  i.onDelete() → lifecycle.dart:78  _isClosed = true; onClose();
```

`VideoDetailController.onClose()` 在小窗进入时提前 return（`controller.dart:1529 if (isEnteringPip) return;`），**所以资源被刻意保住了**；但 `_isClosed` 已经被置为 `true`。而切集链路上有 4 处 `isClosed` 守卫：

| 位置（修复前） | 原代码 | 作用 |
|---|---|---|
| `controller.dart:833` | `if (isClosed \|\| isFileSource) return false;` | CDN 地址过期后的重取兜底 |
| `controller.dart:903` | `if (isClosed) return;` | `playerInit` 中 `setDataSource` 之后的元数据初始化 |
| `controller.dart:1039` | `if (_queryPending && !isClosed)` | 并发查询的补跑 |
| `controller.dart:1312` | `if (!isClosed && result != null)` | 字幕拉取 |

**后果**：小窗里连播到下一集时，这些守卫会**静默丢弃**地址请求——既拿不到新媒体源，也没有人结束过渡态。这与缺陷 A 的终点完全一致（前台服务 + 唤醒锁到期被回收），只是断点更靠后。

### 3.2 修复

引入"是否仍被小窗托管"的判据，只拦住**真正无人持有**的 controller：

```dart
// pip_overlay_service.dart
static bool ownsVideoController(VideoDetailController controller) =>
    isInPipMode && isSavedVideoController(controller);

static bool keepsPlaybackAlive({
  required bool isClosed,
  required bool ownedByPip,
}) => !isClosed || ownedByPip;

// controller.dart
bool get _isPlaybackOwnedByPip => PipOverlayService.keepsPlaybackAlive(
  isClosed: isClosed,
  ownedByPip: PipOverlayService.ownsVideoController(this),
);
```

三处守卫改为 `_isPlaybackOwnedByPip`。

`controller.dart:1312`（现 `:1324`）的字幕守卫**有意保留原样**：字幕只在页面可见时有意义，小窗不显示字幕（与 B 站官方及 pili++ 行为一致），放它继续拉取只是浪费流量。

---

## 4. 缺陷 B：WBI 密钥的失败结果被永久缓存

### 4.1 代码事实（修复前 `lib/utils/wbi_sign.dart`）

```dart
static Future<String>? _future;

static Future<String> _getWbiKeys() async {
  final resp = await Request().get(Api.userInfo);   // ← 在 try 之外
  try { ... } catch (_) { return ''; }
}

static FutureOr<String> getWbiKeys() {
  ...
  return _future ??= _getWbiKeys();                 // ← 失败结果永久驻留
}
```

`Request().get` 位于 `try` **之外**：网络异常会直接抛出，而抛出的 Future 已经存进进程级静态字段 `_future`。此后每次 `makSign` 都走 `_future ??= ...` 命中同一个失败的 Future：

- 抛异常的实现：**每次调用都重抛同一个异常**，网络请求数为 0；
- 返回 `''` 的实现：mixinKey 为空 → `w_rid` 恒定错误 → 服务端必然拒绝。

两条路径都表现为"**完全不发网络请求**"，与用户描述的"卡网络"精确吻合。后台弱网下 playurl 全灭，自动连播自然无法推进。

### 4.2 修复

每次拉取结束后清空 `_future`：成功时密钥已落盘，下次走同步命中（不会多发请求）；失败时允许重取。

```dart
static Future<String> _fetchWbiKeys() async {
  try {
    return await (debugFetchKeysOverride ?? _getWbiKeys)();
  } finally {
    _future = null;
  }
}
```

`getWbiKeys()` 的两条分支都改走 `_fetchWbiKeys()`；时间戳分支额外挂 `.whenComplete(() => _future = null)`，覆盖"连 `put` 都失败"的情况。

`debugFetchKeysOverride` 是 `@visibleForTesting` 注入点（真实路径依赖网络与 Hive）。

---

## 5. 改动清单

| 文件 | 改动 |
|---|---|
| `lib/services/pip_overlay_service.dart` | 新增监听托管（`adoptPlaybackListeners` / `releaseAdoptedPlaybackListeners` / `isSavedVideoController` / `ownsVideoController`）与两个判据（`keepsPlaybackAlive` / `shouldHandOverListeners`）；`stopPip` 与 `startPip` 失败分支接入释放 |
| `lib/pages/video/view.dart` | `dispose()` 改为条件移交监听 |
| `lib/pages/video/controller.dart` | 新增 `_isPlaybackOwnedByPip`；3 处 `isClosed` 守卫改为小窗感知 |
| `lib/utils/wbi_sign.dart` | 失败不再永久缓存；新增测试注入点 |
| `test/services/pip_playback_handover_test.dart` | 新增 7 条（监听归属 + 播放链路判据） |
| `test/utils/wbi_sign_retry_test.dart` | 新增 3 条（失败可重取 + 成功同步命中） |

### 5.1 新增测试覆盖

- 小窗活跃且托管本页 controller → 移交；不在小窗 / 托管他人 / 播放器不存在 → 不移交；
- 路由已销毁但被小窗托管 → 播放链路放行；已关闭且无人托管 → 照旧拦住；
- WBI：失败后**会再次发起拉取**（旧实现停在 1 次）；失败后恢复网络即可取到密钥；成功后走同步命中不重复拉取。

---

## 6. 验证

```
dart analyze lib test            → 41 issues（0 error / 0 warning，与修复前基线一致）
flutter test --no-pub            → 34/34 passed（原 24 + 新增 10）
dart format --set-exit-if-changed（改动文件）→ 仅剩仓库既有的历史格式差异
```

SDK：`D:\SDK\Flutter-3.47.4`（Dart 3.13.3，匹配 `pubspec.yaml` 的 `>=3.13.0`）。

> 注：仓库中 `lib/services/pip_overlay_service.dart`、`lib/pages/video/view.dart`、`lib/pages/video/controller.dart`、`lib/utils/wbi_sign.dart` 在当前 SDK 的 `dart format` 下**本就**存在大量历史格式差异（已验证：HEAD 版本同样 `--set-exit-if-changed` 失败）。为避免把数百行无关重排混入本次修复，提交前已把格式化器造成的无关改动全部还原，仅保留本报告描述的改动。

---

## 7. 未做与遗留

- **未做真机复现**：本报告全部结论来自静态审查与单元测试。真机弱网（后台切网 + 小窗 + 跨集）验证仍需人工执行。
- **未改** `androidStopForegroundOnPause: true`、`stream-lavf-o` 参数、`queryVideoUrl` 的并发骨架、音频焦点与长按倍速逻辑——均与本缺陷无关。
- **未改** 字幕守卫（`controller.dart:1324`，理由见 §3.2）。
- 已知非阻塞小瑕疵：`pip_overlay_service.dart:472` 存在一处 `if (ctrl.isClosed) {}` 空语句，属历史遗留，本次未动。
