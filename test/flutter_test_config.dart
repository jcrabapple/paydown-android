import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:paydown/api/fake.dart';

import 'contract.dart';

/// Runs before every test file: every FakeApiClient request is validated
/// against the server's OpenAPI schema, so a body the real server would
/// reject fails the test that sent it.
///
/// Violations are thrown at the call site AND recorded, then asserted in a
/// global tearDown: screens that `catch (e)` broadly would otherwise swallow
/// the throw and let the test pass.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final contract = OpenApiContract.load();
  final violations = <String>[];
  FakeApiClient.contract = (method, path, body) {
    try {
      contract.check(method, path, body);
    } on ContractError catch (e) {
      violations.add(e.message);
      rethrow;
    }
  };
  setUp(violations.clear);
  tearDown(() {
    if (violations.isNotEmpty) {
      final found = List.of(violations);
      violations.clear();
      fail('API contract violations:\n  ${found.join('\n  ')}');
    }
  });
  await testMain();
}
