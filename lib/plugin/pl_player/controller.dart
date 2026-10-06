import 'dart:async' show Completer, StreamSubscription, Timer, unawaited;
import 'dart:convert' show ascii, utf8;
import 'dart:io' show Platform;
import 'dart:math' show max, min;
import 'dart:ui' as ui;

import 'package:PiliPlus/common/assets.dart';
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/common/audio_normalization.dart';
import 'package:PiliPlus/models/common/super_resolution_type.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/user/danmaku_rule.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/models_new/video/video_shot/data.dart';
import 'package:PiliPlus/pages/danmaku/danmaku_model.dart';
import 'package:PiliPlus/pages/sponsor_block/block_mixin.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/double_tap_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/duration.dart';
import 'package:PiliPlus/plugin/pl_player/models/fullscreen_mode.dart';
import 'package:PiliPlus/plugin/pl_player/models/heart_beat_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/video_fit_type.dart';
import 'package:PiliPlus/plugin/pl_player/utils/danmaku_options.dart';
import 'package:PiliPlus/plugin/pl_player/utils/fullscreen.dart';
import 'package:PiliPlus/services/live_pip_overlay_service.dart';
import 'package:PiliPlus/services/pip_overlay_service.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/android/android_helper.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/asset_utils.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/extension/box_ext.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/extension/size_ext.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/ios/pip_helper.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:archive/archive.dart' show getCrc32;
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/services.dart'
    show DeviceOrientation, HapticFeedback, KeyDownEvent, LogicalKeyboardKey;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:native_device_orientation/native_device_orientation.dart';
import 'package:path/path.dart' as path;
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

typedef PlayCallback = Future<void>? Function();
typedef SkipCallback = bool Function();

typedef PlayOwner = ({String tag, Type type});

class _RateRequest {
  _RateRequest({
    required this.speed,
    required this.updateNormalSpeed,
    required this.source,
    required this.requestId,
    this.sessionId,
  });

  final double speed;
  final bool updateNormalSpeed;
  final String source;
  final int requestId;
  final int? sessionId;
  final completer = Completer<void>();
}

class PlPlayerController with BlockConfigMixin, AudioNormalizationMixin {
  Player? _videoPlayerController;
  VideoController? _videoController;

  static PlPlayerController? _instance;

  PlayerStatus playerStatus = .paused;

  final Rx<DataStatus> dataStatus = Rx(.none);

  Duration? seekToPos;
  bool hasToasted = false;
  final RxBool isSeeking = false.obs;

  final RxInt position = RxInt(0);
  final RxInt seekPosition = RxInt(0);
  int get progress => isSeeking.value ? seekPosition.value : position.value;

  int get positionInMilliseconds =>
      videoPlayerController?.state.position.inMilliseconds ?? 0;

  final RxInt buffered = RxInt(0);

  final RxInt duration = RxInt(0);

  int durationInMilliseconds = 0;

  void updateDuration(Duration value) {
    duration.value = value.inSeconds;
    durationInMilliseconds = value.inMilliseconds;
  }

  int _playerCount = 0;

  final RxDouble _playbackSpeed = Pref.playSpeedDefault.obs;
  double _normalPlaybackSpeed = Pref.playSpeedDefault;
  double _appliedPlaybackSpeed = Pref.playSpeedDefault;

  /// The rate a long press is currently holding, or null when no long-press
  /// session is active. Stored rather than recomputed so the on-screen toast
  /// and the rate actually requested can never disagree.
  double? _longPressTargetSpeed;

  _RateRequest? _pendingRateRequest;
  // Latches whether the drain loop is currently running. This must NOT be
  // derived from the worker's Future: a request whose target rate already
  // matches the player's rate skips the only `await` in the loop, so the
  // worker completes synchronously and its (already finished) Future would
  // be latched as "running", permanently wedging every later rate change.
  bool _rateWorkerActive = false;
  bool _rateCoordinatorDisposed = false;
  int _rateRequestId = 0;

  int _longPressGeneration = 0;
  int? _longPressTraceSession;
  double? _longPressBaseSpeed;
  bool _longPressSessionActive = false;
  final Stopwatch _rateTraceClock = Stopwatch()..start();

  final RxDouble volume = RxDouble(
    PlatformUtils.isDesktop ? Pref.desktopVolume : 1.0,
  );
  final setSystemBrightness = Pref.setSystemBrightness;

  final RxDouble brightness = (-1.0).obs;

  final RxBool showControls = false.obs;

  final RxBool showBrightnessStatus = false.obs;

  final RxBool longPressStatus = false.obs;

  final RxBool controlsLock = false.obs;

  final RxBool isFullScreen = false.obs;
  // 系统原生 PiP 状态（由原生侧 onPipChanged 推送）
  final RxBool isNativePip = false.obs;
  bool isLive = false;

  bool _isVertical = false;

  final Rx<VideoFitType> videoFit = Rx(.contain);

  late final RxBool continuePlayInBackground =
      Pref.continuePlayInBackground.obs;

  bool _autoPlay = false;
  bool _playIntent = false;

  /// 媒体源多次重开都失败时的兜底回调：由页面层重新获取播放地址并重建媒体源。
  ///
  /// 必要性：bilibili 的 CDN 地址带时效参数（deadline），过期后无论重开多少次
  /// 都是 403/410，[refreshPlayer] 重放同一个地址无法恢复。音频页在
  /// `pages/audio/controller.dart` 的 _recoverStreamAfterError 中会重新取地址，
  /// 视频侧原先缺失等价逻辑。
  ///
  /// 返回 true 表示已接管恢复，调用方不再结束过渡态。
  Future<bool> Function()? onMediaSourceExpired;

  // 记录历史记录
  int? _aid;
  String? _bvid;
  int? cid;
  int? _epid;
  int? _seasonId;
  int? _pgcType;
  VideoType _videoType = VideoType.ugc;
  int _heartDuration = 0;
  int? width;
  int? height;

  late final tryLook = !Accounts.get(AccountType.video).isLogin && Pref.p1080;

  late DataSource dataSource;

  Timer? _timer;
  int _streamRecoveryGeneration = 0;
  bool _streamRecoveryInProgress = false;
  StreamSubscription? _subForSeek;

  Box setting = GStorage.setting;

  // final Durations durations;

  String get bvid => _bvid!;

  /// 视频播放速度
  double get playbackSpeed => _playbackSpeed.value;

  /// 长按倍速目标值。
  ///
  /// 长按进行中返回本次会话锁定的目标，否则按当前设置实时计算，因此
  /// 设置页改动无需重建播放器即可生效。toast 与真正下发的倍速共用此值。
  double get longPressSpeed {
    if (_longPressTargetSpeed case final target?) {
      return target;
    }
    return _resolveLongPressTargetSpeed();
  }

  /// 按当前设置计算长按目标倍速（不涉及会话状态）。
  double _resolveLongPressTargetSpeed() {
    if (Pref.enableAutoLongPressSpeed) {
      return _normalPlaybackSpeed * 2;
    }
    return Pref.longPressSpeedDefault;
  }

  /// [videoPlayerController] instance of Player
  Player? get videoPlayerController => _videoPlayerController;

  /// [videoController] instance of Player
  VideoController? get videoController => _videoController;

  bool isMuted = false;

  /// 听视频
  late final RxBool onlyPlayAudio = false.obs;

  /// 镜像
  late final RxBool flipX = false.obs;

  late final RxBool flipY = false.obs;

  final RxBool isBuffering = true.obs;

  /// 全屏方向
  // ignore: unnecessary_getters_setters
  bool get isVertical => _isVertical;

  set isVertical(bool value) {
    _isVertical = value;
  }

  /// 弹幕开关
  late final RxBool enableShowDanmaku = Pref.enableShowDanmaku.obs;
  late final RxBool enableShowLiveDanmaku = Pref.enableShowLiveDanmaku.obs;
  RxBool get enableShowDanmakuAdaptive =>
      isLive ? enableShowLiveDanmaku : enableShowDanmaku;

  late final bool autoPiP = Pref.autoPiP;
  bool get isPipMode =>
      isNativePip.value ||
      (Platform.isAndroid && AndroidHelper.isPipMode) ||
      (PlatformUtils.isDesktop && isDesktopPip);
  late bool isDesktopPip = false;
  late Rect _lastWindowBounds;
  static Rect? _lastPipBounds;

  Rect _adjustPipBounds(Rect lastRect, Size size, double aspectRatio) {
    final lastSize = lastRect.size;
    final lastOrientation = lastSize.orientation;
    final orientation = size.orientation;

    if (lastOrientation != orientation) {
      final double width, height;
      switch (orientation) {
        case .portrait:
          if (lastSize.width > size.height) {
            height = min(lastSize.width, _lastWindowBounds.size.height);
            width = height * aspectRatio;
          } else {
            height = size.height;
            width = size.width;
          }
        case .landscape:
          if (lastSize.height > size.width) {
            width = lastSize.height;
            height = width / aspectRatio;
          } else {
            height = size.height;
            width = size.width;
          }
      }

      return _lastPipBounds = Rect.fromLTWH(
        lastRect.left,
        lastRect.top,
        width,
        height,
      );
    }
    return _lastPipBounds = Rect.fromLTWH(
      lastRect.left,
      lastRect.top,
      lastSize.width,
      lastSize.width / aspectRatio,
    );
  }

  bool updatePipBounds() {
    if (isDesktopPip) {
      windowManager.getBounds().then((rect) {
        if (isDesktopPip) _lastPipBounds = rect;
      });
      return true;
    }
    return false;
  }

