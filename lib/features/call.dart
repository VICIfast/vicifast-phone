import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/clock.dart';
import '../core/errors.dart';
import '../core/format.dart';
import '../data/models.dart';
import '../domain/presence.dart';
import '../state/agent.dart';
import '../ui/adaptive.dart';
import '../ui/parts.dart';
import '../ui/tokens.dart';
import 'calls.dart';
import 'home.dart';

const _callBg = Color(0xFF0F1513);
const _callFg = Color(0xFFF1F5F3);

class IncomingScreen extends ConsumerWidget {
  const IncomingScreen({super.key});

  Future<void> _accept(BuildContext context, WidgetRef ref) async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      if (context.mounted) {
        showMessage(context, 'Allow the microphone to answer calls. The call keeps ringing.');
      }
      if (mic.isPermanentlyDenied) await openAppSettings();
      return;
    }
    await ref.read(agentProvider.notifier).answer();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(agentProvider);
    final call = p.call ?? const CallContext();
    final name = call.displayName.isEmpty ? 'Incoming call' : call.displayName;
    final number = phone(call.phone);
    final local = localTimeAt(call.lead?.gmtOffset, now: ref.watch(nowProvider)());
    final place = [
      if (call.lead?.place.isNotEmpty ?? false) call.lead!.place,
      if (local != null) '${timeOfDay(local, h24: MediaQuery.alwaysUse24HourFormatOf(context))} local',
    ].join(' · ');
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: _callBg,
        body: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: RadialGradient(center: Alignment(0, -0.85), radius: 1.2, colors: [Color(0xFF22302B), _callBg]),
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.xl, Gap.xl, Gap.l),
              child: Column(
                children: [
                  if (call.queueName.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const AppIcon(Ic.people, size: 15, color: _callFg),
                          const SizedBox(width: 6),
                          Text(
                            'Incoming call · ${call.queueName}',
                            style: const TextStyle(color: _callFg, fontSize: 13),
                          ),
                        ],
                      ),
                    )
                  else
                    const Text('Incoming call', style: TextStyle(color: _callFg, fontSize: 14)),
                  const SizedBox(height: Gap.xxl),
                  Avatar(
                    name: name,
                    size: 96,
                    icon: Ic.person,
                    background: Colors.white.withValues(alpha: 0.12),
                    foreground: _callFg,
                  ),
                  const SizedBox(height: Gap.l),
                  Text(
                    name,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _callFg,
                      fontSize: context.ios ? 34 : 30,
                      fontWeight: context.ios ? FontWeight.w400 : FontWeight.w500,
                    ),
                  ),
                  if (number.isNotEmpty && number != name) ...[
                    const SizedBox(height: Gap.xs),
                    Text(
                      number,
                      style: TextStyle(color: _callFg.withValues(alpha: 0.85), fontSize: 17, fontFeatures: tabular),
                    ),
                  ],
                  if (place.isNotEmpty) ...[
                    const SizedBox(height: Gap.s),
                    Text(place, style: TextStyle(color: _callFg.withValues(alpha: 0.7), fontSize: 14)),
                  ],
                  if (call.waitSec != null && call.waitSec! > 0) ...[
                    const SizedBox(height: Gap.xs),
                    Text(
                      'Waited ${clock(Duration(seconds: call.waitSec!))} in the queue',
                      style: TextStyle(color: _callFg.withValues(alpha: 0.7), fontSize: 14),
                    ),
                  ],
                  const Spacer(),
                  Row(
                    children: [
                      Expanded(
                        child: _RoundAction(
                          label: 'Decline',
                          icon: Ic.hangUp,
                          color: context.colors.decline,
                          onTap: () => ref.read(agentProvider.notifier).decline(),
                        ),
                      ),
                      Expanded(
                        child: _RoundAction(
                          label: 'Accept',
                          icon: Ic.phone,
                          color: context.colors.accept,
                          onTap: () => _accept(context, ref),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Gap.l),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({required this.label, required this.icon, required this.color, required this.onTap});

  final String label;
  final Ic icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: AppIcon(icon, color: Colors.white, size: 32),
          ),
          const SizedBox(height: Gap.s),
          ExcludeSemantics(
            child: Text(label, style: const TextStyle(color: _callFg, fontSize: 15)),
          ),
        ],
      ),
    ),
  );
}

class CallScreen extends ConsumerWidget {
  const CallScreen({super.key});

