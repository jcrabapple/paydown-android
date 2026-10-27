import 'package:flutter/material.dart';

import 'api/client.dart';

/// Inherited access to the API client. In tests, wrap the widget under test
/// in [ApiScope] with a FakeApiClient.
class ApiScope extends InheritedWidget {
  const ApiScope({super.key, required this.client, required super.child});

  final ApiClient client;

  static ApiClient of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ApiScope>()!.client;

  @override
  bool updateShouldNotify(ApiScope old) => old.client != client;
}

/// Renders the three async states for one screen-level fetch. Errors render
/// as a dismissible banner that STAYS until dismissed or retried (web app
/// semantics: errors never auto-vanish; only success toasts do).
class AsyncView<T> extends StatelessWidget {
  const AsyncView({
    super.key,
    required this.snapshot,
    required this.builder,
    this.onRetry,
  });

  final AsyncSnapshot<T> snapshot;
  final Widget Function(T data) builder;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final snap = snapshot;
    if (snap.hasError) {
      final err = snap.error;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(err is ApiError ? err.message : '$err',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
              if (onRetry != null) ...[
                const SizedBox(height: 12),
                FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
              ],
            ],
          ),
        ),
      );
    }
    if (snap.connectionState != ConnectionState.done) {
      return const Center(child: CircularProgressIndicator());
    }
    // Done without error: ready. Note AsyncSnapshot<void>.withData(...)
    // carries null data and hasData is false for null — screens that model
    // load state manually (screens use AsyncSnapshot<void>) rely on
    // connectionState, never on hasData.
    return builder(snap.data as T);
  }
}

/// Success feedback, mirroring util.js toast(): short, auto-vanishing.
void toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Error feedback, mirroring util.js errorBanner(): stays until the user
/// dismisses it. Errors never auto-vanish; only success toasts do.
void showError(BuildContext context, String message) {
  final scheme = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message, style: TextStyle(color: scheme.onErrorContainer)),
      backgroundColor: scheme.errorContainer,
      closeIconColor: scheme.onErrorContainer,
      showCloseIcon: true,
      persist: true, // stays past its duration until the close icon is tapped
    ));
}

/// Standard screen scaffold with pull-to-refresh wired to [onRefresh].
class Refresher extends StatelessWidget {
  const Refresher({super.key, required this.onRefresh, required this.child});

  final Future<void> Function() onRefresh;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      RefreshIndicator(onRefresh: onRefresh, child: child);
}

/// One list row: title, optional subtitle, optional trailing amount.
class InfoRow extends StatelessWidget {
  const InfoRow({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle!),
        trailing: trailing,
        onTap: onTap,
      );
}
