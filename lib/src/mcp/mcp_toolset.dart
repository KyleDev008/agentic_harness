import 'dart:async';
import 'dart:convert';

import '../core/cancellation.dart';
import '../core/errors.dart';
import '../core/message.dart';
import '../tools/tool.dart';
import 'mcp_client.dart';
import 'mcp_transport.dart';

/// Exposes an MCP server's tools to an agent (`AgentSpec.toolProviders`).
///
/// ```dart
/// final github = McpToolset(
///   McpClient(McpHttpTransport(Uri.parse('https://mcp.example.com/mcp'),
///       headers: {'Authorization': 'Bearer $token'})),
///   prefix: 'github',
/// );
/// final agent = AgentSpec(..., toolProviders: [github]);
/// ```
///
/// Everything a server sends is untrusted. By default every MCP tool is
/// treated as destructive and open-world (asks under the standard
/// permission policy); set [trustAnnotations] only for servers you
/// control.
class McpToolset implements ToolProvider {
  final McpClient client;

  /// Prepended to tool names as `<prefix>__<name>`, so a server cannot
  /// claim the names of other tools. Pass `''` to expose bare names.
  final String prefix;

  /// When set, only tools whose MCP name passes are exposed.
  final bool Function(McpToolInfo tool)? filter;

  /// Use the server's `readOnlyHint` / `destructiveHint` /
  /// `idempotentHint` / `openWorldHint`. Only for trusted servers: a
  /// read-only hint skips approval under the standard policy.
  final bool trustAnnotations;

  /// Called when a refreshed list changes the description, schema or
  /// annotations of tools seen before. Return false to drop those tools
  /// for this listing (for example until the user re-approves the server).
  /// When null, changes are accepted.
  final bool Function(List<McpToolInfo> changed)? onToolsChanged;

  /// Per-call timeout for these tools (overrides `RunConfig.toolTimeout`).
  /// Set it: MCP calls otherwise wait as long as the run allows.
  final Duration? timeout;

  /// How long a tool list is reused before asking the server again.
  final Duration cacheFor;

  /// Longest tool description passed to the model.
  final int maxDescriptionChars;

  McpToolset(
    this.client, {
    required this.prefix,
    this.filter,
    this.trustAnnotations = false,
    this.onToolsChanged,
    this.timeout,
    this.cacheFor = const Duration(minutes: 5),
    this.maxDescriptionChars = 2000,
  });

  List<HarnessTool>? _cached;
  DateTime? _cachedAt;
  Future<List<HarnessTool>>? _listing;
  final Map<String, String> _fingerprints = {};

  /// Drops the cached tool list (e.g. on `notifications/tools/list_changed`).
  void invalidate() => _cached = null;

  @override
  Future<List<HarnessTool>> listTools() {
    final cached = _cached;
    final at = _cachedAt;
    if (cached != null &&
        at != null &&
        DateTime.now().difference(at) < cacheFor) {
      return Future.value(cached);
    }
    return _listing ??= _list().whenComplete(() => _listing = null);
  }

  Future<List<HarnessTool>> _list() async {
    var infos = [
      for (final info in await client.listTools())
        if (filter?.call(info) ?? true) info,
    ];
    final changed = [
      for (final info in infos)
        if (_fingerprints[info.name] case final old?
            when old != _fingerprint(info))
          info,
    ];
    final accept = changed.isEmpty || (onToolsChanged?.call(changed) ?? true);
    if (!accept) {
      final dropped = {for (final info in changed) info.name};
      infos = [
        for (final info in infos)
          if (!dropped.contains(info.name)) info,
      ];
    }
    for (final info in infos) {
      _fingerprints[info.name] = _fingerprint(info);
    }
    // Names are assigned in sorted order so that reordering a list never
    // renames a tool.
    final names = <String, String>{};
    final used = <String>{};
    for (final mcpName in [for (final i in infos) i.name]..sort()) {
      names[mcpName] = _uniqueName(mcpName, used);
    }
    final tools = <HarnessTool>[
      for (final info in infos)
        McpTool(this, info, exposedName: names[info.name]!),
    ];
    _cached = tools;
    _cachedAt = DateTime.now();
    return tools;
  }

  static String _fingerprint(McpToolInfo info) =>
      jsonEncode([info.description, info.inputSchema, info.annotations]);

  String _uniqueName(String mcpName, Set<String> used) {
    final base = '${prefix.isEmpty ? '' : '${prefix}__'}$mcpName'.replaceAll(
      RegExp(r'[^a-zA-Z0-9_-]'),
      '_',
    );
    var name = base.length > 64 ? base.substring(0, 64) : base;
    for (var i = 2; !used.add(name); i++) {
      final suffix = '_$i';
      final room = 64 - suffix.length;
      name = '${base.length <= room ? base : base.substring(0, room)}$suffix';
    }
    return name;
  }

  Future<void> close() => client.close();
}

/// One MCP server tool as a [HarnessTool].
///
/// The UI label comes from the exposed name, never the server's `title`,
/// so a server cannot word the permission prompt.
class McpTool extends HarnessTool {
  final McpToolset toolset;
  final McpToolInfo info;
  final String exposedName;

