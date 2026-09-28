import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http2/http2.dart';

class RetryInterceptor extends Interceptor {
  final Dio _client;
  final int _count;
  final int _delay;

  RetryInterceptor(this._client, this._count, this._delay);

  /// 幂等请求（无 body、可安全重放）才允许在网络中断时重试。
  /// 非幂等请求维持原有语义：连接中断后请求可能已被服务端接收，
  /// 重放会造成重复提交（如重复点赞、重复发送弹幕）。
  static bool _isIdempotent(RequestOptions options) {
    // dio 会把 method 规范化为大写 (dio/src/options.dart: `toUpperCase()`)
    final method = options.method;
    return method == 'GET' || method == 'HEAD';
  }

  /// 属于"可重试的网络类错误"的异常类型。
  /// 注意 [DioExceptionType.receiveTimeout] 表示连接已建立但服务端未按时回数据，
  /// 对幂等请求而言重试是安全且有价值的（弱网/服务端抖动下常见）。
  static bool _isRetryableType(DioExceptionType type) => switch (type) {
    DioExceptionType.connectionError ||
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout ||
    DioExceptionType.unknown => true,
    _ => false,
  };

  /// 判定该错误是否应当重试。
  /// [_rt] 的读取不产生副作用，自增仍由 [onError] 负责。
  @visibleForTesting
  static bool shouldRetry(DioException err, int count) {
    if ((err.requestOptions.extra['_rt'] ?? 0) >= count) return false;
    if (!_isRetryableType(err.type)) return false;

    // 幂等请求可安全重放，网络类错误一律重试（含 receiveTimeout）
    if (_isIdempotent(err.requestOptions)) return true;

    // 非幂等请求的额外约束：
    // - receiveTimeout 表示请求已完整发出、服务端可能已处理，重放会造成重复提交
    // - 连接中断（http2 TransportConnectionException）同理，无法确认是否已被接收
    return err.type != DioExceptionType.receiveTimeout &&
        err.error is! TransportConnectionException;
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.requestOptions.responseType == ResponseType.stream) {
      return handler.next(err);
    }
    if (err.response != null) {
      final options = err.requestOptions;
      if (options.followRedirects && options.maxRedirects > 0) {
        final status = err.response!.statusCode;
        if (status != null && 300 <= status && status < 400) {
          var redirectUrl = err.response!.headers.value('location');
          if (redirectUrl != null) {
            var uri = Uri.parse(redirectUrl);
            if (!uri.hasScheme) {
              uri = options.uri.resolveUri(uri);
              redirectUrl = uri.toString();
            }
            (options..path = redirectUrl).maxRedirects--;
            if (status == 303) {
              options
                ..data = null
                ..method = 'GET';
            }
            _client
                .fetch(options)
                .then(
                  (i) => handler.resolve(
                    i
                      ..redirects.add(
                        RedirectRecord(status, options.method, uri),
                      )
                      ..isRedirect = true,
                  ),
                )
                .onError<DioException>((error, _) => handler.next(error));
            return;
          }
        }
      }
      return handler.next(err);
    } else {
      if (shouldRetry(err, _count)) {
        Future.delayed(
          Duration(milliseconds: ++err.requestOptions.extra['_rt'] * _delay),
          () => _client
              .fetch(err.requestOptions)
              .then(handler.resolve)
              .onError<DioException>((error, _) => handler.reject(error)),
        );
      } else {
        handler.next(err);
      }
      return;
    }
  }

  RetryInterceptor copyWith({Dio? client, int? count, int? delay}) =>
      .new(client ?? _client, count ?? _count, delay ?? _delay);
}
