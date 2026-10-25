import 'dart:convert';
import 'dart:typed_data';

/// The author of an [AgentMessage].
///
/// System instructions are not messages — they travel on
/// `ModelRequest.system` — so only conversational roles exist here.
enum Role { user, assistant }

/// One turn of a conversation: a role plus an ordered list of content
/// blocks.
///
/// Tool calls are [ToolUseBlock]s on assistant messages; their results are
/// [ToolResultBlock]s on the following user message. Every tool use must be
/// answered by exactly one result with the same id — model providers reject
/// transcripts that break this pairing, and the runner guarantees it.
///
/// [providerMetadata] carries client-specific data that must survive a
/// round-trip, e.g. `rawText` (the model's exact output) written by
/// `PromptedToolCallingClient` so a turn can be re-rendered byte-identically.
final class AgentMessage {
  final Role role;
  final List<ContentBlock> content;
  final Map<String, Object?> providerMetadata;

  const AgentMessage({
    required this.role,
    required this.content,
    this.providerMetadata = const {},
  });

  /// A user message holding plain [text].
  factory AgentMessage.user(
    String text, {
    List<ImageBlock> images = const [],
  }) => AgentMessage(role: Role.user, content: [TextBlock(text), ...images]);

  /// An assistant message holding plain [text].
  factory AgentMessage.assistant(String text) =>
      AgentMessage(role: Role.assistant, content: [TextBlock(text)]);

  /// Concatenated text of every [TextBlock], in order.
  String get text => content.whereType<TextBlock>().map((b) => b.text).join();

  /// Every tool use requested by this message, in order.
  List<ToolUseBlock> get toolUses =>
      content.whereType<ToolUseBlock>().toList(growable: false);

  /// Every tool result carried by this message, in order.
  List<ToolResultBlock> get toolResults =>
      content.whereType<ToolResultBlock>().toList(growable: false);

  AgentMessage copyWith({
    Role? role,
    List<ContentBlock>? content,
    Map<String, Object?>? providerMetadata,
  }) => AgentMessage(
    role: role ?? this.role,
    content: content ?? this.content,
    providerMetadata: providerMetadata ?? this.providerMetadata,
  );

  Map<String, Object?> toJson() => {
    'role': role.name,
    'content': [for (final b in content) b.toJson()],
    if (providerMetadata.isNotEmpty) 'providerMetadata': providerMetadata,
  };

  factory AgentMessage.fromJson(Map<String, Object?> json) {
    final roleName = json['role'];
    final role = Role.values.firstWhere(
      (r) => r.name == roleName,
      orElse: () => throw FormatException('Unknown role: $roleName'),
    );
    final rawContent = json['content'];
    final rawMeta = json['providerMetadata'];
    return AgentMessage(
      role: role,
      content: [
        if (rawContent is List)
          for (final item in rawContent)
            if (item is Map)
              ContentBlock.fromJson(item.cast<String, Object?>()),
      ],
      providerMetadata:
          rawMeta is Map ? rawMeta.cast<String, Object?>() : const {},
    );
  }

  @override
  String toString() => 'AgentMessage(${role.name}, ${content.length} blocks)';
}

/// A piece of message content.
sealed class ContentBlock {
  const ContentBlock();

  Map<String, Object?> toJson();

  static ContentBlock fromJson(Map<String, Object?> json) {
    switch (json['type']) {
      case 'text':
        return TextBlock(json['text'] as String? ?? '');
      case 'image':
        final b64 = json['base64'];
        final url = json['url'];
        return ImageBlock(
          bytes: b64 is String ? base64Decode(b64) : null,
          mediaType: json['mediaType'] as String?,
          url: url is String ? Uri.tryParse(url) : null,
          providerFileId: json['providerFileId'] as String?,
        );
      case 'thinking':
        return ThinkingBlock(
          json['text'] as String? ?? '',
          signature: json['signature'] as String?,
          redactedData: json['redactedData'] as String?,
        );
      case 'tool_use':
        final input = json['input'];
        return ToolUseBlock(
          id: json['id'] as String? ?? '',
          name: json['name'] as String? ?? '',
          input: input is Map ? input.cast<String, Object?>() : const {},
        );
      case 'tool_result':
        final inner = json['content'];
        return ToolResultBlock(
          toolUseId: json['toolUseId'] as String? ?? '',
          content: [
            if (inner is List)
              for (final item in inner)
                if (item is Map)
                  ContentBlock.fromJson(item.cast<String, Object?>()),
          ],
          isError: json['isError'] == true,
        );
      default:
        throw FormatException('Unknown content block type: ${json['type']}');
    }
  }
}

