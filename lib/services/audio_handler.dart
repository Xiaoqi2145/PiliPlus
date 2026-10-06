import 'dart:async';
import 'dart:io' show File, Platform;
import 'dart:ui' show PlatformDispatcher;

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/grpc/bilibili/app/listener/v1.pb.dart' show DetailItem;
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/live/live_room_info_h5/data.dart';
import 'package:PiliPlus/models_new/pgc/pgc_info_model/episode.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/pages/common/common_intro_controller.dart';
import 'package:PiliPlus/pages/video/introduction/local/controller.dart';
import 'package:PiliPlus/pages/video/introduction/pgc/controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/controller.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:audio_service/audio_service.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:get/get_core/src/get_main.dart';
import 'package:get/get_instance/src/extension_instance.dart';
import 'package:path/path.dart' as path;

Future<VideoPlayerServiceHandler> initAudioService() {
  return AudioService.init(
    builder: VideoPlayerServiceHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.example.piliplus.audio',
      androidNotificationChannelName: 'Audio Service ${Constants.appName}',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      fastForwardInterval: Duration(seconds: 10),
      rewindInterval: Duration(seconds: 10),
      androidNotificationChannelDescription: 'Media notification channel',
      androidNotificationIcon: 'drawable/ic_notification_icon',
    ),
  );
}

typedef _StatusConfig = (
  PlayerStatus status,
  bool isBuffering,
  bool isLive,
  double speed,
  bool isTransitioning,
);

class VideoPlayerServiceHandler extends BaseAudioHandler with SeekHandler {
  static final List<MediaItem> _item = [];
  bool enableBackgroundPlay = Pref.enableBackgroundPlay;

  Future<void>? Function()? onPlay;
  Future<void>? Function()? onPause;
  Future<void>? Function(Duration position)? onSeek;
  Future<void>? Function()? onSkipToNext;
  Future<void>? Function()? onSkipToPrevious;

  bool _isTransitioning = false;
  Timer? _pauseTimer;
  Timer? _transitionTimer;
  int _transitionGeneration = 0;

  @override
  Future<void> play() {
    return onPlay?.call() ??
        PlPlayerController.playIfExists() ??
        Future.syncValue(null);
  }

  @override
  Future<void> pause() {
    return onPause?.call() ??
        PlPlayerController.pauseIfExists() ??
        Future.syncValue(null);
  }

  CommonIntroController? _findIntroController() {
    final playOwner = PlPlayerController.playOwner;
    if (playOwner != null) {
      final tag = playOwner.tag;
      try {
        return switch (playOwner.type) {
          UgcIntroController => Get.find<UgcIntroController>(tag: tag),
          PgcIntroController => Get.find<PgcIntroController>(tag: tag),
          LocalIntroController => Get.find<LocalIntroController>(tag: tag),
          _ => throw UnimplementedError(playOwner.type.toString()),
        };
      } catch (_) {
        if (kDebugMode) rethrow;
      }
    }
    return null;
  }

  @override
  Future<void> seek(Duration position) {
    return onSeek?.call(position) ??
        PlPlayerController.seekToIfExists(position, isSeek: false) ??
        Future.syncValue(null);
  }

  // BaseAudioHandler implements these as no-ops, so without these overrides a
  // headset/notification "next"/"previous" is silently swallowed.
  //
  // 三级串联：页面回调（音频页显式返回非 null Future，避免穿透到栈下方
  // 视频页）→ 静态兜底（视频页注册的 skip 回调）→ 上游的 playOwner 解析。
  @override
  Future<void> skipToNext() => _skip(toNext: true);

  @override
  Future<void> skipToPrevious() => _skip(toNext: false);

  Future<void> _skip({required bool toNext}) {
    final callback = toNext
        ? (onSkipToNext?.call() ?? PlPlayerController.skipToNextIfExists())
        : (onSkipToPrevious?.call() ??
              PlPlayerController.skipToPreviousIfExists());
    if (callback != null) return callback;
    final intro = _findIntroController();
    if (intro != null) {
      if (toNext) {
        intro.nextPlay();
      } else {
        intro.prevPlay();
      }
    }
    return Future<void>.value();
  }

  void setMediaItem(MediaItem newMediaItem) {
    if (!enableBackgroundPlay) return;
    // if (kDebugMode) {
    //   debugPrint("此时调用栈为：");
    //   debugPrint(newMediaItem);
    //   debugPrint(newMediaItem.title);
    //   debugPrint(StackTrace.current.toString());
    // }
    if (!mediaItem.isClosed) mediaItem.add(newMediaItem);
  }

