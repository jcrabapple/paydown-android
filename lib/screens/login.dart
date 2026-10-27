import 'package:flutter/material.dart';

import '../api/auth.dart';
import '../api/client.dart';

/// Shown as a hint only: there is no default server. Each install points at
/// the user's own self-hosted Paydown.
const kServerHint = 'https://budget.example.com';

/// Gate shown when no credentials are stored. Validates by fetching
/// /api/settings (any authed endpoint) before saving.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.auth, required this.onSuccess});

  final AuthStore auth;
  final VoidCallback onSuccess;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _serverCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _serverCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final baseUrl = normalizeBaseUrl(_serverCtrl.text)!; // validator checked
    setState(() {
      _busy = true;
      _error = null;
    });
    final creds = Credentials(_userCtrl.text.trim(), _passCtrl.text, baseUrl);
    // Validate the typed credentials BEFORE persisting anything: a failed or
    // aborted sign-in must never leave bad credentials in secure storage.
    final client =
        HttpApiClient(baseUrl: baseUrl, auth: widget.auth, credentials: creds);
    try {
      await client.get('/api/settings');
      await widget.auth.save(creds);
      widget.onSuccess();
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Sign in — Paydown')),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextFormField(
                controller: _serverCtrl,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                    labelText: 'Server',
                    hintText: kServerHint,
                    helperText: 'The address of your Paydown server'),
                validator: (v) => (v != null && normalizeBaseUrl(v) != null)
                    ? null
                    : 'Enter your server address, like $kServerHint',
              ),
              TextFormField(
                controller: _userCtrl,
                decoration: const InputDecoration(labelText: 'User'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              TextFormField(
                controller: _passCtrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Password'),
                validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
                onFieldSubmitted: (_) => _signIn(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error)),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _signIn,
                child: Text(_busy ? 'Signing in…' : 'Sign in'),
              ),
            ],
          ),
        ),
      );
}
