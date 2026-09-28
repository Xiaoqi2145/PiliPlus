import 'dart:io' show SocketException;

import 'package:PiliPlus/http/retry_interceptor.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http2/http2.dart';

/// 构造一个用于 [RetryInterceptor.shouldRetry] 的 [DioException]。
DioException _err({
  required String method,
  required DioExceptionType type,
  Object? error,
  int retried = 0,
}) {
  final options = RequestOptions(path: '/x/player/wbi/playurl', method: method);
  if (retried != 0) {
    options.extra['_rt'] = retried;
  }
  return DioException(requestOptions: options, type: type, error: error);
}

void main() {
  group('shouldRetry — 幂等性分流', () {
    test('GET + TransportConnectionException 允许重试', () {
      // 幂等请求重放无副作用, 网络中断后应重试 (原实现一刀切拒绝)
      final err = _err(
        method: 'GET',
        type: DioExceptionType.connectionError,
        error: TransportConnectionException(1, 'connection reset'),
      );
      expect(RetryInterceptor.shouldRetry(err, 2), isTrue);
    });

    test('POST + TransportConnectionException 拒绝重试', () {
      // 非幂等: 请求可能已被服务端接收, 重放有重复提交风险
      final err = _err(
        method: 'POST',
        type: DioExceptionType.connectionError,
        error: TransportConnectionException(1, 'connection reset'),
      );
      expect(RetryInterceptor.shouldRetry(err, 2), isFalse);
    });

    test('HEAD + TransportConnectionException 允许重试', () {
      final err = _err(
        method: 'HEAD',
        type: DioExceptionType.connectionError,
        error: TransportConnectionException(1, 'connection reset'),
      );
      expect(RetryInterceptor.shouldRetry(err, 2), isTrue);
    });

    test('GET + receiveTimeout 允许重试', () {
      // 原实现的 switch 未覆盖 receiveTimeout, 幂等请求因此从不重试
      final err = _err(method: 'GET', type: DioExceptionType.receiveTimeout);
      expect(RetryInterceptor.shouldRetry(err, 2), isTrue);
    });

    test('POST + receiveTimeout 拒绝重试', () {
      // receiveTimeout 表示请求已完整发出、服务端可能已处理，
      // 非幂等请求重放会造成重复提交（如重复点赞/重复发弹幕）
      final err = _err(method: 'POST', type: DioExceptionType.receiveTimeout);
      expect(RetryInterceptor.shouldRetry(err, 2), isFalse);
    });

    test('POST + connectionError (非 http2 异常) 允许重试', () {
      // 连接未建立/被拒绝时请求显然没被处理, 非幂等也可安全重试
      final err = _err(
        method: 'POST',
        type: DioExceptionType.connectionError,
        error: const SocketException('connection refused'),
      );
      expect(RetryInterceptor.shouldRetry(err, 2), isTrue);
    });
  });

  group('shouldRetry — 不可重试的类型', () {
    test('badResponse 不重试', () {
      final err = _err(method: 'GET', type: DioExceptionType.badResponse);
      expect(RetryInterceptor.shouldRetry(err, 2), isFalse);
    });

    test('cancel 不重试', () {
      final err = _err(method: 'GET', type: DioExceptionType.cancel);
      expect(RetryInterceptor.shouldRetry(err, 2), isFalse);
    });

    test('badCertificate 不重试', () {
      final err = _err(method: 'GET', type: DioExceptionType.badCertificate);
      expect(RetryInterceptor.shouldRetry(err, 2), isFalse);
    });
  });

  group('shouldRetry — 重试次数上限', () {
    test('GET 达到上限后不再重试', () {
      final err = _err(method: 'GET', type: DioExceptionType.connectionError);
      expect(RetryInterceptor.shouldRetry(err, 2), isTrue);
      err.requestOptions.extra['_rt'] = 2;
      expect(RetryInterceptor.shouldRetry(err, 2), isFalse);
    });

    test('count 为 0 时任何错误都不重试', () {
      final err = _err(method: 'GET', type: DioExceptionType.connectionError);
      expect(RetryInterceptor.shouldRetry(err, 0), isFalse);
    });

    test('_rt 缺失时按 0 处理并允许重试', () {
      final err = _err(method: 'GET', type: DioExceptionType.connectionError);
      expect(err.requestOptions.extra.containsKey('_rt'), isFalse);
      expect(RetryInterceptor.shouldRetry(err, 2), isTrue);
      // 纯函数不得产生副作用
      expect(err.requestOptions.extra.containsKey('_rt'), isFalse);
    });
  });
}