  Duration? _lastPos;
  _StatusConfig? _lastConfig;
  void onUpdateState(
    PlayerStatus status,
    bool isBuffering,
    bool isLive, {
    required Duration position,
    required double speed,
    String? debugLabel,
  }) {
    if (!enableBackgroundPlay || _item.isEmpty) {
      return;
    }

    if (onPlay != null && debugLabel == 'onVideoPaused') return;

    // A media_kit playing=false can arrive just before completed. Delay the
    // paused publication so an automatic item transition can keep the
    // foreground service alive.
    if (!status.isPlaying && !isBuffering && !_isTransitioning) {
      _pauseTimer?.cancel();
      _pauseTimer = Timer(const Duration(milliseconds: 450), () {
        if (!_isTransitioning) {
          _publishState(
            status,
            false,
            isLive,
            position: position,
            speed: speed,
          );
        }
      });
      return;
    }
    _pauseTimer?.cancel();
    _publishState(
      status,
      isBuffering,
      isLive,
      position: position,
      speed: speed,
    );
  }

  void _publishState(
    PlayerStatus status,
    bool isBuffering,
    bool isLive, {
    required Duration position,
    required double speed,
  }) {
    if (!enableBackgroundPlay || _item.isEmpty) return;

    // `_isTransitioning` is part of the dedup key: otherwise a transition
    // flipping on/off with unchanged playback status would be swallowed and
    // the foreground service would never be kept alive.
    final newConfig = (status, isBuffering, isLive, speed, _isTransitioning);
    if (_lastConfig == newConfig) {
      if (_lastPos != null) {
        final pos = position.inSeconds;
        final lastPos = _lastPos!.inSeconds;
        _lastPos = position;
        if (pos == lastPos && pos != 0) return;
      }
    }
    _lastConfig = newConfig;

    final AudioProcessingState processingState;
    final bool playing;
    switch (status) {
      case .completed:
        playing = _isTransitioning;
        processingState = _isTransitioning ? .buffering : .completed;
      case .playing:
        playing = true;
        processingState = (_isTransitioning || isBuffering)
            ? .buffering
            : .ready;
      case .paused:
        playing = _isTransitioning || isBuffering;
        processingState = (_isTransitioning || isBuffering)
            ? .buffering
            : .ready;
    }
    _updateState(
      processingState,
      playing,
      isLive,
      position: position,
      speed: speed,
    );
  }

  void _updateState(
    AudioProcessingState state,
    bool playing,
    bool isLive, {
    required Duration position,
    required double speed,
  }) {
    playbackState.add(
      playbackState.value.copyWith(
        processingState: state,
        updatePosition: position,
        speed: speed,
        controls: [
          if (!isLive) MediaControl.skipToPrevious,
          if (!isLive)
            const MediaControl(
              androidIcon: 'drawable/ic_player_rewind_10s',
              label: 'Rewind',
              action: .rewind,
            ),
          if (playing)
            const MediaControl(
              androidIcon: 'drawable/ic_player_pause',
              label: 'Pause',
              action: .pause,
            )
          else
            const MediaControl(
              androidIcon: 'drawable/ic_player_play',
              label: 'Play',
              action: .play,
            ),
          if (!isLive)
            const MediaControl(
              androidIcon: 'drawable/ic_player_fast_forward_10s',
              label: 'Fast Forward',
              action: .fastForward,
            ),
          if (!isLive) MediaControl.skipToNext,
        ],
        // Keep the pre-existing compact view on API < 33 (rewind/play-pause/
        // fast-forward; live has a single play/pause control). The skip
        // controls stay in the expanded notification. These indices must stay
        // in range of the list above or the notification cannot be built.
        androidCompactActionIndices: isLive ? const [0] : const [1, 2, 3],
        playing: playing,
        systemActions: const {.seek},
      ),
    );
    if (Platform.isAndroid &&
        (AndroidHelper.isPipMode ||
            PlPlayerController.instance?.isAutoEnterPip == true)) {
      AndroidHelper.updatePipActions(
        PlatformDispatcher.instance.engineId!,
        isLive,
        playing,
      );
    }
  }

  /// Keep the notification/foreground service active while the next media
  /// item is being resolved. This is intentionally separate from user pause.
  ///
  /// 过渡期上限是**兜底**而非预期路径：正常恢复会在每次重试时调用
  /// [extendTransition] 续命，只有彻底失去恢复意图时才会真正到点。
  /// 取值需覆盖最坏恢复窗口（playurl 退避重试约 7.5s + 媒体源重开 4 轮约 7.5s），
  /// 并留出余量。
  static const _kTransitionTimeout = Duration(seconds: 45);

  void beginTransition() {
    if (!enableBackgroundPlay || _item.isEmpty) return;
    _pauseTimer?.cancel();
    _isTransitioning = true;
    // 过渡态参与去重键，必须失效上一次缓存，否则状态翻转会被吞掉
    _lastConfig = null;
    _transitionGeneration++;
    _armTransitionTimer(_transitionGeneration);
    playbackState.add(
      playbackState.value.copyWith(
        processingState: AudioProcessingState.buffering,
        playing: true,
      ),
    );
  }

  void _armTransitionTimer(int generation) {
    _transitionTimer?.cancel();
    _transitionTimer = Timer(_kTransitionTimeout, () {
      if (generation == _transitionGeneration && _isTransitioning) {
        endTransition(playing: false);
      }
    });
  }

