# PiliPlus 音画同步 / 蓝牙耳机延迟 审查报告

- 审查对象：`https://github.com/bggRGjQaUbCoE/PiliPlus`
- 本地快照：`E:\Project\ALL\PiliPlus`，commit `b0e7e4e`（2026-09-15），`pubspec.yaml` 版本 `2.1.4+1`
- 审查方式：**静态审查**（App 源码 + 打包进 APK 的 mpv 源码 + 上游 issue 交叉验证）。**未在真机 + 蓝牙耳机上实测**，涉及"偏差方向"的结论已单独标注。
- 结论等级：**确认存在系统性缺口**（设计缺失），不是单纯的一处写错。

---

## 0. 结论摘要

**问：视频播放是否没有做音画同步，导致蓝牙耳机延迟？**

不是"没做同步"——同步这件事由 mpv 全权负责，App 只做选项转发。真正的缺口是：

> **App 把「音频输出设备」的默认优先级设成了 `opensles` 排第一，而 mpv 的 OpenSL ES 后端没有任何闭环延迟反馈机制。**
> 音画同步的基准是"音频时钟"，音频时钟的精度取决于后端上报的输出延迟。OpenSL ES 后端上报的是**开环估算值**（固定 250 ms 分片 + 进程启动时读一次的 latency），蓝牙传输延迟（编码 + 空中 + 耳机缓冲，典型 100~250 ms）不在这个公式里，于是产生一个**恒定的系统性偏差**——mpv 的 `--autosync` 只能平滑抖动，消不掉恒定偏置。
> 而同一份 mpv 里的 `audiotrack` / `aaudio` 后端都是**闭环**的（读 `AudioTrack.getTimestamp()` / `AAudioStream_getTimestamp()` 的真实呈现位置），能自校正。

三条独立证据互相印证：

1. 源码：三个 AO 的延迟核算实现差异（本报告 §3.2）
2. 上游 issue：#2938 报"戴上蓝牙耳机音画不同步"，社区回复"把音频输出从 OpenSL ES 换成其他两个，可以有效减少延迟"，提问者确认有效（§8）
3. 上游 issue：#189 直接报"高延迟蓝牙耳机 + 优先 opensles 时，视频同步不生效"，维护者回复"无法测试"后关闭

**最小改动、最高收益**：把 `AudioOutput` 枚举顺序从 `opensles, aaudio, audiotrack` 改成 `aaudio, audiotrack, opensles`。一行改动，无副作用风险。

---

## 1. 播放链路事实（先确认"同步归谁管"）

| 项 | 事实 | 位置 |
|---|---|---|
| 播放内核 | media_kit（libmpv 封装），非 ExoPlayer / video_player | `pubspec.yaml:133-135`、`dependency_overrides` `pubspec.yaml:189-224` |
| 打包的 mpv 版本 | **v0.41.0**（`v_mpv=0.41.0`） | 依赖 `My-Responsitories/media-kit@upstream` → `libs/android/media_kit_libs_android_video/android/build.gradle:61-63` → 预编译包 `libmpv-android-video-build@20260906` → `buildscripts/include/depinfo.sh:19` |
| 播放入口 | `PlPlayerController._initPlayer()` | `lib/plugin/pl_player/controller.dart:725-763` |
| 传给 mpv 的选项 | `video-sync` / `ao` / `volume` / `stream-lavf-o` / `autosync` | `lib/plugin/pl_player/controller.dart:727-738` |
| 进度条 / 弹幕的时间源 | `player.state.position` → mpv `time-pos` → **音频时钟** | `lib/plugin/pl_player/controller.dart:940-944` |

关键含义：**视频、弹幕、进度条都挂在同一个时钟上**，所以一旦音频时钟有偏，坏掉的不是"某个 UI 元素"，而是"视频相对声音的整体偏移"。也就是说：弹幕和画面是一起的，**被错开的是声音**。

---

## 2. 默认值现状

| 设置项 | 默认值 | 位置 |
|---|---|---|
| `ao`（音频输出设备） | `opensles,aaudio,audiotrack` | `lib/utils/storage_pref.dart:851-854` + `lib/plugin/pl_player/models/audio_output_type.dart:3-8` |
| `video-sync` | `display-resample`（mpv 自身默认是 `audio`） | `lib/utils/storage_pref.dart:271-272` |
| `autosync` | Android `30`，桌面 `0` | `lib/utils/storage_pref.dart:274-277` |
| `ao` 仅在 Android 生效 | `if (Platform.isAndroid) 'ao': Pref.audioOutput` | `lib/plugin/pl_player/controller.dart:729` |

