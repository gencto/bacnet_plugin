import 'dart:async';

import 'exceptions.dart';

/// Cancels requests that are no longer needed, e.g. when a screen closes.
///
/// ```dart
/// final token = BacnetCancelToken();
/// final value = client.readProperty(
///   1234,
///   BacnetObjectType.analogInput,
///   1,
///   BacnetPropertyId.presentValue,
///   cancelToken: token,
/// );
/// token.cancel(); // value completes with BacnetCancelledException
/// ```
///
/// Queued requests are dropped; a request already on the wire keeps its
/// transaction, but its answer is ignored. One token can cancel any number
/// of requests and stays cancelled.
final class BacnetCancelToken {
  /// Creates a token that is not cancelled.
  BacnetCancelToken();

  bool _cancelled = false;
  final Set<void Function()> _listeners = {};

  /// Whether [cancel] was called.
  bool get isCancelled => _cancelled;

  /// Cancels every request using this token.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = _listeners.toList();
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  /// Calls [listener] when the token is cancelled (at once if it already
  /// is) and returns a function that removes it again.
  void Function() onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  /// Returns [future], or a [BacnetCancelledException] once the token is
  /// cancelled, whichever comes first.
  Future<T> guard<T>(Future<T> future) {
    if (_cancelled) return Future<T>.error(const BacnetCancelledException());
    final completer = Completer<T>();
    final remove = onCancel(() {
      if (!completer.isCompleted) {
        completer.completeError(const BacnetCancelledException());
      }
    });
    unawaited(
      future.then(
        (value) {
          remove();
          if (!completer.isCompleted) completer.complete(value);
        },
        onError: (Object error, StackTrace stack) {
          remove();
          if (!completer.isCompleted) completer.completeError(error, stack);
        },
      ),
    );
    return completer.future;
  }
}
