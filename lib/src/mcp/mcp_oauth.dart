import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Stores an [McpOAuth] client's tokens and registration between app runs.
///
/// Values are secrets (access and refresh tokens, client secrets): keep
/// them in the platform's secure storage, never in plain preferences.
/// `null` deletes a value.
abstract interface class McpOAuthStore {
  Future<String?> read(String key);
  Future<void> write(String key, String? value);
}

/// An [McpOAuthStore] that forgets everything when the process ends.
final class InMemoryMcpOAuthStore implements McpOAuthStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
  }
}

/// A client registered with the authorization server ahead of time.
final class McpOAuthClientInfo {
  final String clientId;

  /// Only for confidential clients; apps on users' devices have none.
  final String? clientSecret;

  /// The authorization server (its `issuer`) this client is registered
  /// with. It is used only there, so a server that names another
  /// authorization server never receives it.
  final String issuer;

  const McpOAuthClientInfo(
    this.clientId, {
    required this.issuer,
    this.clientSecret,
  });

  Map<String, Object?> toJson() => {
    'clientId': clientId,
    'issuer': issuer,
    if (clientSecret != null) 'clientSecret': clientSecret,
  };

  static McpOAuthClientInfo? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['clientId'];
    final secret = json['clientSecret'];
    final issuer = json['issuer'];
    if (id is! String || id.isEmpty || issuer is! String) return null;
    return McpOAuthClientInfo(
      id,
      issuer: issuer,
      clientSecret: secret is String ? secret : null,
    );
  }
}

/// Why sign-in couldn't complete. [message] is safe to show the user.
final class McpOAuthError implements Exception {
  final String message;

  /// The OAuth `error` code from the authorization server, if any.
  final String? code;

  /// HTTP status of the failed request, if any.
  final int? statusCode;

  const McpOAuthError(this.message, {this.code, this.statusCode});
  @override
  String toString() => 'McpOAuthError: $message';
}

/// A `WWW-Authenticate: Bearer …` challenge from an MCP server.
final class McpAuthChallenge {
  final int statusCode;
  final String? resourceMetadata;
  final String? scope;
  final String? error;

  const McpAuthChallenge({
    required this.statusCode,
    this.resourceMetadata,
    this.scope,
    this.error,
  });

  /// Parses the `Bearer` parameters of a `WWW-Authenticate` header.
  factory McpAuthChallenge.parse(int statusCode, String? header) {
    final params = <String, String>{};
    if (header != null) {
      final bearer = RegExp(
        r'bearer\s+',
        caseSensitive: false,
      ).firstMatch(header);
      final rest = bearer == null ? header : header.substring(bearer.end);
      for (final m in RegExp(
        r'([A-Za-z_]+)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^\s,]+))',
      ).allMatches(rest)) {
        final key = m.group(1)!.toLowerCase();
        final value =
            m
                .group(2)
                ?.replaceAllMapped(RegExp(r'\\(.)'), (e) => e.group(1)!) ??
            m.group(3)!;
        params.putIfAbsent(key, () => value);
      }
    }
    return McpAuthChallenge(
      statusCode: statusCode,
      resourceMetadata: params['resource_metadata'],
      scope: params['scope'],
      error: params['error'],
    );
  }

  /// A 403 asking for more scopes (step-up authorization).
  bool get insufficientScope =>
      statusCode == 403 && error == 'insufficient_scope';
}

/// OAuth 2.1 sign-in for one MCP server, following the MCP authorization
/// spec (2026-07-28): protected resource metadata (RFC 9728),
/// authorization server discovery (RFC 8414 / OpenID Connect), PKCE with
/// S256, resource indicators (RFC 8707), `iss` checks (RFC 9207), and
/// client registration by [client], a [clientMetadataUrl] (Client ID
/// Metadata Document) or dynamic registration, in that order.
///
/// Wire it into the transport:
///
/// ```dart
/// final oauth = McpOAuth(
///   resource: endpoint,
///   redirectUri: Uri.parse('http://127.0.0.1:53682/callback'),
///   authorize: (url) => openBrowserAndWaitForRedirect(url),
///   store: mySecureStore,
/// );
/// final transport = McpHttpTransport(
///   endpoint,
///   headerProvider: oauth.headers,
///   onUnauthorized: oauth.handleChallenge,
/// );
/// ```
///
/// [authorize] opens [Uri] (the authorization page) for the user and
/// completes with the full redirect URI the browser was sent to. Show the
/// user both the MCP server's host and the authorization page's host
/// before they sign in: the MCP server chooses the authorization server,
/// so a hostile one could send them to a look-alike or to a real provider
/// they didn't expect. [allowedIssuers] limits which ones may be used.
///
/// Every discovered URL must be https (loopback http only for a loopback
/// [resource]); [redirectUri] must be https or a loopback address. Pass
/// [urlGuard] so discovered URLs can't reach internal addresses.
class McpOAuth {
  /// The MCP endpoint the tokens are for.
  final Uri resource;
  final Uri redirectUri;
  final Future<Uri> Function(Uri authorizationUrl) authorize;
  final McpOAuthStore store;