`AudioOutput.defaultValue` 是 `values.map((e) => e.name).join(',')`（`audio_output_type.dart:8`），枚举声明顺序即优先级顺序：

```dart
// lib/plugin/pl_player/models/audio_output_type.dart:3-6
enum AudioOutput implements EnumWithLabel {
  opensles('OpenSL ES'),   // ← 排第一，mpv 优先选中它
  aaudio('AAudio'),
  audiotrack('AudioTrack'),
```

mpv 的 `--ao` 接受逗号分隔列表并按顺序尝试，因此**默认命中的就是 OpenSL ES**。

---

## 3. 根因：OpenSL ES 后端的延迟是开环估算

### 3.1 mpv 如何用这个延迟（同步的闭环在这里断掉）

`ao_get_delay()` 是 mpv 计算音频时钟的入口。三个 Android 后端都是"拉模型"（自己在回调里调 `ao_read_data`），因此走的是这个分支：

```c
// audio/out/buffer.c:295-318
double ao_get_delay(struct ao *ao)
{
    if (ao->driver->write) {
        get_dev_state(ao, &state);
        driver_delay = state.delay;               // 推模型：问设备要
    } else {
        int64_t end = p->end_time_ns;             // ← 拉模型：用 AO 自己填的时间戳
        int64_t now = mp_time_ns();
        driver_delay = MPMAX(0, MP_TIME_NS_TO_S(end - now));
    }
    ...
}
```

`end_time_ns` 完全由 AO 决定。**这就是分水岭**：谁能拿到设备真实的呈现位置，谁的时钟就准。

### 3.2 三个后端的延迟核算对比（核心证据）

| 后端 | 延迟怎么算 | 有无设备反馈 | 代码 |
|---|---|---|---|
| **OpenSL ES** | `frames_per_enqueue / samplerate + audio_latency`<br>`audio_latency` 是**进程启动时读一次**的 `androidGetAudioLatency` | **无**。纯开环公式 | `audio/out/ao_opensles.c:72-89`、`:201-219` |
| AudioTrack | `written_frames - getPlaybackHeadPosition()`，`getPlaybackHeadPosition` 优先走 `AudioTrack.getTimestamp()`（帧位置 + 单调时钟时间戳） | **有**，闭环 | `audio/out/ao_audiotrack.c:468-487`、`:382-430` |
| AAudio | `written - (presented + discarded)`，`presented` 来自 `AAudioStream_getTimestamp()` | **有**，闭环 | `audio/out/ao_aaudio.c:230-252` |

OpenSL ES 后端的具体问题（`audio/out/ao_opensles.c`）：

```c
// :72-89  —— 每次 Enqueue 前算一个估值，喂给 mpv 当时钟
static void buffer_callback(...)
{
    delay = p->frames_per_enqueue / (double)ao->samplerate;  // :81 固定分片时长
    delay += p->audio_latency;                               // :82 启动时读一次的常量
    ao_read_data(ao, &p->buf, p->frames_per_enqueue,
        mp_time_ns() + MP_TIME_S_TO_NS(delay), NULL, true, true);  // :83-84
```

- **驱动结构体里没有 `get_delay` / `get_written`**（`ao_driver` 定义见 `:245-265`，只有 `init/uninit/reset/start`），所以设备侧真实进度永远拿不到。
- `buffer_size_in_ms` 默认 **250**（`:255`），进而 `ao->device_buffer = samplerate * 250 / 1000`（`:143-145`），即**每次入队 250 ms 一大块**。
- `audio_latency` 只在 init 时通过 `androidGetAudioLatency` 读一次（`:201-219`），运行期设备变化（比如中途戴上蓝牙耳机）不会重新读。

**为什么蓝牙会放大这个问题**：蓝牙的额外延迟（SBC/AAC 编码 + 空中传输 + 耳机侧缓冲，典型 100~250 ms；aptX LL / LC3 约 30~80 ms）不属于上式的任何一项。`audiotrack` / `aaudio` 通过 HAL 的 presentation position 能间接拿到（现代 Android 的 A2DP HAL 会上报），`opensles` 拿不到。

> **未实测声明**：偏差的**方向**取决于 `androidGetAudioLatency` 的读数与真实延迟的大小关系，静态审查无法确定符号。上游 #2938 报告的现象是"**声音比画面快**"（即视频滞后），与"上报延迟 > 真实延迟"一致；但不同机型 / 编码器的符号可能相反。可以确定的只有：**存在一个不受控的系统性偏置**。

