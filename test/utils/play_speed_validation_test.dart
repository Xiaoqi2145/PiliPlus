import 'dart:io';

import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

/// 倍速写入曾经只做 `double.parse` + 重复检查，因此 `0` 能被存进倍速列表，
/// 还能被选为「默认倍速」或「默认长按倍速」。
///
/// 播放器侧却拒绝 `speed <= 0`（media_kit 的 `setRate` 直接抛
/// `ArgumentError`），于是长按会先发布会话与提示、再下发一个必然失败的倍速：
/// 用户看到「0.0 倍速中」，实际速度纹丝不动。
///
/// 修复分两层：写入时拒绝，读取时过滤。这里锁住的是读取层——只修写入无法
/// 处理升级前已经落盘的坏数据。
void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('piliplus-speed-test-');
    Hive.init(tempDir.path);
    GStorage.regAdapter();
    GStorage.video = await Hive.openBox('video');
  });

  setUp(() => GStorage.video.clear());

  tearDownAll(() async {
    await GStorage.video.close();
    await tempDir.delete(recursive: true);
  });

  group('Pref.isValidSpeed', () {
    test('拒绝 0、负数、NaN 与无穷', () {
      expect(Pref.isValidSpeed(0), isFalse);
      expect(Pref.isValidSpeed(-1), isFalse);
      expect(Pref.isValidSpeed(-0.5), isFalse);
      expect(Pref.isValidSpeed(double.nan), isFalse);
      expect(Pref.isValidSpeed(double.infinity), isFalse);
      expect(Pref.isValidSpeed(null), isFalse);
    });

    test('接受正常倍速', () {
      expect(Pref.isValidSpeed(0.5), isTrue);
      expect(Pref.isValidSpeed(1.0), isTrue);
      expect(Pref.isValidSpeed(3.0), isTrue);
    });
  });

  group('读取层过滤历史坏数据', () {
    test('倍速列表丢弃 0 与负数，保留其余项', () {
      GStorage.video.put(
        VideoBoxKey.speedsList,
        [0.0, 1.0, -2.0, 2.0, 0.5],
      );

      expect(Pref.speedList, [1.0, 2.0, 0.5]);
    });

    test('倍速列表全为非法值时回退到 1.0，不返回空列表', () {
      // 空列表会让倍速菜单没有任何可选项，比回退更糟。
      GStorage.video.put(VideoBoxKey.speedsList, [0.0, -1.0]);

      expect(Pref.speedList, [1.0]);
    });

    test('默认倍速为 0 时回退到 1.0', () {
      GStorage.video.put(VideoBoxKey.playSpeedDefault, 0.0);

      expect(Pref.playSpeedDefault, 1.0);
    });

    test('默认长按倍速为 0 时回退到 3.0', () {
      GStorage.video.put(VideoBoxKey.longPressSpeedDefault, 0.0);

      expect(Pref.longPressSpeedDefault, 3.0);
    });

    test('合法值原样读取', () {
      GStorage.video
        ..put(VideoBoxKey.speedsList, [1.25, 2.0])
        ..put(VideoBoxKey.playSpeedDefault, 1.25)
        ..put(VideoBoxKey.longPressSpeedDefault, 2.0);

      expect(Pref.speedList, [1.25, 2.0]);
      expect(Pref.playSpeedDefault, 1.25);
      expect(Pref.longPressSpeedDefault, 2.0);
    });
  });
}
