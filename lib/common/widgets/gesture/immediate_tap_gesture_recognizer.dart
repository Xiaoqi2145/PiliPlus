import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

/// 单击识别器：**指针抬起即回调，不等待手势竞技场**。
///
/// 为什么不能直接用框架的 [TapGestureRecognizer] 配 [DoubleTapGestureRecognizer]：
/// [DoubleTapGestureRecognizer] 会在**首次按下**时就
/// `gestureArena.hold(pointer)` 把竞技场挂起（见框架 `multitap.dart`
/// `_registerFirstTap`）。竞技场被 hold 期间，其他成员即使调用
/// `resolve(accepted)` 也不会生效，必须等 [kDoubleTapTimeout]（300ms）
/// 超时、hold 被 release 之后才 sweep 决胜。
///
/// 实测后果：单击回调被推迟 302~316ms 才触发，用户明显感知为"点了没反应"。
///
/// 因此这里由识别器**自行完成双击判定**（比对相邻两次点击的时间与位移），
/// 双击不再参与竞技场，单击延迟完全由 [singleTapDelay] 控制。
///
/// **[singleTapDelay] 同时是"单击落地延迟"和"双击判定窗口"**，两者必须相等
/// 才能保证**双击绝不闪烁**：
///
/// - 单击：抬起后等 [singleTapDelay] 落地（无第二下点击时）；
/// - 双击：第二下抬起若落在 [singleTapDelay] 内，则第一下的单击**尚未落地**，
///   直接取消即可 —— 控制层从头到尾不会出现，无闪烁；
/// - 若恰好卡在边界（单击已落地），用 [onTapRevert] 兜底回滚。
///
/// 时序：
/// ```
/// 单击：down ─ up ─(singleTapDelay)─► onTapUp
/// 双击：down ─ up ─(窗口内)─ down ─ up ─► onDoubleTap        ← 全程无闪烁
/// ```
///
/// 取值权衡：该值即"单击延迟"。框架默认 `kDoubleTapTimeout` 为 300ms
/// （用户可感知为"点了没反应"），本识别器默认取 **200ms**：
/// 单击延迟降为原来的 2/3，同时给双击留出足够的连点间隔。
/// 实测 100ms 时，间隔 155ms 的连点会被判成两次单击；200ms 可覆盖绝大多数
/// 用户的连点节奏。若双击仍不灵敏就继续调大（300ms 即与框架默认一致）；
/// 若更在意跟手就调小（代价是双击需要点得更快）。
class ImmediateTapGestureRecognizer extends OneSequenceGestureRecognizer {
  ImmediateTapGestureRecognizer({
    super.debugOwner,
    super.supportedDevices,
    super.allowedButtonsFilter = _defaultButtonAcceptBehavior,
    this.singleTapDelay = const Duration(milliseconds: 200),
    this.onTapDown,
    this.onTapUp,
    this.onTapCancel,
    this.onTap,
    this.onDoubleTap,
    this.onTapRevert,
  });

  /// 单击落地延迟，同时作为双击判定窗口。详见类文档。
  final Duration singleTapDelay;

  static bool _defaultButtonAcceptBehavior(int buttons) =>
      buttons == kPrimaryButton;

  GestureTapDownCallback? onTapDown;

  GestureTapUpCallback? onTapUp;

  GestureTapCancelCallback? onTapCancel;

  GestureTapCallback? onTap;

  /// 双击回调。参数是**第二次按下**的详情，便于按位置分区（左/中/右），
  /// 与框架 [DoubleTapGestureRecognizer.onDoubleTapDown] 的语义保持一致。
  ///
  /// 为 null 时不做双击判定，所有点击都按单击处理。
  GestureTapDownCallback? onDoubleTap;

  /// 双击**成立**时、在 [onDoubleTap] 之前回调，用于回滚第一下已产生的
  /// 单击效果（例如把刚弹出的控制层收回去），使双击不留下单击的痕迹。
  /// 对齐 B 站"双击快退/快进不显示控制 UI"的行为。
  VoidCallback? onTapRevert;