  McpTool(this.toolset, this.info, {required this.exposedName});

  @override
  String get name => exposedName;

  @override
  String get description {
    final text = info.description.trim();
    final base = text.isEmpty ? (info.title ?? info.name) : text;
    final max = toolset.maxDescriptionChars;
    return base.length <= max ? base : '${base.substring(0, max)}…';
  }

  @override
  Map<String, Object?> get inputSchema => info.inputSchema;

  @override
  ToolAnnotations get annotations {
    if (!toolset.trustAnnotations) {
      return const ToolAnnotations(openWorld: true);
    }
    final hints = info.annotations;
    bool hint(String key, bool fallback) {
      final value = hints[key];
      return value is bool ? value : fallback;
    }

    // Defaults follow the MCP spec.
    final readOnly = hint('readOnlyHint', false);
    return ToolAnnotations(
      readOnly: readOnly,
      destructive: !readOnly && hint('destructiveHint', true),
      idempotent: hint('idempotentHint', false),
      openWorld: hint('openWorldHint', true),
    );
  }

  @override
  Duration? get timeout => toolset.timeout;

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final Map<String, Object?> result;
    try {
      result = await toolset.client.callTool(
        info.name,
        input,
        cancel: context.cancel,
      );
    } on CancelledException {
      rethrow;
    } on McpError catch (e) {
      return ToolOutput.error('MCP error ${e.code}: ${e.message}');
    } on McpTransportError catch (e) {
      return ToolOutput.error('MCP server unavailable: ${e.message}');
    } on HarnessError catch (e) {
      return ToolOutput.error('MCP server refused the call: ${e.message}');
    } on TimeoutException {
      return ToolOutput.error('MCP server did not respond in time.');
    }
    return toolOutputFromMcp(result);
  }
}

const _imageTypes = {'image/png', 'image/jpeg', 'image/gif', 'image/webp'};

/// Converts an MCP `CallToolResult` to a [ToolOutput].
///
/// Text and up to [maxImages] images (PNG, JPEG, GIF or WebP, each at most
/// [maxImageBase64Chars] of base64) go to the model; audio, resources and
/// extra images become short text notes. `structuredContent` becomes
/// [ToolOutput.structured] when it encodes to at most [maxStructuredChars],
/// and the model-facing text when there is no other content.
ToolOutput toolOutputFromMcp(
  Map<String, Object?> result, {
  int maxImages = 4,
  int maxImageBase64Chars = 4 * 1024 * 1024,
  int maxStructuredChars = 1024 * 1024,
}) {
  final type = result['resultType'];
  if (type != null && type != 'complete') {
    return ToolOutput.error(
      type == 'input_required'
          ? 'The MCP tool needs extra user input, which this client does not '
              'support.'
          : 'Unsupported MCP result type.',
    );
  }
  final blocks = <ContentBlock>[];
  var images = 0;
  final raw = result['content'];
  if (raw is List) {
    for (final item in raw) {
      if (item is Map && item['type'] == 'image') {
        blocks.add(_image(item, ++images <= maxImages, maxImageBase64Chars));
        continue;
      }
      final block = _block(item);
      if (block != null) blocks.add(block);
    }
  }
  var structured = result['structuredContent'];
  if (structured != null) {
    final encoded = jsonEncode(structured);
    if (encoded.length > maxStructuredChars) {
      structured = null;
      if (blocks.isEmpty) {
        blocks.add(const TextBlock('[structured output too large]'));
      }
    } else if (blocks.isEmpty) {
      blocks.add(TextBlock(encoded));
    }
  }
  if (blocks.isEmpty) blocks.add(const TextBlock('(no output)'));
  return ToolOutput(
    content: blocks,
    structured: structured,
    isError: result['isError'] == true,
  );
}

ContentBlock _image(Map<Object?, Object?> item, bool allowed, int maxChars) {
  final data = item['data'];
  final mime = item['mimeType'];
  if (!allowed) return const TextBlock('[image omitted: too many images]');
  if (data is! String || !_imageTypes.contains(mime)) {
    return const TextBlock('[image omitted: unsupported type]');
  }
  if (data.length > maxChars) {
    return const TextBlock('[image omitted: too large]');
  }
  try {
    return ImageBlock(bytes: base64Decode(data), mediaType: mime as String);
  } on FormatException {
    return const TextBlock('[image omitted: invalid data]');
  }
}

ContentBlock? _block(Object? item) {
  if (item is! Map) return null;
  switch (item['type']) {
    case 'text':
      final text = item['text'];
      return text is String ? TextBlock(text) : null;
    case 'audio':
      return const TextBlock('[audio omitted]');
    case 'resource_link':
      return TextBlock(
        '[resource ${item['name'] ?? ''}: ${item['uri'] ?? ''}]',
      );
    case 'resource':
      final resource = item['resource'];
      if (resource is! Map) return null;
      final text = resource['text'];
      return text is String
          ? TextBlock(text)
          : TextBlock('[binary resource ${resource['uri'] ?? ''} omitted]');
    default:
      return null;
  }
}