  late final showWindowTitleBar = Pref.showWindowTitleBar;
  late final RxBool isAlwaysOnTop = false.obs;
  Future<void> setAlwaysOnTop(bool value) {
    isAlwaysOnTop.value = value;
    return windowManager.setAlwaysOnTop(value);
  }

  Future<void> exitDesktopPip() {
    isDesktopPip = false;
    return Future.wait([
      if (showWindowTitleBar)
        windowManager.setTitleBarStyle(TitleBarStyle.normal),
      windowManager.setMinimumSize(const Size(400, 700)),
      windowManager.setBounds(_lastWindowBounds),
      setAlwaysOnTop(false),
      windowManager.setAspectRatio(0),
    ]);
  }

  Future<void> enterDesktopPip() async {
    if (isFullScreen.value) return;

    isDesktopPip = true;

    _lastWindowBounds = await windowManager.getBounds();

    if (showWindowTitleBar) {
      windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    }

    const shortSide = 280.0;
    const minShortSide = 160.0;
    final Size size;
    final Size minimumSize;
    final state = videoPlayerController!.state;
    int width = state.width;
    int height = state.height;
    if (width == 0) width = this.width ?? 16;
    if (height == 0) height = this.height ?? 9;
    final aspectRatio = width / height;
    if (height > width) {
      size = Size(shortSide, shortSide / aspectRatio);
      minimumSize = Size(minShortSide, minShortSide / aspectRatio);
    } else {
      size = Size(shortSide * aspectRatio, shortSide);
      minimumSize = Size(minShortSide * aspectRatio, minShortSide);
    }

    await windowManager.setMinimumSize(minimumSize);
    setAlwaysOnTop(true);
    if (_lastPipBounds != null) {
      windowManager.setBounds(
        _adjustPipBounds(_lastPipBounds!, size, aspectRatio),
      );
    } else {
      windowManager.setSize(size);
    }
    windowManager.setAspectRatio(width / height);
  }

  void toggleDesktopPip() {
    if (isDesktopPip) {
      exitDesktopPip();
    } else {
      enterDesktopPip();
    }
  }

  late bool _isAutoEnterPip = false;
  bool get isAutoEnterPip => _isAutoEnterPip;

  static bool get _isCurrVideoPage {
    final routing = Get.routing;
    if (routing.route is! GetPageRoute) {
      return false;
    }
    return _isVideoPage(routing.current);
  }

  static bool _isVideoPage(String routeName) {
    return routeName == '/videoV' || routeName == '/liveRoom';
  }

  /// 是否存在应用内小窗（视频页或直播页）
  bool get _isInInAppPip {
    return PipOverlayService.isInPipMode || LivePipOverlayService.isInPipMode;
  }

  void enterPip({bool autoEnter = false}) {
    if (videoPlayerController case NativePlayer(:final state)) {
      if (Platform.isIOS) {
        if (videoController?.id.value case final textureId?) {
          IOSPipHelper.enter(
            textureId,
            width: state.width == 0 ? width : state.width,
            height: state.height == 0 ? height : state.height,
            autoEnter: autoEnter,
            state: _iosPipState(state),
          );
        }
        return;
      }
      PageUtils.enterPip(
        autoEnter: autoEnter,
        width: state.width == 0 ? width : state.width,
        height: state.height == 0 ? height : state.height,
        isLive: isLive,
        isPlaying: playerStatus.isPlaying,
      );
    }
  }

  /// 供外部（小窗服务）主动切断 Auto-Enter PiP
  void disableAutoEnterPip() => _disableAutoEnterPip();

  void _disableAutoEnterPip() {
    if (_isAutoEnterPip) {
      if (Platform.isIOS) {
        IOSPipHelper.disableAutoEnter();
      } else {
        PiliAndroidHelper.disableAutoEnterPip();
      }
    }
  }

  Map<String, Object> _iosPipState(PlayerState state, [Duration? position]) {
    return {
      'isPlaying': playerStatus.isPlaying,
      'isBuffering': isBuffering.value,
      'isLive': isLive,
      'position': (position ?? state.position).inMilliseconds,
      'duration': durationInMilliseconds,
      'speed': state.rate,
    };
  }

  void _updateIOSPip([Duration? position]) {
    if (Platform.isIOS && IOSPipHelper.needsUpdate) {
      if (_videoPlayerController case final player?) {
        IOSPipHelper.update(_iosPipState(player.state, position));
      }
    }
  }

  // 弹幕相关配置
  late final enableTapDm = PlatformUtils.isMobile && Pref.enableTapDm;
  late RuleFilter filters = Pref.danmakuFilterRule;
  // 关联弹幕控制器
  DanmakuController<DanmakuExtra>? danmakuController;
  bool showDanmaku = true;
  Set<int> dmState = <int>{};
  late final mergeDanmaku = Pref.mergeDanmaku;
  late final String midHash = getCrc32(
    ascii.encode(Accounts.main.mid.toString()),
    0,
  ).toRadixString(16);
  late final RxDouble danmakuOpacity = Pref.danmakuOpacity.obs;

  late List<double> speedList = Pref.speedList;
  late final showControlDuration = Pref.enableLongShowControl
      ? const Duration(seconds: 30)
      : const Duration(seconds: 3);
  // 字幕
  late double subtitleFontScale = Pref.subtitleFontScale;
  late double subtitleFontScaleFS = Pref.subtitleFontScaleFS;
  late int subtitlePaddingH = Pref.subtitlePaddingH;
  late int subtitlePaddingB = Pref.subtitlePaddingB;
  late double subtitleBgOpacity = Pref.subtitleBgOpacity;
  final bool showVipDanmaku = Pref.showVipDanmaku; // loop unswitching
  late double subtitleStrokeWidth = Pref.subtitleStrokeWidth;
  late int subtitleFontWeight = Pref.subtitleFontWeight;

  // settings
  late final showFSActionItem = Pref.showFSActionItem;
  late final enableShrinkVideoSize = Pref.enableShrinkVideoSize;
  late final darkVideoPage = Pref.darkVideoPage;
  late final enableSlideVolumeBrightness = Pref.enableSlideVolumeBrightness;
  late final enableSlideFS = Pref.enableSlideFS;
  late final enableDragSubtitle = Pref.enableDragSubtitle;
  late final fastForBackwardDuration = Duration(
    seconds: Pref.fastForBackwardDuration,
  );

  late final horizontalSeasonPanel = Pref.horizontalSeasonPanel;
  late final preInitPlayer = Pref.preInitPlayer;
  late final showRelatedVideo = Pref.showRelatedVideo;
  late final showVideoReply = Pref.showVideoReply;
  late final showBangumiReply = Pref.showBangumiReply;
  late final reverseFromFirst = Pref.reverseFromFirst;
  late final horizontalPreview = Pref.horizontalPreview;
  late final showDmChart = Pref.showDmChart;
  late final showViewPoints = Pref.showViewPoints;
  late final showFsScreenshotBtn = Pref.showFsScreenshotBtn;
  late final showFsLockBtn = Pref.showFsLockBtn;
  late final keyboardControl = Pref.keyboardControl;
  late final uiScale = Pref.uiScale;

  late final bool autoEnterFullScreen = Pref.autoEnterFullScreen;
  late final bool autoExitFullscreen = Pref.autoExitFullscreen;
  late final bool autoPlayEnable = Pref.autoPlayEnable;
  late final bool enableVerticalExpand = Pref.enableVerticalExpand;
  late final bool pipNoDanmaku = Pref.pipNoDanmaku;

  late final bool tempPlayerConf = Pref.tempPlayerConf;

  late int? cacheVideoQa = PlatformUtils.isMobile ? null : Pref.defaultVideoQa;
  late int cacheAudioQa = Pref.defaultAudioQa;
  bool enableHeart = true;
  late final String? hwdec = Pref.enableHA ? Pref.hardwareDecoding : null;

  late final progressType = Pref.btmProgressBehavior;
  late final enableQuickDouble = Pref.enableQuickDouble;
  late final fullScreenGestureReverse = Pref.fullScreenGestureReverse;

  late final isRelative = Pref.useRelativeSlide;
  late final offset = isRelative
      ? Pref.sliderDuration / 100
      : Pref.sliderDuration * 1000;

  num get sliderScale => isRelative ? durationInMilliseconds * offset : offset;

  // 播放顺序相关
  late PlayRepeat playRepeat = Pref.playRepeat;

  TextStyle get subTitleStyle => TextStyle(
    height: 1.5,
    fontSize:
        16 * (isFullScreen.value ? subtitleFontScaleFS : subtitleFontScale),
    letterSpacing: 0.1,
    wordSpacing: 0.1,
    color: Colors.white,
    fontWeight: FontWeight.values[subtitleFontWeight],
    backgroundColor: subtitleBgOpacity == 0
        ? null
        : Colors.black.withValues(alpha: subtitleBgOpacity),
  );

  late final Rx<SubtitleViewConfiguration> subtitleConfig = getSubConfig.obs;

  SubtitleViewConfiguration get getSubConfig {
    final subTitleStyle = this.subTitleStyle;
    return SubtitleViewConfiguration(
      style: subTitleStyle,
      strokeStyle: subtitleBgOpacity == 0
          ? subTitleStyle.copyWith(
              color: null,
              background: null,
              backgroundColor: null,
              foreground: Paint()
                ..color = Colors.black
                ..style = PaintingStyle.stroke
                ..strokeWidth = subtitleStrokeWidth,
            )
          : null,
      padding: EdgeInsets.only(
        left: subtitlePaddingH.toDouble(),
        right: subtitlePaddingH.toDouble(),
        bottom: subtitlePaddingB.toDouble(),
      ),
      textScaleFactor: 1,
    );
  }

