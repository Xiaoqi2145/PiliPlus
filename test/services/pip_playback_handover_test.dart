import 'package:PiliPlus/services/pip_overlay_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 应用内小窗是**在 pop 视频页时**开启的，页面随之被销毁。
///
/// 页面 `dispose()` 原先无条件摘掉播放状态/进度监听，而小窗内容
/// (`PipMiniVideoContent`) 自身不注册状态监听，于是小窗里再没有人能收到
/// `stream.completed`：播放停在片尾，无人调用 `introController.nextPlay()`
/// 连播下一集；过渡态兜底到期后前台服务与 `PARTIAL_WAKE_LOCK` 一并被回收，
/// 后台表现就是"播完自动切集卡住/卡网络"。
///
/// 修复把监听**移交给小窗会话**保管，并让被托管的 controller 在路由已销毁
/// (`isClosed == true`) 时仍能继续走播放链路。这组测试锁定这两条判据。
void main() {
  group('shouldHandOverListeners — 页面销毁时监听该不该交给小窗', () {
    test('小窗活跃且托管的正是本页 controller 时移交', () {
      expect(
        PipOverlayService.shouldHandOverListeners(
          inPipMode: true,
          savedControllerMatches: true,
          hasPlayer: true,
        ),
        isTrue,
      );
    });

    test('不在小窗时照常摘除（普通返回不留下悬挂监听）', () {
      expect(
        PipOverlayService.shouldHandOverListeners(
          inPipMode: false,
          savedControllerMatches: true,
          hasPlayer: true,
        ),
        isFalse,
      );
    });

    test('小窗托管的不是本页 controller 时不移交', () {
      // 例如从列表点开了另一个视频：小窗属于旧 controller，
      // 本页销毁必须摘掉自己的监听，否则会去驱动别人的播放。
      expect(
        PipOverlayService.shouldHandOverListeners(
          inPipMode: true,
          savedControllerMatches: false,
          hasPlayer: true,
        ),
        isFalse,
      );
    });

    test('播放器实例已不存在时不移交（无从挂载）', () {
      expect(
        PipOverlayService.shouldHandOverListeners(
          inPipMode: true,
          savedControllerMatches: true,
          hasPlayer: false,
        ),
        isFalse,
      );
    });
  });

  group('keepsPlaybackAlive — 被小窗托管的 controller 不被 isClosed 拦住', () {
    test('路由已销毁但小窗仍在托管：播放链路继续工作', () {
      // 这正是"小窗里连播到下一集"的关键：地址请求不能被静默丢弃。
      expect(
        PipOverlayService.keepsPlaybackAlive(
          isClosed: true,
          ownedByPip: true,
        ),
        isTrue,
      );
    });

    test('路由未销毁时正常放行', () {
      expect(
        PipOverlayService.keepsPlaybackAlive(
          isClosed: false,
          ownedByPip: false,
        ),
        isTrue,
      );
    });

    test('已关闭且无人托管：照旧拦住（保持原有清理语义）', () {
      expect(
        PipOverlayService.keepsPlaybackAlive(
          isClosed: true,
          ownedByPip: false,
        ),
        isFalse,
      );
    });
  });
}
