# 播放器控制层点击延迟 — 根因分析与修复

> 排查对象：`E:\Project\ALL\PiliPlus`
> 排查方式：静态代码追溯 + Flutter 框架源码核对 + **模拟器实测埋点**
> 状态：**已修复并实测验证**（单击延迟 302ms → 203ms，双击零闪烁）

---

## 一、结论（一句话）

**根因**：单击回调被"双击判定窗口"阻塞了约 300ms。播放器把单击和双击识别器放进了**同一个手势竞技场**，而 `DoubleTapGestureRecognizer` 在**手指按下的瞬间就 hold 住整个竞技场**，导致单击识别器即使赢了也无法立刻收到 `acceptGesture`，必须等 `kDoubleTapTimeout`（框架常量 = 300ms）超时后竞技场被释放，单击回调才触发。

**修复**：让双击**不进竞技场**，由单击识别器自行用原始指针事件判定双击；单击延迟由一个旋钮 `singleTapDelay`（当前 200ms）控制。该值同时是双击判定窗口，两者相等即可保证**双击零闪烁**。

**注意**：这是既有问题，不是应用内小窗移植引入的（详见 §五"已排除"）。

---

## 二、实测数据（埋点证据）

在 `_onPointerDown` 与 `_onTapUp` / 小窗 `_onTap` 之间插入时间戳埋点，模拟器（Android 14 / API 34）实测：

| 位置 | 实测延迟 | 样本 |
|---|---|---|
| **主播放器** `[TapLatency] player onTapUp` | **316 / 302 / 303 / 302 ms** | 4 次 |
| **应用内小窗** `[TapLatency] pip onTap` | **304 / 302 / 302 / 302 / 303 ms** | 5 次 |

两处都稳定落在 **302–316ms**，与框架常量 `kDoubleTapTimeout = 300ms` 吻合（`packages/flutter/lib/src/gestures/constants.dart:35`）。这个"恰好等于框架常量、且不随系统负载波动"的特征，直接排除了性能类原因，指向**确定性的等待**。

---

## 三、根因机制（含框架源码证据）

### 3.1 本仓：四个识别器被注册进同一个竞技场

`lib/plugin/pl_player/view/view.dart:1236` `_onPointerDown` 里，同一个 pointer 被手动分发给多个识别器：

```dart
_tapGestureRecognizer.addPointer(event);          // 单击（ImmediateTapGestureRecognizer）
_doubleTapGestureRecognizer.addPointer(event);    // 双击  ← view.dart:1251
longPressRecognizer.addPointer(event);            // 长按
_scaleGestureRecognizer..addPointer(event);       // 缩放/拖动
```

### 3.2 框架：双击识别器在首次按下时就 hold 住竞技场

`packages/flutter/lib/src/gestures/multitap.dart:328`：

```dart
void _registerFirstTap(_TapTracker tracker) {
  _startDoubleTapTimer();
  GestureBinding.instance.gestureArena.hold(tracker.pointer);   // ← 关键
  ...
}
```

`hold()` 会让竞技场**挂起**：此后任何成员调用 `resolve(accepted)` 都不会立即生效，只置一个 `hasPendingSweep` 标记，等 hold 被释放后才 sweep 决胜。

超时 300ms 后，`_reset()`（`multitap.dart:312`）才会 reject 自己并 `release(pointer)`，此时竞技场才 sweep。

### 3.3 本仓：自定义识别器的 `onTapUp` 仍然要等竞技场

`lib/common/widgets/gesture/immediate_tap_gesture_recognizer.dart`：

```dart
void _handlePointerUp(PointerUpEvent event) {   // :88
  if (_wonArena) {          // ← 必须先赢下竞技场
    _handleTapUp(event);
  }
}

void acceptGesture(int pointer) {               // :126
  super.acceptGesture(pointer);
  if (pointer == _activePointer) {
    _wonArena = true;
    if (_up != null) _handleTapUp(_up!);        // ← 赢下竞技场后才回调
  }
}
```

**注意**：这个识别器虽然叫 "Immediate"，但它的"立即"只体现在 `onTapDown`（按下即回调）。它的 `onTapUp` **从不主动 `resolve(accepted)`**，只能等竞技场超时 sweep 时才被动获胜。所以自定义识别器**没有**解决单击延迟。

### 3.4 小窗：同一个坑，走的是 Flutter 内置 `GestureDetector`

`lib/services/pip_overlay_service.dart:834`：

```dart
GestureDetector(
  behavior: HitTestBehavior.opaque,
  onTap: _onTap,                 // 单击：切显隐
  onDoubleTap: _onDoubleTap,     // 双击：切档位
  onScaleStart: ...,             // 拖动/缩放
```

