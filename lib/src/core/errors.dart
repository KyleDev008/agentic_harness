/// Coarse error category, carried on `RunError` events so hosts can map
/// errors to user-facing messages without string matching.
enum ErrorClass {
  rateLimit,
  overloaded,
  auth,
  notFound,
  badRequest,
  contextOverflow,
  network,
  timeout,
  provider,
  tool,
  cancelled,
  internal,
}

/// Base class for every error the harness raises from model calls.
///
/// Messages are safe to log: they never contain API keys, and response
/// bodies are truncated.
sealed class HarnessError implements Exception {
  final String message;
  const HarnessError(this.message);

  ErrorClass get errorClass;

  /// Whether retrying the same request may succeed.
  bool get isRetryable => false;

  @override
  String toString() => '$runtimeType: $message';
}

/// HTTP 429. [retryAfter] is the server's hint when it sent one.
final class RateLimitError extends HarnessError {
  final Duration? retryAfter;
  const RateLimitError(super.message, {this.retryAfter});
  @override
  ErrorClass get errorClass => ErrorClass.rateLimit;
  @override
  bool get isRetryable => true;
}

/// HTTP 503 / 529: the provider is temporarily overloaded.
final class OverloadedError extends HarnessError {
  final Duration? retryAfter;
  const OverloadedError(super.message, {this.retryAfter});
  @override
  ErrorClass get errorClass => ErrorClass.overloaded;
  @override
  bool get isRetryable => true;
}

/// HTTP 401 / 403.
final class AuthError extends HarnessError {
  const AuthError(super.message);
  @override
  ErrorClass get errorClass => ErrorClass.auth;
}

/// HTTP 404 — usually an unknown model name or a wrong base URL.
final class NotFoundError extends HarnessError {
  const NotFoundError(super.message);
  @override
  ErrorClass get errorClass => ErrorClass.notFound;
}

/// The request was too large for the model's context window.
final class ContextOverflowError extends HarnessError {
  const ContextOverflowError(super.message);
  @override
  ErrorClass get errorClass => ErrorClass.contextOverflow;
}

/// Connection failure (DNS, refused, reset, TLS).
final class NetworkError extends HarnessError {
  const NetworkError(super.message);
  @override
  ErrorClass get errorClass => ErrorClass.network;
  @override
  bool get isRetryable => true;
}

/// No response (or no stream progress) within the configured timeout.
final class ModelTimeoutError extends HarnessError {
  const ModelTimeoutError(super.message);
  @override
  ErrorClass get errorClass => ErrorClass.timeout;
  @override
  bool get isRetryable => true;
}

/// Any other provider-side failure. [statusCode] is the HTTP status when
/// known.
final class ProviderError extends HarnessError {
  final int? statusCode;
  const ProviderError(super.message, {this.statusCode});
  @override
  ErrorClass get errorClass =>
      statusCode == 400 || statusCode == 422
          ? ErrorClass.badRequest
          : ErrorClass.provider;
}

/// Maps an arbitrary error thrown during a run to an [ErrorClass].
ErrorClass classifyError(Object error) {
  if (error is HarnessError) return error.errorClass;
  final name = error.runtimeType.toString();
  if (name.contains('Timeout')) return ErrorClass.timeout;
  if (name.contains('Socket') ||
      name.contains('ClientException') ||
      name.contains('Handshake')) {
    return ErrorClass.network;
  }
  if (name.contains('Cancelled') || name.contains('Aborted')) {
    return ErrorClass.cancelled;
  }
  return ErrorClass.internal;
}
