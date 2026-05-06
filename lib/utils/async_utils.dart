import 'dart:async';

import 'package:flutter/foundation.dart';

Future<T> withTimeout<T>({
  required Future<T> Function() operation,
  required Duration timeout,
  required T Function() fallback,
  String operationName = 'operation',
}) async {
  final stopwatch = Stopwatch()..start();
  try {
    return await operation().timeout(
      timeout,
      onTimeout: () {
        debugPrint(
          '$operationName timed out after ${timeout.inMilliseconds}ms',
        );
        return fallback();
      },
    );
  } on TimeoutException {
    debugPrint(
      '$operationName threw timeout after ${stopwatch.elapsedMilliseconds}ms',
    );
    return fallback();
  } finally {
    stopwatch.stop();
  }
}
