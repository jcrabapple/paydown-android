import 'package:flutter/material.dart';

import '../theme.dart';
import 'bills.dart';
import 'goals.dart';
import 'insights.dart';
import 'payments.dart';
import 'settings.dart';
import 'subscriptions.dart';

/// "More" hub: app preferences plus secondary screens as pushed routes.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key, required this.theme});

  final ThemeModeController theme;

  static const _destinations = [
    (label: 'Bills', icon: Icons.receipt_long, builder: BillsScreen.new),
    (label: 'Payments', icon: Icons.payments, builder: PaymentsScreen.new),
    (label: 'Subscriptions', icon: Icons.autorenew, builder: SubscriptionsScreen.new),
    (label: 'Goals', icon: Icons.flag, builder: GoalsScreen.new),
    (label: 'Insights', icon: Icons.insights, builder: InsightsScreen.new),
    (label: 'Settings', icon: Icons.settings, builder: SettingsScreen.new),
  ];

  @override
  Widget build(BuildContext context) => ListView(
        children: [
          const ListTile(
            leading: Icon(Icons.brightness_6),
            title: Text('Appearance'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                    value: ThemeMode.system,
                    label: Text('System'),
                    icon: Icon(Icons.brightness_auto)),
                ButtonSegment(
                    value: ThemeMode.light,
                    label: Text('Light'),
                    icon: Icon(Icons.light_mode)),
                ButtonSegment(
                    value: ThemeMode.dark,
                    label: Text('Dark'),
                    icon: Icon(Icons.dark_mode)),
              ],
              selected: {theme.mode},
              onSelectionChanged: (s) => theme.set(s.first),
            ),
          ),
          const Divider(height: 32),
          for (final d in _destinations)
            ListTile(
              leading: Icon(d.icon),
              title: Text(d.label),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => d.builder())),
            ),
        ],
      );
}