  Future<void> _do(BuildContext context, Future<void> Function() action) async {
    try {
      await action();
    } on AppError catch (e) {
      if (context.mounted) showMessage(context, e.message);
    } catch (_) {
      if (context.mounted) showMessage(context, const AppError(AppErrorCode.unknown).message);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final p = ref.watch(agentProvider);
    final agent = ref.read(agentProvider.notifier);
    final call = p.call ?? const CallContext();
    final queue = call.queueName.isNotEmpty ? call.queueName : 'Inbound call';
    final callStart = p.callStart ?? p.since;
    // Tall phones put the caller and a big timer up top; short ones keep the
    // compact card and move the timer into the band.
    // Large text counts against the height: at 200% the big layout would push
    // the customer's details off screen.
    final tall = MediaQuery.sizeOf(context).height / MediaQuery.textScalerOf(context).scale(1) >= 700;
    final lastResult = call.lead == null ? null : resultLabel(ref, call.lead!.lastResult);

    final band = p.held
        ? Elapsed(
            since: p.heldSince ?? p.since,
            builder: (_, d) => StateBand(
              tone: c.hold,
              icon: Ic.pause,
              label: 'Customer on hold',
              subtitle: 'Hold music is playing',
              timer: clock(d),
            ),
          )
        : tall
        ? StateBand(tone: c.call, icon: Ic.phone, label: 'On call', subtitle: queue)
        : Elapsed(
            since: callStart,
            builder: (_, d) =>
                StateBand(tone: c.call, icon: Ic.phone, label: 'On call', subtitle: queue, timer: clock(d)),
          );

    final muted = StatePill(tone: c.problem, label: 'Muted · the customer can’t hear you');

    final Widget top = tall
        ? Column(
            children: [
              const SizedBox(height: Gap.l),
              _CallerIdentity(call: call, since: callStart),
              if (p.muted) ...[const SizedBox(height: Gap.m), muted],
              const SizedBox(height: Gap.l),
              LeadCard(call: call, header: false, lastResultLabel: lastResult),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (p.muted) ...[Align(alignment: Alignment.centerLeft, child: muted), const SizedBox(height: Gap.m)],
              LeadCard(call: call, lastResultLabel: lastResult),
            ],
          );

    Widget controlRow(List<Widget> children) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final w in children) Expanded(child: w)],
    );

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          band,
          Expanded(
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.l, Gap.l),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: SingleChildScrollView(child: top)),
                    const SizedBox(height: Gap.m),
                    MediaQuery.withClampedTextScaling(
                      maxScaleFactor: 1.5,
                      child: Column(
                        children: [
                          controlRow([
                            CallControl(
                              icon: Ic.micOff,
                              label: 'Mute',
                              toggle: true,
                              on: p.muted,
                              onTone: c.problem,
                              onTap: () => _do(context, agent.toggleMute),
                            ),
                            CallControl(
                              icon: Ic.keypad,
                              label: 'Keypad',
                              onTap: () => showAppSheet<void>(context, (_) => const KeypadSheet()),
                            ),
                            CallControl(
                              icon: Ic.speaker,
                              label: 'Speaker',
                              toggle: true,
                              on: p.speaker,
                              onTap: () => _do(context, agent.toggleSpeaker),
                            ),
                          ]),
                          const SizedBox(height: Gap.l),
                          controlRow([
                            CallControl(
                              icon: Ic.pause,
                              label: 'Hold',
                              toggle: true,
                              on: p.held,
                              onTone: c.hold,
                              onTap: () => _do(context, agent.toggleHold),
                            ),
                            CallControl(
                              icon: Ic.transfer,
                              label: 'Transfer',
                              onTap: () =>
                                  showAppSheet<void>(context, (_) => TransferSheet(customer: call.displayName)),
                            ),
                            CallControl(
                              icon: Ic.lead,
                              label: 'Lead',
                              onTap: call.lead == null
                                  ? null
                                  : () => showAppSheet<void>(context, (_) => LeadSheet(call: call)),
                            ),
                          ]),
                        ],
                      ),
                    ),
                    const SizedBox(height: Gap.l),
                    SizedBox(
                      height: 58,
                      child: FilledButton(
                        onPressed: () => _do(context, agent.endCall),
                        style: FilledButton.styleFrom(backgroundColor: c.decline, foregroundColor: Colors.white),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            AppIcon(Ic.hangUp, size: 24),
                            SizedBox(width: Gap.s),
                            Text('End call'),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The caller, large, with the call's running time.
class _CallerIdentity extends StatelessWidget {
  const _CallerIdentity({required this.call, required this.since});

  final CallContext call;
  final DateTime since;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final name = call.displayName.isEmpty ? 'Unknown caller' : call.displayName;
    final number = phone(call.phone);
    return Column(
      children: [
        Avatar(name: name, size: 72, icon: Ic.person),
        const SizedBox(height: Gap.m),
        Text(
          name,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600, color: c.ink, height: 1.15),
        ),
        if (number.isNotEmpty && number != name) ...[
          const SizedBox(height: 2),
          Text(
            number,
            style: context.text.bodyLarge?.copyWith(color: c.ink2, fontFeatures: tabular),
          ),
        ],
        const SizedBox(height: Gap.s),
        Elapsed(
          since: since,
          builder: (_, d) => Semantics(
            label: 'Call time ${span(d)}',
            excludeSemantics: true,
            child: Text(
              clock(d),
              style: TextStyle(
                fontSize: 40,
                height: 1.1,
                fontWeight: context.ios ? FontWeight.w600 : FontWeight.w500,
                letterSpacing: -0.5,
                color: c.ink,
                fontFeatures: tabular,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class TransferSheet extends ConsumerStatefulWidget {
  const TransferSheet({super.key, required this.customer});

  final String customer;

  @override
  ConsumerState<TransferSheet> createState() => _TransferSheetState();
}

enum _To { queue, number }

class _TransferSheetState extends ConsumerState<TransferSheet> {
  _To _to = _To.queue;
  TransferQueue? _queue;
  final _number = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    final agent = ref.read(agentProvider.notifier);
    setState(() => _busy = true);
    try {
      if (_to == _To.queue) {
        await agent.transferToQueue(_queue!);
      } else {
        await agent.transferToNumber(_number.text);
      }
      if (mounted) Navigator.pop(context);
    } on AppError catch (e) {
      if (mounted) {
        showMessage(context, e.code == AppErrorCode.unknown ? "The transfer didn't go through. Try again." : e.message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final queues = ref.watch(transferQueuesProvider);
    final digits = _number.text.replaceAll(RegExp(r'\D'), '');
    final ready = _to == _To.queue ? _queue != null : digits.length >= 3;
    final who = widget.customer.isEmpty ? 'The customer' : widget.customer.split(' ').first;
    final dest = _to == _To.queue ? (_queue?.name ?? 'the queue') : (digits.isEmpty ? 'that number' : phone(digits));
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Transfer call',
            style: context.text.titleLarge,
            textAlign: context.ios ? TextAlign.center : TextAlign.start,
          ),
          const SizedBox(height: Gap.l),
          AppSegmented<_To>(
            segments: const {_To.queue: 'To a queue', _To.number: 'To a number'},
            value: _to,
            onChanged: (v) => setState(() => _to = v),
          ),
          const SizedBox(height: Gap.l),
          if (_to == _To.queue)
            Flexible(
              child: queues.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(Gap.xl),
                  child: Center(child: CircularProgressIndicator.adaptive()),
                ),
                error: (_, _) =>
                    Text("Couldn't load the queues. Close this and try again.", style: context.text.bodyMedium),
                data: (list) => list.isEmpty
                    ? Text('No queues are set up for transfers in this campaign.', style: context.text.bodyMedium)
                    : SingleChildScrollView(
                        child: AppGroup(
                          children: [
                            for (final q in list)
                              AppRow(
                                selected: _queue?.id == q.id,
                                title: q.name,
                                subtitle: switch (q.readyAgents) {
                                  null => null,
                                  0 => 'No agents ready',
                                  1 => '1 agent ready',
                                  final n => '$n agents ready',
                                },
                                onTap: () => setState(() => _queue = q),
                              ),
                          ],
                        ),
                      ),
              ),
            )
          else
            TextField(
              controller: _number,
              autofocus: true,
              keyboardType: TextInputType.phone,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9+()\-\s]'))],
              decoration: const InputDecoration(labelText: 'Phone number'),
              onChanged: (_) => setState(() {}),
            ),
          const SizedBox(height: Gap.l),
          AppButton(
            label: ready ? 'Transfer to $dest' : (_to == _To.queue ? 'Pick a queue' : 'Enter a number'),
            icon: ready ? Ic.transfer : null,
            busy: _busy,
            onPressed: ready ? _go : null,
          ),
          const SizedBox(height: Gap.s),
          Text(
            '$who moves to $dest and your call ends. Then you wrap up.',
            textAlign: TextAlign.center,
            style: context.text.bodySmall?.copyWith(color: c.muted),
          ),
        ],
      ),
    );
  }
}

class KeypadSheet extends ConsumerStatefulWidget {
  const KeypadSheet({super.key});

  @override
  ConsumerState<KeypadSheet> createState() => _KeypadSheetState();
}

class _KeypadSheetState extends ConsumerState<KeypadSheet> {
  String _typed = '';

  static const _keys = [
    ('1', ''),
    ('2', 'ABC'),
    ('3', 'DEF'),
    ('4', 'GHI'),
    ('5', 'JKL'),
    ('6', 'MNO'),
    ('7', 'PQRS'),
    ('8', 'TUV'),
    ('9', 'WXYZ'),
    ('*', ''),
    ('0', '+'),
    ('#', ''),
  ];

  void _press(String d) {
    HapticFeedback.lightImpact();
    setState(() => _typed += d);
    ref.read(agentProvider.notifier).dtmf(d);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final keySize = context.ios ? 74.0 : 68.0;
    final radius = BorderRadius.circular(context.cardRadius + 2);
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.5,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Keypad', style: context.text.titleLarge, textAlign: context.ios ? TextAlign.center : TextAlign.start),
            const SizedBox(height: Gap.m),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Center(
                child: _typed.isEmpty
                    ? Text('Tones play as you tap', style: context.text.bodyMedium?.copyWith(color: c.muted))
                    : Text(
                        _typed,
                        style: TextStyle(fontSize: 30, letterSpacing: 4, color: c.ink, fontFeatures: tabular),
                        overflow: TextOverflow.ellipsis,
                      ),
              ),
            ),
            const SizedBox(height: Gap.s),
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: Gap.m,
              crossAxisSpacing: Gap.l,
              childAspectRatio: context.ios ? 1.25 : 1.4,
              children: [
                for (final k in _keys)
                  Center(
                    child: Semantics(
                      button: true,
                      label: k.$1 == '*' ? 'Star' : (k.$1 == '#' ? 'Pound' : k.$1),
                      child: Material(
                        color: c.fill,
                        shape: context.ios ? const CircleBorder() : RoundedRectangleBorder(borderRadius: radius),
                        child: InkWell(
                          customBorder: context.ios
                              ? const CircleBorder()
                              : RoundedRectangleBorder(borderRadius: radius),
                          onTap: () => _press(k.$1),
                          child: SizedBox(
                            width: context.ios ? keySize : keySize + 8,
                            height: keySize - (context.ios ? 0 : 6),
                            child: ExcludeSemantics(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(k.$1, style: TextStyle(fontSize: 26, color: c.ink, height: 1)),
                                  if (k.$2.isNotEmpty)
                                    Text(k.$2, style: TextStyle(fontSize: 9.5, letterSpacing: 1.2, color: c.ink2)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: Gap.s),
            Center(
              child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Hide keypad')),
            ),
          ],
        ),
      ),
    );
  }
}

class LeadSheet extends ConsumerWidget {
  const LeadSheet({super.key, required this.call});

  final CallContext call;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lead = call.lead;
    final rows = <(String, String)>[
      ('Phone', phone(call.phone)),
      if (lead != null && lead.place.isNotEmpty) ('Location', lead.place),
      if (call.queueName.isNotEmpty) ('Queue', call.queueName),
      if (lead != null && lead.lastResult.isNotEmpty) ('Last result', resultLabel(ref, lead.lastResult)),
      if (lead != null && lead.id.isNotEmpty) ('Lead', '#${lead.id}'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Avatar(name: call.displayName, icon: Ic.person),
              const SizedBox(width: Gap.m),
              Expanded(
                child: Text(
                  call.displayName.isEmpty ? 'Unknown caller' : call.displayName,
                  style: context.text.titleLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.l),
          AppGroup(
            children: [for (final r in rows) AppRow(title: r.$1, value: r.$2)],
          ),
          if (lead != null && lead.comments.isNotEmpty) ...[
            const SizedBox(height: Gap.l),
            AppGroup(
              header: 'Notes',
              children: [
                Padding(
                  padding: const EdgeInsets.all(Gap.l),
                  child: Text(lead.comments, style: context.text.bodyMedium),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Used by the router: which call screen the agent's state calls for.
String? callRouteFor(PresenceKind kind) => switch (kind) {
  PresenceKind.ringing => '/incoming',
  PresenceKind.onCall => '/call',
  PresenceKind.wrapUp => '/wrapup',
  _ => null,
};
