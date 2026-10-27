import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'auth.dart';

/// Wire-contract error, mirroring app/static/api.js ApiError + errText:
/// `detail` is a string, a FastAPI 422 array, or an object.
class ApiError implements Exception {
  ApiError(this.status, this.detail);

  final int status;
  final Object? detail;

  String get message {
    final d = detail;
    if (d is String) return d;
    if (d is List) {
      return d.map((e) {
        if (e is Map) {
          final loc = ((e['loc'] as List?) ?? const [])
              .where((p) => p != 'body')
              .join('.');
          return '$loc: ${e['msg']}';
        }
        return e.toString();
      }).join('; ');
    }
    if (d is Map && d.isNotEmpty) {
      return d.entries.map((e) => '${e.key}: ${e.value}').join('; ');
    }
    return 'Request failed ($status)';
  }

  @override
  String toString() => message;
}

/// Abstract JSON API. [HttpApiClient] talks to the Paydown server; tests use
/// [FakeApiClient] (api/fake.dart). Methods return decoded JSON: Map, List,
/// or null for 204.
abstract class ApiClient {
  Future<dynamic> get(String path);
  Future<dynamic> post(String path, [Map<String, dynamic>? body]);
  Future<dynamic> put(String path, [Map<String, dynamic>? body]);
  Future<dynamic> delete(String path);
}

/// "example.com/" -> "https://example.com"; "http://10.0.2.2:8485/" ->
/// "http://10.0.2.2:8485". Returns null when there is no usable host.
String? normalizeBaseUrl(String input) {
  var t = input.trim();
  if (t.isEmpty) return null;
  if (!t.contains('://')) t = 'https://$t';
  while (t.endsWith('/')) {
    t = t.substring(0, t.length - 1);
  }
  final uri = Uri.tryParse(t);
  if (uri == null ||
      uri.host.isEmpty ||
      !(uri.scheme == 'https' || uri.scheme == 'http')) {
    return null;
  }
  return t;
}

class HttpApiClient implements ApiClient {
  /// [credentials], when given, is used instead of [auth] — the login screen
  /// validates typed credentials before anything is persisted.
  HttpApiClient({
    required String baseUrl,
    required this.auth,
    this.credentials,
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
    this.onUnauthorized,
  })  : baseUrl = normalizeBaseUrl(baseUrl) ?? baseUrl,
        _http = client ?? http.Client();

  final String baseUrl;
  final AuthStore auth;
  final Credentials? credentials;
  final Duration timeout;
  final http.Client _http;

  /// Called on any 401: the stored credentials no longer work (password
  /// changed on the server). The session root signs out so the user lands
  /// on the login screen instead of a wall of Retry buttons.
  final void Function()? onUnauthorized;

  /// Releases pooled connections. Call when the session ends.
  void close() => _http.close();

  Future<http.Response> _send(String method, String path,
      [Map<String, dynamic>? body]) async {
    final creds = credentials ?? await auth.read();
    if (creds == null) throw ApiError(401, 'Not signed in');
    final uri = Uri.parse('$baseUrl$path');
    final headers = <String, String>{
      // D4 (budget repo docs/API1.md): never set Origin — the CSRF guard
      // passes origin-less clients and blocks foreign origins.
      'Authorization':
          'Basic ${base64Encode(utf8.encode('${creds.user}:${creds.password}'))}',
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json',
    };
    final encoded = body == null ? null : jsonEncode(body);
    late http.Response res;
    try {
      res = await switch (method) {
        'GET' => _http.get(uri, headers: headers),
        'POST' => _http.post(uri, headers: headers, body: encoded),
        'PUT' => _http.put(uri, headers: headers, body: encoded),
        'DELETE' => _http.delete(uri, headers: headers),
        _ => throw ArgumentError(method),
      }
          .timeout(timeout);
    } on TimeoutException {
      throw ApiError(0, 'The server took too long to respond.');
    } on HandshakeException {
      throw ApiError(0, 'Secure connection failed — check the server URL.');
    } on SocketException {
      throw ApiError(0, 'Network error — is the server reachable?');
    } on http.ClientException {
      throw ApiError(0, 'Network error — is the server reachable?');
    }
    if (res.statusCode >= 400) {
      Object? detail = res.reasonPhrase;
      try {
        final decoded = jsonDecode(res.body);
        if (decoded is Map && decoded.containsKey('detail')) {
          detail = decoded['detail'];
        }
      } on FormatException {/* non-JSON error body: keep reasonPhrase */}
      if (res.statusCode == 401) {
        detail = 'Wrong user or password.';
        onUnauthorized?.call();
      }
      throw ApiError(res.statusCode, detail);
    }
    return res;
  }

  Future<dynamic> _json(String method, String path,
      [Map<String, dynamic>? body]) async {
    final res = await _send(method, path, body);
    if (res.statusCode == 204 || res.body.isEmpty) return null;
    try {
      return jsonDecode(res.body);
    } on FormatException {
      // A proxy/captive-portal HTML page answering 200 instead of the API.
      throw ApiError(res.statusCode,
          'Unexpected response from the server — is this a Paydown URL?');
    }
  }

  @override
  Future<dynamic> get(String path) => _json('GET', path);

  @override
  Future<dynamic> post(String path, [Map<String, dynamic>? body]) =>
      _json('POST', path, body);

  @override
  Future<dynamic> put(String path, [Map<String, dynamic>? body]) =>
      _json('PUT', path, body);

  @override
  Future<dynamic> delete(String path) => _json('DELETE', path);
}
