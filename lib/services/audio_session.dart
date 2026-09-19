import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:audio_session/audio_session.dart';

class AudioSessionHandler {
  late final AudioSession _session;
  late final Future<void> _ready;
  bool _playInterrupted = false;
  bool _isDucked = false;
  double? _volumeBeforeDuck;
  PlPlayerController? _duckedPlayer;
  PlPlayerController? _interruptedPlayer;

  Future<bool> setActive(bool active) async {
    await _ready;
    if (!active) _restoreDuckedVolume();
    return _session.setActive(active);
  }

  AudioSessionHandler() {
    _ready = _initSession();
  }

  Future<void> _initSession() async {
    _session = await AudioSession.instance;
    await _session.configure(const AudioSessionConfiguration.music());

    _session.interruptionEventStream.listen((event) {
      final player = PlPlayerController.instance;
      final playerStatus = player?.playerStatus.value;
      if (event.begin) {
        if (player == null || playerStatus != PlayerStatus.playing) return;
        switch (event.type) {
          case AudioInterruptionType.duck:
            if (!_isDucked) {
              final volume = PlPlayerController.getVolumeIfExists();
              if (volume != null) {
                _volumeBeforeDuck = volume;
                _duckedPlayer = player;
                _isDucked = true;
                PlPlayerController.setVolumeIfExists(
                  volume * 0.5,
                  showIndicator: false,
                );
              }
            }
            break;
          case AudioInterruptionType.pause:
            PlPlayerController.pauseIfExists(isInterrupt: true);
            _playInterrupted = true;
            _interruptedPlayer = player;
            break;
          case AudioInterruptionType.unknown:
            PlPlayerController.pauseIfExists(isInterrupt: true);
            // Unknown interruptions (including permanent focus loss) must not
            // be resumed automatically when the platform later reports gain.
            _playInterrupted = false;
            _interruptedPlayer = null;
            break;
        }
      } else {
        switch (event.type) {
          case AudioInterruptionType.duck:
            // Preserve a manual volume change made while ducked.
            _restoreDuckedVolume();
            break;
          case AudioInterruptionType.pause:
            final shouldResume =
                _playInterrupted &&
                identical(_interruptedPlayer, PlPlayerController.instance) &&
                PlPlayerController.getPlayerStatusIfExists() ==
                    PlayerStatus.paused;
            _playInterrupted = false;
            _interruptedPlayer = null;
            if (shouldResume) PlPlayerController.playIfExists();
            break;
          case AudioInterruptionType.unknown:
            _playInterrupted = false;
            _interruptedPlayer = null;
            break;
        }
      }
    });

    // 耳机拔出暂停
    _session.becomingNoisyEventStream.listen((_) {
      PlPlayerController.pauseIfExists();
    });
  }

  /// Prevents a focus interruption from resuming playback after a user pause.
  void cancelInterruptionResume() {
    _playInterrupted = false;
    _interruptedPlayer = null;
  }

  void _restoreDuckedVolume() {
    if (!_isDucked) return;
    final volumeBeforeDuck = _volumeBeforeDuck;
    final samePlayer = identical(_duckedPlayer, PlPlayerController.instance);
    final currentVolume = samePlayer
        ? PlPlayerController.getVolumeIfExists()
        : null;
    if (currentVolume != null && volumeBeforeDuck != null) {
      final duckedVolume = volumeBeforeDuck * 0.5;
      if ((currentVolume - duckedVolume).abs() < 0.01) {
        PlPlayerController.setVolumeIfExists(
          volumeBeforeDuck,
          showIndicator: false,
        );
      }
    }
    _isDucked = false;
    _volumeBeforeDuck = null;
    _duckedPlayer = null;
  }
}