  /// Pre-registered client, used first when the authorization server is
  /// the one it names ([McpOAuthClientInfo.issuer]).
  final McpOAuthClientInfo? client;

  /// When set, only these authorization servers (`issuer` values) may be
  /// used; any other is refused before the user is sent anywhere.
  final Set<String>? allowedIssuers;

  /// Shortest time between sign-ins started by [handleChallenge], so a
  /// server that keeps refusing tokens can't keep opening sign-in pages.
  final Duration signInCooldown;

  /// An https URL serving this app's Client ID Metadata Document, used
  /// when the authorization server supports them.
  final Uri? clientMetadataUrl;

  /// Shown on the authorization server's consent page (dynamic
  /// registration).
  final String clientName;

  /// Checked before every request to a discovered URL; pass
  /// `const NetGuard().check` (from `io_tools.dart`) so a server's
  /// metadata can't point requests at internal addresses.
  final FutureOr<void> Function(Uri url)? urlGuard;

  /// Refresh this long before the access token expires.
  final Duration refreshMargin;
  final Duration timeout;

  final http.Client _http;
  final bool _ownsHttp;
  final Random _random;

  Future<void>? _signingIn;
  Future<bool>? _refreshing;
  _Tokens? _tokens;
  bool _loaded = false;

  /// When [handleChallenge] last started a sign-in.
  DateTime? _lastChallengeSignIn;

  /// Access tokens a 401 already led to a refresh for.
  final Set<String> _refreshedFor401 = {};

  McpOAuth({
    required this.resource,
    required this.redirectUri,
    required this.authorize,
    McpOAuthStore? store,
    this.client,
    this.allowedIssuers,
    this.signInCooldown = const Duration(minutes: 1),
    this.clientMetadataUrl,
    this.clientName = 'MCP client',
    this.urlGuard,
    this.refreshMargin = const Duration(minutes: 1),
    this.timeout = const Duration(seconds: 30),
    http.Client? httpClient,
    Random? random,
  }) : store = store ?? InMemoryMcpOAuthStore(),
       _http = httpClient ?? http.Client(),
       _ownsHttp = httpClient == null,
       _random = random ?? Random.secure() {
    if (!_secureOrLoopback(resource)) {
      throw ArgumentError.value(
        resource,
        'resource',
        'must be https or a loopback address',
      );
    }
    if (!_secureOrLoopback(redirectUri)) {
      throw ArgumentError.value(
        redirectUri,
        'redirectUri',
        'must be https or a loopback address',
      );
    }
    if (clientMetadataUrl case final url?
        when url.scheme != 'https' || url.path.isEmpty || url.path == '/') {
      throw ArgumentError.value(
        url,
        'clientMetadataUrl',
        'must be an https URL with a path',
      );
    }
  }

  /// The canonical resource identifier (RFC 8707): no fragment, no
  /// trailing slash on an empty path.
  String get resourceId {
    final r = resource.removeFragment();
    var text = r.toString();
    if (r.path == '/' && !r.hasQuery) text = text.substring(0, text.length - 1);
    return text;
  }

  String get _storeKey => 'mcp_oauth:$resourceId';

  /// Whether tokens are stored for this server.
  Future<bool> get isSignedIn async {
    await _load();
    return _tokens != null;
  }

