import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import 'dart:async';

import '../app/brand.dart';
import '../core/format.dart';
import '../platform/updater.dart';
import '../state/line.dart';
import '../state/services.dart';
import '../state/session.dart';
import '../state/shift.dart';
import '../ui/adaptive.dart';
import '../ui/parts.dart';
import '../ui/tokens.dart';
import 'home.dart';

class MeScreen extends ConsumerWidget {
  const MeScreen({super.key});

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    final ok = await confirm(
      context,
      title: 'Sign out?',
      body: "You'll stop getting calls until you sign in again.",
      action: 'Sign out',
      destructive: true,
    );
    if (ok) await ref.read(sessionProvider.notifier).signOut();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final s = ref.watch(sessionProvider).value;
    final line = ref.watch(lineProvider);
    final setup = ref.watch(setupStatusProvider).value;
    final theme = ref.watch(themeModeProvider);
    final version = ref.watch(appVersionProvider);
    final needsCode = ref.watch(renewNeedsCodeProvider);
    final update = ref.watch(updateAvailableProvider).value;
    final api = ref.read(apiProvider);
    final queues = s?.queueIds.map(api.queueName).join(', ') ?? '';
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: Gap.xl),
          children: [
            const AppHeader(title: 'Me', trailing: PresencePill()),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.l),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(Gap.l),
                    decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(context.cardRadius)),
                    child: Row(
                      children: [
                        Avatar(name: s?.user ?? '#'),
                        const SizedBox(width: Gap.m),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Agent ${s?.user ?? ''}', style: context.text.titleMedium),
                              Text('Company code: ${s?.slug ?? ''}', style: context.text.bodySmall),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Gap.xl),
                  AppGroup(
                    header: 'Shift',
                    children: [
                      AppRow(title: s?.campaignName ?? 'No campaign', subtitle: queues.isEmpty ? 'No queues' : queues),
                      AppRow(title: 'Change campaign or queues', chevron: true, onTap: () => context.push('/shift')),
                    ],
                  ),
                  const SizedBox(height: Gap.xl),
                  AppGroup(
                    header: 'Phone',
                    children: [
                      AppRow(
                        title: 'Phone line',
                        subtitle: line.up ? null : 'Tap to reconnect',
                        value: line.up ? 'Connected' : 'Offline',
                        valueColor: line.up ? null : c.problem.fg,
                        onTap: line.up ? null : () => ref.read(lineProvider.notifier).reconnect(),
                      ),
                      AppRow(
                        title: 'Phone setup',
                        value: setup == null ? null : (setup.ready ? 'All set' : '${setup.missing} off'),
                        valueColor: setup == null || setup.ready ? null : c.paused.fg,
                        chevron: true,
                        onTap: () => context.push('/setup'),
                      ),
                      if (needsCode)
                        AppRow(
                          title: 'Enter your code to stay signed in',
                          titleColor: c.paused.fg,
                          chevron: true,
                          onTap: () => askRenewCode(context, ref),
                        ),
                      AppRow(
                        title: 'Signed in until',
                        value: s == null
                            ? ''
                            : timeOfDay(s.expiresAt.toLocal(), h24: MediaQuery.alwaysUse24HourFormatOf(context)),
                      ),
                    ],
                  ),
                  const SizedBox(height: Gap.xl),
                  AppGroup(
                    header: 'Appearance',
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(Gap.m),
                        child: AppSegmented<ThemeMode>(
                          segments: const {
                            ThemeMode.system: 'Automatic',
                            ThemeMode.light: 'Light',
                            ThemeMode.dark: 'Dark',
                          },
                          value: theme,
                          onChanged: (m) => ref.read(themeModeProvider.notifier).set(m),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Gap.xl),
                  AppGroup(
                    header: 'App',
                    children: [
                      AppRow(title: 'Version', value: version),
                      AppRow(
                        title: 'Source code',
                        subtitle: 'This app is open source (GPLv3)',
                        chevron: true,
                        onTap: () => launchUrl(Uri.parse(kSourceUrl), mode: LaunchMode.externalApplication),
                      ),
                      AppRow(
                        title: 'Open-source licences',
                        chevron: true,
                        onTap: () => showLicensePage(
                          context: context,
                          applicationName: '$kBrandName Phone',
                          applicationVersion: version,
                          applicationLegalese: 'GPLv3. Source code: $kSourceUrl',
                        ),
                      ),
                      if (update != null)
                        AppRow(
                          title: 'Update to ${update.version}',
                          subtitle: '${(update.sizeBytes / 1048576).toStringAsFixed(0)} MB download',
                          chevron: true,
                          onTap: () => showAppSheet<void>(context, (_) => UpdateSheet(update: update)),
                        ),
                    ],
                  ),
                  const SizedBox(height: Gap.xl),
                  AppGroup(
                    footer: "You'll stop getting calls until you sign in again.",
                    children: [
                      AppRow(
                        leading: AppIcon(Ic.signOut, color: c.problem.fg, size: 20),
                        title: 'Sign out',
                        titleColor: c.problem.fg,
                        onTap: () => _signOut(context, ref),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class UpdateSheet extends ConsumerStatefulWidget {
  const UpdateSheet({super.key, required this.update});

  final AppUpdate update;

  @override
  ConsumerState<UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends ConsumerState<UpdateSheet> {
  double? _progress;
  String? _message;

  Future<void> _go() async {
    setState(() {
      _progress = 0;
      _message = null;
    });
    try {
      await ref.read(updaterProvider).install(widget.update, (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (mounted) setState(() => _message = 'Follow the installer to finish. Your shift settings stay.');
    } on UpdateNeedsPermission {
      if (mounted) {
        setState(() => _message = 'Allow installs from this app on the screen that opened, then tap Download again.');
      }
    } catch (_) {
      if (mounted) setState(() => _message = "The download didn't finish. Check your connection and try again.");
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final busy = _progress != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Update to ${widget.update.version}', style: context.text.titleLarge),
          const SizedBox(height: Gap.xs),
          Text(
            "Updating keeps you signed in. Calls can't ring while the installer is open, so update on a break.",
            style: context.text.bodyMedium?.copyWith(color: c.ink2),
          ),
          const SizedBox(height: Gap.l),
          if (busy) ...[
            LinearProgressIndicator(
              value: _progress,
              minHeight: 6,
              borderRadius: BorderRadius.circular(3),
              color: c.ink,
              backgroundColor: c.fill,
            ),
            const SizedBox(height: Gap.s),
            Text('${((_progress ?? 0) * 100).round()}%', style: context.text.bodySmall),
            const SizedBox(height: Gap.l),
          ],
          if (_message != null) ...[Text(_message!, style: context.text.bodyMedium), const SizedBox(height: Gap.l)],
          AppButton(label: 'Download and install', busy: busy, onPressed: () => unawaited(_go())),
        ],
      ),
    );
  }
}