/// Plain text.
final class TextBlock extends ContentBlock {
  final String text;
  const TextBlock(this.text);

  @override
  Map<String, Object?> toJson() => {'type': 'text', 'text': text};
}

/// An image, supplied as raw [bytes], a remote [url], or an id for a file
/// the provider already holds ([providerFileId], e.g. an upload id).
///
/// The core never reads files — load paths with
/// `package:agentic_harness/io_tools.dart` (`loadImageBlock`) or app code.
final class ImageBlock extends ContentBlock {
  final Uint8List? bytes;

  /// IANA media type for [bytes] (e.g. `image/png`).
  final String? mediaType;
  final Uri? url;
  final String? providerFileId;

  const ImageBlock({this.bytes, this.mediaType, this.url, this.providerFileId})
    : assert(
        bytes != null || url != null || providerFileId != null,
        'ImageBlock needs bytes, url or providerFileId',
      );

  /// Base64 of [bytes], or `null` when this image has no bytes.
  String? get base64Data => bytes == null ? null : base64Encode(bytes!);

  /// `data:` URL for [bytes], or `null` when this image has no bytes.
  String? get dataUrl {
    final b64 = base64Data;
    if (b64 == null) return null;
    return 'data:${mediaType ?? 'image/png'};base64,$b64';
  }

  @override
  Map<String, Object?> toJson() => {
    'type': 'image',
    if (bytes != null) 'base64': base64Encode(bytes!),
    if (mediaType != null) 'mediaType': mediaType,
    if (url != null) 'url': url.toString(),
    if (providerFileId != null) 'providerFileId': providerFileId,
  };
}

/// Model reasoning. [signature] is provider-issued (Anthropic) and must be
/// sent back unchanged when the block is replayed in a later request.
/// [redactedData] holds an encrypted (`redacted_thinking`) block, which
/// must likewise be replayed verbatim.
final class ThinkingBlock extends ContentBlock {
  final String text;
  final String? signature;
  final String? redactedData;
  const ThinkingBlock(this.text, {this.signature, this.redactedData});

  @override
  Map<String, Object?> toJson() => {
    'type': 'thinking',
    'text': text,
    if (signature != null) 'signature': signature,
    if (redactedData != null) 'redactedData': redactedData,
  };
}

/// A tool call requested by the model.
final class ToolUseBlock extends ContentBlock {
  final String id;
  final String name;
  final Map<String, Object?> input;
  const ToolUseBlock({
    required this.id,
    required this.name,
    required this.input,
  });

  @override
  Map<String, Object?> toJson() => {
    'type': 'tool_use',
    'id': id,
    'name': name,
    'input': input,
  };
}

/// The result of the [ToolUseBlock] with id [toolUseId].
final class ToolResultBlock extends ContentBlock {
  final String toolUseId;
  final List<ContentBlock> content;
  final bool isError;
  const ToolResultBlock({
    required this.toolUseId,
    required this.content,
    this.isError = false,
  });

  /// Concatenated text of the result's [TextBlock]s.
  String get text =>
      content.whereType<TextBlock>().map((b) => b.text).join('\n');

  @override
  Map<String, Object?> toJson() => {
    'type': 'tool_result',
    'toolUseId': toolUseId,
    'content': [for (final b in content) b.toJson()],
    if (isError) 'isError': true,
  };
}