  /// `Authorization` for the next request (refreshing an expiring token),
  /// or nothing before sign-in. Use as `McpHttpTransport.headerProvider`.
  Future<Map<String, String>> headers() async {
    await _load();
    var tokens = _tokens;
    if (tokens == null) return const {};
    if (tokens.expiresSoon(refreshMargin) && tokens.refreshToken != null) {
      await _refresh();
      tokens = _tokens;
      if (tokens == null) return const {};
    }
    return {'Authorization': 'Bearer ${tokens.accessToken}'};
  }

  /// Handles a 401 (or a 403 `insufficient_scope`): refreshes the token or
  /// signs in, then returns whether to retry the request. Use as
  /// `McpHttpTransport.onUnauthorized`.
  Future<bool> handleChallenge(McpAuthChallenge challenge) async {
    if (challenge.statusCode == 403 && !challenge.insufficientScope) {
      return false;
    }
    await _load();
    // A sign-in already under way (another request's 401): use its token.
    if (_signingIn case final running?) {
      await running;
      return true;
    }
    final tokens = _tokens;
    if (challenge.statusCode == 401 &&
        tokens?.refreshToken != null &&
        _refreshedFor401.add(tokens!.accessToken)) {
      if (await _refresh()) {
        _refreshedFor401.add(_tokens!.accessToken);
        return true;
      }
    }
    // Asking for scopes not granted yet is new information; anything else
    // within the cooldown is a server that keeps refusing.
    final granted = {...?_tokens?.scope?.split(' ')};
    final wantsMore =
        challenge.insufficientScope &&
        (challenge.scope ?? '')
            .split(' ')
            .any((s) => s.isNotEmpty && !granted.contains(s));
    final last = _lastChallengeSignIn;
    if (!wantsMore &&
        last != null &&
        DateTime.now().difference(last) < signInCooldown) {
      return false;
    }
    _lastChallengeSignIn = DateTime.now();
    await signIn(challenge: challenge);
    return true;
  }

  /// Runs the authorization code flow (opening [authorize]) and stores the
  /// tokens. Concurrent calls share one sign-in. Throws [McpOAuthError].
  Future<void> signIn({McpAuthChallenge? challenge}) {
    final running = _signingIn;
    if (running != null) return running;
    final work = _signIn(challenge);
    _signingIn = work;
    return work.whenComplete(() => _signingIn = null);
  }

  /// Forgets the tokens (the client registration is kept).
  Future<void> signOut() async {
    await _load();
    _tokens = null;
    await _save();
  }

  void close() {
    if (_ownsHttp) _http.close();
  }

  // ── Flow ─────────────────────────────────────────────────────────────

  Future<void> _signIn(McpAuthChallenge? challenge) async {
    await _load();
    final resourceMeta = await _protectedResource(challenge?.resourceMetadata);
    final issuer = resourceMeta.authorizationServer;
    if (allowedIssuers case final allowed? when !allowed.contains(issuer)) {
      throw McpOAuthError(
        'This server uses an authorization server that isn\'t allowed '
        '(${Uri.tryParse(issuer)?.host ?? 'unknown'}).',
      );
    }
    final server = await _authorizationServer(issuer);
    final registered = await _clientFor(server);

    // Scopes: the challenge first, then what the resource advertises;
    // keep previously granted ones on a step-up.
    final scopes = <String>{
      if (challenge?.insufficientScope ?? false)
        ...?_tokens?.scope?.split(' ').where((s) => s.isNotEmpty),
      ...?(challenge?.scope ?? resourceMeta.scopes?.join(' '))
          ?.split(' ')
          .where((s) => s.isNotEmpty),
    };

    final verifier = _randomToken(48);
    final state = _randomToken(24);
    final authUrl = server.authorizationEndpoint.replace(
      queryParameters: {
        ...server.authorizationEndpoint.queryParameters,
        'response_type': 'code',
        'client_id': registered.clientId,
        'redirect_uri': '$redirectUri',
        'code_challenge': _s256(verifier),
        'code_challenge_method': 'S256',
        'state': state,
        'resource': resourceId,
        if (scopes.isNotEmpty) 'scope': scopes.join(' '),
      },
    );
    final redirect = await authorize(authUrl);
    final params = redirect.queryParameters;
    if (!_sameEndpoint(redirect, redirectUri)) {
      throw const McpOAuthError(
        'The sign-in returned to an unexpected address.',
      );
    }
    if (params['state'] != state) {
      throw const McpOAuthError(
        'The sign-in response did not match this request.',
      );
    }
    if (params['error'] case final error?) {
      final safe = _safeCode(error);
      throw McpOAuthError(
        error == 'access_denied'
            ? 'Sign-in was cancelled.'
            : safe != null
            ? 'The server refused the sign-in ($safe).'
            : 'The server refused the sign-in.',
        code: safe,
      );
    }
    // RFC 9207: a present iss must match exactly; a missing one is only
    // allowed when the server doesn't promise to send it.
    final iss = params['iss'];
    if (iss != null ? iss != server.issuer : server.sendsIss) {
      throw const McpOAuthError(
        'The sign-in response came from a different authorization server.',
      );
    }
    final code = params['code'];
    if (code == null || code.isEmpty) {
      throw const McpOAuthError('The sign-in response had no code.');
    }
    final tokens = await _tokenRequest(server, registered, {
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': '$redirectUri',
      'code_verifier': verifier,
    }, requested: scopes);
    _tokens = tokens;
    await _save();
  }

