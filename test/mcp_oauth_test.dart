import 'dart:convert';

import 'package:agentic_harness/agentic_harness.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'mcp_test.dart' show FakeServer;

/// An MCP server at https://mcp.test/mcp behind an authorization server at
/// https://auth.test, all in one [MockClient].
class FakeOAuthWorld {
  FakeOAuthWorld({
    this.issuer = 'https://auth.test',
    this.pkce = true,
    this.sendsIss = true,
    this.resource = 'https://mcp.test/mcp',
    this.tokenLifetime = 3600,
    this.claimedIssuer,
  });

  /// The `issuer` the metadata claims (defaults to [issuer]).
  final String? claimedIssuer;

  final String issuer;
  final bool pkce;
  final bool sendsIss;
  final String resource;
  final int tokenLifetime;

  final mcp = FakeServer();
  final List<http.Request> requests = [];
  final Map<String, String> codes = {}; // code -> code_challenge
  final Set<String> validTokens = {};
  String? requiredScope;
  int registrations = 0;
  int tokenCalls = 0;
  Map<String, String>? lastTokenRequest;
  int _next = 0;

  http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  late final http.Client client = MockClient((request) async {
    requests.add(request);
    final url = request.url;
    if (url.host == 'mcp.test' && url.path == '/mcp') {
      final auth = request.headers['Authorization'] ?? '';
      final token = auth.startsWith('Bearer ') ? auth.substring(7) : null;
      if (token == null || !validTokens.contains(token)) {
        return http.Response(
          '',
          401,
          headers: {
            'www-authenticate':
                'Bearer resource_metadata="https://mcp.test/.well-known/'
                'oauth-protected-resource/mcp", scope="files:read"',
          },
        );
      }
      if (requiredScope != null && !token.contains(requiredScope!)) {
        return http.Response(
          '',
          403,
          headers: {
            'www-authenticate':
                'Bearer error="insufficient_scope", scope="$requiredScope"',
          },
        );
      }
      final forwarded = await mcp.client.send(
        http.Request(request.method, url)
          ..headers.addAll(request.headers)
          ..body = request.body,
      );
      return http.Response.fromStream(forwarded);
    }
    if (url.toString() ==
        'https://mcp.test/.well-known/oauth-protected-resource/mcp') {
      return _json({
        'resource': resource,
        'authorization_servers': [issuer],
        'scopes_supported': ['files:read', 'files:write'],
      });
    }
    if (url.toString() ==
        'https://auth.test/.well-known/oauth-authorization-server') {
      return _json({
        'issuer': claimedIssuer ?? issuer,
        'authorization_endpoint': 'https://auth.test/authorize',
        'token_endpoint': 'https://auth.test/token',
        'registration_endpoint': 'https://auth.test/register',
        if (pkce) 'code_challenge_methods_supported': ['S256'],
        'authorization_response_iss_parameter_supported': sendsIss,
      });
    }
    if (url.toString() == 'https://auth.test/register') {
      registrations++;
      final body = jsonDecode(request.body) as Map;
      expect(body['token_endpoint_auth_method'], 'none');
      return _json({'client_id': 'client-$registrations'}, 201);
    }
    if (url.toString() == 'https://auth.test/token') {
      tokenCalls++;
      final form = request.bodyFields;
      lastTokenRequest = form;
      expect(form['resource'], 'https://mcp.test/mcp');
      final String scope;
      if (form['grant_type'] == 'authorization_code') {
        final challenge = codes.remove(form['code']);
        if (challenge == null) return _json({'error': 'invalid_grant'}, 400);
        final verifier = form['code_verifier']!;
        final computed = base64Url
            .encode(sha256.convert(ascii.encode(verifier)).bytes)
            .replaceAll('=', '');
        if (computed != challenge) {
          return _json({'error': 'invalid_grant'}, 400);
        }
        scope = form['scope'] ?? _pendingScope;
      } else if (form['grant_type'] == 'refresh_token') {
        if (form['refresh_token'] != 'refresh-ok') {
          return _json({'error': 'invalid_grant'}, 400);
        }
        scope = _pendingScope;
      } else {
        return _json({'error': 'unsupported_grant_type'}, 400);
      }
      final token = 'token-${_next++}-$scope';
      validTokens.add(token);
      return _json({
        'access_token': token,
        'token_type': 'Bearer',
        'expires_in': tokenLifetime,
        'refresh_token': 'refresh-ok',
        'scope': scope,
      });
    }
    return http.Response('not found', 404);
  });

  String _pendingScope = '';