  void updateSubtitleStyle() {
    subtitleConfig.value = getSubConfig;
  }

  void onUpdatePadding(EdgeInsets padding) {
    subtitlePaddingB = padding.bottom.round().clamp(0, 200);
    putSubtitleSettings();
  }

  static PlPlayerController? get instance => _instance;

  static bool instanceExists() {
    return _instance != null;
  }

  static void setPlayCallBack(
    PlayCallback? playCallBack, {
    SkipCallback? skipToNext,
    SkipCallback? skipToPrevious,
    PlayOwner? playOwner,
  }) {
    _playCallBack = playCallBack;
    _skipToNextCallBack = skipToNext;
    _skipToPreviousCallBack = skipToPrevious;
    _playOwner = playOwner;
  }

  static PlayOwner? _playOwner;
  static PlayOwner? get playOwner => _playOwner;
  static PlayCallback? _playCallBack;
  static SkipCallback? _skipToNextCallBack;
  static SkipCallback? _skipToPreviousCallBack;

  static Future<void>? playIfExists() {
    // The page callback is only an enhancement (it re-attaches page listeners
    // and can start an item that is not loaded yet).  It must never swallow a
    // play request: the callback is registered in the page's initState and
    // cleared again on pop or when the in-app PiP window closes, so a play
    // command from the media notification or a headset button would otherwise
    // fall through to nothing and only start working after returning to the
    // player page.
    if (_playCallBack?.call() case final callback?) {
      return callback;
    }
    final player = _instance;
    if (player == null ||
        player._playerCount == 0 ||
        player.videoPlayerController == null) {
      return null;
    }
    // Keep the in-page control bar hidden: this path serves media notification
    // and headset commands, which must not reveal the on-screen controls.
    return player.play(hideControls: false);
  }

  /// Headset/notification "next". Returns null when no page registered a skip
  /// callback (or the registered one reports "already at the last item"), so
  /// [VideoPlayerServiceHandler] can tell "handled" from "nothing to do".
  static Future<void>? skipToNextIfExists() {
    return (_skipToNextCallBack?.call() ?? false) ? Future<void>.value() : null;
  }

  static Future<void>? skipToPreviousIfExists() {
    return (_skipToPreviousCallBack?.call() ?? false)
        ? Future<void>.value()
        : null;
  }

  // try to get PlayerStatus
  static PlayerStatus? getPlayerStatusIfExists() {
    return _instance?.playerStatus;
  }

  static Future<void>? pauseIfExists({
    bool notify = true,
    bool isInterrupt = false,
  }) {
    if (_instance?.playerStatus.isPlaying ?? false) {
      return _instance?.pause(notify: notify, isInterrupt: isInterrupt);
    }
    return null;
  }

  static Future<void>? seekToIfExists(
    Duration position, {
    bool isSeek = true,
  }) {
    return _instance?.seekTo(position, isSeek: isSeek);
  }

  static double? getVolumeIfExists() {
    return _instance?.volume.value;
  }

  static Future<void>? setVolumeIfExists(
    double volumeNew, {
    bool showIndicator = true,
  }) {
    return _instance?.setVolume(volumeNew, showIndicator: showIndicator);
  }

  Box video = GStorage.video;

  bool visible = true;

  DeviceOrientation? _orientation;
  late final checkIsAutoRotate = Platform.isAndroid && mode != .gravity;
  StreamSubscription<OrientationParams>? _orientationListener;

  void _stopOrientationListener() {
    _orientationListener?.cancel();
    _orientationListener = null;
  }

  void _onOrientationChanged(OrientationParams param) {
    _orientation = param.orientation;
    if (Platform.isIOS && !visible) return;
    final orientation = param.orientation;
    final isFullScreen = this.isFullScreen.value;
    if (checkIsAutoRotate &&
        param.isAutoRotate != true &&
        (!isFullScreen ||
            _isVertical ||
            orientation == .portraitUp ||
            orientation == .portraitDown)) {
      return;
    }
    switch (orientation) {
      case .portraitUp:
        if (!_isVertical && controlsLock.value) return;
        if (!horizontalScreen && !_isVertical && isFullScreen) {
          if (!isManualFS) {
            triggerFullScreen(status: false, orientation: orientation);
          }
        } else {
          portraitUpMode();
        }
      case .portraitDown:
        if (!horizontalScreen) return;
        if (!_isVertical && controlsLock.value) return;
        portraitDownMode();
      case .landscapeLeft:
        if (!horizontalScreen && !isFullScreen) {
          triggerFullScreen(orientation: orientation, isManualFS: false);
        } else {
          landscapeLeftMode();
        }
      case .landscapeRight:
        if (!horizontalScreen && !isFullScreen) {
          triggerFullScreen(orientation: orientation, isManualFS: false);
        } else {
          landscapeRightMode();
        }
    }
  }

  // 添加一个私有构造函数
  PlPlayerController._() {
    if (PlatformUtils.isMobile) {
      _orientationListener = NativeDeviceOrientationPlatform.instance
          .onOrientationChanged(
            checkIsAutoRotate: checkIsAutoRotate,
            angleDegrees: Platform.isAndroid ? Pref.angleDegrees : null,
          )
          .listen(_onOrientationChanged);
    }

    if (!Accounts.heartbeat.isLogin || Pref.historyPause) {
      enableHeart = false;
    }

    if (Platform.isAndroid) {
      // 原生侧 PiP 状态变化推送，用于同步应用内小窗与系统 PiP
      Utils.channel.setMethodCallHandler((call) async {
        if (call.method == 'onPipChanged') {
          final bool isInPip = call.arguments as bool;
          isNativePip.value = isInPip;
          PipOverlayService.isNativePip = isInPip;
          LivePipOverlayService.isNativePip = isInPip;
        }
      });

      if (autoPiP) {
        if (DeviceUtils.sdkInt < 31) {
          AndroidHelper$ToDart.onUserLeaveHint = Runnable.implement(
            $Runnable(run: _onUserLeaveHint),
          );
        } else {
          _isAutoEnterPip = true;
        }
      }
    } else if (Platform.isIOS && autoPiP && IOSPipHelper.isAvailable) {
      _isAutoEnterPip = true;
    }
  }

  void _onUserLeaveHint() {
    // 应用内小窗存在时，系统 PiP 交由小窗服务接管
    if (_isInInAppPip) {
      enterPip();
      return;
    }
    if (playerStatus.isPlaying && _isCurrVideoPage) {
      enterPip();
    }
  }

  // 获取实例 传参
  static PlPlayerController getInstance({bool isLive = false}) {
    // 如果实例尚未创建，则创建一个新实例
    return (_instance ??= PlPlayerController._())
      ..isLive = isLive
      .._playerCount += 1;
  }

  bool _processing = false;
  bool get processing => _processing;

  // offline
  bool get isFileSource => dataSource is FileSource;

  // 初始化资源
  Future<void> setDataSource(
    DataSource dataSource, {
    bool isLive = false,
    bool autoplay = true,
    // 初始化播放位置
    Duration? seekTo,
    // 初始化播放速度
    double speed = 1.0,
    int? width,
    int? height,
    Duration? duration,
    // 方向
    bool? isVertical,
    // 记录历史记录
    int? aid,
    String? bvid,
    int? cid,
    int? epid,
    int? seasonId,
    int? pgcType,
    VideoType? videoType,
    VoidCallback? onInit,
    Volume? volume,
    bool autoFullScreenFlag = false,
  }) async {
    try {
      _processing = true;
      this.isLive = isLive;
      _videoType = videoType ?? VideoType.ugc;
      this.width = width;
      this.height = height;
      this.dataSource = dataSource;
      _autoPlay = autoplay;
      // 初始化数据加载状态
      dataStatus.value = DataStatus.loading;
      // 初始化全屏方向
      _isVertical = isVertical ?? false;
      _aid = aid;
      _bvid = bvid;
      this.cid = cid;
      _epid = epid;
      _seasonId = seasonId;
      _pgcType = pgcType;

      if (showSeekPreview) {
        _clearPreview();
      }
      cancelKeyGestureTimers();
      // 切集/换清晰度会重建媒体源。长按会话若跨越这次切换，其锁定目标与
      // 基准倍速都已失效，必须在这里结束，否则 _initializePlayer 会把
      // 提升后的倍速当作新的常规倍速写下去。
      _cancelLongPressSessionForNormalRateChange();
      if (_videoPlayerController != null &&
          _videoPlayerController!.state.playing) {
        // setDataSource is also used for automatic next-item transitions.
        // Keep the playback intent and audio focus while the media source is
        // being replaced; a normal pause here releases focus and clears
        // _playIntent, which can make background playback stop during the
        // short gap between two videos.
        await pause(notify: false, isInterrupt: true);
      }

      if (_playerCount == 0) {
        return;
      }
      // 配置Player 音轨、字幕等等
      await _createVideoController(dataSource, seekTo, volume);

      if (_playerCount == 0) {
        _removeListeners();
        _videoPlayerController?.dispose();
        _videoPlayerController = null;
        _videoController = null;
        return;
      }

      updateDuration(duration ?? _videoPlayerController!.state.duration);
      position.value = buffered.value = seekTo?.inSeconds ?? 0;

      dataStatus.value = .loaded;

      if (autoFullScreenFlag && autoEnterFullScreen) {
        triggerFullScreen(status: true);
      }

      await _initializePlayer();
      onInit?.call();
    } catch (err, stackTrace) {
      dataStatus.value = DataStatus.error;
      if (kDebugMode) {
        debugPrint(stackTrace.toString());
        debugPrint('plPlayer err:  $err');
      }
    } finally {
      _processing = false;
    }
  }