  /// Refreshes the access token; concurrent callers share one request,
  /// so a rotating refresh token is used once.
  Future<bool> _refresh() {
    final running = _refreshing;
    if (running != null) return running;
    final tokens = _tokens;
    if (tokens == null || tokens.refreshToken == null) {
      return Future.value(false);
    }
    final work = _refreshNow(tokens);
    _refreshing = work;
    return work.whenComplete(() => _refreshing = null);
  }

  Future<bool> _refreshNow(_Tokens tokens) async {
    final server = tokens.server;
    final registered = tokens.client;
    if (server == null || registered == null) return false;
    try {
      final next = await _tokenRequest(
        server,
        registered,
        {'grant_type': 'refresh_token', 'refresh_token': tokens.refreshToken!},
        requested: tokens.scope?.split(' ').toSet() ?? const {},
        previous: tokens,
      );
      _tokens = next;
      await _save();
      return true;
    } on McpOAuthError catch (e) {
      // Only a refused grant means the refresh token is no longer good;
      // anything else (an outage, a rate limit) keeps it for next time.
      if (const {
        'invalid_grant',
        'invalid_client',
        'unauthorized_client',
      }.contains(e.code)) {
        _tokens = null;
        await _save();
      }
      return false;
    } on TimeoutException {
      return false;
    } on http.ClientException {
      return false;
    }
  }

  Future<_Tokens> _tokenRequest(
    _AuthServer server,
    McpOAuthClientInfo registered,
    Map<String, String> grant, {
    required Set<String> requested,
    _Tokens? previous,
  }) async {
    final secret = registered.clientSecret;
    final body = {
      ...grant,
      'resource': resourceId,
      if (secret == null) 'client_id': registered.clientId,
    };
    final json = await _postForm(
      server.tokenEndpoint,
      body,
      headers: {
        if (secret != null)
          'Authorization':
              'Basic ${base64.encode(utf8.encode('${Uri.encodeQueryComponent(registered.clientId)}:${Uri.encodeQueryComponent(secret)}'))}',
      },
    );
    final access = json['access_token'];
    final type = json['token_type'];
    if (access is! String || access.isEmpty) {
      throw const McpOAuthError(
        'The authorization server sent no access token.',
      );
    }
    if (type is! String || type.toLowerCase() != 'bearer') {
      throw const McpOAuthError(
        'The authorization server sent an unsupported token type.',
      );
    }
    final expiresIn = json['expires_in'];
    final refresh = json['refresh_token'];
    final scope = json['scope'];
    return _Tokens(
      accessToken: access,
      refreshToken:
          refresh is String && refresh.isNotEmpty
              ? refresh
              : previous?.refreshToken,
      expiresAt:
          expiresIn is num && expiresIn > 0
              ? DateTime.now().toUtc().add(Duration(seconds: expiresIn.toInt()))
              : null,
      scope:
          scope is String
              ? scope
              : (requested.isEmpty ? previous?.scope : requested.join(' ')),
      server: server,
      client: registered,
    );
  }

  // ── Discovery ────────────────────────────────────────────────────────