  PointerUpEvent? _up;
  int? _activePointer;
  bool _sentTapDown = false;
  bool _wonArena = false;
  Offset? _initialPosition;
  TapDownDetails? _downDetails;

  /// 本轮手势是否已经回调过，避免竞技场随后 accept/reject 时重复触发。
  bool _dispatched = false;

  /// 上一次单击的抬起时刻（挂钟毫秒）与位置，用于自行判定双击。
  int? _lastTapMs;
  Offset? _lastTapPosition;

  /// 待派发的单击（延后 [singleTapDelay] 落地）。
  Timer? _singleTapTimer;
  PointerUpEvent? _pendingTapEvent;

  /// 最近一次单击是否已经落地，用于双击时判断该"取消"还是"回滚"。
  bool _singleTapDispatched = false;

  @override
  bool isPointerPanZoomAllowed(PointerPanZoomStartEvent event) => false;

  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      _activePointer == null && super.isPointerAllowed(event);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _reset(event.pointer);
    _handleTapDown(event);
    _initialPosition = event.position;
    _downDetails = TapDownDetails(
      globalPosition: event.position,
      localPosition: event.localPosition,
      kind: event.kind,
    );
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _activePointer) {
      resolvePointer(event.pointer, GestureDisposition.rejected);
      stopTrackingPointer(event.pointer);
      return;
    }

    if (event is PointerMoveEvent) {
      _handlePointerMove(event);
    } else if (event is PointerUpEvent) {
      _up = event;
      _handlePointerUp(event);
    } else if (event is PointerCancelEvent) {
      resolve(GestureDisposition.rejected);
    }

    stopTrackingIfPointerNoLongerDown(event);
  }

  void _handleTapDown(PointerDownEvent event) {
    if (_sentTapDown) return;
    _sentTapDown = true;

    if (onTapDown != null) {
      final details = TapDownDetails(
        globalPosition: event.position,
        localPosition: event.localPosition,
        kind: event.kind,
      );
      invokeCallback<void>('onTapDown', () => onTapDown!(details));
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if ((event.position - _initialPosition!).distanceSquared > 4.0) {
      resolve(GestureDisposition.rejected);
      stopTrackingPointer(event.pointer);
    }
  }

  /// 关键差异：不再 `if (_wonArena)`，抬起即判定并派发，
  /// 从而不受双击识别器 hold 竞技场的影响。
  void _handlePointerUp(PointerUpEvent event) {
    if (_dispatched) return;
    _dispatched = true;

    final upPosition = event.position;
    // 用挂钟时间而非 event.timeStamp：后者在部分合成事件里恒为 0，
    // 会把连续单击误判成双击。
    final now = DateTime.now().millisecondsSinceEpoch;

    final bool isDoubleTap =
        onDoubleTap != null && _isWithinDoubleTapWindow(upPosition, now);

    if (isDoubleTap) {
      // 双击成立：消费掉上一次记录，避免三击被判成两次双击
      _lastTapMs = null;
      _lastTapPosition = null;
      if (_singleTapTimer != null) {
        // 单击尚未落地 → 直接取消，双击全程无闪烁
        _cancelPendingSingleTap();
      } else if (_singleTapDispatched) {
        // 单击已落地 → 回滚（此时才可能有一次"间隔−singleTapDelay"的闪烁）
        _singleTapDispatched = false;
        if (onTapRevert != null) {
          invokeCallback<void>('onTapRevert', onTapRevert!);
        }
      }
      final details = _downDetails;
      if (details != null) {
        invokeCallback<void>('onDoubleTap', () => onDoubleTap!(details));
      }
    } else {
      _lastTapMs = now;
      _lastTapPosition = upPosition;
      _dispatchSingleTap(event);
    }

    _reset();
  }

  /// 双击判定窗口 == 单击落地延迟。两者相等才能保证双击时单击尚未落地、
  /// 从而完全不闪烁。
  bool _isWithinDoubleTapWindow(Offset position, int nowMs) =>
      _lastTapMs != null &&
      nowMs - _lastTapMs! <= singleTapDelay.inMilliseconds &&
      (_lastTapPosition == null ||
          (position - _lastTapPosition!).distance <= kDoubleTapSlop);

  /// 派发单击：存在双击回调时延后 [singleTapDelay]，给第二下留判定时间；
  /// 否则立即派发（无歧义）。
  void _dispatchSingleTap(PointerUpEvent event) {
    if (onDoubleTap == null || singleTapDelay <= Duration.zero) {
      _singleTapDispatched = true;
      _handleTapUp(event);
      return;
    }
    _singleTapDispatched = false;
    _pendingTapEvent = event;
    _singleTapTimer?.cancel();
    _singleTapTimer = Timer(singleTapDelay, () {
      _singleTapTimer = null;
      final pending = _pendingTapEvent;
      _pendingTapEvent = null;
      if (pending == null) return;
      _singleTapDispatched = true;
      _handleTapUp(pending);
    });
  }

  void _cancelPendingSingleTap() {
    _singleTapTimer?.cancel();
    _singleTapTimer = null;
    _pendingTapEvent = null;
    _singleTapDispatched = false;
  }

  void _handleTapUp(PointerUpEvent event) {
    if (onTapUp != null) {
      final details = TapUpDetails(
        globalPosition: event.position,
        localPosition: event.localPosition,
        kind: event.kind,
      );
      invokeCallback<void>('onTapUp', () => onTapUp!(details));
    }

    if (onTap != null) {
      invokeCallback<void>('onTap', onTap!);
    }
  }

  void _cancelGesture(String reason) {
    if (_sentTapDown && onTapCancel != null) {
      invokeCallback<void>('onTapCancel: $reason', onTapCancel!);
    }
    _reset();
  }

  void _reset([int? pointer]) {
    _activePointer = pointer;
    _up = null;
    _sentTapDown = false;
    _wonArena = false;
    _dispatched = false;
    _downDetails = null;
  }

  @override
  void acceptGesture(int pointer) {
    super.acceptGesture(pointer);

    if (pointer == _activePointer) {
      _wonArena = true;

      // 常规路径下单击已在 _handlePointerUp 里按 singleTapDelay 延后派发；
      // 这里只兜底"指针抬起前竞技场已提前 sweep"的次序，且同样走延后派发，
      // 避免绕过延迟导致双击闪烁。
      if (_up != null && !_dispatched) {
        _dispatched = true;
        _dispatchSingleTap(_up!);
        _reset();
      }
    }
  }

  @override
  void rejectGesture(int pointer) {
    super.rejectGesture(pointer);

    if (pointer == _activePointer) {
      // 已回调过（抬起即回调）时只做状态清理，不再补报 cancel；
      // 未回调过（如长按先赢下竞技场）则正常走 cancel。
      if (_dispatched) {
        _reset();
      } else {
        _cancelGesture('gesture rejected by arena');
      }
      stopTrackingPointer(pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _initialPosition = null;
  }

  @override
  void dispose() {
    // 组件销毁时取消待派发的单击，避免回调打到已释放的 widget 上
    _singleTapTimer?.cancel();
    _singleTapTimer = null;
    _pendingTapEvent = null;
    super.dispose();
  }

  @override
  void resolve(GestureDisposition disposition) {
    if (_wonArena && disposition == GestureDisposition.rejected) {
      _cancelGesture('spontaneous');
    }
    super.resolve(disposition);
  }

  @override
  String get debugDescription => 'immediate tap';

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    properties
      ..add(IntProperty('activePointer', _activePointer))
      ..add(
        FlagProperty(
          'sentTapDown',
          value: _sentTapDown,
          ifTrue: 'has sentTapDown',
        ),
      )
      ..add(FlagProperty('wonArena', value: _wonArena, ifTrue: 'wonArena'))
      ..add(FlagProperty('dispatched', value: _dispatched, ifTrue: 'dispatched'))
      ..add(IntProperty('lastTapMs', _lastTapMs))
      ..add(
        DiagnosticsProperty<PointerUpEvent>(
          'pointerUpEvent',
          _up,
          defaultValue: null,
        ),
      );
  }
}
