import 'dart:io';

import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/wbi_sign.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

/// WBI 签名密钥的获取曾经把"一次失败"永久钉死在进程级静态字段 `_future` 上。
///
/// `_getWbiKeys()` 里的 `Request().get` 在 try **之外**：后台弱网/切网抖动让它
/// 抛异常时，异常会带着同一个失败的 Future 留在 `_future`，此后每个
/// `makSign` 都立刻拿到这个失败结果——**完全不再发起网络请求**。自动连播的
/// playurl 全部被打死，用户看到的就是"播完切集卡住"。
///
/// 修复：每次拉取结束后清空 `_future`，失败可以重取；成功时密钥已落盘，
/// 下次调用走同步命中，不会多发请求。
void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('piliplus-wbi-test-');
    Hive.init(tempDir.path);
    GStorage.regAdapter();
    GStorage.localCache = await Hive.openBox('localCache');
  });

  setUp(() {
    GStorage.localCache.clear();
    WbiSign.debugFetchKeysOverride = null;
  });

  tearDown(() => WbiSign.debugFetchKeysOverride = null);

  tearDownAll(() async {
    await GStorage.localCache.close();
    await tempDir.delete(recursive: true);
  });

  test('拉取失败后可以重取，不会把失败结果永久缓存', () async {
    var calls = 0;
    WbiSign.debugFetchKeysOverride = () {
      calls++;
      return Future<String>.error(const SocketException('network down'));
    };

    // 第一次失败：异常如实抛出
    await expectLater(WbiSign.getWbiKeys(), throwsA(isA<SocketException>()));
    expect(calls, 1);

    // 第二次必须**再次发起拉取**（旧实现会直接复用失败 Future，calls 停在 1）
    await expectLater(WbiSign.getWbiKeys(), throwsA(isA<SocketException>()));
    expect(calls, 2);
  });

  test('失败后恢复网络即可取到密钥', () async {
    var calls = 0;
    WbiSign.debugFetchKeysOverride = () async {
      calls++;
      if (calls == 1) throw const SocketException('network down');
      return 'recovered-mixin-key';
    };

    await expectLater(WbiSign.getWbiKeys(), throwsA(isA<SocketException>()));
    expect(await WbiSign.getWbiKeys(), 'recovered-mixin-key');
  });

  test('成功结果落盘后走同步命中，不再重复拉取', () async {
    var calls = 0;
    WbiSign.debugFetchKeysOverride = () {
      calls++;
      const key = 'stable-mixin-key';
      GStorage.localCache
        ..put(LocalCacheKey.mixinKey, key)
        ..put(
          LocalCacheKey.timeStamp,
          DateTime.now().millisecondsSinceEpoch,
        );
      return Future.value(key);
    };

    expect(await WbiSign.getWbiKeys(), 'stable-mixin-key');
    expect(calls, 1);

    // 已落盘且时间戳是今天：直接同步返回，不再拉取
    expect(await WbiSign.getWbiKeys(), 'stable-mixin-key');
    expect(calls, 1);
  });
}