### 3.3 为什么 `--autosync=30` 救不了

App 已经在 Android 上把 `autosync` 设成 30（`storage_pref.dart:274-277` → `controller.dart:735-738`）。mpv 官方文档对它的定义是：

> `--autosync=<factor>`: Gradually adjusts the A/V sync **based on audio delay measurements**. ... Try `--autosync=30` to smooth out problems with sound drivers which **do not implement a perfect audio delay measurement**.
> —— `DOCS/man/options.rst:8128-8141`

注意措辞：它是**基于延迟测量**去平滑修正。测量本身有恒定偏置时，平滑只会让偏置稳定存在。**这个默认值 30 恰恰说明项目早就知道 Android 的延迟测量不可靠，但选择的是"抹平抖动"，而不是"消除偏置"。**

### 3.4 `--video-sync=display-resample` 的相互作用

默认值 `display-resample`（`storage_pref.dart:271-272`）不是 mpv 的默认（mpv 默认 `audio`）。按官方文档（`DOCS/man/options.rst:8162` 起）：

- `display-*` 系列"改视频速度去匹配显示器"，假设 CFR、需要 vsync 阻塞呈现，"robustness ... reduced by making some idealized assumptions, which may not always apply in reality"；
- 而 `audio` 模式被明确称为 **"the most robust mode"**；
- 更要紧的是：`display-*` 模式下的 A/V 修正靠**重采样音频**实现（受 `--video-sync-max-audio-change` 约束，默认 0.125 即 ±12.5%）。当音频时钟本身有偏时，mpv 会为了对齐这个有偏的时钟去**实际改变音频播放速率**，可能把感知偏差做得更大。

**这是"设计取舍"而非 bug**：`display-resample` 在高刷屏上换来了更好的观感，代价是同步鲁棒性下降。但对蓝牙耳机场景，它是错误的一侧。

---

## 4. 其他确认存在的缺口

| # | 缺口 | 证据 | 影响 |
|---|---|---|---|
| 4.1 | **完全没有手动音画偏移补偿**。全仓 grep `audio-delay` / `video-delay` / `audioDelay` / `videoDelay` / `sub-delay` → **0 命中**。唯一一处 `setProperty` 是切"听视频"模式 | `lib/pages/video/widgets/header_control.dart:593`（唯一命中） | 用户遇到蓝牙延迟**无任何手段自救**。而 mpv 本身有 `--audio-delay`（`DOCS/man/options.rst:2221-2223`，正值延迟音频 / 负值延迟视频），只是没被暴露 |
| 4.2 | **无音频设备切换监听**。只有 `becomingNoisyEventStream`（拔耳机暂停），没有任何 `AUDIO_BECOMING_NOISY` 之外的设备变化处理，也不触发 AO 重建 | `lib/services/audio_session.dart:67`（全仓唯一命中） | 播放中连上蓝牙耳机 → AO 不重建、延迟不重估，偏置从"有线值"直接跳到"蓝牙场景"而无人纠正 |
| 4.3 | **`video-sync` 对话框把 `desync` 系列也列出来了，且无任何警告** | `lib/pages/setting/models/video_settings.dart:421-443` | 9 个选项里 `display-desync` / `display-resample-desync` / `desync` 按文档"**do not attempt to keep audio/video in sync**"（`DOCS/man/options.rst:8162+`）。用户随手一选就把同步彻底关掉，然后来报 bug |
| 4.4 | **改 `ao` 设置不会立即生效**。`Pref.audioOutput` 只在 `_initPlayer()` 里读一次 | `controller.dart:729`（读取点）vs `video_settings.dart:393-413`（写入点，仅写 storage） | 用户改完设置回到原视频，音频输出其实没换。上游 #2721 的抱怨（"拖动进度条、切换和长按倍速时都会卡顿"）和"改 ao 有效果"这类时好时坏的反馈，很可能与此有关 |
| 4.5 | **调试面板读不出 `avsync`**，只读 `hwdec-current` 和 `volume` | `lib/pages/video/widgets/header_control.dart:810-811` | 排查同步问题时没有任何可观测性。mpv 有现成的 `avsync` / `audio-delay` / `display-fps` 属性可直接读 |

---

## 5. 已经做对的部分（修复时不要动）

