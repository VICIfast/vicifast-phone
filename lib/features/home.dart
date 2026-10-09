import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/clock.dart';
import '../core/errors.dart';
import '../core/format.dart';
import '../data/models.dart';
import '../domain/presence.dart';
import '../state/agent.dart';
import '../state/line.dart';
import '../state/services.dart';
import '../state/session.dart';
import '../state/shift.dart';
import '../ui/adaptive.dart';
import '../ui/parts.dart';
import '../ui/tokens.dart';

/// Rebuilds once a second with the time elapsed since [since].
class Elapsed extends ConsumerWidget {
  const Elapsed({super.key, required this.since, required this.builder});

  final DateTime since;
  final Widget Function(BuildContext, Duration) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(tickProvider);
    final now = ref.watch(nowProvider)();
    final d = now.difference(since);
    return builder(context, d.isNegative ? Duration.zero : d);
  }
}

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final p = ref.watch(agentProvider);
    final session = ref.watch(sessionProvider).value;
    final line = ref.watch(lineProvider);
    final setup = ref.watch(setupStatusProvider).value;
    final needsCode = ref.watch(renewNeedsCodeProvider);
    final stats = (session?.features.showStats ?? true) ? ref.watch(todayStatsProvider) : null;
    final api = ref.read(apiProvider);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator.adaptive(
          onRefresh: () async {
            ref.invalidate(todayStatsProvider);
            await ref.read(todayStatsProvider.future).catchError((Object _) => const TodayStats());
          },
          child: ListView(
            padding: const EdgeInsets.only(bottom: Gap.xl),
            children: [
              const AppHeader(title: 'Home'),
              _Page(
                children: [
                  if (!line.up && session?.hasShift == true) ...[
                    Banner2(
                      tone: c.problem,
                      title: 'Phone line offline',
                      body: "Reconnecting. You won't get calls until it's back.",
                      action: 'Retry',
                      onAction: () => ref.read(lineProvider.notifier).reconnect(),
                    ),
                    const SizedBox(height: Gap.m),
                  ],
                  if (needsCode) ...[
                    Banner2(
                      tone: c.paused,
                      title: 'Enter your code to stay signed in',
                      body: 'Your session renews soon and needs a new two-factor code.',
                      action: 'Enter',
                      onAction: () => askRenewCode(context, ref),
                    ),
                    const SizedBox(height: Gap.m),
                  ],
                  if (setup != null && !setup.ready) ...[
                    Banner2(
                      tone: c.paused,
                      title: 'Finish phone setup',
                      body: setup.missing == 1
                          ? '1 setting is off, so calls may not ring.'
                          : '${setup.missing} settings are off, so calls may not ring.',
                      action: 'Fix',
                      onAction: () => context.push('/setup'),
                    ),
                    const SizedBox(height: Gap.m),
                  ],
                  _StatusCard(presence: p, campaignId: session?.campaignId),
                  if (session != null && session.queueIds.isNotEmpty) ...[
                    const SizedBox(height: Gap.xl),
                    _SectionTitle('Your queues', action: 'Change', onAction: () => context.push('/shift')),
                    const SizedBox(height: Gap.s),
                    Wrap(
                      spacing: Gap.s,
                      runSpacing: Gap.s,
                      children: [
                        for (final id in session.queueIds)
                          Chip2(label: api.queueName(id), onTap: () => context.push('/shift')),
                      ],
                    ),
                  ],
                  if (stats != null) ...[
                    const SizedBox(height: Gap.xl),
                    const _SectionTitle('Today'),
                    const SizedBox(height: Gap.s),
                    stats.when(
                      data: (s) => StatsGrid(stats: s),
                      loading: () => const StatsGrid(stats: TodayStats()),
                      error: (_, _) =>
                          Text("Today's numbers aren't available right now.", style: context.text.bodySmall),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusCard extends ConsumerStatefulWidget {
  const _StatusCard({required this.presence, required this.campaignId});

  final Presence presence;
  final String? campaignId;

  @override
  ConsumerState<_StatusCard> createState() => _StatusCardState();
}

class _StatusCardState extends ConsumerState<_StatusCard> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on AppError catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pause() async {
    final codes = widget.campaignId == null
        ? const <PauseCode>[]
        : await ref.read(pauseCodesProvider(widget.campaignId!).future).catchError((Object _) => const <PauseCode>[]);
    if (!mounted) return;
    if (codes.isEmpty) {
      await _run(() => ref.read(agentProvider.notifier).pause(const PauseReason('Paused')));
      return;
    }
    final reason = await pickPauseReason(context, codes);
    if (reason != null) await _run(() => ref.read(agentProvider.notifier).pause(reason));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final p = widget.presence;
    final agent = ref.read(agentProvider.notifier);
    if (p.kind == PresenceKind.ready) {
      return Elapsed(
        since: p.since,
        builder: (_, d) => StatusCard(
          tone: c.ready,
          label: 'Ready',
          reason: 'Waiting for the next call',
          timer: clock(d),
          actions: [
            AppButton(label: 'Pause', icon: Ic.pause, kind: ButtonKind.secondary, busy: _busy, onPressed: _pause),
          ],
          note: 'Calls ring here even when the phone is locked.',
        ),
      );
    }
    // Offline is already explained by the banner above and the reason here.
    return Elapsed(
      since: p.since,
      builder: (_, d) => StatusCard(
        tone: c.paused,
        label: 'Paused',
        reason: p.pause.label,
        timer: clock(d),
        trailing: p.pause.automatic || widget.campaignId == null
            ? null
            : TextButton(
                onPressed: _busy ? null : _pause,
                style: TextButton.styleFrom(minimumSize: const Size(48, 40)),
                child: const Text('Change reason'),
              ),
        actions: [
          AppButton(
            label: 'Go ready',
            icon: Ic.play,
            kind: ButtonKind.ready,
            busy: _busy,
            onPressed: p.lineUp ? () => _run(agent.goReady) : null,
          ),
        ],
      ),
    );
  }
}

/// Asks why the agent is pausing. One tap on a reason pauses: an action
/// sheet on iPhone, a list sheet on Android. Nothing is preselected, so the
/// reasons supervisors see are the ones agents chose.
Future<PauseReason?> pickPauseReason(BuildContext context, List<PauseCode> codes) {
  if (!context.ios) return showAppSheet<PauseReason>(context, (_) => PauseSheet(codes: codes));
  return showCupertinoModalPopup<PauseReason>(
    context: context,
    builder: (ctx) => CupertinoActionSheet(
      title: const Text('Pause'),
      message: const Text('Pick a reason. Your supervisor sees it.'),
      actions: [
        for (final code in codes)
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, PauseReason(code.label, code: code.code)),
            child: Text(code.label),
          ),
      ],
      cancelButton: CupertinoActionSheetAction(
        isDefaultAction: true,
        onPressed: () => Navigator.pop(ctx),
        child: const Text('Cancel'),
      ),
    ),
  );
}

class PauseSheet extends StatelessWidget {
  const PauseSheet({super.key, required this.codes});

  final List<PauseCode> codes;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Pause', style: context.text.titleLarge),
          const SizedBox(height: Gap.xs),
          Text(
            'Pick a reason. Your supervisor sees it.',
            style: context.text.bodyMedium?.copyWith(color: context.colors.ink2),
          ),
          const SizedBox(height: Gap.l),
          Flexible(
            child: SingleChildScrollView(
              child: AppGroup(
                children: [
                  for (final code in codes)
                    AppRow(
                      leading: AppIcon(Ic.pause, color: context.colors.ink2, size: 20),
                      title: code.label,
                      onTap: () => Navigator.pop(context, PauseReason(code.label, code: code.code)),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The side padding for page content under an [AppHeader].
class _Page extends StatelessWidget {
  const _Page({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: Gap.l),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, {this.action, this.onAction});

  final String title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 32,
    child: Row(
      children: [
        Expanded(
          child: Semantics(header: true, child: Text(title, style: context.text.titleMedium)),
        ),
        if (action != null)
          TextButton(
            onPressed: onAction,
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 32),
              padding: const EdgeInsets.symmetric(horizontal: Gap.s),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            child: Text(action!),
          ),
      ],
    ),
  );
}

/// Shows the agent's status on tabs that don't have the big status card.
class PresencePill extends ConsumerWidget {
  const PresencePill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(agentProvider);
    final c = context.colors;
    final tone = p.kind == PresenceKind.ready ? c.ready : c.paused;
    final label = p.kind == PresenceKind.ready ? 'Ready' : 'Paused';
    return Elapsed(
      since: p.since,
      builder: (_, d) => StatePill(tone: tone, label: '$label ${clock(d)}'),
    );
  }
}

Future<void> askRenewCode(BuildContext context, WidgetRef ref) async {
  final controller = TextEditingController();
  final code = await showAdaptiveDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog.adaptive(
      title: const Text('Enter your code'),
      content: Padding(
        padding: const EdgeInsets.only(top: Gap.s),
        child: Material(
          type: MaterialType.transparency,
          child: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            autofillHints: const [AutofillHints.oneTimeCode],
            decoration: const InputDecoration(hintText: '6-digit code'),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Later')),
        TextButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('Verify')),
      ],
    ),
  );
  controller.dispose();
  if (code != null && code.length == 6) await ref.read(sessionProvider.notifier).renewNow(code: code);
}
