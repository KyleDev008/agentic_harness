import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math';

import 'package:http/http.dart' as http;

import '../core/cancellation.dart';
import '../core/errors.dart';

/// Retry behaviour for model HTTP calls.
///
/// Only retryable failures are retried — 429, 503/529 (overloaded),
/// 408/504 and connection/timeout errors — never 4xx validation or auth
/// errors. Retries happen only before any response bytes are consumed, so a
/// partially streamed answer is never duplicated.
final class RetryPolicy {
  /// Total attempts including the first (default 3).
  final int maxAttempts;
  final Duration baseDelay;
  final Duration maxDelay;

  /// Upper bound on a server-supplied `retry-after`; longer hints fail fast.
  final Duration maxRetryAfter;

  const RetryPolicy({
    this.maxAttempts = 3,
    this.baseDelay = const Duration(milliseconds: 800),
    this.maxDelay = const Duration(seconds: 20),
    this.maxRetryAfter = const Duration(seconds: 60),
  });

  static const none = RetryPolicy(maxAttempts: 1);

  /// Exponential backoff with full jitter for attempt [attempt] (1-based).
  Duration backoff(int attempt, Random random) {
    final exp = baseDelay.inMilliseconds * pow(2, attempt - 1);
    final capped = min(exp.toInt(), maxDelay.inMilliseconds);
    return Duration(milliseconds: random.nextInt(max(capped, 1)) + 1);
  }
}

/// Called before each retry so the runner can emit a `Retrying` event.
typedef RetryCallback =
    void Function(int attempt, Duration delay, HarnessError error);

/// Zone key through which the runner receives retry notifications from
/// transports it did not construct (so `Retrying` events work for any
/// client built by the host).
const Object retryZoneKey = #agentic_harness_retry;

/// Upper bound (UTF-16 units, ~4 MiB) on a buffered line or response body —
/// the idle timeout only bounds silence, not volume.
const int maxStreamBufferChars = 4 * 1024 * 1024;

/// Shared HTTP plumbing for model clients: typed errors, retries with
/// backoff, request abort on cancel, idle timeouts and line framing.
///
/// Redirects are never followed: `dart:io` re-attaches every header
/// (including `Authorization`) to the redirect target without an origin
/// check, which would leak credentials. A 3xx surfaces as a [ProviderError].
class HttpTransport {
  final http.Client _client;
  final bool _ownsClient;
  final RetryPolicy retryPolicy;

  /// Time allowed until response headers arrive.
  final Duration connectTimeout;

  /// Maximum silence between stream chunks.
  final Duration idleTimeout;

  final Random _random = Random();

