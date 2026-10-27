import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class Credentials {
  const Credentials(this.user, this.password, [this.baseUrl]);

  final String user;
  final String password;

  /// The user's server. Null only for credentials saved by a very early
  /// build; the app treats that as signed out.
  final String? baseUrl;
}

/// Basic-auth credentials in platform secure storage. Never log them.
class AuthStore {
  AuthStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _kUser = 'paydown_user';
  static const _kPass = 'paydown_pass';
  static const _kUrl = 'paydown_base_url';

  Future<Credentials?> read() async {
    final user = await _storage.read(key: _kUser);
    final pass = await _storage.read(key: _kPass);
    if (user == null || pass == null) return null;
    return Credentials(user, pass, await _storage.read(key: _kUrl));
  }

  Future<void> save(Credentials creds) async {
    await _storage.write(key: _kUser, value: creds.user);
    await _storage.write(key: _kPass, value: creds.password);
    if (creds.baseUrl != null) {
      await _storage.write(key: _kUrl, value: creds.baseUrl);
    } else {
      await _storage.delete(key: _kUrl);
    }
  }

  Future<void> clear() async {
    await _storage.delete(key: _kUser);
    await _storage.delete(key: _kPass);
    await _storage.delete(key: _kUrl);
  }
}
