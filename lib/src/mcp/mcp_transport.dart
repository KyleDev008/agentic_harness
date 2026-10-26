import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/cancellation.dart';
import '../core/errors.dart';
import '../model/http_transport.dart';

/// A JSON-RPC error returned by an MCP server.
final class McpError implements Exception {
  final int code;
  final String message;
  final Object? data;

  const McpError(this.code, this.message, [this.data]);

  /// The server does not support the requested protocol version.
  static const unsupportedProtocolVersion = -32022;

  /// HTTP headers did not match the request body.
  static const headerMismatch = -32020;
  static const methodNotFound = -32601;

  factory McpError.fromJson(Object? json) {
    if (json is! Map) return const McpError(-32603, 'Malformed error');
    final code = json['code'];
    final message = json['message'];
    return McpError(
      code is num ? code.toInt() : -32603,
      truncateForError(message is String ? message : 'Unknown error'),
      json['data'],
    );
  }

  @override
  String toString() => 'McpError($code): $message';
}

/// The connection to an MCP server failed outside JSON-RPC (HTTP status,
/// process exit, timeout or malformed message).
class McpTransportError implements Exception {
  final String message;

  /// HTTP status, when the failure was an HTTP response.
  final int? statusCode;

  const McpTransportError(this.message, {this.statusCode});

  @override
  String toString() => 'McpTransportError: $message';
}

/// A legacy (initialize-based) HTTP session expired; the client starts a
/// new one.
final class McpSessionExpiredError extends McpTransportError {
  const McpSessionExpiredError()
    : super('MCP session expired', statusCode: 404);
}

/// Carries JSON-RPC messages between [McpClient] and one server.
///
/// [request] returns the server's JSON-RPC response object (with `result`
/// or `error`); it throws [McpTransportError] when no such object arrives.
abstract interface class McpTransport {
  /// Sends a request. [protocolVersion] is the negotiated version, or null
  /// during a legacy `initialize`. Cancelling [cancel] abandons the request
  /// and tells the server.
  Future<Map<String, Object?>> request(
    Map<String, Object?> message, {
    String? protocolVersion,
    CancelToken? cancel,
  });

  /// Sends a notification (no response expected).
  Future<void> notify(Map<String, Object?> message, {String? protocolVersion});

  /// Forgets per-connection state (a legacy session id) before a new
  /// handshake.
  void resetSession();

  Future<void> close();
}

/// The Streamable HTTP transport.
///
/// Every message is a POST to [endpoint]; the server answers with JSON or
/// an SSE stream. Sends the `MCP-Protocol-Version`, `Mcp-Method` and
/// `Mcp-Name` headers, and echoes a legacy `Mcp-Session-Id`. Redirects are
/// not followed, so credentials in [headers] stay with [endpoint] (an
/// injected browser client may still follow them). Put credentials in
/// headers, never in the endpoint URL.
class McpHttpTransport implements McpTransport {
  final Uri endpoint;

  /// Static headers, e.g. `Authorization`.
  final Map<String, String> headers;

  /// Called before every request for headers that change (refreshed
  /// tokens). Merged over [headers].
  final FutureOr<Map<String, String>> Function()? headerProvider;

  /// Time allowed until response headers arrive.
  final Duration connectTimeout;

  /// Maximum silence while reading a response.
  final Duration readTimeout;

  /// Largest JSON response body, or single SSE event, accepted.
  final int maxResponseBytes;

  /// Largest total SSE stream accepted for one request.
  final int maxStreamBytes;

  final http.Client _client;
  final bool _ownsClient;
  String? _sessionId;
  bool _replying = false;

