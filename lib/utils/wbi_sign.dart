// Wbi签名 用于生成 REST API 请求中的 w_rid 和 wts 字段
// https://github.com/SocialSisterYi/bilibili-API-collect/blob/master/docs/misc/sign/wbi.md
// import md5 from 'md5'
// import axios from 'axios'
import 'dart:async';
import 'dart:convert';

import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:hive_ce/hive.dart';

abstract final class WbiSign {
  static Box get _localCache => GStorage.localCache;
  static final RegExp _chrFilter = RegExp(r"[!\'\(\)\*]");
  static const _mixinKeyEncTab = <int>[
    46,
    47,
    18,
    2,
    53,
    8,
    23,
    32,
    15,
    50,
    10,
    31,
    58,
    3,
    45,
    35,
    27,
    43,
    5,
    49,
    33,
    9,
    42,
    19,
    29,
    28,
    14,
    39,
    12,
    38,
    41,
    13,
  ];

  static Future<String>? _future;

  // 对 imgKey 和 subKey 进行字符顺序打乱编码
  static String getMixinKey(String orig) {
    return String.fromCharCodes(_mixinKeyEncTab.map(orig.codeUnitAt));
  }

  // 为请求参数进行 wbi 签名
  static void encWbi(Map<String, Object> params, String mixinKey) {
    params['wts'] = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // 按照 key 重排参数
    final List<String> keys = params.keys.toList()..sort();
    final queryStr = keys
        .map(
          (i) =>
              '${Uri.encodeComponent(i)}=${Uri.encodeComponent(params[i].toString().replaceAll(_chrFilter, ''))}',
        )
        .join('&');
    params['w_rid'] = md5
        .convert(utf8.encode(queryStr + mixinKey))
        .toString(); // 计算 w_rid
  }

  static Future<String> _getWbiKeys() async {
    final resp = await Request().get(Api.userInfo);
    try {
      final wbiUrls = resp.data['data']['wbi_img'];

      final mixinKey = getMixinKey(
        Utils.getFileName(wbiUrls['img_url'], fileExt: false) +
            Utils.getFileName(wbiUrls['sub_url'], fileExt: false),
      );

      _localCache.put(LocalCacheKey.mixinKey, mixinKey);

      return mixinKey;
    } catch (_) {
      return '';
    }
  }

  /// 仅供测试替换真实拉取实现（真实路径依赖网络与 Hive 缓存）。
  @visibleForTesting
  static Future<String> Function()? debugFetchKeysOverride;

  /// 取密钥并在结束后清空 [_future]。
  ///
  /// 成功时密钥已落盘，下次调用走同步命中，不会多发请求；失败（异常或空串）
  /// 时必须允许重取：[_future] 是进程级静态字段，若把一次失败的结果留在里面，
  /// 之后每个 WBI 签名请求都会立刻拿到同一个失败结果（空密钥会让 w_rid 恒定
  /// 错误，异常则直接重抛），**完全不再发起网络请求**。后台弱网下这会把
  /// 自动连播的 playurl 全部打死，表现为"播完切集卡住"。
  static Future<String> _fetchWbiKeys() async {
    try {
      return await (debugFetchKeysOverride ?? _getWbiKeys)();
    } finally {
      _future = null;
    }
  }

  static FutureOr<String> getWbiKeys() {
    final nowDate = DateTime.now();
    if (DateTime.fromMillisecondsSinceEpoch(
          _localCache.get(LocalCacheKey.timeStamp, defaultValue: 0) as int,
        ).day ==
        nowDate.day) {
      final String? mixinKey = _localCache.get(LocalCacheKey.mixinKey);
      if (mixinKey != null) return mixinKey;
      return _future ??= _fetchWbiKeys();
    } else {
      return _future = _localCache
          .put(LocalCacheKey.timeStamp, nowDate.millisecondsSinceEpoch)
          .then((_) => _fetchWbiKeys())
          // 连 put 都失败时同样不能把失败的 future 留在静态字段里
          .whenComplete(() => _future = null);
    }
  }

  static Future<Map<String, Object>> makSign(
    Map<String, Object> params,
  ) async {
    // params 为需要加密的请求参数
    final String mixinKey = await getWbiKeys();
    encWbi(params, mixinKey);
    return params;
  }
}