`GestureDetector` 同时收到 `onTap` + `onDoubleTap` 时，内部同样创建 `TapGestureRecognizer` + `DoubleTapGestureRecognizer` 进同一竞技场 → 完全相同的 300ms 阻塞。

---

## 四、交互流程对照

### 现状（延迟 300ms）

```
手指按下 ──► _onPointerDown
              ├─ 单击识别器 addPointer
              └─ 双击识别器 addPointer ──► gestureArena.hold(pointer)   ★竞技场挂起
手指抬起 ──► 单击识别器 handleEvent(PointerUp)
              └─ if (_wonArena) ...  ← 此时 _wonArena == false，什么都不做
                    │
                    │  ←── 干等 300ms ───┐
                    ▼                    │
              kDoubleTapTimeout 超时 ─────┘
                    │
                    ▼
              release(pointer) ──► 竞技场 sweep ──► acceptGesture
                    │
                    ▼
              _handleTapUp ──► onTapUp ──► controls = !showControls ──► 控制条显隐
```

### 期望（< 50ms）

```
手指按下 ──► 记录时间戳/位置
手指抬起 ──► 位移未超阈值 ──► 立即判定
              ├─ 距上次点击 < 300ms 且位置接近 ──► onDoubleTap（快退/暂停/快进）
              └─ 否则 ──► 立即 onTapUp ──► 控制条显隐（不等待竞技场）
```

---

## 五、影响因素分级

### 主因（占延迟的 ~100%）
- **双击识别器 hold 竞技场**（§三）。证据：延迟精确等于 `kDoubleTapTimeout`，且两条独立代码路径（主播放器 / 小窗）测出同一个值。

### 次因（不影响"点击响应"，但会造成"卡顿/迟钝"的错觉，建议一并审视）
- **`showControls` 是 `RxBool`，切换触发 `Obx` 重建**（`controller.dart:116`、setter 在 `:1260`）。重建范围覆盖播放器 Stack 时会有额外一帧构建开销。实测未成为主因（延迟不随负载波动），但优化后仍有收益。
- **控制条自动隐藏时长**：`hideTaskControls()`（`controller.dart:1179`）按 `showControlDuration`（受 `enableLongShowControl` 偏好影响）延时隐藏。这只影响"多久后消失"，**不影响点击响应**，但用户容易把"控制条赖着不走"和"点击没反应"混为一谈，需在反馈中区分。
- **小窗的 3 秒自动隐藏**（`pip_overlay_service.dart` 内 `Timer(const Duration(seconds: 3))`）同理。

### 已排除
- ❌ **不是本次小窗移植引入**：`ImmediateTapGestureRecognizer` 与 PiliNara 的实现**逐字节相同**，`_onPointerDown` 的注册方式也相同 → **上游同样存在此问题**；且主播放器的单击路径未被本次移植触及。
- ❌ **不是性能/掉帧**：延迟稳定等于框架常量，与设备负载无关。
- ❌ **不是动画时长**：控制条显隐没有入场动画造成的额外等待。

---

## 六、修复方案（已实施并实测）

### 采用方案：单击脱离竞技场 + 自行判定双击 + 可调的判定窗口

**核心思路**：让双击**根本不进竞技场**（框架的 `DoubleTapGestureRecognizer` 正是 hold 竞技场的元凶），由单击识别器自己用原始指针事件判定双击。单击延迟由 `singleTapDelay` 一个旋钮控制。

**关键设计：`singleTapDelay` 同时是"单击落地延迟"和"双击判定窗口"**，两者相等才能保证双击绝不闪烁：

- 单击：抬起后等 `singleTapDelay` 落地；
- 双击：第二下抬起若落在窗口内，则第一下的单击**尚未落地**，直接取消 → 控制层从头到尾不出现，**零闪烁**；
- 边界兜底：若单击恰好已落地，用 `onTapRevert` 回滚。

### 改动范围（3 个文件）

| 文件 | 改动 |
|---|---|
| `lib/common/widgets/gesture/immediate_tap_gesture_recognizer.dart` | 新增 `onDoubleTap` / `onTapRevert` / `singleTapDelay`；单击改为延后派发；双击自行判定；`dispose` 取消待派发定时器 |
| `lib/plugin/pl_player/view/view.dart` | 移动端不再把双击注册进竞技场；接线 `onDoubleTap`/`onTapRevert`；新增 `_onTapRevert` 与 `_controlsBeforeTap` |
| `lib/services/pip_overlay_service.dart` | 小窗 `GestureDetector(onTap+onDoubleTap)` 换成 `RawGestureDetector` + 同一识别器 + `ScaleGestureRecognizer`；新增 `_onTapRevert` |

