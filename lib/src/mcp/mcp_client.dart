import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import '../core/cancellation.dart';
import 'mcp_transport.dart';

/// One tool advertised by an MCP server (`tools/list`). Every field is
/// server-controlled.
final class McpToolInfo {
  final String name;
  final String? title;
  final String description;
  final Map<String, Object?> inputSchema;

  /// The server's `annotations` hints (`readOnlyHint`, `destructiveHint`,
  /// `idempotentHint`, `openWorldHint`, `title`). Untrusted.
  final Map<String, Object?> annotations;

  const McpToolInfo({
    required this.name,
    this.title,
    this.description = '',
    this.inputSchema = const {'type': 'object'},
    this.annotations = const {},
  });

  /// Longest nested schema `description`/`title` kept.
  static const maxSchemaTextChars = 500;

  /// Parses one tool, or returns null when it is unusable or its schema
  /// encodes to more than [maxSchemaChars].
  static McpToolInfo? tryParse(Object? json, {int maxSchemaChars = 16384}) {
    if (json is! Map) return null;
    final name = json['name'];
    if (name is! String || name.isEmpty || name.length > 256) return null;
    final schema = json['inputSchema'];
    if (schema is! Map || schema['type'] != 'object') return null;
    final trimmed = _trimSchema(schema, 0);
    if (trimmed is! Map<String, Object?> ||
        jsonEncode(trimmed).length > maxSchemaChars) {
      return null;
    }
    final annotations = json['annotations'];
    final title =
        json['title'] ?? (annotations is Map ? annotations['title'] : null);
    final description = json['description'];
    return McpToolInfo(
      name: name,
      title:
          title is String && title.isNotEmpty && title.length <= 128
              ? title
              : null,
      description: description is String ? description : '',
      inputSchema: trimmed,
      annotations:
          annotations is Map ? annotations.cast<String, Object?>() : const {},
    );
  }

  /// Caps nested descriptions and depth; returns null past depth 16.
  static Object? _trimSchema(Object? node, int depth) {
    if (depth > 16) return null;
    if (node is List) {
      return [for (final item in node) _trimSchema(item, depth + 1)];
    }
    if (node is! Map) return node;
    return <String, Object?>{
      for (final entry in node.entries)
        '${entry.key}': switch (entry.value) {
          final String text
              when (entry.key == 'description' || entry.key == 'title') &&
                  text.length > maxSchemaTextChars =>
            '${text.substring(0, maxSchemaTextChars)}…',
          final value => _trimSchema(value, depth + 1),
        },
    };
  }
}

/// The client side of one MCP server connection.
///
/// Speaks the stateless protocol (2026-07-28, per-request `_meta`) and
/// falls back to the `initialize` handshake for servers on earlier
/// versions, as the spec's dual-era rules describe. Only tools are used;
/// the client declares no capabilities, so servers do not send sampling,
/// roots or elicitation requests.
class McpClient {
  final McpTransport transport;
  final String clientName;
  final String clientVersion;

  /// How long to wait for `server/discover` before assuming a legacy
  /// server (some never answer requests sent before `initialize`).
  final Duration probeTimeout;

  /// Timeout for handshake and list requests (not tool calls, which the
  /// runner's tool timeout governs).
  final Duration requestTimeout;

  /// Most tools taken from `tools/list`; the rest are dropped.
  final int maxTools;

  /// Stateless versions, newest first.
  static const modernVersions = ['2026-07-28'];

  /// `initialize`-based versions, newest first.
  static const legacyVersions = ['2025-11-25', '2025-06-18', '2025-03-26'];

  McpClient(
    this.transport, {
    this.clientName = 'agentic_harness',
    this.clientVersion = '2.0.0',
    this.probeTimeout = const Duration(seconds: 10),
    this.requestTimeout = const Duration(seconds: 60),
    this.maxTools = 200,
  });

  static const _log = 'agentic_harness.mcp';

  int _nextId = 1;
  Future<void>? _connecting;
  String? _version;
  bool _legacy = false;
  int _session = 0;
  Map<String, Object?> _serverInfo = const {};

  /// The negotiated protocol version, once connected.
  String? get protocolVersion => _version;

  /// Whether the server uses the `initialize` handshake.
  bool get isLegacy => _legacy;

  /// `serverInfo` (`name`, `version`, ...) as the server reported it.
  Map<String, Object?> get serverInfo => _serverInfo;

  /// Negotiates the protocol version. Safe to call repeatedly; [cancel]
  /// stops waiting (the handshake itself continues for other callers).
  Future<void> connect({CancelToken? cancel}) {
    final pending =
        _connecting ??= _negotiate().catchError((Object error) {
          _connecting = null;
          throw error;
        });
    if (cancel == null) return pending;
    return Future.any([
      pending,
      cancel.whenCancelled.then<void>(
        (_) => throw CancelledException(cancel.reason),
      ),
    ]);
  }

  Future<void> _negotiate() async {
    try {
      final result = await _send(
        'server/discover',
        const {},
        version: modernVersions.first,
        timeout: probeTimeout,
      );
      final supported = _strings(result['supportedVersions']);
      _useModern(supported.isEmpty ? modernVersions : supported);
      _serverInfo = _map(result['serverInfo']) ?? _serverInfo;
      return;
    } on McpError catch (e) {
      if (e.code == McpError.unsupportedProtocolVersion) {
        final data = e.data;
        final supported = _strings(data is Map ? data['supported'] : null);
        if (modernVersions.any(supported.contains)) {
          _useModern(supported);
          return;
        }
        if (!legacyVersions.any(supported.contains)) {
          throw McpTransportError(
            'The server supports MCP ${supported.join(', ')}, none of which '
            'this client speaks.',
          );
        }
        // A dual-era server that only speaks legacy versions to us.
      } else if (e.code == McpError.headerMismatch) {
        rethrow;
      }
    } on McpTransportError catch (e) {
      // Overload and server errors say nothing about the protocol era.
      final status = e.statusCode;
      if (status != null && (status == 429 || status >= 500)) rethrow;
    } on TimeoutException {
      // No answer before initialize: a legacy server.
    }
    await _initialize();
  }