  String? shadersDirPath;
  Future<String> get copyShadersToExternalDirectory async {
    if (shadersDirPath != null) {
      return shadersDirPath!;
    }

    return shadersDirPath = await AssetUtils.getOrCopy(
      'assets/shaders',
      Assets.mpvAnime4KShaders.followedBy(Assets.mpvAnime4KShadersLite),
      path.join(appSupportDirPath, 'anime_shaders'),
    );
  }

  late final isAnim = _pgcType == 1 || _pgcType == 4;
  late final Rx<SuperResolutionType> superResolutionType =
      (isAnim ? Pref.superResolutionType : SuperResolutionType.disable).obs;
  Future<void> setShader([SuperResolutionType? type, NativePlayer? pp]) async {
    if (type == null) {
      type = superResolutionType.value;
    } else {
      superResolutionType.value = type;
      if (isAnim && !tempPlayerConf) {
        setting.put(SettingBoxKey.superResolutionType, type.index);
      }
    }
    pp ??= _videoPlayerController!;
    switch (type) {
      case SuperResolutionType.disable:
        return pp.command(const ['change-list', 'glsl-shaders', 'clr', '']);
      case SuperResolutionType.efficiency:
        return pp.command([
          'change-list',
          'glsl-shaders',
          'set',
          PathUtils.buildShadersAbsolutePath(
            await copyShadersToExternalDirectory,
            Assets.mpvAnime4KShadersLite,
          ),
        ]);
      case SuperResolutionType.quality:
        return pp.command([
          'change-list',
          'glsl-shaders',
          'set',
          PathUtils.buildShadersAbsolutePath(
            await copyShadersToExternalDirectory,
            Assets.mpvAnime4KShaders,
          ),
        ]);
    }
  }

  Future<Player> _initPlayer() async {
    assert(_videoPlayerController == null);
    final opt = {
      'video-sync': Pref.videoSync,
      if (Platform.isAndroid) 'ao': Pref.audioOutput,
      'volume':
          (PlatformUtils.isMobile ? Pref.playerVolume : volume.value * 100)
              .toString(),
    };
    final autosync = Pref.autosync;
    if (autosync != '0') {
      opt['autosync'] = autosync;
    }

    final player = await Player.create(
      configuration: PlayerConfiguration(
        logLevel: kDebugMode ? .warn : .error,
        options: opt,
      ),
    );

    assert(_videoController == null);

    _videoController = await VideoController.create(
      player,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: hwdec != null,
        androidAttachSurfaceAfterVideoParameters: false,
        hwdec: hwdec,
      ),
    );

    player.setMediaHeader(userAgent: BrowserUa.pc, referer: HttpString.baseUrl);

    _startListeners(player);