  HttpTransport({
    http.Client? client,
    this.retryPolicy = const RetryPolicy(),
    this.connectTimeout = const Duration(seconds: 60),
    this.idleTimeout = const Duration(seconds: 120),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  /// POSTs JSON [body] to [uri] and returns the streamed response once a
  /// 2xx status arrives, retrying retryable failures.
  Future<http.StreamedResponse> postJson(
    Uri uri,
    Map<String, Object?> body, {
    Map<String, String> headers = const {},
    CancelToken? cancel,
    RetryCallback? onRetry,
    String logName = 'agentic_harness.http',
  }) async {
    final encoded = jsonEncode(body);
    if (uri.scheme == 'http' && !_isLocalHost(uri.host)) {
      const credentialHeaders = {
        'authorization',
        'x-api-key',
        'api-key',
        'x-goog-api-key',
      };
      if (headers.keys.any(
        (k) => credentialHeaders.contains(k.toLowerCase()),
      )) {
        developer.log(
          'credentials will be sent over plaintext HTTP to ${uri.host} — '
          'use https for remote endpoints',
          name: logName,
          level: 900,
        );
      }
    }
    for (var attempt = 1; ; attempt++) {
      cancel?.throwIfCancelled();
      try {
        return await _sendOnce(uri, encoded, headers, cancel);
      } on HarnessError catch (error) {
        if (!error.isRetryable || attempt >= retryPolicy.maxAttempts) rethrow;
        final hinted = switch (error) {
          RateLimitError(:final retryAfter) => retryAfter,
          OverloadedError(:final retryAfter) => retryAfter,
          _ => null,
        };
        if (hinted != null && hinted > retryPolicy.maxRetryAfter) rethrow;
        final delay = hinted ?? retryPolicy.backoff(attempt, _random);
        developer.log(
          'retrying after ${error.errorClass.name} '
          '(attempt $attempt/${retryPolicy.maxAttempts}, '
          'delay ${delay.inMilliseconds}ms)',
          name: logName,
        );
        final zoneCallback = Zone.current[retryZoneKey];
        if (onRetry != null) {
          onRetry(attempt, delay, error);
        } else if (zoneCallback is RetryCallback) {
          zoneCallback(attempt, delay, error);
        }
        await _sleep(delay, cancel);
      }
    }
  }

  Future<http.StreamedResponse> _sendOnce(
    Uri uri,
    String body,
    Map<String, String> headers,
    CancelToken? cancel,
  ) async {
    final abort = Completer<void>();
    final unregister = cancel?.onCancel(() {
      if (!abort.isCompleted) abort.complete();
    });
    final request = http.AbortableRequest(
      'POST',
      uri,
      abortTrigger: abort.future,
    );
    request.followRedirects = false;
    request.headers['Content-Type'] = 'application/json';
    request.headers.addAll(headers);
    request.body = body;

    http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(connectTimeout);
    } on TimeoutException {
      if (!abort.isCompleted) abort.complete();
      unregister?.call();
      throw ModelTimeoutError(
        'No response from ${uri.host} within ${connectTimeout.inSeconds}s',
      );
    } on http.RequestAbortedException {
      unregister?.call();
      throw CancelledException(cancel?.reason ?? 'Request aborted');
    } on http.ClientException catch (e) {
      unregister?.call();
      throw NetworkError('Could not reach ${uri.host}: ${e.message}');
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      // Keep the abort hook registered — it cancels the body stream. It is
      // released when the stream ends (see [lines]).
      return _TrackedResponse(response, unregister);
    }
    unregister?.call();
    final errorBody = await readBoundedBody(response);
    throw errorFromStatus(response.statusCode, errorBody, response.headers);
  }

  /// Decodes [response] as UTF-8 lines, enforcing [idleTimeout] and
  /// [maxStreamBufferChars], and mapping transport failures to
  /// [HarnessError]s.
  Stream<String> lines(
    http.StreamedResponse response, {
    CancelToken? cancel,
  }) async* {
    final buffer = StringBuffer();
    try {
      await for (final chunk in response.stream
          .transform(utf8.decoder)
          .timeout(idleTimeout)) {
        buffer.write(chunk);
        if (buffer.length > maxStreamBufferChars) {
          throw const ProviderError(
            'Response stream exceeded the size limit without a line break.',
          );
        }
        var text = buffer.toString();
        var newline = text.indexOf('\n');
        if (newline < 0) continue;
        buffer.clear();
        while (newline >= 0) {
          var line = text.substring(0, newline);
          if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
          yield line;
          text = text.substring(newline + 1);
          newline = text.indexOf('\n');
        }
        buffer.write(text);
      }
      final tail = buffer.toString();
      if (tail.trim().isNotEmpty) yield tail;
    } on TimeoutException {
      throw ModelTimeoutError(
        'The model stream stalled for ${idleTimeout.inSeconds}s',
      );
    } on http.RequestAbortedException {
      throw CancelledException(cancel?.reason ?? 'Request aborted');
    } on http.ClientException catch (e) {
      if (cancel?.isCancelled ?? false) {
        throw CancelledException(cancel!.reason);
      }
      throw NetworkError('Connection lost while streaming: ${e.message}');
    } finally {
      if (response is _TrackedResponse) response.release();
    }
  }

  /// Parses Server-Sent Events `data:` payloads as JSON objects. Stops at
  /// `[DONE]`. Malformed payloads are skipped.
  Stream<Map<String, Object?>> sseJson(
    http.StreamedResponse response, {
    CancelToken? cancel,
  }) async* {
    await for (final line in lines(response, cancel: cancel)) {
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data.isEmpty) continue;
      if (data == '[DONE]') return;
      final decoded = _tryDecode(data);
      if (decoded is Map) yield decoded.cast<String, Object?>();
    }
  }