  /// The browser: checks the authorization request and "approves" it.
  Future<Uri> authorize(Uri url, {String? iss, String? state}) async {
    final q = url.queryParameters;
    expect(url.path, '/authorize');
    expect(q['response_type'], 'code');
    expect(q['code_challenge_method'], 'S256');
    expect(q['resource'], 'https://mcp.test/mcp');
    _pendingScope = q['scope'] ?? '';
    final code = 'code-${_next++}';
    codes[code] = q['code_challenge']!;
    return Uri.parse(q['redirect_uri']!).replace(
      queryParameters: {
        'code': code,
        'state': state ?? q['state']!,
        if (sendsIss || iss != null) 'iss': iss ?? issuer,
      },
    );
  }
}

void main() {
  final redirect = Uri.parse('http://127.0.0.1:53682/callback');

  McpOAuth oauthFor(
    FakeOAuthWorld world, {
    Future<Uri> Function(Uri url)? authorize,
    McpOAuthStore? store,
  }) => McpOAuth(
    resource: Uri.parse('https://mcp.test/mcp'),
    redirectUri: redirect,
    authorize: authorize ?? world.authorize,
    store: store,
    httpClient: world.client,
    clientName: 'Test app',
  );

  McpClient mcpClient(FakeOAuthWorld world, McpOAuth oauth) => McpClient(
    McpHttpTransport(
      Uri.parse('https://mcp.test/mcp'),
      client: world.client,
      headerProvider: oauth.headers,
      onUnauthorized: oauth.handleChallenge,
    ),
  );

  test('a 401 signs in and the request is retried', () async {
    final world = FakeOAuthWorld();
    final store = InMemoryMcpOAuthStore();
    final oauth = oauthFor(world, store: store);
    final client = mcpClient(world, oauth);
    await client.connect();
    final tools = await client.listTools();
    expect(tools, isNotEmpty);
    expect(world.registrations, 1);
    expect(await oauth.isSignedIn, isTrue);
    // The challenge's scope was requested.
    expect(world.validTokens.single, contains('files:read'));

    // A new client with the same store reuses tokens and registration.
    final again = oauthFor(world, store: store);
    final headers = await again.headers();
    expect(headers['Authorization'], startsWith('Bearer token-'));
    await mcpClient(world, again).connect();
    expect(world.registrations, 1);
    expect(world.tokenCalls, 1);
  });

  test('an expiring token is refreshed before use', () async {
    final world = FakeOAuthWorld(tokenLifetime: 30); // under the margin
    final oauth = oauthFor(world);
    await oauth.signIn();
    expect(world.tokenCalls, 1);
    await oauth.headers();
    expect(world.tokenCalls, 2);
    expect(world.lastTokenRequest!['grant_type'], 'refresh_token');
    expect(world.lastTokenRequest!['client_id'], 'client-1');
  });

  test('a 403 insufficient_scope steps up, keeping earlier scopes', () async {
    final world = FakeOAuthWorld();
    final oauth = oauthFor(world);
    final client = mcpClient(world, oauth);
    await client.connect();
    world.requiredScope = 'files:write';
    await client.listTools();
    final scopes = world.validTokens.last.split('-').last.split(' ');
    expect(scopes, containsAll(['files:read', 'files:write']));
  });

  group('refuses', () {
    Future<void> expectRefused(
      FakeOAuthWorld world, {
      Future<Uri> Function(Uri url)? authorize,
      String? message,
    }) async {
      final oauth = oauthFor(world, authorize: authorize);
      await expectLater(
        oauth.signIn(),
        throwsA(
          isA<McpOAuthError>().having(
            (e) => e.message,
            'message',
            message == null ? anything : contains(message),
          ),
        ),
      );
      expect(world.tokenCalls, 0);
    }

    test('an authorization server without PKCE', () async {
      await expectRefused(FakeOAuthWorld(pkce: false), message: 'PKCE');
    });

    test('metadata whose issuer does not match its address', () async {
      // Metadata served for auth.test claiming another issuer.
      await expectRefused(
        FakeOAuthWorld(claimedIssuer: 'https://honest.test'),
        message: "don't match",
      );
    });

    test('resource metadata for another server', () async {
      await expectRefused(
        FakeOAuthWorld(resource: 'https://evil.test/mcp'),
        message: 'different address',
      );
    });

    test('a response with the wrong state', () async {
      final world = FakeOAuthWorld();
      await expectRefused(
        world,
        authorize: (url) => world.authorize(url, state: 'forged'),
        message: 'did not match',
      );
    });

    test('a response from another issuer (mix-up)', () async {
      final world = FakeOAuthWorld();
      await expectRefused(
        world,
        authorize: (url) => world.authorize(url, iss: 'https://evil.test'),
        message: 'different authorization server',
      );
    });

    test('a missing iss when the server promises one', () async {
      final world = FakeOAuthWorld();
      await expectRefused(
        world,
        authorize: (url) async {
          final back = await world.authorize(url);
          final q = Map.of(back.queryParameters)..remove('iss');
          return back.replace(queryParameters: q);
        },
      );
    });

    test('a redirect to a different address', () async {
      final world = FakeOAuthWorld();
      await expectRefused(
        world,
        authorize: (url) async {
          final back = await world.authorize(url);
          return back.replace(path: '/elsewhere');
        },
      );
    });
  });

  test('a pre-registered client is used only with its own issuer', () async {
    final world = FakeOAuthWorld();
    final requests = <Uri>[];
    final oauth = McpOAuth(
      resource: Uri.parse('https://mcp.test/mcp'),
      redirectUri: redirect,
      authorize: (url) {
        requests.add(url);
        return world.authorize(url);
      },
      httpClient: world.client,
      client: const McpOAuthClientInfo(
        'mine',
        issuer: 'https://other-auth.test',
        clientSecret: 'secret',
      ),
    );
    await oauth.signIn();
    // Registered dynamically instead; the secret never left.
    expect(requests.single.queryParameters['client_id'], 'client-1');
    expect(
      world.requests.any(
        (r) => (r.headers['Authorization'] ?? '').startsWith('Basic'),
      ),
      isFalse,
    );
  });

  test('allowedIssuers refuses other authorization servers', () async {
    final world = FakeOAuthWorld();
    final oauth = McpOAuth(
      resource: Uri.parse('https://mcp.test/mcp'),
      redirectUri: redirect,
      authorize: world.authorize,
      httpClient: world.client,
      allowedIssuers: {'https://trusted.test'},
    );
    await expectLater(oauth.signIn(), throwsA(isA<McpOAuthError>()));
    expect(world.codes, isEmpty); // the user was never sent anywhere
  });

  test('refresh: one request at a time; outages keep the tokens', () async {
    final world = FakeOAuthWorld(tokenLifetime: 30);
    final oauth = oauthFor(world);
    await oauth.signIn();
    await Future.wait([oauth.headers(), oauth.headers(), oauth.headers()]);
    expect(world.tokenCalls, 2); // sign-in + one shared refresh

    final failing = FakeOAuthWorld(tokenLifetime: 30);
    final down = MockClient((request) async {
      if (request.url.path == '/token' &&
          request.bodyFields['grant_type'] == 'refresh_token') {
        return http.Response('{"error":"temporarily_unavailable"}', 503);
      }
      final copy =
          http.Request(request.method, request.url)
            ..headers.addAll(request.headers)
            ..bodyBytes = request.bodyBytes;
      return failing.client.send(copy).then(http.Response.fromStream);
    });
    final kept = McpOAuth(
      resource: Uri.parse('https://mcp.test/mcp'),
      redirectUri: redirect,
      authorize: failing.authorize,
      httpClient: down,
    );
    await kept.signIn();
    final headers = await kept.headers();
    expect(headers['Authorization'], startsWith('Bearer'));
    expect(await kept.isSignedIn, isTrue);
  });

  test('a server that keeps refusing gets one sign-in per cooldown', () async {
    final world = FakeOAuthWorld();
    var signIns = 0;
    final oauth = oauthFor(
      world,
      authorize: (url) {
        signIns++;
        return world.authorize(url);
      },
    );
    const challenge = McpAuthChallenge(statusCode: 401);
    expect(await oauth.handleChallenge(challenge), isTrue);
    world.validTokens.clear(); // the server forgets every token
    expect(await oauth.handleChallenge(challenge), isTrue); // refresh
    expect(await oauth.handleChallenge(challenge), isFalse);
    expect(signIns, 1);
  });

  test('discovered URLs must be https for a remote server', () async {
    final world = FakeOAuthWorld();
    final oauth = oauthFor(world);
    await expectLater(
      oauth.signIn(
        challenge: McpAuthChallenge.parse(
          401,
          'Bearer resource_metadata="http://127.0.0.1:8080/admin"',
        ),
      ),
      throwsA(isA<McpOAuthError>()),
    );
    expect(world.requests.where((r) => r.url.host == '127.0.0.1'), isEmpty);
  });

  test('redirect URIs must be https or loopback', () {
    expect(
      () => McpOAuth(
        resource: Uri.parse('https://mcp.test/mcp'),
        redirectUri: Uri.parse('http://example.com/cb'),
        authorize: (_) async => Uri(),
      ),
      throwsArgumentError,
    );
  });

  test('challenge headers are parsed', () {
    final c = McpAuthChallenge.parse(
      403,
      'Bearer error="insufficient_scope", scope="a b", '
      'resource_metadata="https://x.test/.well-known/oauth-protected-resource"',
    );
    expect(c.insufficientScope, isTrue);
    expect(c.scope, 'a b');
    expect(c.resourceMetadata, contains('x.test'));
    expect(McpAuthChallenge.parse(401, null).resourceMetadata, isNull);
  });
}
