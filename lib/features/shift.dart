import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/errors.dart';
import '../data/models.dart';
import '../state/session.dart';
import '../state/shift.dart';
import '../ui/adaptive.dart';
import '../ui/tokens.dart';
import 'home.dart';

class ShiftScreen extends ConsumerStatefulWidget {
  const ShiftScreen({super.key});

  @override
  ConsumerState<ShiftScreen> createState() => _ShiftScreenState();
}

class _ShiftScreenState extends ConsumerState<ShiftScreen> {
  String? _campaignId;
  Set<String>? _queues;
  bool _busy = false;
  String? _error;

  void _pick(Campaign c, {Set<String>? queues}) {
    setState(() {
      _campaignId = c.id;
      _queues = queues ?? c.queues.map((q) => q.id).toSet();
    });
  }

  Future<void> _start(Campaign campaign) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(shiftActionsProvider.notifier).start(campaign, _queues!.toList());
      if (!mounted) return;
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/home');
      }
    } on AppError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final session = ref.watch(sessionProvider).value;
    final campaigns = ref.watch(campaignsProvider);
    final changing = session?.hasShift ?? false;
    final needsCode = ref.watch(renewNeedsCodeProvider);
    return Scaffold(
      body: SafeArea(
        child: campaigns.when(
          loading: () => const Center(child: CircularProgressIndicator.adaptive()),
          error: (e, _) => _LoadError(
            message: e is AppError ? e.message : const AppError(AppErrorCode.unknown).message,
            onRetry: () async {
              // An expired session renews quietly; then the list loads again.
              if (e is AppError && e.code == AppErrorCode.sessionEnded) {
                await ref.read(sessionProvider.notifier).renewNow();
              }
              ref.invalidate(campaignsProvider);
            },
            // Home and Me hold the code prompt, but the router keeps an agent
            // without a shift here, so this screen has to offer it too.
            onCode: e is AppError && e.code == AppErrorCode.sessionEnded && needsCode
                ? () async {
                    await askRenewCode(context, ref);
                    ref.invalidate(campaignsProvider);
                  }
                : null,
            onSignOut: e is AppError && e.endsSession
                ? () => ref.read(sessionProvider.notifier).signOut(notice: e.message)
                : null,
          ),
          data: (list) {
            if (list.isEmpty) {
              return _LoadError(
                message: 'No campaigns are set up for you yet. Ask your supervisor.',
                onRetry: () => ref.invalidate(campaignsProvider),
              );
            }
            if (_campaignId == null) {
              final previous = list.where((x) => x.id == session?.campaignId).firstOrNull;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                if (previous != null && (session?.queueIds.isNotEmpty ?? false)) {
                  _pick(
                    previous,
                    queues: session!.queueIds.where((id) => previous.queues.any((q) => q.id == id)).toSet(),
                  );
                } else {
                  _pick(list.first);
                }
              });
              return const SizedBox.shrink();
            }
            final campaign = list.firstWhere((x) => x.id == _campaignId, orElse: () => list.first);
            final queues = _queues ?? {};
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppHeader(
                  title: changing ? 'Change shift' : 'Start your shift',
                  backLabel: 'Me',
                  onBack: changing && context.canPop() ? () => context.pop() : null,
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l),
                    children: [
                      AppGroup(
                        header: 'Campaign',
                        children: [
                          for (final x in list)
                            AppRow(
                              selected: x.id == campaign.id,
                              title: x.name,
                              subtitle: x.queues.isEmpty
                                  ? 'Outbound calls'
                                  : '${x.queues.length} ${x.queues.length == 1 ? 'queue' : 'queues'}',
                              onTap: () => _pick(x),
                            ),
                        ],
                      ),
                      if (campaign.queues.isNotEmpty) ...[
                        const SizedBox(height: Gap.xl),
                        Row(
                          children: [
                            Expanded(
                              child: Padding(
                                padding: EdgeInsets.only(left: context.ios ? Gap.l : Gap.xs),
                                child: Text(
                                  context.ios ? 'QUEUES' : 'Queues',
                                  style: context.ios
                                      ? TextStyle(fontSize: 13, color: c.muted)
                                      : context.text.titleSmall?.copyWith(color: c.ink2, fontWeight: FontWeight.w600),
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: () => setState(
                                () => _queues = queues.length == campaign.queues.length
                                    ? <String>{}
                                    : campaign.queues.map((q) => q.id).toSet(),
                              ),
                              child: Text(queues.length == campaign.queues.length ? 'Clear all' : 'Select all'),
                            ),
                          ],
                        ),
                        AppGroup(
                          footer: "We'll pick these again next time.",
                          children: [
                            for (final q in campaign.queues)
                              AppRow(
                                selected: queues.contains(q.id),
                                multi: true,
                                title: q.name,
                                subtitle: q.waiting == null
                                    ? null
                                    : (q.waiting == 0 ? 'None waiting' : '${q.waiting} waiting'),
                                onTap: () => setState(() {
                                  final next = {...queues};
                                  next.contains(q.id) ? next.remove(q.id) : next.add(q.id);
                                  _queues = next;
                                }),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.l),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_error != null) ...[
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: context.text.bodyMedium?.copyWith(color: c.problem.fg),
                        ),
                        const SizedBox(height: Gap.s),
                      ],
                      AppButton(
                        label: changing ? 'Save shift' : 'Start shift',
                        busy: _busy,
                        onPressed: campaign.queues.isNotEmpty && queues.isEmpty ? null : () => _start(campaign),
                      ),
                      if (campaign.queues.isNotEmpty && queues.isEmpty) ...[
                        const SizedBox(height: Gap.s),
                        Text(
                          'Pick at least one queue to take calls.',
                          textAlign: TextAlign.center,
                          style: context.text.bodySmall?.copyWith(color: c.muted),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.message, required this.onRetry, this.onCode, this.onSignOut});

  final String message;
  final VoidCallback onRetry;
  final VoidCallback? onCode;
  final VoidCallback? onSignOut;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(Gap.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(Ic.alert, color: context.colors.problem.fg, size: 32),
          const SizedBox(height: Gap.m),
          Text(message, textAlign: TextAlign.center, style: context.text.bodyLarge),
          const SizedBox(height: Gap.l),
          SizedBox(
            width: 220,
            child: onCode != null
                ? AppButton(label: 'Enter your code', onPressed: onCode)
                : AppButton(label: 'Try again', kind: ButtonKind.secondary, onPressed: onRetry),
          ),
          if (onSignOut != null) ...[
            const SizedBox(height: Gap.s),
            TextButton(onPressed: onSignOut, child: const Text('Sign out')),
          ],
        ],
      ),
    ),
  );
}