  /// [endpoint] must be `https`, or `http` on a loopback host. Pass
  /// [allowInsecureHttp] to accept plain `http` elsewhere: credentials and
  /// tool results then travel unencrypted.
  McpHttpTransport(
    this.endpoint, {
    this.headers = const {},
    this.headerProvider,
    http.Client? client,
    bool allowInsecureHttp = false,
    this.connectTimeout = const Duration(seconds: 30),
    this.readTimeout = const Duration(minutes: 5),
    this.maxResponseBytes = 4 * 1024 * 1024,
    this.maxStreamBytes = 32 * 1024 * 1024,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null {
    if (endpoint.scheme != 'https' && endpoint.scheme != 'http') {
      throw ArgumentError.value(endpoint, 'endpoint', 'must be http(s)');
    }
    if (endpoint.scheme == 'http' &&
        !allowInsecureHttp &&
        !_isLoopback(endpoint.host)) {
      throw ArgumentError.value(
        endpoint,
        'endpoint',
        'must use https for non-local hosts (or set allowInsecureHttp)',
      );
    }
  }

  @override
  void resetSession() => _sessionId = null;

  @override
  Future<Map<String, Object?>> request(
    Map<String, Object?> message, {
    String? protocolVersion,
    CancelToken? cancel,
  }) async {
    final id = '${message['id']}';
    final abort = Completer<void>();
    final session = _sessionId;
    final unregister = cancel?.onCancel(() {
      if (!abort.isCompleted) abort.complete();
      // Legacy sessions expect an explicit cancel; a disconnect is not one.
      if (session != null && message['method'] != 'initialize') {
        unawaited(
          notify({
            'jsonrpc': '2.0',
            'method': 'notifications/cancelled',
            'params': {'requestId': message['id'], 'reason': cancel.reason},
          }, protocolVersion: protocolVersion).catchError((Object _) {}),
        );
      }
    });
    try {
      final reading = _exchange(message, id, protocolVersion, abort, cancel);
      if (cancel == null) return await reading;
      // Not every client honours the abort trigger.
      reading.ignore();
      return await Future.any([
        reading,
        cancel.whenCancelled.then<Map<String, Object?>>(
          (_) => throw CancelledException(cancel.reason),
        ),
      ]);
    } finally {
      unregister?.call();
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<Map<String, Object?>> _exchange(
    Map<String, Object?> message,
    String id,
    String? protocolVersion,
    Completer<void> abort,
    CancelToken? cancel,
  ) async {
    try {
      final response = await _post(message, protocolVersion, abort);
      final status = response.statusCode;
      if (status < 200 || status >= 300) throw await _failure(response);
      final type = response.headers['content-type'] ?? '';
      if (type.contains('text/event-stream')) {
        return await _readSse(response, id, protocolVersion, cancel);
      }
      final body = await _readBody(response);
      final decoded = _decode(body);
      if (decoded is Map && _isResponse(decoded, id)) {
        return decoded.cast<String, Object?>();
      }
      throw McpTransportError(
        'Unexpected response (HTTP $status): ${truncateForError(body)}',
        statusCode: status,
      );
    } on http.RequestAbortedException {
      throw CancelledException(cancel?.reason ?? 'Request aborted');
    } on http.ClientException {
      if (cancel?.isCancelled ?? false) {
        throw CancelledException(cancel!.reason);
      }
      // The message can contain the full URL; keep it out of errors.
      throw McpTransportError('Could not reach ${endpoint.host}');
    }
  }

  @override
  Future<void> notify(
    Map<String, Object?> message, {
    String? protocolVersion,
  }) async {
    final abort = Completer<void>();
    try {
      final response = await _post(message, protocolVersion, abort);
      final status = response.statusCode;
      if (status < 200 || status >= 300) throw await _failure(response);
      await response.stream.drain<void>().timeout(connectTimeout);
    } on http.ClientException {
      throw McpTransportError('Could not reach ${endpoint.host}');
    } on TimeoutException {
      throw McpTransportError('No response from ${endpoint.host}');
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<http.StreamedResponse> _post(
    Map<String, Object?> message,
    String? protocolVersion,
    Completer<void> abort, {
    String method = 'POST',
  }) async {
    final request = http.AbortableRequest(
      method,
      endpoint,
      abortTrigger: abort.future,
    );
    request.followRedirects = false;
    request.headers.addAll(headers);
    final provided = await headerProvider?.call();
    if (provided != null) request.headers.addAll(provided);
    if (method == 'POST') {
      request.headers['Content-Type'] = 'application/json';
      request.headers['Accept'] = 'application/json, text/event-stream';
      final rpcMethod = message['method'];
      if (rpcMethod is String) {
        request.headers['Mcp-Method'] = headerValue(rpcMethod);
      }
      final params = message['params'];
      if (params is Map &&
          const {
            'tools/call',
            'resources/read',
            'prompts/get',
          }.contains(rpcMethod)) {
        final name = params['name'] ?? params['uri'];
        if (name is String) request.headers['Mcp-Name'] = headerValue(name);
      }
      request.body = jsonEncode(message);
    }
    if (protocolVersion != null) {
      request.headers['MCP-Protocol-Version'] = protocolVersion;
    }
    final session = _sessionId;
    if (session != null) request.headers['Mcp-Session-Id'] = session;

    final http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(connectTimeout);
    } on TimeoutException {
      if (!abort.isCompleted) abort.complete();
      throw McpTransportError(
        'No response from ${endpoint.host} within '
        '${connectTimeout.inSeconds}s',
      );
    }
    if (response.isRedirect ||
        (response.statusCode >= 300 && response.statusCode < 400)) {
      await response.stream.drain<void>().catchError((Object _) {});
      throw McpTransportError(
        'Refused a redirect from ${endpoint.host} (HTTP '
        '${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
    final newSession = response.headers['mcp-session-id'];
    if (newSession != null && _validSessionId(newSession)) {
      _sessionId = newSession;
    }
    return response;
  }

  Future<Exception> _failure(http.StreamedResponse response) async {
    final status = response.statusCode;
    final body = await readBoundedBody(response);
    if (status == 404 && _sessionId != null) {
      _sessionId = null;
      return const McpSessionExpiredError();
    }
    if (status == 401 || status == 403) {
      return errorFromStatus(status, body, response.headers);
    }
    final decoded = _decode(body);
    if (decoded is Map && decoded['error'] is Map) {
      return McpError.fromJson(decoded['error']);
    }
    return McpTransportError(
      'HTTP $status from ${endpoint.host}: ${truncateForError(body)}',
      statusCode: status,
    );
  }

  /// Reads a JSON body, failing (not truncating) past [maxResponseBytes].
  Future<String> _readBody(http.StreamedResponse response) async {
    final bytes = BytesBuilder(copy: false);
    try {
      await for (final chunk in response.stream.timeout(readTimeout)) {
        bytes.add(chunk);
        if (bytes.length > maxResponseBytes) {
          throw const McpTransportError('MCP response exceeded the size limit');
        }
      }
    } on TimeoutException {
      throw McpTransportError('${endpoint.host} stopped sending data');
    }
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }

  Future<Map<String, Object?>> _readSse(
    http.StreamedResponse response,
    String id,
    String? protocolVersion,
    CancelToken? cancel,
  ) async {
    final reader = HttpTransport(client: _NoClient(), idleTimeout: readTimeout);
    final data = StringBuffer();
    var total = 0;

    /// Handles one complete event; returns the response when it is ours.
    Map<String, Object?>? dispatch() {
      final decoded = _decode(data.toString());
      data.clear();
      if (decoded is! Map) return null;
      if (_isResponse(decoded, id)) return decoded.cast<String, Object?>();
      final method = decoded['method'];
      if (method is String && decoded.containsKey('id')) {
        // Legacy servers may ping over the response stream; anything else
        // is refused (no capabilities were declared).
        _reply(decoded['id'], method == 'ping', protocolVersion);
      }
      return null;
    }

    try {
      await for (final line in reader.lines(response, cancel: cancel)) {
        total += line.length + 1;
        if (total > maxStreamBytes) {
          throw const McpTransportError('MCP stream exceeded the size limit');
        }
        if (line.startsWith('data:')) {
          if (data.isNotEmpty) data.write('\n');
          data.write(line.substring(line.startsWith('data: ') ? 6 : 5));
          if (data.length > maxResponseBytes) {
            throw const McpTransportError('MCP event exceeded the size limit');
          }
          continue;
        }
        if (line.isNotEmpty || data.isEmpty) continue;
        final result = dispatch();
        if (result != null) return result;
      }
      // Some servers close the stream without the final blank line.
      if (data.isNotEmpty) {
        final result = dispatch();
        if (result != null) return result;
      }
    } on CancelledException {
      rethrow;
    } on McpTransportError {
      rethrow;
    } on ModelTimeoutError {
      throw McpTransportError('${endpoint.host} stopped sending data');
    } on HarnessError catch (e) {
      throw McpTransportError('MCP stream failed: ${e.message}');
    }
    throw const McpTransportError('MCP stream ended without a response');
  }

  /// Answers a server request, one at a time (extra requests are dropped).
  void _reply(Object? id, bool ok, String? protocolVersion) {
    if (_replying) return;
    _replying = true;
    notify(
      {
        'jsonrpc': '2.0',
        'id': id,
        if (ok)
          'result': <String, Object?>{}
        else
          'error': {
            'code': McpError.methodNotFound,
            'message': 'Not supported',
          },
      },
      protocolVersion: protocolVersion,
    ).catchError((Object _) {}).whenComplete(() => _replying = false);
  }

  static bool _isResponse(Map<Object?, Object?> message, String id) =>
      '${message['id']}' == id &&
      (message.containsKey('result') || message.containsKey('error'));

  static Object? _decode(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }

  static bool _validSessionId(String id) =>
      id.isNotEmpty &&
      id.length <= 256 &&
      id.codeUnits.every((c) => c >= 0x21 && c <= 0x7e);

  static bool _isLoopback(String host) =>
      host == 'localhost' || host == '::1' || host.startsWith('127.');

  /// Ends a legacy session (best effort) and releases the HTTP client.
  @override
  Future<void> close() async {
    if (_sessionId != null) {
      final abort = Completer<void>();
      try {
        final response = await _post(
          const {},
          null,
          abort,
          method: 'DELETE',
        ).timeout(const Duration(seconds: 5));
        await response.stream.drain<void>().timeout(const Duration(seconds: 5));
      } catch (_) {
        // The server may not support explicit termination.
      } finally {
        if (!abort.isCompleted) abort.complete();
        _sessionId = null;
      }
    }
    if (_ownsClient) _client.close();
  }
}

/// Encodes [value] for an MCP header: as-is when it is plain visible
/// ASCII, otherwise the `=?base64?…?=` sentinel form.
String headerValue(String value) {
  final plain =
      value.isNotEmpty &&
      value.trim() == value &&
      value.codeUnits.every((c) => c >= 0x20 && c <= 0x7e) &&
      !(value.startsWith('=?base64?') && value.endsWith('?='));
  return plain ? value : '=?base64?${base64Encode(utf8.encode(value))}?=';
}

/// [HttpTransport.lines] only reads the response it is given.
class _NoClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw UnsupportedError('not used');
}
