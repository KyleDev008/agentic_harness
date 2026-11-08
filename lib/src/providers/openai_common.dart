import 'dart:developer' as developer;

/// Helpers shared by the OpenAI Chat Completions and Responses clients.
/// Internal: not exported.

/// Whether [model] is an OpenAI reasoning model (o-series, gpt-5 and
/// later): sampling parameters are omitted and reasoning is requested.
/// Provider prefixes such as `openai/` are ignored.
bool isOpenAiReasoningModel(String model) {
  final name = model.toLowerCase().split('/').last;
  return RegExp(r'^(o\d|gpt-[5-9]|gpt-\d{2})').hasMatch(name);
}

/// `<baseUrl>/<path>` with trailing slashes removed from [baseUrl] and
/// [queryParameters] added (Azure's `api-version`, for example).
Uri openAiEndpoint(
  String baseUrl,
  String path,
  Map<String, String> queryParameters,
) {
  var base = baseUrl.trim();
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  final uri = Uri.parse('$base/$path');
  return queryParameters.isEmpty
      ? uri
      : uri.replace(
        queryParameters: {...uri.queryParameters, ...queryParameters},
      );
}

/// Streaming request headers. `Authorization` carries `Bearer <key>`; any
/// other [apiKeyHeader] (Azure: `api-key`) carries the raw key.
Map<String, String> openAiHeaders({
  required String? apiKey,
  required String apiKeyHeader,
  required Map<String, String> headers,
}) => {
  'Accept': 'text/event-stream',
  if (apiKey != null && apiKey.isNotEmpty)
    apiKeyHeader:
        apiKeyHeader.toLowerCase() == 'authorization'
            ? 'Bearer $apiKey'
            : apiKey,
  ...headers,
};

/// Logs a warning when [apiKey] would go over plain HTTP to a host other
/// than this machine.
void warnIfPlaintextKey(Uri uri, String? apiKey, String logName) {
  if (uri.scheme == 'http' &&
      (apiKey ?? '').isNotEmpty &&
      !isLoopbackHost(uri.host)) {
    developer.log(
      'API key will be sent over plaintext HTTP to ${uri.host}',
      name: logName,
      level: 900,
    );
  }
}

bool isLoopbackHost(String host) =>
    host == 'localhost' ||
    host == '127.0.0.1' ||
    host == '::1' ||
    host == '[::1]';
