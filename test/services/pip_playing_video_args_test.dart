import 'package:PiliPlus/services/pip_overlay_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 小窗展开回大窗时，恢复页完全按路由 args 重建。
/// 若 args 停留在"进入小窗时/创建列表时"的旧视频上，恢复页就会跳回那个视频，
/// 播放列表也会跟着错位。这组测试锁定"把当前播放身份写回 args"的行为，
/// 以及它必须让 [PipOverlayService.contextKeyFromArgs] 与实时 key 一致
/// （否则同视频恢复会被误判成换视频而走销毁式关闭）。
void main() {
  group('syncPlayingVideoToArgs — 把当前播放的视频写回路由参数', () {
    test('用正在播放的视频覆盖创建页面时的旧快照', () {
      // 进入小窗（/打开列表）时是 A，小窗里后台连播到了 B
      final args = <String, dynamic>{
        'videoType': 'ugc',
        'bvid': 'BVA',
        'aid': 1,
        'cid': 11,
        'epId': null,
        'seasonId': null,
        'isVertical': false,
        'cover': 'cover-A',
        'heroTag': 'hero-1',
        'sourceType': 'watchLater',
        'mediaId': 42,
      };

      PipOverlayService.syncPlayingVideoToArgs(
        args,
        videoType: 'ugc',
        bvid: 'BVB',
        aid: 2,
        cid: 22,
        isVertical: true,
        cover: 'cover-B',
      );

      expect(args['bvid'], 'BVB');
      expect(args['aid'], 2);
      expect(args['cid'], 22);
      expect(args['cover'], 'cover-B');
      expect(args['isVertical'], true);
      // 列表标识与 heroTag 属于"同一个页面"，不能被播放身份覆盖
      expect(args['heroTag'], 'hero-1');
      expect(args['sourceType'], 'watchLater');
      expect(args['mediaId'], 42);
    });

    test('同步后 contextKeyFromArgs 与实时 key 一致（同视频恢复判定）', () {
      final args = <String, dynamic>{
        'videoType': 'ugc',
        'bvid': 'BVA',
        'cid': 11,
        'epId': null,
        'seasonId': null,
      };
      // 小窗里已经连播到 B：实时 key 与 args 快照 key 不同
      const liveKey = 'ugc|BVB|22||';
      expect(PipOverlayService.contextKeyFromArgs(args), isNot(liveKey));

      PipOverlayService.syncPlayingVideoToArgs(
        args,
        videoType: 'ugc',
        bvid: 'BVB',
        aid: 2,
        cid: 22,
        isVertical: false,
      );

      expect(PipOverlayService.contextKeyFromArgs(args), liveKey);
    });

    test('pgc 的 epId/seasonId 同样被同步', () {
      final args = <String, dynamic>{
        'videoType': 'pgc',
        'bvid': 'BVA',
        'cid': 11,
        'epId': 100,
        'seasonId': 900,
      };

      PipOverlayService.syncPlayingVideoToArgs(
        args,
        videoType: 'pgc',
        bvid: 'BVB',
        aid: 2,
        cid: 22,
        epId: 200,
        seasonId: 900,
        isVertical: false,
      );

      expect(args['epId'], 200);
      expect(args['seasonId'], 900);
      expect(args['cid'], 22);
    });

    test('"继续播放"列表把 oid 锚点移到当前视频', () {
      final args = <String, dynamic>{
        'bvid': 'BVA',
        'aid': 1,
        'cid': 11,
        'isContinuePlaying': true,
        'oid': 1,
      };

      PipOverlayService.syncPlayingVideoToArgs(
        args,
        videoType: 'ugc',
        bvid: 'BVB',
        aid: 2,
        cid: 22,
        isVertical: false,
      );

      expect(args['oid'], 2);
    });

    test('非"继续播放"列表不改写 oid（它可能是别的语义）', () {
      final args = <String, dynamic>{
        'bvid': 'BVA',
        'aid': 1,
        'cid': 11,
        'oid': 1,
      };

      PipOverlayService.syncPlayingVideoToArgs(
        args,
        videoType: 'ugc',
        bvid: 'BVB',
        aid: 2,
        cid: 22,
        isVertical: false,
      );

      expect(args['oid'], 1);
    });

    test('封面为空时不覆盖已有封面；本地文件同步 entry/title', () {
      final args = <String, dynamic>{
        'bvid': 'BVA',
        'aid': 1,
        'cid': 11,
        'cover': 'cover-A',
        'title': '上一个本地视频',
      };
      final entry = Object();

      PipOverlayService.syncPlayingVideoToArgs(
        args,
        videoType: 'ugc',
        bvid: 'BVB',
        aid: 2,
        cid: 22,
        isVertical: false,
        cover: '',
        fileEntry: entry,
        fileTitle: '当前本地视频',
      );

      expect(args['cover'], 'cover-A');
      expect(args['entry'], same(entry));
      expect(args['title'], '当前本地视频');
    });
  });
}
