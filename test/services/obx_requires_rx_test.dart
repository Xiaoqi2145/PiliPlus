import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 回归护栏：应用内小窗控制栏曾用 Obx 包裹播放/暂停图标。
///
/// 去 Rx 化后 `PlPlayerController.playerStatus` 变成普通枚举，该 Obx 闭包内
/// 不再有任何 Rx 读取，GetX 会抛 "improper use of a GetX"；release 下子树被
/// 替换成 RenderErrorBox（sizedByParent、100000×100000、近白），在只给 bottom
/// 的 Positioned 里高度无界，渲染成巨幅白块并挤掉两侧按钮。
///
/// 修复方式：改用 `PlPlayerController.addStatusLister` + setState，不再依赖 Obx。
/// 这里锁住"Obx 必须读到 Rx"这一前提，避免有人再把普通字段塞回 Obx。
void main() {
  testWidgets('Obx 闭包内无 Rx 读取时会抛 improper use of a GetX', (tester) async {
    var plainStatus = 1; // 模拟去 Rx 化后的普通枚举

    await tester.pumpWidget(
      MaterialApp(
        home: Obx(() {
          final isPlaying = plainStatus == 1;
          return Text(isPlaying ? 'playing' : 'paused');
        }),
      ),
    );

    final caught = tester.takeException();
    expect(
      caught,
      isNotNull,
      reason: 'Obx 内必须存在 Rx 读取，否则 GetX 会抛错（小窗控制栏曾因此白屏）',
    );
    expect(caught.toString(), contains('improper use of a GetX'));
  });

  testWidgets('Obx 闭包内读到 Rx 时正常构建', (tester) async {
    final rx = 1.obs;

    await tester.pumpWidget(
      MaterialApp(
        home: Obx(() => Text(rx.value == 1 ? 'playing' : 'paused')),
      ),
    );

    expect(tester.takeException(), isNull);
  });
}
