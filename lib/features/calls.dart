import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/format.dart';
import '../data/models.dart';
import '../state/agent.dart';
import '../state/services.dart';
import '../state/session.dart';
import '../state/shift.dart';
import '../ui/adaptive.dart';
import '../ui/parts.dart';
import '../ui/tokens.dart';
import 'home.dart';

/// A result code's human label, from the campaign's result list when loaded.
String resultLabel(WidgetRef ref, String code) {
  if (code.isEmpty) return 'No result';
  final campaign = ref.read(sessionProvider).value?.campaignId;
  final list = campaign == null ? null : ref.read(resultsProvider(campaign)).value;
  final hit = list?.where((d) => d.code.toUpperCase() == code.toUpperCase()).firstOrNull;
  if (hit != null) return hit.label;
  return switch (code) {
    'SALE' => 'Sale',
    'NI' => 'Not interested',
    'DNC' => 'Do not call',
    'CALLBK' => 'Call back',
    'XFER' => 'Transferred',
    'DROP' || 'XDROP' => 'Dropped',
    'AFTHRS' => 'After hours',
    'A' || 'AA' => 'Answering machine',
    'B' => 'Busy',
    'N' || 'NA' => 'No answer',
    'DC' || 'ADC' => 'Disconnected',
    'HU' => 'Hung up',
    _ => code,
  };
}

class CallsScreen extends ConsumerWidget {
  const CallsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final calls = ref.watch(todayCallsProvider);
    final stats = ref.watch(todayStatsProvider).value;
    final api = ref.read(apiProvider);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator.adaptive(
          onRefresh: () async {
            ref.invalidate(todayCallsProvider);
            ref.invalidate(todayStatsProvider);
            await ref.read(todayCallsProvider.future).catchError((Object _) => const <CallRecord>[]);
          },
          child: ListView(
            padding: const EdgeInsets.only(bottom: Gap.xl),
            children: [
              const AppHeader(title: 'Calls', trailing: PresencePill()),
              if (stats != null)
                Padding(
                  padding: EdgeInsets.fromLTRB(context.ios ? Gap.xxl : Gap.l + Gap.xs, 0, Gap.l, Gap.m),
                  child: Text(
                    'Today · ${stats.calls} ${stats.calls == 1 ? 'call' : 'calls'} · ${span(stats.talk)} talk · ${talk(stats.average)} average',
                    style: context.text.bodyMedium?.copyWith(color: c.ink2),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.l),
                child: calls.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.all(Gap.xxl),
                    child: Center(child: CircularProgressIndicator.adaptive()),
                  ),
                  error: (_, _) =>
                      const _Empty(text: "Today's calls aren't available right now. Pull down to try again."),
                  data: (list) => list.isEmpty
                      ? const _Empty(text: 'No calls yet today. They show up here after each wrap-up.')
                      : AppGroup(
                          children: [
                            for (final r in list)
                              _CallRow(
                                record: r,
                                label: resultLabel(ref, r.result),
                                queue: r.queueId.isEmpty
                                    ? (r.inbound ? 'Inbound' : 'Outbound')
                                    : api.queueName(r.queueId),
                                onTap: () => context.push('/calls/detail', extra: r),
                              ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CallRow extends StatelessWidget {
  const _CallRow({required this.record, required this.label, required this.queue, required this.onTap});

  final CallRecord record;
  final String label;
  final String queue;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final at = record.at == null ? '' : timeOfDay(record.at!, h24: MediaQuery.alwaysUse24HourFormatOf(context));
    final number = phone(record.phone);
    // With large text there's no room beside the number; the time and result
    // move under it instead of squeezing the number onto two lines.
    final stacked = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    final who = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          number.isEmpty ? 'Unknown caller' : number,
          style: context.text.bodyLarge?.copyWith(fontWeight: FontWeight.w600, fontFeatures: tabular),
        ),
        const SizedBox(height: 2),
        Text('$queue · ${talk(Duration(seconds: record.seconds))}', style: context.text.bodySmall),
      ],
    );
    final time = Text(
      at,
      style: context.text.bodySmall?.copyWith(color: c.muted, fontFeatures: tabular),
    );
    final tag = ResultTag(code: record.result, label: label);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.m),
          child: Row(
            children: [
              Expanded(
                child: stacked
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          who,
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: Gap.s,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [time, tag],
                          ),
                        ],
                      )
                    : who,
              ),
              if (!stacked) ...[
                const SizedBox(width: Gap.s),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [time, const SizedBox(height: 4), tag]),
              ],
              if (context.ios) ...[const SizedBox(width: Gap.xs), AppIcon(Ic.chevron, color: c.muted, size: 18)],
            ],
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Gap.xxl, horizontal: Gap.xl),
    child: Column(
      children: [
        AppIcon(Ic.calls, size: 32, color: context.colors.muted),
        const SizedBox(height: Gap.m),
        Text(
          text,
          textAlign: TextAlign.center,
          style: context.text.bodyMedium?.copyWith(color: context.colors.ink2),
        ),
      ],
    ),
  );
}

class CallDetailScreen extends ConsumerWidget {
  const CallDetailScreen({super.key, required this.record});

  final CallRecord record;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final api = ref.read(apiProvider);
    final number = phone(record.phone);
    final at = record.at;
    final h24 = MediaQuery.alwaysUse24HourFormatOf(context);
    final end = at?.add(Duration(seconds: record.seconds));
    final rows = <(String, String)>[
      if (at != null) ('Time', '${timeOfDay(at, h24: h24)} – ${timeOfDay(end!, h24: h24)}'),
      ('Direction', record.inbound ? 'Inbound' : 'Outbound'),
      if (record.queueId.isNotEmpty) ('Queue', api.queueName(record.queueId)),
      ('Talk time', talk(Duration(seconds: record.seconds))),
      if (record.leadId.isNotEmpty) ('Lead', '#${record.leadId}'),
    ];
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: Gap.xl),
          children: [
            AppHeader(title: 'Call details', backLabel: 'Calls', onBack: () => context.pop(), large: false),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.l),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: Gap.s),
                  Container(
                    padding: const EdgeInsets.all(Gap.l),
                    decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(context.cardRadius)),
                    child: Row(
                      children: [
                        const Avatar(name: ''),
                        const SizedBox(width: Gap.m),
                        Expanded(
                          child: Text(
                            number.isEmpty ? 'Unknown caller' : number,
                            style: context.text.titleLarge?.copyWith(fontFeatures: tabular),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Gap.l),
                  AppGroup(
                    children: [
                      for (final r in rows) AppRow(title: r.$1, value: r.$2),
                      AppRow(
                        title: 'Result',
                        trailing: ResultTag(code: record.result, label: resultLabel(ref, record.result)),
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
