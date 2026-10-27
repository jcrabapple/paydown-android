import 'dart:convert';
import 'dart:io';

/// Validates app requests against the server's OpenAPI schema
/// (docs/openapi.json, exported from the budget repo's FastAPI app).
///
/// Checks, per request: the path+method exists; a required request body is
/// present; every required field is present; no unknown fields; and each
/// value's JSON type matches the schema. Violations throw [ContractError],
/// which fails the widget test that triggered the request.
///
/// Regenerate the schema whenever the server's models change:
///   see docs/ANDROID1.md "Contract schema".
class OpenApiContract {
  OpenApiContract._(this._spec) {
    for (final entry in (_spec['paths'] as Map<String, dynamic>).entries) {
      _routes.add((_compile(entry.key), entry.key));
    }
  }

  factory OpenApiContract.load([String path = 'docs/openapi.json']) =>
      OpenApiContract._(
          jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>);

  final Map<String, dynamic> _spec;
  final List<(RegExp, String)> _routes = [];

  static RegExp _compile(String template) => RegExp(
      '^${template.split('/').map((seg) => seg.startsWith('{') ? '[^/]+' : RegExp.escape(seg)).join('/')}\$');

  void check(String method, String path, Map<String, dynamic>? body) {
    final bare = path.split('?').first;
    final m = method.toLowerCase();
    // Prefer a literal route over a templated one (e.g. /log-all vs /{id}).
    final candidates = _routes.where((r) => r.$1.hasMatch(bare)).toList()
      ..sort((a, b) => '{'.allMatches(a.$2).length
          .compareTo('{'.allMatches(b.$2).length));
    final route = candidates
        .map((r) => r.$2)
        .firstWhere(
          (t) => (_spec['paths'][t] as Map).containsKey(m),
          orElse: () => throw ContractError(
              '$method $bare: no such route on the server'),
        );
    final op = _spec['paths'][route][m] as Map<String, dynamic>;
    final rb = op['requestBody'] as Map<String, dynamic>?;
    if (rb == null) return; // body ignored by the server
    final schema = _bodySchema(
        (rb['content']['application/json'] as Map)['schema'] as Map<String, dynamic>);
    if (body == null) {
      if (rb['required'] == true) {
        throw ContractError('$method $route: request body is required');
      }
      return;
    }
    _checkObject('$method $route', schema, body);
  }

  void _checkObject(String where, Map<String, dynamic> schema,
      Map<String, dynamic> body) {
    final props = (schema['properties'] as Map<String, dynamic>?) ?? const {};
    final required = ((schema['required'] as List?) ?? const []).cast<String>();
    for (final r in required) {
      if (!body.containsKey(r)) {
        throw ContractError('$where: missing required field "$r"');
      }
    }
    for (final e in body.entries) {
      final p = props[e.key] as Map<String, dynamic>?;
      if (p == null) {
        throw ContractError('$where: unknown field "${e.key}" '
            '(server fields: ${props.keys.join(', ')})');
      }
      if (!_typeOk(_resolve(p), e.value)) {
        throw ContractError('$where: field "${e.key}" has wrong type '
            '(${e.value.runtimeType} ${jsonEncode(e.value)}; schema ${jsonEncode(p)})');
      }
    }
  }

  /// Optional bodies (`Model | None = None` in FastAPI) are emitted as
  /// `anyOf: [{$ref: Model}, {type: null}]`; unwrap to the object schema.
  Map<String, dynamic> _bodySchema(Map<String, dynamic> s) {
    final any = (s['anyOf'] ?? s['oneOf']) as List?;
    if (any != null) {
      for (final x in any.cast<Map<String, dynamic>>()) {
        final r = _resolve(x);
        if (r['type'] == 'object' || r.containsKey('properties')) return r;
      }
    }
    return _resolve(s);
  }

  Map<String, dynamic> _resolve(Map<String, dynamic> s) {
    final ref = s[r'$ref'] as String?;
    if (ref == null) return s;
    final name = ref.split('/').last;
    return _spec['components']['schemas'][name] as Map<String, dynamic>;
  }

  bool _typeOk(Map<String, dynamic> s, Object? v) {
    final any = (s['anyOf'] ?? s['oneOf']) as List?;
    if (any != null) {
      return any.any((x) => _typeOk(_resolve(x as Map<String, dynamic>), v));
    }
    final t = s['type'];
    if (t == null) return true; // unconstrained
    return switch (t) {
      'null' => v == null,
      'integer' => v is int,
      'number' => v is num,
      'string' => v is String,
      'boolean' => v is bool,
      'array' => v is List,
      'object' => v is Map,
      _ => true,
    };
  }
}

class ContractError extends Error {
  ContractError(this.message);
  final String message;
  @override
  String toString() => 'API contract violation: $message';
}