    return player;
  }

  /// 当前生效的缓冲参数，随常规倍速重建。
  ///
  /// `cache-secs` / `demuxer-hysteresis-secs` 由 [Pref.initBuffer] 按倍速缩放：
  /// 倍速越高，单位实际时间消费的媒体越多，时间目标必须同步放大。原先的
  /// `late final` 只在首次读取时算一次，之后每次建源都复用旧倍速算出的目标。
  late Map<String, String> buffer = Pref.initBuffer(_normalPlaybackSpeed);
  late final liveBuffer = Pref.initLiveBuffer();

  // 配置播放器
  Future<void> _createVideoController(
    DataSource dataSource,
    Duration? seekTo,
    Volume? volume,
  ) async {
    isBuffering.value = false;
    _heartDuration = 0;
    danmakuController?.clear();

    var player = _videoPlayerController;

    if (player == null) {
      player = await _initPlayer();
      if (_playerCount == 0) {
        _removeListeners();
        player.dispose();
        player = null;
        _videoController = null;
        return;
      }
      _videoPlayerController = player;
      if (isAnim && superResolutionType.value != .disable) {
        await setShader();
      }
    }

    final Map<String, String> extras = {
      if (dataSource is FileSource)
        'cache': 'no'
      else if (isLive)
        ...liveBuffer
      else
        ...buffer,
    };

    String video = dataSource.videoSource;
    if (dataSource.audioSource case final audio? when (audio.isNotEmpty)) {
      if (onlyPlayAudio.value) {
        video = audio;
      } else {
        // dely_open need provide length
        video =
            ('edl://'
            '!no_chapters;'
            // '!delay_open,media_type=video;'
            '%${isFileSource ? utf8.encode(video).length : video.length}%$video;'
            '!new_stream;!no_chapters;'
            // '!delay_open,media_type=audio;'
            '%${isFileSource ? utf8.encode(audio).length : audio.length}%$audio');
      }
      audioFilterExtras(volume, map: extras);
    }

    assert(!isLive || seekTo == null);
    await player.open(
      Media(
        video,
        start: seekTo,
        extras: extras.isEmpty ? null : extras,
      ),
      play: false,
    );
  }

  Future<void>? refreshPlayer() {
    if (dataSource is FileSource) {
      return null;
    }
    if (_videoPlayerController case final ctr? when (ctr.current.isNotEmpty)) {
      var media = ctr.current.last;
      if (!isLive) media = media.copyWith(start: ctr.state.position);
      return ctr.open(media, play: true);
    }
    return null;
  }

  // 开始播放
  Future<void> _initializePlayer() async {
    if (_instance == null) return;
    // 设置倍速
    if (_videoPlayerController != null) {
      // 用常规倍速而非 _playbackSpeed：后者在长按会话期间是提升后的值，
      // 新建媒体源不应继承它。
      final speed = isLive ? 1.0 : _normalPlaybackSpeed;
      if (_videoPlayerController!.state.rate != speed) {
        await setPlaybackSpeed(speed);
      }
    }
    _initVideoFit();

    // 自动播放：直接驱动自身播放，不能依赖页面注册的静态回调。
    // 页面切换/小窗交接期间静态回调可能被清空或仍指向旧页面，
    // 会导致 setDataSource 完成后停在暂停态。
    if (_autoPlay) {
      await play();
    }
  }

  List<StreamSubscription>? _subscriptions;
  final Set<ValueChanged<Duration>> _positionListeners = {};
  final Set<ValueChanged<PlayerStatus>> _statusListeners = {};

  Timer? _wakeLockTimer;

  void _startWakeLockTimer() {
    _wakeLockTimer?.cancel();
    _wakeLockTimer = Timer(
      const Duration(milliseconds: 500),
      _stopWakeLock,
    );
  }

  void _stopWakeLockTimer() {
    _wakeLockTimer?.cancel();
    _wakeLockTimer = null;
  }

  void _stopWakeLock() {
    WakelockPlus.disable();
    _updatePlaybackState(debugLabel: 'onVideoPaused');
  }

  void _updatePlaybackState({Duration? position, String? debugLabel}) {
    videoPlayerServiceHandler?.onUpdateState(
      playerStatus,
      isBuffering.value,
      isLive,
      position: position ?? _videoPlayerController!.state.position,
      speed: playbackSpeed,
      debugLabel: debugLabel,
    );
    _updateIOSPip(position);
  }

  /// 播放事件监听
  void _startListeners(NativePlayer player) {
    assert(_subscriptions == null);
    final stream = player.stream;
    _subscriptions = [
      /// playing
      stream.playing.listen((bool playing) {
        if (playing) {
          playerStatus = .playing;
          videoPlayerServiceHandler?.endTransition(playing: true);
          _stopWakeLockTimer();
          _updatePlaybackState();
          WakelockPlus.enable();

          if (_isAutoEnterPip) {
            if (_isCurrVideoPage || _isInInAppPip) {
              enterPip(autoEnter: true);
            } else {
              _disableAutoEnterPip();
            }
          }
        } else {
          // 播放停下（暂停、音频焦点中断、播放完成）意味着长按手势已经结束。
          // 移动端长按期间指针被识别器独占，抬手不会走 onLongPressEnd；桌面端
          // 按空格、或按住 → 时窗口失焦，也都不会回调长按结束。此处不清理的话，
          // 提升后的倍速会一直留在播放器上，直到用户再长按一次或切源。
          _endLongPressSessionOnStop();
          playerStatus = .paused;
          // 用上游的 helper 而非内联 Timer：_stopWakeLock 还会发布
          // onVideoPaused 状态，内联实现会漏掉这次发布。
          _startWakeLockTimer();
          _disableAutoEnterPip();
          _updateIOSPip();
        }

        for (final element in _statusListeners) {
          element(playing ? .playing : .paused);
        }

        final seconds = videoPlayerController!.state.position.inSeconds;
        if (seconds != 0) {
          makeHeartBeat(seconds, type: .status);
        }
      }),

      ///completed
      stream.completed.listen((bool completed) async {
        if (completed) {
          playerStatus = .completed;
          videoPlayerServiceHandler?.beginTransition();
          // Abandon focus before notifying the next item.  The session
          // handler serializes this with a subsequent play request so the
          // completed item cannot keep focus or release it out of order.
          await audioSessionHandler?.setActive(false);
          _startWakeLockTimer();

          for (final element in _statusListeners) {
            element(.completed);
          }

          makeHeartBeat(-1, type: .completed);
        }
      }),

      /// position
      stream.position.listen((Duration position) {
        final posInSeconds = position.inSeconds;

        if (posInSeconds != this.position.value) {
          if (posInSeconds == 0 && playerStatus.isPlaying) {
            _updatePlaybackState(position: position);
          }

          this.position.value = posInSeconds;

          makeHeartBeat(posInSeconds);
        }

        for (final element in _positionListeners) {
          element(position);
        }
      }),
      stream.duration.listen((Duration duration) {
        updateDuration(duration);
        _updateIOSPip();
      }),
      stream.buffer.listen((Duration buffer) {
        buffered.value = buffer.inSeconds;
        if (_longPressTraceSession != null) {
          _traceLongPressRate(
            'buffer',
            bufferSeconds: buffer.inMilliseconds / 1000,
          );
        }
      }),
      stream.buffering.listen((bool buffering) {
        isBuffering.value = buffering;
        if (_longPressTraceSession != null) {
          _traceLongPressRate(buffering ? 'bufferingStart' : 'bufferingEnd');
        }
        // 过渡态（beginTransition/extendTransition/endTransition）的暂停防抖
        // 已收敛到 audio_handler 的 onUpdateState，这里只负责发布。
        if (!playerStatus.isCompleted) {
          _stopWakeLockTimer();
          _updatePlaybackState();
        }
      }),
      if (kDebugMode)
        stream.log.listen(((PlayerLog log) {
          if (log.level == 'error' || log.level == 'fatal') {
            Utils.reportError(
              '${log.level}: ${log.prefix}: ${log.text}\n${player.state.playlist}',
              null,
            );
          } else {
            debugPrint(log.toString());
          }
        })),
      stream.error.listen((String event) {
        if (dataSource is FileSource &&
            event.startsWith("Failed to open file")) {
          return;
        }
        if (isLive) {
          if (event.startsWith('tcp: ffurl_read returned ') ||
              event.startsWith("Failed to open https://") ||
              event.startsWith("Can not open external file https://")) {
            Timer(const Duration(milliseconds: 3000), refreshPlayer);
          }
          return;
        }
        if (_playIntent) {
          _recoverStreamAfterError();
        }
        if (event.startsWith("Failed to open https://") ||
            event.startsWith("Can not open external file https://") ||
            //tcp: ffurl_read returned 0xdfb9b0bb
            //tcp: ffurl_read returned 0xffffff99
            event.startsWith('tcp: ffurl_read returned ')) {
          EasyThrottle.throttle(
            'controllerStream.error.listen',
            const Duration(milliseconds: 10000),
            () {
              Timer(const Duration(milliseconds: 3000), () {
                // if (kDebugMode) {
                //   debugPrint("isBuffering.value: ${isBuffering.value}");
                // }
                // if (kDebugMode) {
                //   debugPrint("_buffered.value: ${_buffered.value}");
                // }
                if (isBuffering.value && buffered.value == 0) {
                  SmartDialog.showToast(
                    '视频链接打开失败，重试中',
                    displayTime: const Duration(milliseconds: 500),
                  );
                  refreshPlayer();
                }
              });
            },
          );
        } else if (event.startsWith('Could not open codec')) {
          SmartDialog.showToast('无法加载解码器, $event，可能会切换至软解');
        } else if (!onlyPlayAudio.value) {
          if (event.startsWith("error running") ||
              event.startsWith("Failed to open .") ||
              event.startsWith("Cannot open") ||
              event.startsWith("Can not open")) {
            return;
          }
          if (!kDebugMode) {
            Utils.reportError('$event\n${player.state.playlist}');
          }
          // SmartDialog.showToast('视频加载错误, $event');
        }
      }),
    ];
  }

  Future<void> _recoverStreamAfterError() async {
    if (_streamRecoveryInProgress || dataSource is FileSource) return;
    final player = _videoPlayerController;
    if (player == null) return;
    _streamRecoveryInProgress = true;
    final generation = ++_streamRecoveryGeneration;
    videoPlayerServiceHandler?.beginTransition();
    var recovered = false;
    try {
      const delays = <Duration>[
        Duration(milliseconds: 500),
        Duration(seconds: 1),
        Duration(seconds: 2),
        Duration(seconds: 4),
      ];
      for (final delay in delays) {
        await Future<void>.delayed(delay);
        if (generation != _streamRecoveryGeneration || !_playIntent) return;
        if (player.state.playing) {
          recovered = true;
          return;
        }
        // 每次重试都为过渡态续命，避免恢复过程被过渡期上限判死
        videoPlayerServiceHandler?.extendTransition();
        try {
          await refreshPlayer();
          if (player.state.playing) {
            recovered = true;
            return;
          }
        } catch (_) {}
      }
      // 反复重开同一地址仍失败：多半是 CDN 地址已过期，交给页面层重取
      if (generation == _streamRecoveryGeneration && _playIntent) {
        recovered = await onMediaSourceExpired?.call() ?? false;
      }
    } finally {
      if (generation == _streamRecoveryGeneration) {
        _streamRecoveryInProgress = false;
        // 已由页面层接管恢复时不结束过渡态：重建成功后 stream.playing
        // 监听会调用 endTransition(playing: true)
        if (!recovered) {
          videoPlayerServiceHandler?.endTransition(playing: false);
        }
      }
    }
  }

  /// 移除事件监听
  void _removeListeners() {
    _subscriptions?.forEach((e) => e.cancel());
    _subscriptions?.clear();
    _subscriptions = null;
  }

  void _cancelSubForSeek() {
    if (_subForSeek != null) {
      _subForSeek!.cancel();
      _subForSeek = null;
    }
  }

  Future<void> seek(Duration position, {bool isSeek = false}) async {
    if (isSeek) {
      /// 拖动进度条调节时，不等待第一帧，防止抖动
      await _videoPlayerController?.stream.buffer.first;
    }
    danmakuController?.clear();
    try {
      await _videoPlayerController?.seek(position);
      _updateIOSPip(position);
    } catch (e) {
      if (kDebugMode) debugPrint('seek failed: $e');
    }
  }

  /// 跳转至指定位置
  Future<void> seekTo(Duration position, {bool isSeek = true}) async {
    if (_playerCount == 0) {
      return;
    }
    if (position < Duration.zero) {
      position = Duration.zero;
    }
    _heartDuration = position.inSeconds;

    if (duration.value != 0) {
      seek(position, isSeek: isSeek);
    } else {
      // if (kDebugMode) debugPrint('seek duration else');
      _subForSeek?.cancel();
      _subForSeek = duration.listen((_) {
        seek(position, isSeek: isSeek);
        _cancelSubForSeek();
      });
    }
  }

  /// 设置倍速
  Future<void> setPlaybackSpeed(double speed) async {
    _cancelLongPressSessionForNormalRateChange();
    if (speed.isFinite && speed > 0) {
      _normalPlaybackSpeed = speed;
    }
    await _requestPlaybackRate(
      speed,
      updateNormalSpeed: true,
      source: 'normal',
    );
  }

  void _cancelLongPressSessionForNormalRateChange() {
    if (!_longPressSessionActive && !longPressStatus.value) return;
    _longPressGeneration++;
    _clearLongPressSession();
  }

  /// 播放停下时收尾长按会话，把倍速还原为长按前的常规值。
  ///
  /// 刻意复用 [setLongPressStatus] 的结束分支而不是自己再发一次
  /// [_requestPlaybackRate]：结束分支已经处理了基准倍速回退、代次校验与
  /// 会话字段清理，多一条恢复路径就多一处可能与它不一致的地方。
  ///
  /// 由播放状态监听调用，因此必须是同步且幂等的：没有会话时立即返回。
  void _endLongPressSessionOnStop() {
    if (!_longPressSessionActive && !longPressStatus.value) return;
    unawaited(setLongPressStatus(false));
  }

  /// Drops every trace of an in-flight long-press session.
  ///
  /// Kept in one place so a newly added session field cannot be forgotten in
  /// one of the several teardown paths (normal rate change, media source
  /// switch, setRate failure, release, dispose).
  void _clearLongPressSession() {
    _longPressSessionActive = false;
    _longPressBaseSpeed = null;
    _longPressTargetSpeed = null;
    _longPressTraceSession = null;
    longPressStatus.value = false;
  }

  Future<void> _requestPlaybackRate(
    double speed, {
    required bool updateNormalSpeed,
    required String source,
    int? sessionId,
  }) {
    if (!speed.isFinite || speed <= 0) {
      return Future.value();
    }
    if (_rateCoordinatorDisposed) {
      return Future.value();
    }

    final requestId = ++_rateRequestId;
    final request = _RateRequest(
      speed: speed,
      updateNormalSpeed: updateNormalSpeed,
      source: source,
      requestId: requestId,
      sessionId: sessionId,
    );
    final previous = _pendingRateRequest;
    _pendingRateRequest = request;
    // A pending request is deliberately latest-wins. Its caller has no useful
    // work left to wait for because the newer request superseded its target.
    if (previous != null && !previous.completer.isCompleted) {
      previous.completer.complete();
    }
    _traceLongPressRate(
      'rateRequest',
      requestId: requestId,
      target: speed,
      source: source,
      sessionId: sessionId,
    );
    _ensureRateWorker();
    return request.completer.future;
  }

  /// Starts the drain loop unless it is already running.
  ///
  /// The latch is a plain bool rather than the worker's [Future] on purpose:
  /// see [_rateWorkerActive].
  void _ensureRateWorker() {
    if (_rateWorkerActive) return;
    _rateWorkerActive = true;
    unawaited(_drainRateRequests());
  }

  Future<void> _drainRateRequests() async {
    // The cleanup below must stay inside this function, directly around the
    // loop: hoisting the loop into a separate async method would insert an
    // `await` between the loop exiting and the latch being cleared, leaving
    // requests queued during that window stranded.
    try {
      while (!_rateCoordinatorDisposed) {
        final request = _pendingRateRequest;
        if (request == null) break;
        _pendingRateRequest = null;
        final requestId = request.requestId;
        final player = _videoPlayerController;
        if (player == null || _playerCount == 0) {
          if (request.sessionId != null &&
              request.sessionId == _longPressGeneration) {
            _clearLongPressSession();
          }
          _completeRateRequest(request);
          continue;
        }

        try {
          final currentRate = player.state.rate;
          if ((currentRate - request.speed).abs() >= 0.0001) {
            _traceLongPressRate(
              'setRateStart',
              requestId: requestId,
              target: request.speed,
              source: request.source,
              sessionId: request.sessionId,
            );
            await player.setRate(request.speed);
            _traceLongPressRate(
              'setRateDone',
              requestId: requestId,
              target: request.speed,
              source: request.source,
              sessionId: request.sessionId,
            );
          }

          // 以 mpv 回读值为准；读不到时退回 state.rate 并保持原有宽容行为。
          final nativeRate = _readNativePlaybackRate(player);
          final actualRate = nativeRate ?? (player.state.rate > 0
              ? player.state.rate
              : request.speed);
          _traceLongPressRate(
            'state.rate',
            requestId: requestId,
            target: actualRate,
            source: request.source,
            sessionId: request.sessionId,
          );

          // mpv 回读明确否定了本次请求：属性写入被拒绝，state.rate 是乐观值。
          // 此时必须走失败分支，否则 UI 与弹幕会按一个并未生效的倍速运行。
          if (nativeRate != null &&
              (nativeRate - request.speed).abs() >= 0.0001) {
            throw StateError(
              'mpv rejected rate ${request.speed}, actual $nativeRate',
            );
          }

          _commitPlaybackRate(
            actualRate,
            updateNormalSpeed: request.updateNormalSpeed,
          );
          if (request.source == 'longPressRestoreAfterError' &&
              request.sessionId == _longPressGeneration) {
            _longPressTraceSession = null;
            _traceLongPressRate(
              'restoreDone',
              requestId: requestId,
              target: actualRate,
              source: request.source,
              sessionId: request.sessionId,
            );
          }
        } catch (error, stackTrace) {
          if (kDebugMode) {
            debugPrint('playback rate change failed: $error\n$stackTrace');
          }
          _traceLongPressRate(
            'setRateError',
            requestId: requestId,
            target: request.speed,
            source: request.source,
            sessionId: request.sessionId,
          );
          if (request.updateNormalSpeed &&
              _normalPlaybackSpeed == request.speed) {
            _normalPlaybackSpeed = _appliedPlaybackSpeed;
          }
          if (request.sessionId != null &&
              request.sessionId == _longPressGeneration) {
            final restoreSpeed = _longPressBaseSpeed;
            final restoreSession = ++_longPressGeneration;
            _clearLongPressSession();
            _longPressTraceSession = restoreSession;
            if (restoreSpeed != null) {
              unawaited(
                _requestPlaybackRate(
                  restoreSpeed,
                  updateNormalSpeed: false,
                  source: 'longPressRestoreAfterError',
                  sessionId: restoreSession,
                ),
              );
            } else {
              _longPressTraceSession = null;
            }
          }
        } finally {
          _completeRateRequest(request);
        }
      }
    } finally {
      // Cleared unconditionally so an unexpected throw can never wedge the
      // latch and silently disable every later playback-rate change.
      _rateWorkerActive = false;
    }
  }

  /// 读回 mpv 实际生效的倍速，无法确认时返回 null。
  ///
  /// 为什么不能信 [Player.state]`.rate`：fork 的 `setRate` 先写 `state.rate`
  /// 再提交 mpv 属性，而 `_setPropertyDouble` 的失败只经 `_logError` 记一条日志、
  /// 不抛异常（real.dart 的 `_setProperty` → `completer.future.then(_logError)`）。
  /// 因此 mpv 拒绝该速度时 await 仍正常返回，`state.rate` 是乐观写入，不能作为
  /// 原生成功的证据。观测列表里也没有 `speed`，事件流不会纠正它。
  ///
  /// 仅在 `pitch` 关闭时可用：开启后实际速度由 `af=scaletempo` 决定，`speed`
  /// 属性不再是真实倍速，此时返回 null 让调用方沿用旧逻辑。
  double? _readNativePlaybackRate(NativePlayer player) {
    if (player.configuration.pitch) return null;
    try {
      final raw = player.getProperty('speed');
      if (raw.isEmpty) return null;
      final value = double.tryParse(raw);
      if (value == null || !value.isFinite || value <= 0) return null;
      return value;
    } catch (_) {
      return null;
    }
  }

  void _completeRateRequest(_RateRequest request) {
    if (!request.completer.isCompleted) {
      request.completer.complete();
    }
  }

  void _commitPlaybackRate(
    double speed, {
    required bool updateNormalSpeed,
  }) {
    final previousSpeed = _appliedPlaybackSpeed;
    _appliedPlaybackSpeed = speed;
    _playbackSpeed.value = speed;
    if (updateNormalSpeed) {
      _normalPlaybackSpeed = speed;
      // 缓冲目标按倍速缩放，常规倍速变了就必须重算，否则下一个媒体源仍会用
      // 旧倍速算出的 cache-secs（例如一直按 1x 的 30 秒目标跑 3x）。
      _refreshBufferForSpeed(speed);
    }
    if (danmakuController != null && previousSpeed != speed) {
      try {
        // 用绝对式而非复合比率：DanmakuOptions.get 也按 danmakuDuration / speed
        // 计算，复合式在一次"失败→恢复"后会累积漂移。
        danmakuController!.updateOption(
          danmakuController!.option.copyWith(
            duration: DanmakuOptions.danmakuDuration / speed,
            staticDuration: DanmakuOptions.danmakuStaticDuration / speed,
          ),
        );
      } catch (_) {}
    }
    // 上游在每次改倍速后都会发布媒体会话状态；本地协调器此前漏了这一步，
    // 会让媒体通知里的 speed 一直滞留旧值。
    _updatePlaybackState();
  }

  /// 按新的常规倍速重算缓冲参数，并尽力推给当前媒体源。
  ///
  /// 推属性只影响正在播放的媒体源；下次 [setDataSource] 会直接用新 map 建源，
  /// 两条路径合起来才能保证「改倍速」和「切集」后目标一致。mpv 的 `cache-secs`
  /// 是 demuxer 选项，部分后端只在下一次 `open` 时读取，因此推送失败不算错误。
  void _refreshBufferForSpeed(double speed) {
    final rebuilt = Pref.initBuffer(speed);
    buffer = rebuilt;
    final player = _videoPlayerController;
    if (player == null || isLive) return;
    for (final entry in rebuilt.entries) {
      try {
        player.setProperty(entry.key, entry.value);
      } catch (_) {}
    }
  }

  void _traceLongPressRate(
    String event, {
    int? requestId,
    double? target,
    double? bufferSeconds,
    String? source,
    int? sessionId,
  }) {
    if (!kDebugMode || !Platform.isAndroid) return;
    final details = <String>[
      't=${_rateTraceClock.elapsedMilliseconds}ms',
      'event=$event',
      if (requestId != null) 'request=$requestId',
      if (sessionId != null) 'session=$sessionId',
      if (target != null) 'target=${target.toStringAsFixed(2)}',
      if (bufferSeconds != null) 'buffer=${bufferSeconds.toStringAsFixed(2)}s',
      if (source != null) 'source=$source',
    ].join(' ');
    debugPrint('[LongPressRate] $details');
  }

  void traceLongPressPointerDown() {
    _traceLongPressRate('pointerDown');
  }

  /// 播放视频
  Future<void> play({bool repeat = false, bool hideControls = true}) async {
    if (_playerCount == 0) return;
    // 播放时自动隐藏控制条
    controls = !hideControls;
    // repeat为true，将从头播放
    if (repeat) {
      await seekTo(Duration.zero, isSeek: false);
    }

    final focusGranted = await audioSessionHandler?.setActive(true) ?? true;
    if (!focusGranted) {
      playerStatus = .paused;
      return;
    }

    audioSessionHandler?.cancelInterruptionResume();
    _playIntent = true;
    try {
      await _videoPlayerController?.play();
    } catch (_) {
      await audioSessionHandler?.setActive(false);
      rethrow;
    }

    playerStatus = .playing;
  }

  /// 暂停播放
  Future<void> pause({bool notify = true, bool isInterrupt = false}) async {
    if (!isInterrupt) {
      audioSessionHandler?.cancelInterruptionResume();
    }
    await _videoPlayerController?.pause();
    if (!isInterrupt) _playIntent = false;
    playerStatus = .paused;

    // 主动暂停时让出音频焦点
    if (!isInterrupt) {
      await audioSessionHandler?.setActive(false);
    }
  }

  bool tripling = false;

  /// 隐藏控制条
  void hideTaskControls() {
    _timer?.cancel();
    _timer = Timer(showControlDuration, () {
      if (!isSeeking.value && !tripling) {
        controls = false;
      }
      _timer = null;
    });
  }

  void onSeekStart(int seekFrom) {
    seekPosition.value = seekFrom;
    isSeeking.value = true;
  }

  void onSeekEnd() {
    if (showSeekPreview) {
      showPreview.value = false;
    }
    hasToasted = false;
    isSeeking.value = false;
    hideTaskControls();
  }

  final RxBool volumeIndicator = false.obs;
  Timer? volumeTimer;
  bool volumeInterceptEventStream = false;

  final double maxVolume = PlatformUtils.isDesktop ? Pref.maxVolume : 1.0;
  Future<void> setVolume(double volume, {bool showIndicator = true}) async {
    if (this.volume.value != volume) {
      this.volume.value = volume;
      try {
        if (PlatformUtils.isDesktop) {
          await _videoPlayerController!.setVolume(volume * 100);
        } else {
          FlutterVolumeController.updateShowSystemUI(false);
          await FlutterVolumeController.setVolume(volume);
        }
      } catch (err) {
        if (kDebugMode) debugPrint(err.toString());
      }
    }
    if (showIndicator) {
      volumeIndicator.value = true;
    }
    volumeInterceptEventStream = true;
    volumeTimer?.cancel();
    volumeTimer = Timer(const Duration(milliseconds: 200), () {
      volumeIndicator.value = false;
      volumeInterceptEventStream = false;
      if (PlatformUtils.isDesktop) {
        setting.put(SettingBoxKey.desktopVolume, volume.toPrecision(3));
      }
    });
  }

  /// Toggle Change the videofit accordingly
  void toggleVideoFit(VideoFitType value) {
    _prefFit = videoFit.value = value;
    video.put(VideoBoxKey.cacheVideoFit, value.index);
  }

  /// 读取fit
  var _prefFit = VideoFitType.values[Pref.cacheVideoFit];
  void _initVideoFit() {
    if (_prefFit == .fill && _isVertical) {
      videoFit.value = .contain;
    } else {
      videoFit.value = _prefFit;
    }
  }

  /// 设置后台播放
  void setBackgroundPlay(bool val) {
    videoPlayerServiceHandler?.enableBackgroundPlay = val;
    if (!tempPlayerConf) {
      setting.put(SettingBoxKey.enableBackgroundPlay, val);
    }
  }

  set controls(bool visible) {
    showControls.value = visible;
    _timer?.cancel();
    if (visible) {
      hideTaskControls();
    }
  }

  Timer? longPressTimer;
  void cancelLongPressTimer() {
    longPressTimer?.cancel();
    longPressTimer = null;
  }

  /// 音量键连发计时器。与 [longPressTimer]（长按 → 加速）分开持有：
  /// 两者是不同的按键手势，共用一个字段会导致按住音量键时 → 被静默取消。
  Timer? volumeKeyRepeatTimer;
  void cancelVolumeKeyRepeatTimer() {
    volumeKeyRepeatTimer?.cancel();
    volumeKeyRepeatTimer = null;
  }

  /// 取消全部按键手势计时器，用于媒体源切换与销毁。
  void cancelKeyGestureTimers() {
    cancelLongPressTimer();
    cancelVolumeKeyRepeatTimer();
  }

  /// 设置长按倍速状态 live模式下禁用
  Future<void> setLongPressStatus(bool val) async {
    if (isLive) {
      return;
    }
    // controlsLock 只阻止长按「开始」。会话一旦建立就必须能结束，否则锁屏
    // 恰好发生在长按期间会把提升后的倍速永久留在播放器上。
    if (val && controlsLock.value) {
      return;
    }
    if (longPressStatus.value == val) {
      return;
    }
    if (val) {
      if (!playerStatus.isPlaying) return;

      final sessionId = ++_longPressGeneration;
      final baseSpeed = _normalPlaybackSpeed;
      final targetSpeed = _resolveLongPressTargetSpeed();
      _longPressBaseSpeed = baseSpeed;
      // Published before longPressStatus flips so the toast and the requested
      // rate are derived from one and the same value.
      _longPressTargetSpeed = targetSpeed;
      _longPressSessionActive = true;
      _longPressTraceSession = sessionId;
      longPressStatus.value = true;
      HapticFeedback.lightImpact();
      _traceLongPressRate(
        'longPressStart',
        target: targetSpeed,
        source: 'longPress',
        sessionId: sessionId,
      );
      await _requestPlaybackRate(
        targetSpeed,
        updateNormalSpeed: false,
        source: 'longPress',
        sessionId: sessionId,
      );
    } else {
      if (!_longPressSessionActive && !longPressStatus.value) return;

      final sessionId = ++_longPressGeneration;
      final restoreSpeed = _longPressBaseSpeed ?? _normalPlaybackSpeed;
      _longPressSessionActive = false;
      longPressStatus.value = val;
      _traceLongPressRate(
        'longPressEnd',
        target: restoreSpeed,
        source: 'longPressRestore',
        sessionId: sessionId,
      );
      await _requestPlaybackRate(
        restoreSpeed,
        updateNormalSpeed: false,
        source: 'longPressRestore',
        sessionId: sessionId,
      );
      if (sessionId == _longPressGeneration) {
        _longPressBaseSpeed = null;
        _longPressTargetSpeed = null;
        _longPressTraceSession = null;
        _traceLongPressRate(
          'restoreDone',
          target: restoreSpeed,
          source: 'longPressRestore',
          sessionId: sessionId,
        );
      }
    }
  }

  bool get isCompleted =>
      videoPlayerController!.state.completed ||
      durationInMilliseconds - positionInMilliseconds <= 50;

  // 双击播放、暂停
  Future<void> onDoubleTapCenter() async {
    if (!isLive && isCompleted) {
      await videoPlayerController!.seek(Duration.zero);
      videoPlayerController!.play();
    } else {
      videoPlayerController!.playOrPause();
    }
  }

  final RxBool mountSeekBackwardButton = false.obs;
  final RxBool mountSeekForwardButton = false.obs;

  void onDoubleTapSeekBackward() {
    mountSeekBackwardButton.value = true;
  }

  void onDoubleTapSeekForward() {
    mountSeekForwardButton.value = true;
  }

  void onForward(Duration duration) {
    onForwardBackward(videoPlayerController!.state.position + duration);
  }

  void onBackward(Duration duration) {
    onForwardBackward(videoPlayerController!.state.position - duration);
  }

  void onForwardBackward(Duration duration) {
    seekTo(
      duration.clamp(Duration.zero, videoPlayerController!.state.duration),
      isSeek: false,
    ).whenComplete(play);
  }

  void doubleTapFuc(DoubleTapType type) {
    if (!enableQuickDouble) {
      onDoubleTapCenter();
      return;
    }
    switch (type) {
      case DoubleTapType.left:
        // 双击左边区域 👈
        onDoubleTapSeekBackward();
        break;
      case DoubleTapType.center:
        onDoubleTapCenter();
        break;
      case DoubleTapType.right:
        // 双击右边区域 👈
        onDoubleTapSeekForward();
        break;
    }
  }

  /// 关闭控制栏
  void onLockControl(bool val) {
    feedBack();
    controlsLock.value = val;
    if (!val && showControls.value) {
      showControls.refresh();
    }
    controls = !val;
  }

  void _setFullScreen(bool val) {
    isFullScreen.value = val;
    updateSubtitleStyle();
  }

  double screenRatio = 0.0;
  bool isManualFS = true;
  late final FullScreenMode mode = Pref.fullScreenMode;
  late final horizontalScreen = Pref.horizontalScreen;
  late final removeSafeArea = Pref.removeSafeArea;

  Future<void>? changeOrientation({
    required bool isVertical,
    DeviceOrientation? orientation,
  }) {
    if (orientation == null && (mode == .none || mode == .gravity)) {
      return null;
    }
    if (orientation == null &&
        (mode == .vertical ||
            (mode == .auto && isVertical) ||
            (mode == .ratio && (isVertical || screenRatio < kScreenRatio)))) {
      return portraitUpMode();
    } else {
      // https://github.com/flutter/flutter/issues/73651
      // https://github.com/flutter/flutter/issues/183708
      if (Platform.isAndroid) {
        if ((orientation ?? _orientation) == .landscapeRight) {
          return landscapeRightMode();
        } else {
          return landscapeLeftMode();
        }
      } else {
        if (orientation == .landscapeLeft) {
          return landscapeLeftMode();
        } else {
          return landscapeRightMode();
        }
      }
    }
  }

  // 全屏
  bool _fsProcessing = false;
  Future<void> triggerFullScreen({
    bool status = true,
    bool inAppFullScreen = false,
    DeviceOrientation? orientation,
    bool isManualFS = true,
  }) async {
    if (isDesktopPip) return;
    if (isFullScreen.value == status) return;

    if (_fsProcessing) return;
    _fsProcessing = true;
    this.isManualFS = isManualFS;
    try {
      if (status) {
        if (PlatformUtils.isMobile) {
          hideSystemBar();
          await changeOrientation(
            isVertical: isVertical,
            orientation: orientation,
          );
        } else {
          await enterDesktopFullScreen(inAppFullScreen: inAppFullScreen);
        }
      } else {
        if (PlatformUtils.isMobile) {
          if (!removeSafeArea) {
            showSystemBar();
          }
          if (orientation == null && mode == .none) {
            return;
          }
          await resetScreenRotation();
        } else {
          await exitDesktopFullScreen();
        }
      }
    } finally {
      _setFullScreen(status);
      _fsProcessing = false;
    }
  }

  void addPositionListener(ValueChanged<Duration> listener) {
    if (_playerCount == 0) return;
    _positionListeners.add(listener);
  }

  void removePositionListener(ValueChanged<Duration> listener) =>
      _positionListeners.remove(listener);

  void addStatusLister(ValueChanged<PlayerStatus> listener) {
    if (_playerCount == 0) return;
    _statusListeners.add(listener);
  }

  void removeStatusLister(ValueChanged<PlayerStatus> listener) =>
      _statusListeners.remove(listener);

  // 记录播放记录
  Future<void>? makeHeartBeat(
    int progress, {
    HeartBeatType type = .playing,
    bool isManual = false,
    dynamic aid,
    dynamic bvid,
    dynamic cid,
    dynamic epid,
    dynamic seasonId,
    dynamic pgcType,
    VideoType? videoType,
  }) {
    if (isLive ||
        !enableHeart ||
        progress == 0 ||
        (playerStatus.isPaused && !isManual)) {
      return null;
    }

    Future<void> send() {
      return VideoHttp.heartBeat(
        aid: aid ?? _aid,
        bvid: bvid ?? _bvid,
        cid: cid ?? this.cid,
        progress: progress,
        epid: epid ?? _epid,
        seasonId: seasonId ?? _seasonId,
        subType: pgcType ?? _pgcType,
        videoType: videoType ?? _videoType,
      );
    }

    switch (type) {
      case .playing:
        if (progress - _heartDuration >= 5) {
          _heartDuration = progress;
          return send();
        }
      case .status:
        if (progress - _heartDuration >= 2) {
          _heartDuration = progress;
          return send();
        }
      case .completed:
        if (playerStatus.isCompleted &&
            (durationInMilliseconds - positionInMilliseconds) <= 1000) {
          progress = -1;
        }
        return send();
    }
    return null;
  }

  void setPlayRepeat(PlayRepeat type) {
    playRepeat = type;
    if (!tempPlayerConf) video.put(VideoBoxKey.playRepeat, type.index);
  }

  void putSubtitleSettings() {
    setting.putAllNE({
      SettingBoxKey.subtitleFontScale: subtitleFontScale,
      SettingBoxKey.subtitleFontScaleFS: subtitleFontScaleFS,
      SettingBoxKey.subtitlePaddingH: subtitlePaddingH,
      SettingBoxKey.subtitlePaddingB: subtitlePaddingB,
      SettingBoxKey.subtitleBgOpacity: subtitleBgOpacity,
      SettingBoxKey.subtitleStrokeWidth: subtitleStrokeWidth,
      SettingBoxKey.subtitleFontWeight: subtitleFontWeight,
    });
  }

  bool _isCloseAll = false;
  bool get isCloseAll => _isCloseAll;

  Future<void>? resetScreenRotation() {
    if (horizontalScreen) {
      return fullMode();
    } else {
      return portraitUpMode();
    }
  }

  void onCloseAll() {
    _isCloseAll = true;
    if (PlatformUtils.isDesktop) exitDesktopFullScreen();
    dispose();
    Get.until((route) => route.isFirst);
  }

  void dispose() {
    // 每次减1，最后销毁
    resetScreenRotation();
    cancelKeyGestureTimers();
    _cancelSubForSeek();
    if (!_isCloseAll && _playerCount > 1) {
      _playerCount -= 1;
      _heartDuration = 0;
      return;
    }

    _rateCoordinatorDisposed = true;
    _longPressGeneration++;
    _clearLongPressSession();
    final pendingRateRequest = _pendingRateRequest;
    _pendingRateRequest = null;
    if (pendingRateRequest != null) {
      _completeRateRequest(pendingRateRequest);
    }

    _playerCount = 0;
    _playIntent = false;
    _streamRecoveryGeneration++;
    if (removeSafeArea) {
      showSystemBar();
    }
    danmakuController = null;
    _stopOrientationListener();
    _disableAutoEnterPip();
    setPlayCallBack(null);
    // 与 setPlayCallBack 并列：播放器真正被拆毁时才清回调，
    // 避免持有已关闭的页面 controller（上面 _playerCount > 1 的提前返回
    // 意味着其它页面仍在复用本实例，此时不能清）
    onMediaSourceExpired = null;
    dmState.clear();
    if (showSeekPreview) {
      _clearPreview();
    }
    if (Platform.isAndroid) {
      AndroidHelper$ToDart.onUserLeaveHint?.release();
      AndroidHelper$ToDart.onUserLeaveHint = null;
    } else if (Platform.isIOS) {
      IOSPipHelper.dispose();
    }
    _timer?.cancel();
    // _position.close();
    // _playerEventSubs?.cancel();
    // _sliderPosition.close();
    // _sliderTempPosition.close();
    // _isSliderMoving.close();
    // _duration.close();
    // _buffered.close();
    // _showControls.close();
    // _controlsLock.close();

    // playerStatus.close();
    // dataStatus.close();

    if (PlatformUtils.isDesktop && isAlwaysOnTop.value) {
      windowManager.setAlwaysOnTop(false);
    }

    _removeListeners();
    _positionListeners.clear();
    _statusListeners.clear();
    audioSessionHandler?.cancelInterruptionResume();
    audioSessionHandler?.setActive(false);
    // 无条件释放：本地此前的 if (playerStatus.isPlaying) 守卫会让
    // "已播完但仍在持有唤醒锁"的播放器继续占用唤醒锁。
    _stopWakeLockTimer();
    WakelockPlus.disable();
    if (kDebugMode) {
      debugPrint('dispose player');
    }
    _videoPlayerController?.dispose();
    _videoPlayerController = null;
    _videoController = null;
    _instance = null;
    videoPlayerServiceHandler?.clear();
  }

  static void updatePlayCount() {
    if (_instance?._playerCount == 1) {
      _instance?.dispose();
    } else {
      _instance?._playerCount -= 1;
    }
  }

  /// 释放一条不再使用的引用计数，但绝不在只剩最后一条引用时销毁播放器。
  /// 用于小窗恢复等"新对象只借用同一实例"的场景：此时计数里多出来的那条
  /// 来自被丢弃的对象，而播放器本身仍要被恢复页继续使用。
  static void releaseExtraPlayerCount() {
    final instance = _instance;
    if (instance != null && instance._playerCount > 1) {
      instance._playerCount -= 1;
    }
  }

  void setContinuePlayInBackground() {
    continuePlayInBackground.toggle();
    if (!tempPlayerConf) {
      setting.put(
        SettingBoxKey.continuePlayInBackground,
        continuePlayInBackground.value,
      );
    }
  }

  late final Map<String, ui.Image?> previewCache = {};
  LoadingState<VideoShotData>? videoShot;
  late final RxBool showPreview = false.obs;
  late final showSeekPreview = Pref.showSeekPreview;
  late final previewIndex = RxnInt();

  void updatePreviewIndex(int seconds) {
    if (videoShot == null) {
      videoShot = LoadingState.loading();
      getVideoShot();
      return;
    }
    if (videoShot case Success(:final response)) {
      showPreview.value = true;
      previewIndex.value = max(
        0,
        (response.index.where((item) => item <= seconds).length - 2),
      );
    }
  }

  void _clearPreview() {
    showPreview.value = false;
    previewIndex.value = null;
    videoShot = null;
    for (final i in previewCache.values) {
      i?.dispose();
    }
    previewCache.clear();
  }

  Future<void> getVideoShot() async {
    videoShot = await VideoHttp.videoshot(bvid: bvid, cid: cid!);
  }

  Future<void> takeScreenshot() async {
    SmartDialog.showToast('截图中');
    final image = await videoPlayerController?.screenshot();
    if (image == null) {
      SmartDialog.showToast('截图失败');
      return;
    }

    var saved = false;
    Future<void> save() async {
      if (saved) return;
      saved = true;
      Get.back(result: false);
      final bytes = await image.toByteData(format: .png);
      image.dispose();
      if (bytes != null) {
        final time = DurationUtils.formatDuration(
          positionInMilliseconds / 1000,
        ).replaceAll(':', '-');
        ImageUtils.saveByteImg(
          bytes: bytes.buffer.asUint8List(),
          fileName: 'screenshot_${cid}_$time',
        );
      } else {
        SmartDialog.showToast('保存失败');
      }
    }

    SmartDialog.showToast('点击弹窗或按 Enter 保存截图');
    final dispose = await showDialog<bool>(
      context: Get.context!,
      builder: (context) => Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
            save();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: GestureDetector(
          onTap: save,
          child: Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: min(MediaQuery.widthOf(context) / 3, 350),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      width: 5,
                      color: ColorScheme.of(context).surface,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: RawImage(image: image),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (dispose ?? true) image.dispose();
  }

  void onPopInvokedWithResult(
    bool didPop,
    Object? result, {

    /// 正在进入应用内小窗时传 false：退出页面不应暂停播放
    bool pauseOnPop = true,
  }) {
    if (didPop) {
      if (pauseOnPop && playerStatus.isPlaying) {
        pause();
      }

      setPlayCallBack(null);

      if (Platform.isAndroid && _playerCount <= 1) {
        _disableAutoEnterPip();
        if (!setSystemBrightness) {
          ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
        }
      }

      return;
    }

    if (controlsLock.value) {
      onLockControl(false);
      return;
    }
    if (isDesktopPip) {
      exitDesktopPip();
      return;
    }
    if (isFullScreen.value) {
      triggerFullScreen(status: false);
      return;
    }
    Get.back();
  }
}