  void _useModern(List<String> supported) {
    _version = modernVersions.firstWhere(supported.contains);
    _legacy = false;
  }

  Future<void> _initialize() async {
    transport.resetSession();
    _legacy = true;
    _version = null;
    final result = await _send('initialize', {
      'protocolVersion': legacyVersions.first,
      'capabilities': <String, Object?>{},
      'clientInfo': {'name': clientName, 'version': clientVersion},
    }, timeout: requestTimeout);
    final version = result['protocolVersion'];
    if (version is! String || !legacyVersions.contains(version)) {
      throw McpTransportError(
        'The server chose MCP version "$version", which this client does '
        'not support.',
      );
    }
    _version = version;
    _serverInfo = _map(result['serverInfo']) ?? const {};
    _session++;
    await transport.notify({
      'jsonrpc': '2.0',
      'method': 'notifications/initialized',
    }, protocolVersion: _headerVersion);
  }

  /// `MCP-Protocol-Version` header value: 2025-03-26 predates the header.
  String? get _headerVersion => _version == '2025-03-26' ? null : _version;

  /// Lists the server's tools, following `nextCursor` for at most
  /// [maxPages] pages and keeping at most [maxTools]. Tools with unusable
  /// or oversized schemas are skipped.
  Future<List<McpToolInfo>> listTools({int maxPages = 20}) async {
    await connect();
    final tools = <McpToolInfo>[];
    var skipped = 0;
    String? cursor;
    for (var page = 0; page < maxPages; page++) {
      final result = await _request('tools/list', {
        if (cursor != null) 'cursor': cursor,
      }, timeout: requestTimeout);
      final list = result['tools'];
      if (list is List) {
        for (final raw in list) {
          final info = McpToolInfo.tryParse(raw);
          if (info == null) {
            skipped++;
          } else if (tools.length < maxTools) {
            tools.add(info);
          }
        }
      }
      final next = result['nextCursor'];
      if (next is! String ||
          next.isEmpty ||
          next == cursor ||
          next.length > 2048 ||
          tools.length >= maxTools) {
        break;
      }
      cursor = next;
    }
    if (skipped > 0) {
      developer.log('skipped $skipped unusable MCP tools', name: _log);
    }
    return tools;
  }

  /// Calls a tool and returns the raw `CallToolResult`.
  Future<Map<String, Object?>> callTool(
    String name,
    Map<String, Object?> arguments, {
    CancelToken? cancel,
  }) async {
    await connect(cancel: cancel);
    return _request('tools/call', {
      'name': name,
      'arguments': arguments,
    }, cancel: cancel);
  }

  /// Sends a request on the negotiated connection, starting a new legacy
  /// session once if the old one expired.
  Future<Map<String, Object?>> _request(
    String method,
    Map<String, Object?> params, {
    CancelToken? cancel,
    Duration? timeout,
  }) async {
    final session = _session;
    try {
      return await _send(
        method,
        params,
        version: _legacy ? null : _version,
        cancel: cancel,
        timeout: timeout,
      );
    } on McpSessionExpiredError {
      if (!_legacy) rethrow;
      // Concurrent callers share one new session.
      if (_session == session) {
        _connecting = _initialize().catchError((Object error) {
          _connecting = null;
          throw error;
        });
      }
      await connect(cancel: cancel);
      return _send(method, params, cancel: cancel, timeout: timeout);
    }
  }

  Future<Map<String, Object?>> _send(
    String method,
    Map<String, Object?> params, {
    String? version,
    CancelToken? cancel,
    Duration? timeout,
  }) async {
    final modern = version != null && modernVersions.contains(version);
    final message = {
      'jsonrpc': '2.0',
      'id': _nextId++,
      'method': method,
      'params': {
        ...params,
        if (modern)
          '_meta': {
            'io.modelcontextprotocol/protocolVersion': version,
            'io.modelcontextprotocol/clientInfo': {
              'name': clientName,
              'version': clientVersion,
            },
            'io.modelcontextprotocol/clientCapabilities': <String, Object?>{},
          },
      },
    };
    final headerVersion = modern ? version : (_legacy ? _headerVersion : null);
    // A timeout cancels the request so the transport stops waiting too.
    final token = cancel?.child() ?? CancelToken();
    var timedOut = false;
    final timer =
        timeout == null
            ? null
            : Timer(timeout, () {
              timedOut = true;
              token.cancel('MCP request timed out');
            });
    final Map<String, Object?> response;
    try {
      response = await transport.request(
        message,
        protocolVersion: method == 'initialize' ? null : headerVersion,
        cancel: token,
      );
    } on CancelledException {
      if (timedOut) throw TimeoutException('MCP $method timed out', timeout);
      rethrow;
    } finally {
      timer?.cancel();
    }
    final error = response['error'];
    if (error != null) throw McpError.fromJson(error);
    final result = response['result'];
    if (result is! Map) {
      throw const McpTransportError('MCP response has no result object');
    }
    return result.cast<String, Object?>();
  }

  Future<void> close() => transport.close();

  static List<String> _strings(Object? raw) =>
      raw is List ? raw.whereType<String>().toList() : const [];

  static Map<String, Object?>? _map(Object? raw) =>
      raw is Map ? raw.cast<String, Object?>() : null;
}