**未改动**：桌面端鼠标路径（仍用框架双击识别器）、`enableTapDm` 弹幕命中逻辑、`controlsLock` 锁定态、拖动/缩放手势、播放内核。

### 实测结果（Android 14 / API 34 模拟器）

| 项 | 修复前 | 修复后 |
|---|---|---|
| 主播放器单击延迟 | 302 / 316 / 303 / 302 ms | **214 ms** |
| 小窗单击延迟 | 304 / 302 / 302 / 302 / 303 ms | **203 ms** |
| 双击（间隔 56ms） | — | 判定成立，**无 `onTapUp`** → 零闪烁 ✓ |
| 双击（间隔 157ms） | — | 判定成立，**无 `onTapUp`** → 零闪烁 ✓ |
| 间隔 257ms（> 窗口） | — | 判为两次单击（符合设计） |
| 小窗双击切档位 | — | 窗口尺寸切换生效 ✓ |

**`singleTapDelay` 的取值权衡（实测数据）**：

| 取值 | 单击延迟 | 双击可靠性 |
|---|---|---|
| 100ms | 103–110ms | 间隔 155ms 的连点**会被判成两次单击**（实测） |
| **200ms（当前）** | **203–214ms** | 间隔 157ms 可正常识别为双击 ✓ |
| 300ms（框架默认） | ~300ms | 与系统手势一致，最宽容 |

结论：**200ms 是"跟手"与"双击可靠"的较好平衡点** —— 单击延迟降为原来的 2/3，同时覆盖绝大多数用户的连点节奏。改一行即可调整。

---

## 七、验证方式

### 1. 量化验证（已做）
在 `_onPointerDown` 与 `onTapUp`/`onTap` 之间插入时间戳埋点，用 `adb logcat | grep TapLatency` 取数；双击判定日志输出实际间隔 `gap=..ms`。

### 2. 双击事件注入（关键技巧）
`adb shell input tap` 每次要启动 JVM（约 300ms），两次间隔必然超过判定窗口，**无法用来测双击**。可行做法是在同一条 shell 里并行错时注入：

```bash
# 目标间隔 ≈50ms
adb shell 'input tap X Y & sleep 0.05; input tap X Y; wait'
# 目标间隔 ≈150ms
adb shell 'input tap X Y & sleep 0.15; input tap X Y; wait'
```

### 3. 功能回归清单
| 场景 | 预期 | 状态 |
|---|---|---|
| 单击视频区 | 控制层即时显隐 | ✅ 已验（唤出正常） |
| 双击左/中/右 | 快退 / 暂停 / 快进 | ✅ 双击判定已验（动作分发为未改动逻辑） |
| 双击不显示控制 UI | 无 `onTapUp` | ✅ 日志确认 |
| 间隔 > 窗口的连点 | 两次独立单击 | ✅ 已验 |
| 长按倍速 | 不误触发单击 | 逻辑未变（竞技场 reject 路径已保留） |
| 拖动进度条 / 双指缩放 | 不误触发单击 | 逻辑未变（位移阈值 reject） |
| 弹幕点击（`enableTapDm`） | 行为一致 | 逻辑未变 |
| 小窗单击 / 双击 / 拖动 / 缩放 | 全部正常 | ✅ 单击+双击已验 |
| 桌面端鼠标 | 行为不变 | 未改动该路径 |

> 注：控制层"第二次单击收起"的视觉回归受弹幕命中干扰（点中弹幕会暂停弹幕而非切控制层，属既有行为），建议在关闭弹幕或空白区复测。

---

## 八、遗留与建议

1. **`singleTapDelay` 建议做成可配置项**（设置里暴露），让用户按自己的连点习惯调；默认 200ms。
2. **桌面端仍走框架双击识别器**，理论上单击也有 300ms 延迟。桌面有 hover 显示控制层，感知不明显，故未改动；若要统一，可按同样方式改。
3. **三击**会先被判为一次双击（消费掉记录），第三次点击作为新的单击 —— 符合预期。
4. 本次只测了 Android；iOS 未验证（`PlatformUtils.isMobile` 已覆盖 iOS，代码路径相同）。


---

## 附：本次排查用到的证据获取方式

```bash
# 1) 埋点：在 _onPointerDown 记录时间戳，在 onTapUp/onTap 打印差值
# 2) 构建并安装
export PATH="/d/SDK/Flutter-3.47.4/bin:$PATH"
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export JAVA_TOOL_OPTIONS="-Djavax.net.ssl.trustStoreType=Windows-ROOT"
flutter build apk --debug && adb install -r build/app/outputs/flutter-apk/app-debug.apk
# 3) 驱动点击并取日志
adb logcat -c; for i in 1 2 3 4 5; do adb shell input tap <x> <y>; sleep 2; done
adb logcat -d | grep TapLatency
```
