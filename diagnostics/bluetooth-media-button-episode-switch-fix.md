# 蓝牙耳机上一首/下一首无法切集 — 根因与修复

## 现象

连接蓝牙耳机（或使用系统媒体通知）时，按耳机上的「上一首 / 下一首」，App 不切换剧集/分集；
App 内按钮、键盘 `[` `]` 均正常。

## 根因

`lib/services/audio_handler.dart:38` 的
`class VideoPlayerServiceHandler extends BaseAudioHandler with SeekHandler`
只覆写了 `play()` / `pause()` / `seek()`，**没有覆写 `skipToNext()` / `skipToPrevious()`**。

audio_service 的 `BaseAudioHandler` 把这两个方法实现为**空实现**，按键因此被静默吞掉：

```dart
Future<void> skipToNext() async {}
Future<void> skipToPrevious() async {}
```

链路本身是通的，断点只在 Dart 侧这一个方法上：

1. Android `MediaSessionCompat` 回调 → `AudioService.java` `onMediaButtonEvent`
   （`KEYCODE_MEDIA_NEXT` / `KEYCODE_MEDIA_PREVIOUS`）→ `eventToButton()` 映射为
   `MediaButton.next` / `MediaButton.previous`；
2. `audio_service.dart` 的 `click([MediaButton button])` → `case MediaButton.next: await skipToNext();`；
3. `skipToNext()` 落到 `BaseAudioHandler` 的空实现 → 无任何效果。

次要问题：通知栏本身也没有「上一首/下一首」按钮。fork 版插件在
`AudioService.java` 的 `AUTO_ENABLED_ACTIONS` 中刻意注释掉了
`ACTION_SKIP_TO_PREVIOUS` / `ACTION_SKIP_TO_NEXT`（避免 Android Auto 强制常显），
所以必须由 Dart 侧在 `controls` 里显式声明才会出现。

## 修复

### 1. `lib/services/audio_handler.dart`

- 新增回调字段 `onSkipToNext` / `onSkipToPrevious`（与既有 `onPlay` / `onPause` / `onSeek` 同风格）；
- 覆写 `skipToNext()` / `skipToPrevious()`：按
  `页面回调 ?? PlPlayerController 静态兜底 ?? Future.syncValue(null)` 三级串联；
- 在 `controls` 中加入 `MediaControl.skipToPrevious` / `MediaControl.skipToNext`（仅非直播），
  并显式给出 `androidCompactActionIndices`：
  `isLive ? const [0] : const [1, 2, 3]`。
  直播时 `controls` 只有 play/pause 一项，统一用 `[1,2,3]` 会越界；
  索引同时保持在列表范围内，紧凑视图在 API < 33 上仍是原来的
  rewind / play-pause / fast-forward。

### 2. `lib/plugin/pl_player/controller.dart`

新增静态切集回调面，供页面注册、供 handler 兜底：

```dart
typedef SkipCallback = bool Function();

static void setPlayCallBack(
  PlayCallback? playCallBack, {
  SkipCallback? skipToNext,
  SkipCallback? skipToPrevious,
})
```

`bool` 返回值表示「本次是否真的切了」。`skipToNextIfExists()` /
`skipToPreviousIfExists()` 在无人注册、或已到首/末集（回调返回 `false`）时返回 `null`，
让 handler 的 `??` 链能区分「已处理」与「无人处理」。

**`setPlayCallBack` 省略 skip 参数即清空**这一点是刻意设计：既有的 8 个调用点
（小窗关闭、直播页注册/清理等）无需改动，就会自动清掉 skip 回调，
避免直播页或小窗关闭后耳机按键误触发栈下方视频页的切集。

### 3. `lib/pages/video/view.dart`

`setPlayCallBack(playCallBack, ...)` 的两处（`:394` 注册、`:791` `didPopNext` 恢复）
补上 `skipToNext` / `skipToPrevious` 闭包：

```dart
PlPlayerController.setPlayCallBack(
  playCallBack,
  skipToNext: () => introController.nextPlay(),
  skipToPrevious: () => introController.prevPlay(),
);
```

必须用闭包延迟求值：`introController`（`:100-105`）依赖 `:106-108` 三个
`late final` 分页 controller，而它们到 `:450-456` 才 `Get.put`，
在 `:394` 直接取属性会抛 `LateInitializationError`。

这样视频页复用既有 `CommonIntroController.nextPlay()` / `prevPlay()` 抽象，
UGC / PGC / 本地下载三个子类各自的重载（含 `skipPart`、`PlayRepeat.listCycle` 等语义）全部自动生效。

### 4. `lib/pages/audio/controller.dart`

「听视频」页在 `onInit()`（`:183-189`）接线，并在 `onClose()`（`:928-933`）随
`onPlay` / `onPause` / `onSeek` 一起置空：

```dart
Future<void> onSkipToNext() {
  playNext();
  return Future<void>.value();
}
```

这里**必须返回非 null 的 `Future`**：`playNext()` / `playPrev()` 在已是末/首集时
静默返回 `false`，若本方法返回 `null`，handler 的 `??` 链会继续穿透到栈下方
视频页注册的 skip 回调，造成「听视频页切不动却把底下的视频页切走了」。

## 语义取舍

耳机「上一首」直接切上一集，未实现「播放超过 3 秒则回到本集开头」的通行媒体语义，
理由是与 App 内按钮、键盘 `bracketLeft` / `bracketRight` 的行为保持一致。
处于第一集的「上一首」、最后一集的「下一首」为静默无操作。

## 验证

- `flutter analyze`（`D:\SDK\Flutter-3.47.4\bin\flutter.bat`）：
  本次涉及的 5 个文件仅剩 4 条既有 `cascade_invocations` info
  （`lib/pages/video/view.dart:236/243/249/255`，属未触碰的 `_startInAppPipIfNeeded` 区域），无新增告警。
- `flutter test`：18/18 通过。其中新增
  `test/plugin/pl_player_skip_callback_test.dart` 4 条，覆盖
  ① 无回调时为 `null`；② 注册后转发且各调用一次；③ 回调返回 `false` 仍报 `null`；
  ④ 重新注册不带 skip 会清空旧回调。
- `dart format --set-exit-if-changed`：涉及的 5 个文件全部干净。
- 真机蓝牙按键需在设备上复验（会话内无法完成）。