- **`autosync=30` 的平台区分**（`storage_pref.dart:274-277`）：Android 30 / 桌面 0，方向是对的，保留。
- **`audiotrack` / `aaudio` 的闭环实现**：它们已经能自校正，问题只是没被排到前面。
- **时间源单一**：进度条 / 弹幕 / 视频共用一个 `time-pos`（`controller.dart:940-944`），没有引入第二个时钟。**这是正确的设计**，不要为了"修同步"另起一套计时器。
- **缓冲参数**（`storage_pref.dart:825-849`）：`cache-secs` / `demuxer-max-bytes` 等只影响卡顿，与音画偏移无关，不要往这里找原因。
- **`audio_session` 用 `AudioSessionConfiguration.music()`**（`lib/services/audio_session.dart:19`）：这是 Android `USAGE_MEDIA` + iOS `playback` 的正确配置，与延迟无关。
- **音频页独立播放器**（`lib/pages/audio/controller.dart:359-365`）：纯音频场景不受音画同步影响，无需改动。

---

## 6. 建议（按优先级）

### P0 — 默认 `ao` 顺序（一行改动，立竿见影）

`lib/plugin/pl_player/models/audio_output_type.dart:3-6`，把闭环后端排到前面：

```dart
enum AudioOutput implements EnumWithLabel {
  aaudio('AAudio'),        // 闭环 + 低延迟性能模式
  audiotrack('AudioTrack'),// 闭环，兼容性最好
  opensles('OpenSL ES'),   // 保留但降到兜底
```

理由：`aaudio` / `audiotrack` 都有设备反馈（§3.2），`opensles` 既无反馈又用 250 ms 大分片，作为兜底即可。**副作用需实测确认**：老机型（API < 26 无 AAudio）会自动回落到下一项，但部分用户反馈切换 AO 后拖动/倍速有卡顿，需要单独验证。

### P0 — 补一个手动音频延迟补偿（给用户兜底手段）

在设置里加 `audio-delay` 滑块（mpv 原生支持，正值延迟音频 / 负值延迟视频，`DOCS/man/options.rst:2221-2223`），范围建议 ±500 ms。这是**唯一能覆盖"自动补偿测不准"场景的手段**，B 站官方 App 就是靠这个（上游 #2064 / #2721 反复要求）。

实现上可参考现有唯一的 `setProperty` 用法（`header_control.dart:593`），运行时直接 `player.setProperty('audio-delay', '${ms / 1000.0}')`，不必重建 Player。

### P1 — `video-sync` 对话框收敛 + 加说明

`lib/pages/setting/models/video_settings.dart:421-443`：把 `desync` 系列（`display-desync` / `display-resample-desync` / `desync`）从用户可选项里去掉，或至少标注"不会保持音画同步，仅用于测试"（文档原话）。同时建议在蓝牙场景引导用户用 `audio` 模式。

### P1 — 监听音频输出设备变化

在 `lib/services/audio_session.dart` 或播放器控制器里订阅音频设备变化；检测到切换到蓝牙输出时，**重建 AO**（或至少提示用户切换/启用延迟补偿）。这能覆盖 §4.2 的"播放中途戴耳机"场景。

### P2 — 调试面板暴露 `avsync`

`header_control.dart:810-811` 顺手加两行 `player.getProperty('avsync')` / `player.getProperty('audio-delay')`，让"音画偏移多少毫秒"变成可读数字，而不是靠肉眼猜。这是把 §7 验证方案变成可自助操作的前提。

---

## 7. 验证方案（尚未执行）

静态审查到此为止，以下为落地验证路径，建议按顺序做：

1. **基线复现**：`ao` 默认（opensles 优先）→ 播放"拍手 / 敲击"类测试视频，用另一台手机高速录像（240fps 以上），逐帧比对"画面撞击"与"声音波峰"的帧差。
2. **对照组**：仅改 `ao` 为 `aaudio,audiotrack,opensles`，**重开视频**（§4.4：设置不会热生效）后重复步骤 1。两次帧差之差 = 该缺口造成的偏移量。
3. **数字读数**（比录像更准）：在调试面板加 `avsync` 后，或用 `adb` 直接读 mpv 属性，对比两种 `ao` 下的 `avsync` 稳态值。注意 `avsync` 是 mpv 自己的估计，它的绝对值不可信、**相对变化才是信号**。
4. **耳机类型分层**：至少覆盖 SBC/AAC（高延迟）与 aptX LL / LC3（低延迟）各一副，验证偏移是否随耳机类型变化——若是，则坐实"传输延迟未进公式"这一判断。
5. **回归**：改动后确认拖动进度条、长按倍速、切后台、切集这些路径没有引入新卡顿（对应上游 #2721 的抱怨）。