  Future<_ResourceMeta> _protectedResource(String? fromChallenge) async {
    Uri? challenged;
    if (fromChallenge != null) {
      challenged = Uri.tryParse(fromChallenge);
      if (challenged == null || challenged.host.isEmpty) {
        throw const McpOAuthError(
          'The server sent an invalid sign-in details address.',
        );
      }
    }
    final candidates = <Uri>[
      if (challenged != null) challenged,
      if (challenged == null) ...[
        if (resource.path.isNotEmpty && resource.path != '/')
          resource.replace(
            path: '/.well-known/oauth-protected-resource${resource.path}',
            query: null,
            fragment: null,
          ),
        resource.replace(
          path: '/.well-known/oauth-protected-resource',
          query: null,
          fragment: null,
        ),
      ],
    ];
    for (final url in candidates) {
      final json = await _getJson(url, optional: fromChallenge == null);
      if (json == null) continue;
      // RFC 9728 §3.3: the document must describe this resource.
      final described = json['resource'];
      if (described is! String || !_sameResource(described)) {
        throw const McpOAuthError(
          'The server\'s sign-in details are for a different address.',
        );
      }
      final servers = json['authorization_servers'];
      final first =
          servers is List ? servers.whereType<String>().firstOrNull : null;
      if (first == null) {
        throw const McpOAuthError('The server names no authorization server.');
      }
      final scopes = json['scopes_supported'];
      return _ResourceMeta(
        first,
        scopes is List ? scopes.whereType<String>().toList() : null,
      );
    }
    throw const McpOAuthError('The server does not say how to sign in.');
  }

