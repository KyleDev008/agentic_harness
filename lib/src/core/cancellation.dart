import 'dart:async';

/// Thrown when work stops because its [CancelToken] was cancelled.
class CancelledException implements Exception {
  final String reason;
  const CancelledException([this.reason = 'Cancelled']);

  @override
  String toString() => 'CancelledException: $reason';
}

/// Cooperative cancellation shared by a run, its model requests and its
/// tools.
///
/// Long operations either poll [isCancelled] / [throwIfCancelled] or
/// register an [onCancel] callback (HTTP clients complete their abort
/// trigger there; process tools kill the child). Cancellation is one-way and
/// idempotent.
class CancelToken {
  bool _cancelled = false;
  String _reason = 'Cancelled';
  final List<void Function()> _callbacks = [];
  final Completer<void> _completer = Completer<void>();

  bool get isCancelled => _cancelled;
  String get reason => _reason;

  /// Completes when the token is cancelled.
  Future<void> get whenCancelled => _completer.future;

  void cancel([String reason = 'Cancelled']) {
    if (_cancelled) return;
    _cancelled = true;
    _reason = reason;
    final callbacks = List.of(_callbacks);
    _callbacks.clear();
    for (final cb in callbacks) {
      try {
        cb();
      } catch (_) {
        // A misbehaving callback must not stop the others from running.
      }
    }
    _completer.complete();
  }

  /// Runs [callback] on cancellation (immediately if already cancelled).
  /// Returns a function that unregisters it.
  void Function() onCancel(void Function() callback) {
    if (_cancelled) {
      callback();
      return () {};
    }
    _callbacks.add(callback);
    return () => _callbacks.remove(callback);
  }

  void throwIfCancelled() {
    if (_cancelled) throw CancelledException(_reason);
  }

  /// A child token cancelled together with this one (but not vice versa).
  CancelToken child() {
    final child = CancelToken();
    final unregister = onCancel(() => child.cancel(_reason));
    child.onCancel(unregister);
    return child;
  }
}