---

## 8. 上游 issue 索引（交叉验证）

| # | 标题 | 状态 | 关键信息 |
|---|---|---|---|
| [2938](https://github.com/bggRGjQaUbCoE/PiliPlus/issues/2938) | [Bug] 戴上蓝牙耳机音画不同步 | open | 现象"**声音比画面快**"；社区回复"把音频输出从 OpenGL es 换成其他两个，可以有效减少延迟"，提问者确认有效 |
| [2721](https://github.com/bggRGjQaUbCoE/PiliPlus/issues/2721) | [FR] 蓝牙音频延迟 | open | 观察到"原版 B 站连蓝牙时会自动启用音频延迟"；评论确认改 `ao` 有效 |
| [2064](https://github.com/bggRGjQaUbCoE/PiliPlus/issues/2064) | [FR] 希望添加官方 APP 同款音频延迟补偿 | closed | 用户实测"与官方 App 差 200 ms" |
| [2275](https://github.com/bggRGjQaUbCoE/PiliPlus/issues/2275) | [FR] 关于蓝牙设备音频延迟 | closed | "更改『视频同步』选项貌似不起作用"——与 §3.3 判断一致 |
| [189](https://github.com/bggRGjQaUbCoE/PiliPlus/issues/189) / [190](https://github.com/bggRGjQaUbCoE/PiliPlus/issues/190) | [Bug] 高延迟蓝牙耳机优先使用 opensles 输出时，视频同步不生效 | closed | 维护者回复"无法测试"后关闭。**这是最直接指向 opensles 的一条** |
| [562](https://github.com/bggRGjQaUbCoE/PiliPlus/issues/562) / [1036](https://github.com/bggRGjQaUbCoE/PiliPlus/issues/1036) / [1695](https://github.com/bggRGjQaUbCoE/PiliPlus/issues/1695) | 蓝牙耳机延迟补偿相关 | closed | 长期重复诉求 |

---

## 附：证据文件清单

App 侧（本地快照 `E:\Project\ALL\PiliPlus`）：
`lib/plugin/pl_player/models/audio_output_type.dart`、`lib/plugin/pl_player/controller.dart:725-763, 880-945`、`lib/utils/storage_pref.dart:262-277, 818-860`、`lib/pages/setting/models/video_settings.dart:143-175, 393-443`、`lib/pages/video/widgets/header_control.dart:575-620, 805-890`、`lib/services/audio_session.dart`、`lib/pages/audio/controller.dart:359-365`

mpv 侧（v0.41.0 上游源码）：
`audio/out/ao_opensles.c`、`audio/out/ao_audiotrack.c`、`audio/out/ao_aaudio.c`、`audio/out/buffer.c:295-318`、`DOCS/man/options.rst:2221-2223, 8128-8141, 8162+`

打包来源：`My-Responsitories/media-kit@upstream` → `libs/android/media_kit_libs_android_video/android/build.gradle:61-63` → `My-Responsitories/libmpv-android-video-build@main` → `buildscripts/include/depinfo.sh:19`（`v_mpv=0.41.0`）、`buildscripts/patches/mpv/`（仅一个补丁 `mpv_lavc_set_java_vm.patch`，与音频同步无关 —— 即**该分支没有对同步逻辑做任何魔改**）

---

## 附录 B：配置速查（不改代码即可完成）

> 前提：先明确「最优」指什么。**同步准确**与**流畅省电**是互斥目标，`video-sync` 一项上直接冲突。

### B.0 共同前提：改音频输出设备顺序（P0，UI 内可完成）

**操作**：设置 → 视频设置 → 音频输出设备 → **先取消勾选全部** → 再按 `AAudio` → `AudioTrack` → `OpenSL ES` 的顺序依次重新勾选 → 确定。

**为什么必须"先全取消"**：该对话框的排序语义是"新勾选的项追加到末尾"，不是拖拽。依据：

- `lib/pages/setting/widgets/checkbox_num_list_tile.dart:197` —— `onTap: () => onChanged!(value)`，传入的是**当前值**
- `lib/pages/setting/widgets/ordered_multi_select_dialog.dart:52-56` —— 当前值非空（已勾选）→ 移除；当前值空（未勾选）→ `_tempValues[i.key] = _tempValues.length + 1`，**排到末尾**
- `:108` —— 返回的 `_tempValues.keys.toList()` 即最终优先级顺序

**回退安全性**：`ao_aaudio.c:196-198` 用 `dlopen("libaaudio.so")`，加载失败即 `return false`，mpv 自动尝试列表中的下一项。故 API < 26 的老机型会把 `aaudio` 跳过、落到 `audiotrack`，**不会导致无声**。

### B.1 两套推荐配置

| 设置项 | 默认值 | A：同步 / 低延迟优先 | B：流畅 / 省电优先 |
|---|---|---|---|
| 音频输出设备 | `opensles,aaudio,audiotrack` | `aaudio,audiotrack,opensles` | 同 A（两套都要改） |
| 视频同步 | `display-resample` | `audio`（文档称 most robust） | `display-resample`（高刷屏少掉帧） |
| 自动同步 | Android `30` | 保持 `30` | 保持 `30` |
| 首选解码格式 | `[AVC, AV1]` | 仅 `AVC`（硬解支持最广、功耗最低） | `AVC` + `AV1`（仅当 SoC 有 AV1 硬解） |
| 硬解模式 | `mediacodec,auto-safe` | 同默认（`mediacodec` 直通） | 同默认 |
| 缓冲大小 | `4.0` MB | `16` MB | `16` MB（4K 用 `32`） |
| 缓冲时长 | `16.0` s | `30` s | `30` s（4K 用 `60`） |
| 超分辨率 | `disable` | 关闭 | 关闭（除非确实需要且能接受 GPU 开销） |

依据：`storage_pref.dart:248-254`（preferCodecs）、`:271-277`（videoSync/autosync）、`:785-786`（enableHA）、`:825-849`（buffer）、`hwdec_type.dart`（`androidDefault`）、`extra_settings.dart:306`（超分辨率需硬件解码且建议 `auto-copy`）。

**缓冲的取舍**：默认 4 MB 在 1080P 高码率（约 6 Mbps）下仅够约 5 秒，偏小。但注意 `demuxer-max-back-bytes` 与 `demuxer-max-bytes` 取同值（`storage_pref.dart:833-839`），所以内存占用约为设定值的 **2 倍**；且 `demuxer-hysteresis-secs = bufSec / 1.5`。盲目加大只会换来内存上升 + 起播变慢 + seek 变慢，不解决根本卡顿。

### B.2 生效方式（易踩坑）

| 设置 | 读取时机 | 生效条件 |
|---|---|---|
| `ao` / `video-sync` / `autosync` | `_initPlayer()` 内直接读 Pref（`controller.dart:727-738`） | 播放器实例重建即可 |
| `hwdec` / `缓冲大小` / `缓冲时长` | **单例控制器上的 `late final`**（`controller.dart:368`、`:765-766`） | 需控制器实例重建 |

`dispose()` 末尾会 `_instance = null`（`controller.dart:1583`），而 `dispose()` 仅在引用计数归零时执行完整清理（`:1536-1542` 在 `_playerCount > 1` 时提前 `return`）。

**结论**：**关闭所有播放相关页面（含画中画 / 后台播放）→ 改设置 → 重新进入视频**，上述全部设置都会重新读取，**不必重启 App**。若不确定是否真的销毁干净，重启 App 是最保险的做法。

### B.3 反向清单：这些"看起来提性能"其实有害

- **`video-sync` 选 `desync` 系列**：按文档根本不保持音画同步（`DOCS/man/options.rst:8162+`），且它就在用户可选的 9 个选项里（`video_settings.dart:421-443`），无任何警告。
- **`hwdec` 选 `*-copy`**：需要把解码结果回读到内存，性能更差。只在花屏/兼容性问题或要用 GLSL 滤镜（超分辨率）时才用。
- **超分辨率（Anime4K）**：GPU 开销显著，且要求硬解走 `*-copy`（`extra_settings.dart:306` 自带提示）。性能优先时保持关闭。
- **首选解码格式里保留 AV1 而 SoC 无 AV1 硬解**：会退化到软解，CPU 占用飙升。`[AVC, AV1]` 的顺序决定了优先请求 AVC，是安全的默认值。
- **缓冲无脑加大**：见 B.1 的取舍说明。

### B.4 仍需改代码才能拿到的能力

1. `--audio-delay` 手动补偿 UI（§6 P0）—— 目前**用户侧完全无法自救**
2. `--aaudio-performance-mode=low-latency`（`ao_aaudio.c:501-506` 提供该选项，App 未暴露）
3. 调试面板读 `avsync`（§6 P2）—— 没有它就无法自助量化偏移
4. `ao` 默认顺序（枚举写死）—— 但可被 B.0 的 UI 操作覆盖

