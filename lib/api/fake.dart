import 'dart:async';

import 'client.dart';

/// Scripted [ApiClient] for widget tests. Routes map "METHOD /path" (or just
/// "/path" for GET) to a response payload, a thrown ApiError, or a function
/// of the decoded body. Records every call in [calls].
class FakeApiClient implements ApiClient {
  FakeApiClient(this.routes);

  /// Optional contract check run on EVERY call before routing. Tests install
  /// an OpenAPI validator here (test/flutter_test_config.dart) so a request
  /// the real server would reject (wrong path, missing required field,
  /// unknown key, wrong type) fails the test instead of passing silently.
  static void Function(String method, String path, Map<String, dynamic>? body)?
      contract;

  final Map<String, dynamic> routes;
  final List<Record> calls = [];

  dynamic _respond(String method, String path, dynamic body) {
    // Match most-specific first: method+full path, method+path-without-query,
    // then bare registrations in the same two forms. This lets tests register
    // either '/api/upcoming?days=31' or '/api/deposit-rules/preview' and have
    // calls with additional/differing query strings resolve correctly.
    final barePath = path.split('?').first;
    for (final key in [
      '$method $path',
      '$method $barePath',
      path,
      barePath,
    ]) {
      if (routes.containsKey(key)) return routes[key];
    }
    return null;
  }

  Future<dynamic> _call(String method, String path,
      [Map<String, dynamic>? body]) async {
    calls.add((method, path, body));
    contract?.call(method, path, body);
    final r = _respond(method, path, body);
    if (r is ApiError) throw r;
    if (r is Function) return r(body);
    return r;
  }

  @override
  Future<dynamic> get(String path) => _call('GET', path);

  @override
  Future<dynamic> post(String path, [Map<String, dynamic>? body]) =>
      _call('POST', path, body);

  @override
  Future<dynamic> put(String path, [Map<String, dynamic>? body]) =>
      _call('PUT', path, body);

  @override
  Future<dynamic> delete(String path) => _call('DELETE', path);
}

typedef Record = (String method, String path, Map<String, dynamic>? body);
