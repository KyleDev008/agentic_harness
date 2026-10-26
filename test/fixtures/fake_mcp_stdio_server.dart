// A legacy (initialize-based) MCP server over stdio, for tests.
import 'dart:convert';
import 'dart:io';

void main() {
  var initialized = false;
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    final message = jsonDecode(line) as Map<String, Object?>;
    final id = message['id'];
    final method = message['method'];
    final params = (message['params'] as Map?) ?? const {};
    void reply(Map<String, Object?> body) =>
        stdout.writeln(jsonEncode({'jsonrpc': '2.0', 'id': id, ...body}));

    if (id == null) {
      if (method == 'notifications/initialized') initialized = true;
      return;
    }
    switch (method) {
      case 'initialize':
        reply({
          'result': {
            'protocolVersion': '2025-06-18',
            'capabilities': {'tools': <String, Object?>{}},
            'serverInfo': {'name': 'stdio-fake', 'version': '0.1'},
          },
        });
      case 'tools/list' when initialized:
        reply({
          'result': {
            'tools': [
              {
                'name': 'shout',
                'description': 'Upper-cases text',
                'inputSchema': {
                  'type': 'object',
                  'properties': {
                    'text': {'type': 'string'},
                  },
                },
              },
            ],
          },
        });
      case 'tools/call' when initialized && params['name'] == 'bye':
        reply({
          'result': {
            'content': [
              {'type': 'text', 'text': 'bye'},
            ],
          },
        });
        stdout.flush().then((_) => exit(0));
      case 'tools/call' when initialized:
        final args = params['arguments'] as Map;
        reply({
          'result': {
            'content': [
              {'type': 'text', 'text': '${args['text']}'.toUpperCase()},
            ],
          },
        });
      default:
        reply({
          'error': {'code': -32601, 'message': 'Method not found: $method'},
        });
    }
  });
}