  /// 重试 / 重取播放地址期间续命，避免把"正在恢复"误判成"已失败"。
  ///
  /// 若不加此机制，弱网下自动连播的地址请求超过上限就会走到
  /// [endTransition](playing: false)，进而退出前台服务并释放
  /// audio_service 的 PARTIAL_WAKE_LOCK，使后台恢复彻底失去保障。
  ///
  /// 仅在过渡态生效；非过渡期调用是 no-op。
  void extendTransition() {
    if (!_isTransitioning || !enableBackgroundPlay) return;
    _armTransitionTimer(_transitionGeneration);
  }

  void endTransition({required bool playing}) {
    if (!_isTransitioning) return;
    _transitionGeneration++;
    _transitionTimer?.cancel();
    _transitionTimer = null;
    _isTransitioning = false;
    // 过渡态离开后同样要让去重键失效
    _lastConfig = null;
    if (!enableBackgroundPlay || _item.isEmpty) return;
    playbackState.add(
      playbackState.value.copyWith(
        processingState: playing
            ? AudioProcessingState.ready
            : AudioProcessingState.idle,
        playing: playing,
      ),
    );
  }

  void onVideoDetailChange(
    dynamic data,
    int cid,
    String herotag, {
    String? artist,
    String? cover,
  }) {
    if (!enableBackgroundPlay) return;
    // if (kDebugMode) {
    //   debugPrint('当前调用栈为：');
    //   debugPrint(StackTrace.current);
    // }
    if (data == null) return;

    Uri getUri(String? cover) => Uri.parse(ImageUtils.safeThumbnailUrl(cover));

    late final id = '$cid$herotag';
    final MediaItem mediaItem;
    switch (data) {
      case VideoDetailData(:final pages):
        if (pages != null && pages.length > 1) {
          final current = pages.firstWhereOrNull((e) => e.cid == cid);
          mediaItem = MediaItem(
            id: id,
            title: current?.part ?? '',
            artist: data.owner?.name,
            duration: Duration(seconds: current?.duration ?? 0),
            artUri: getUri(data.pic),
          );
        } else {
          mediaItem = MediaItem(
            id: id,
            title: data.title ?? '',
            artist: data.owner?.name,
            duration: Duration(seconds: data.duration ?? 0),
            artUri: getUri(data.pic),
          );
        }
      case EpisodeItem():
        mediaItem = MediaItem(
          id: id,
          title: data.showTitle ?? data.longTitle ?? data.title ?? '',
          artist: artist,
          duration: data.from == 'pugv'
              ? Duration(seconds: data.duration ?? 0)
              : Duration(milliseconds: data.duration ?? 0),
          artUri: getUri(data.cover),
        );
      case RoomInfoH5Data():
        mediaItem = MediaItem(
          id: id,
          title: data.roomInfo?.title ?? '',
          artist: data.anchorInfo?.baseInfo?.uname,
          artUri: getUri(data.roomInfo?.cover),
          isLive: true,
        );
      case Part():
        mediaItem = MediaItem(
          id: id,
          title: data.part ?? '',
          artist: artist,
          duration: Duration(seconds: data.duration ?? 0),
          artUri: getUri(cover),
        );
      case DetailItem(:final arc):
        mediaItem = MediaItem(
          id: id,
          title: arc.title,
          artist: data.owner.name,
          duration: Duration(seconds: arc.duration.toInt()),
          artUri: getUri(arc.cover),
        );
      case BiliDownloadEntryInfo():
        final coverFile = File(
          path.join(data.entryDirPath, PathUtils.coverName),
        );
        final uri = coverFile.existsSync()
            ? coverFile.absolute.uri
            : getUri(data.cover);
        mediaItem = MediaItem(
          id: id,
          title: data.showTitle,
          artist: data.ownerName,
          duration: Duration(milliseconds: data.totalTimeMilli),
          artUri: uri,
        );
      default:
        return;
    }
    _item.add(mediaItem);
    setMediaItem(mediaItem);
  }

  void onVideoDetailDispose(String herotag) {
    if (!enableBackgroundPlay) return;

    if (_item.isNotEmpty) {
      _item.removeWhere((item) => item.id.endsWith(herotag));
    }
    if (_item.isNotEmpty) {
      setMediaItem(_item.last);
      playbackState.add(
        playbackState.value.copyWith(processingState: .ready, playing: false),
      );
    }
  }

  void clearIfNeeded() {
    if (!enableBackgroundPlay) return;
    if (_item.isEmpty) clear();
  }

  void clear() {
    if (!enableBackgroundPlay) return;
    _pauseTimer?.cancel();
    _transitionTimer?.cancel();
    _isTransitioning = false;
    mediaItem.add(null);
    _item.clear();
    _lastPos = null;
    _lastConfig = null;
    /**
     * if (playbackState.processingState == AudioProcessingState.idle &&
            previousState?.processingState != AudioProcessingState.idle) {
          await AudioService._stop();
        }
     */
    if (playbackState.value.processingState == .idle) {
      playbackState.add(PlaybackState(processingState: .completed));
    }
    playbackState.add(PlaybackState(processingState: .idle));
  }
}