  Future<_AuthServer> _authorizationServer(String issuer) async {
    final base = Uri.tryParse(issuer);
    if (base == null || base.scheme != 'https' || base.host.isEmpty) {
      throw const McpOAuthError(
        'The authorization server address is not https.',
      );
    }
    final path = base.path == '/' ? '' : base.path;
    final candidates =
        path.isEmpty
            ? [
              base.replace(path: '/.well-known/oauth-authorization-server'),
              base.replace(path: '/.well-known/openid-configuration'),
            ]
            : [
              base.replace(
                path: '/.well-known/oauth-authorization-server$path',
              ),
              base.replace(path: '/.well-known/openid-configuration$path'),
              base.replace(path: '$path/.well-known/openid-configuration'),
            ];
    for (final url in candidates) {
      final json = await _getJson(url, optional: true);
      if (json == null) continue;
      if (json['issuer'] != issuer) {
        throw const McpOAuthError(
          'The authorization server\'s details don\'t match its address.',
        );
      }
      final methods = json['code_challenge_methods_supported'];
      if (methods is! List || !methods.contains('S256')) {
        throw const McpOAuthError(
          'The authorization server doesn\'t support secure sign-in (PKCE).',
        );
      }
      Uri endpoint(String key, {bool required = true}) {
        final value = json[key];
        final uri = value is String ? Uri.tryParse(value) : null;
        if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
          if (!required && value == null) return Uri();
          throw McpOAuthError('The authorization server\'s $key is not https.');
        }
        return uri;
      }

      final registration = endpoint('registration_endpoint', required: false);
      return _AuthServer(
        issuer: issuer,
        authorizationEndpoint: endpoint('authorization_endpoint'),
        tokenEndpoint: endpoint('token_endpoint'),
        registrationEndpoint: registration.hasScheme ? registration : null,
        supportsClientMetadata:
            json['client_id_metadata_document_supported'] == true,
        sendsIss:
            json['authorization_response_iss_parameter_supported'] == true,
      );
    }
    throw const McpOAuthError(
      'Could not find the authorization server\'s details.',
    );
  }

  Future<McpOAuthClientInfo> _clientFor(_AuthServer server) async {
    if (client case final c? when c.issuer == server.issuer) return c;
    if (server.supportsClientMetadata && clientMetadataUrl != null) {
      return McpOAuthClientInfo('$clientMetadataUrl', issuer: server.issuer);
    }
    // Per redirect URI: a registration names the redirect it allows.
    final key = 'mcp_oauth_client:${server.issuer} $redirectUri';
    final stored = McpOAuthClientInfo.fromJson(
      _tryDecode(await store.read(key)),
    );
    if (stored != null && stored.issuer == server.issuer) return stored;
    final endpoint = server.registrationEndpoint;
    if (endpoint == null) {
      throw const McpOAuthError(
        'The authorization server needs a registered app; this one isn\'t.',
      );
    }
    final json = await _postJson(endpoint, {
      'client_name': clientName,
      'redirect_uris': ['$redirectUri'],
      'grant_types': ['authorization_code', 'refresh_token'],
      'response_types': ['code'],
      'token_endpoint_auth_method': 'none',
    });
    final id = json['client_id'];
    if (id is! String || id.isEmpty) {
      throw const McpOAuthError(
        'The authorization server did not register this app.',
      );
    }
    final secret = json['client_secret'];
    final registered = McpOAuthClientInfo(
      id,
      issuer: server.issuer,
      clientSecret: secret is String && secret.isNotEmpty ? secret : null,
    );
    await store.write(key, jsonEncode(registered.toJson()));
    return registered;
  }

  // ── HTTP ─────────────────────────────────────────────────────────────

  static const _maxBody = 256 * 1024;

  Future<Map<String, Object?>?> _getJson(
    Uri url, {
    required bool optional,
  }) async {
    final response = await _send(
      http.Request('GET', url)..headers['Accept'] = 'application/json',
    );
    if (optional && (response.$1 == 404 || response.$1 == 405)) return null;
    if (response.$1 != 200) {
      throw McpOAuthError('${url.host} answered HTTP ${response.$1}.');
    }
    final json = _tryDecode(response.$2);
    if (json is! Map<String, Object?>) {
      throw McpOAuthError('${url.host} sent invalid sign-in details.');
    }
    return json;
  }

  Future<Map<String, Object?>> _postForm(
    Uri url,
    Map<String, String> body, {
    Map<String, String> headers = const {},
  }) async {
    final request =
        http.Request('POST', url)
          ..headers.addAll(headers)
          ..headers['Accept'] = 'application/json'
          ..bodyFields = body;
    return _jsonResult(url, await _send(request));
  }

  Future<Map<String, Object?>> _postJson(
    Uri url,
    Map<String, Object?> body,
  ) async {
    final request =
        http.Request('POST', url)
          ..headers['Content-Type'] = 'application/json'
          ..headers['Accept'] = 'application/json'
          ..body = jsonEncode(body);
    return _jsonResult(url, await _send(request));
  }

  Map<String, Object?> _jsonResult(Uri url, (int, String) response) {
    final json = _tryDecode(response.$2);
    if (response.$1 >= 200 &&
        response.$1 < 300 &&
        json is Map<String, Object?>) {
      return json;
    }
    final error = json is Map ? json['error'] : null;
    final code = error is String ? _safeCode(error) : null;
    throw McpOAuthError(
      code != null
          ? 'The authorization server refused the request ($code).'
          : '${url.host} answered HTTP ${response.$1}.',
      code: code,
      statusCode: response.$1,
    );
  }

  Future<(int, String)> _send(http.Request request) async {
    final url = request.url;
    // Plain http only to this machine, and only for a server on this
    // machine (local development): never to reach local services from a
    // remote server's metadata.
    if (url.scheme != 'https' &&
        !(url.scheme == 'http' &&
            _isLoopback(url.host) &&
            _isLoopback(resource.host))) {
      throw McpOAuthError('Refused a non-https sign-in address (${url.host}).');
    }
    if (urlGuard case final guard?) {
      try {
        await guard(url);
      } catch (e) {
        throw McpOAuthError('Refused ${url.host}: $e');
      }
    }
    request.followRedirects = false;
    final response = await _http.send(request).timeout(timeout);
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(timeout)) {
      bytes.addAll(chunk);
      if (bytes.length > _maxBody) {
        throw McpOAuthError('${url.host} sent too much data.');
      }
    }
    return (response.statusCode, utf8.decode(bytes, allowMalformed: true));
  }

  // ── Storage ──────────────────────────────────────────────────────────

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    _tokens = _Tokens.fromJson(_tryDecode(await store.read(_storeKey)));
  }

  Future<void> _save() => store.write(
    _storeKey,
    _tokens == null ? null : jsonEncode(_tokens!.toJson()),
  );

  // ── Helpers ──────────────────────────────────────────────────────────

  String _randomToken(int bytes) => base64Url
      .encode(List<int>.generate(bytes, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  static String _s256(String verifier) => base64Url
      .encode(sha256.convert(ascii.encode(verifier)).bytes)
      .replaceAll('=', '');

  bool _sameResource(String described) {
    String norm(String s, {bool originOnly = false}) {
      final u = Uri.tryParse(s);
      if (u == null) return s;
      final path = originOnly || u.path == '/' ? '' : u.path;
      return '${u.scheme.toLowerCase()}://${u.host.toLowerCase()}'
          '${u.hasPort ? ':${u.port}' : ''}$path';
    }

    final got = norm(described);
    // This exact server, or its whole origin (a root metadata document
    // that only the host's owner can serve) — never a path in between,
    // which on a shared host another tenant could own.
    return got == norm(resourceId) || got == norm(resourceId, originOnly: true);
  }

  /// [code] when it looks like an OAuth error code (safe to show).
  static String? _safeCode(String code) =>
      RegExp(r'^[a-z0-9_.-]{1,64}$').hasMatch(code) ? code : null;

  static bool _sameEndpoint(Uri a, Uri b) =>
      a.scheme == b.scheme &&
      a.host == b.host &&
      a.port == b.port &&
      a.path == b.path;

  static bool _secureOrLoopback(Uri uri) =>
      uri.scheme == 'https' || (uri.scheme == 'http' && _isLoopback(uri.host));

  static bool _isLoopback(String host) =>
      host == 'localhost' ||
      host == '127.0.0.1' ||
      host == '::1' ||
      host == '[::1]';

  static Object? _tryDecode(String? text) {
    if (text == null) return null;
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }
}

final class _ResourceMeta {
  final String authorizationServer;
  final List<String>? scopes;
  const _ResourceMeta(this.authorizationServer, this.scopes);
}

final class _AuthServer {
  final String issuer;
  final Uri authorizationEndpoint;
  final Uri tokenEndpoint;
  final Uri? registrationEndpoint;
  final bool supportsClientMetadata;
  final bool sendsIss;

  const _AuthServer({
    required this.issuer,
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    required this.registrationEndpoint,
    required this.supportsClientMetadata,
    required this.sendsIss,
  });

  Map<String, Object?> toJson() => {
    'issuer': issuer,
    'authorizationEndpoint': '$authorizationEndpoint',
    'tokenEndpoint': '$tokenEndpoint',
    'sendsIss': sendsIss,
  };

  static _AuthServer? fromJson(Object? json) {
    if (json is! Map) return null;
    final issuer = json['issuer'];
    final auth = Uri.tryParse('${json['authorizationEndpoint']}');
    final token = Uri.tryParse('${json['tokenEndpoint']}');
    if (issuer is! String || auth == null || token == null) return null;
    if (auth.scheme != 'https' || token.scheme != 'https') return null;
    return _AuthServer(
      issuer: issuer,
      authorizationEndpoint: auth,
      tokenEndpoint: token,
      registrationEndpoint: null,
      supportsClientMetadata: false,
      sendsIss: json['sendsIss'] == true,
    );
  }
}

final class _Tokens {
  final String accessToken;
  final String? refreshToken;
  final DateTime? expiresAt;
  final String? scope;

  /// Where to refresh, kept with the tokens.
  final _AuthServer? server;
  final McpOAuthClientInfo? client;

  _Tokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.scope,
    required this.server,
    required this.client,
  });

  bool expiresSoon(Duration margin) {
    final at = expiresAt;
    return at != null && DateTime.now().toUtc().add(margin).isAfter(at);
  }

  Map<String, Object?> toJson() => {
    'accessToken': accessToken,
    if (refreshToken != null) 'refreshToken': refreshToken,
    if (expiresAt != null) 'expiresAt': expiresAt!.toIso8601String(),
    if (scope != null) 'scope': scope,
    if (server != null) 'server': server!.toJson(),
    if (client != null) 'client': client!.toJson(),
  };

  static _Tokens? fromJson(Object? json) {
    if (json is! Map) return null;
    final access = json['accessToken'];
    if (access is! String || access.isEmpty) return null;
    final refresh = json['refreshToken'];
    final expires = json['expiresAt'];
    final scope = json['scope'];
    return _Tokens(
      accessToken: access,
      refreshToken: refresh is String ? refresh : null,
      expiresAt: expires is String ? DateTime.tryParse(expires) : null,
      scope: scope is String ? scope : null,
      server: _AuthServer.fromJson(json['server']),
      client: McpOAuthClientInfo.fromJson(json['client']),
    );
  }
}