  /// Parses newline-delimited JSON objects (Ollama). A server that ignored
  /// `stream` and returned one pretty-printed object is handled too.
  Stream<Map<String, Object?>> ndjson(
    http.StreamedResponse response, {
    CancelToken? cancel,
  }) async* {
    final unparsed = StringBuffer();
    var yielded = false;
    await for (final line in lines(response, cancel: cancel)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final decoded = _tryDecode(trimmed);
      if (decoded is Map) {
        yielded = true;
        yield decoded.cast<String, Object?>();
      } else if (!yielded && unparsed.length < maxStreamBufferChars) {
        unparsed.writeln(line);
      }
    }
    if (!yielded && unparsed.isNotEmpty) {
      final decoded = _tryDecode(unparsed.toString());
      if (decoded is Map) yield decoded.cast<String, Object?>();
    }
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  static bool _isLocalHost(String host) =>
      host == 'localhost' ||
      host == '127.0.0.1' ||
      host == '::1' ||
      host == '[::1]' ||
      host.startsWith('192.168.') ||
      host.startsWith('10.');

  Future<void> _sleep(Duration delay, CancelToken? cancel) async {
    if (cancel == null) {
      await Future<void>.delayed(delay);
      return;
    }
    await Future.any([Future<void>.delayed(delay), cancel.whenCancelled]);
    cancel.throwIfCancelled();
  }

  static Object? _tryDecode(String data) {
    try {
      return jsonDecode(data);
    } on FormatException {
      return null;
    }
  }
}

/// Maps an HTTP error response to a typed [HarnessError].
HarnessError errorFromStatus(
  int status,
  String body,
  Map<String, String> headers,
) {
  final snippet = truncateForError(body);
  final retryAfter = parseRetryAfter(headers);
  final lower = body.toLowerCase();
  if (status == 401 || status == 403) {
    return AuthError('Authentication failed (HTTP $status): $snippet');
  }
  if (status == 404) return NotFoundError('Not found (HTTP 404): $snippet');
  if (status == 429) {
    return RateLimitError(
      'Rate limited (HTTP 429): $snippet',
      retryAfter: retryAfter,
    );
  }
  if (status == 503 || status == 529) {
    return OverloadedError(
      'Provider overloaded (HTTP $status): $snippet',
      retryAfter: retryAfter,
    );
  }
  if (status == 408 || status == 504) {
    return ModelTimeoutError('Provider timed out (HTTP $status)');
  }
  if ((status == 400 || status == 413) &&
      (lower.contains('context') ||
          lower.contains('too long') ||
          lower.contains('too many tokens')) &&
      (lower.contains('length') ||
          lower.contains('window') ||
          lower.contains('maximum') ||
          lower.contains('too long') ||
          lower.contains('tokens'))) {
    return ContextOverflowError('Request exceeds the context window: $snippet');
  }
  return ProviderError(
    'Provider error (HTTP $status): $snippet',
    statusCode: status,
  );
}

/// Parses `retry-after-ms` / `retry-after` (delta-seconds).
Duration? parseRetryAfter(Map<String, String> headers) {
  final ms = headers['retry-after-ms'];
  if (ms != null) {
    final value = double.tryParse(ms);
    if (value != null) return Duration(milliseconds: value.round());
  }
  final raw = headers['retry-after'];
  if (raw == null) return null;
  // HTTP-date values are ignored (backoff applies) — model providers send
  // delta-seconds, and parsing dates would need dart:io or http_parser.
  final seconds = double.tryParse(raw.trim());
  if (seconds != null) return Duration(milliseconds: (seconds * 1000).round());
  return null;
}

/// Truncates text echoed into error messages so hostile or huge bodies
/// cannot flood logs.
String truncateForError(String body, [int maxChars = 400]) {
  final oneLine = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  return oneLine.length <= maxChars
      ? oneLine
      : '${oneLine.substring(0, maxChars)}…';
}

/// Reads at most [maxBytes] of [response]'s body within [timeout].
Future<String> readBoundedBody(
  http.StreamedResponse response, {
  int maxBytes = 64 * 1024,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final bytes = <int>[];
  final done = Completer<void>();
  late final StreamSubscription<List<int>> sub;
  sub = response.stream.listen(
    (chunk) {
      final remaining = maxBytes - bytes.length;
      if (remaining <= 0) return;
      bytes.addAll(
        chunk.length <= remaining ? chunk : chunk.sublist(0, remaining),
      );
      if (bytes.length >= maxBytes && !done.isCompleted) done.complete();
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
    onError: (Object e) {
      if (!done.isCompleted) done.complete();
    },
  );
  try {
    await done.future.timeout(timeout);
  } on TimeoutException {
    // Return what arrived.
  } finally {
    await sub.cancel();
  }
  return utf8.decode(bytes, allowMalformed: true);
}

/// A 2xx response whose cancel hook is released when its stream is done.
class _TrackedResponse extends http.StreamedResponse {
  final void Function()? _release;
  bool _released = false;

  _TrackedResponse(http.StreamedResponse inner, this._release)
    : super(
        inner.stream,
        inner.statusCode,
        contentLength: inner.contentLength,
        request: inner.request,
        headers: inner.headers,
        isRedirect: inner.isRedirect,
        persistentConnection: inner.persistentConnection,
        reasonPhrase: inner.reasonPhrase,
      );

  void release() {
    if (_released) return;
    _released = true;
    _release?.call();
  }
}
