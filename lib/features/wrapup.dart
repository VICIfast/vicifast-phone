import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../core/clock.dart';
import '../core/errors.dart';
import '../core/format.dart';
import '../data/models.dart';
import '../state/agent.dart';
import '../state/services.dart';
import '../state/session.dart';
import '../ui/adaptive.dart';
import '../ui/parts.dart';
import '../ui/tokens.dart';
import 'home.dart';

class WrapUpScreen extends ConsumerStatefulWidget {
  const WrapUpScreen({super.key});

  @override
  ConsumerState<WrapUpScreen> createState() => _WrapUpScreenState();
}

class _WrapUpScreenState extends ConsumerState<WrapUpScreen> {
  Disposition? _pick;
  String _query = '';
  bool _busy = false;
  List<String> _recent = const [];

  @override
  void initState() {
    super.initState();
    final campaign = ref.read(sessionProvider).value?.campaignId;
    if (campaign != null) {
      ref.read(storeProvider).recentResults(campaign).then((r) {
        if (mounted) setState(() => _recent = r);
      });
    }
  }

  Future<void> _save() async {
    final d = _pick;
    if (d == null) return;
    final call = ref.read(agentProvider).call;
    CallbackPick? callback;
    if (d.callback) {
      callback = await showAppSheet<CallbackPick>(context, (_) => CallbackSheet(call: call ?? const CallContext()));
      if (callback == null) return;
    }
    if (!mounted) return;
    if (d.dnc) {
      final ok = await confirm(
        context,
        title: 'Add to do-not-call?',
        body:
            '${phone(call?.phone)} will not be called again by any campaign. This can only be undone by a supervisor.',
        action: 'Do not call',
        destructive: true,
      );
      if (!ok) return;
    }
    final agent = ref.read(agentProvider.notifier);
    setState(() => _busy = true);
    try {
      // Saving routes away from this screen; nothing may use ref after it.
      await agent.saveResult(
        d,
        note: callback?.note,
        callbackAt: callback?.at,
        callbackOnlyMe: callback?.onlyMe ?? false,
      );
    } on AppError catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final p = ref.watch(agentProvider);
    final campaign = ref.watch(sessionProvider).value?.campaignId ?? '';
    final results = ref.watch(resultsProvider(campaign));
    final call = p.call ?? const CallContext();
    final talked = p.callStart == null ? null : p.since.difference(p.callStart!);
    final who = call.displayName.isEmpty ? 'Last call' : call.displayName;
    final saveLabel = !p.lineUp ? 'Save' : (p.pauseAfterCall ? 'Save and pause' : 'Save and go ready');

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Elapsed(
            since: p.since,
            builder: (_, d) => StateBand(
              tone: c.wrap,
              icon: Ic.wrapUp,
              label: 'Wrap up',
              timer: clock(d),
              subtitle: talked == null ? who : '$who · ${talk(talked)} call',
            ),
          ),
          Expanded(
            child: results.when(
              loading: () => const Center(child: CircularProgressIndicator.adaptive()),
              error: (e, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(Gap.xl),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text("Couldn't load the results.", style: context.text.bodyLarge),
                      const SizedBox(height: Gap.m),
                      AppButton(
                        label: 'Try again',
                        kind: ButtonKind.secondary,
                        onPressed: () => ref.invalidate(resultsProvider(campaign)),
                      ),
                    ],
                  ),
                ),
              ),
              data: (all) {
                final q = _query.trim().toLowerCase();
                final shown = q.isEmpty
                    ? all
                    : all.where((d) => d.label.toLowerCase().contains(q) || d.code.toLowerCase().contains(q)).toList();
                // Older saves kept codes upper-cased; match either way.
                final recent = [
                  for (final code in _recent) ...all.where((d) => d.code.toUpperCase() == code.toUpperCase()),
                ];
                return ListView(
                  padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.l, Gap.l),
                  children: [
                    if (all.length > 6) ...[
                      TextField(
                        onChanged: (v) => setState(() => _query = v),
                        decoration: InputDecoration(
                          hintText: 'Find a result',
                          prefixIcon: AppIcon(Ic.search, color: c.muted, size: 20),
                          filled: true,
                          fillColor: c.fill,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(context.ios ? 10 : 999),
                            borderSide: BorderSide.none,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(context.ios ? 10 : 999),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                      ),
                      const SizedBox(height: Gap.m),
                    ],
                    if (recent.isNotEmpty && q.isEmpty) ...[
                      Wrap(
                        spacing: Gap.s,
                        runSpacing: Gap.s,
                        children: [
                          for (final d in recent)
                            Chip2(
                              label: d.label,
                              selected: _pick?.code == d.code,
                              onTap: () => setState(() => _pick = d),
                            ),
                        ],
                      ),
                      const SizedBox(height: Gap.m),
                    ],
                    if (shown.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(Gap.l),
                        child: Text('No result matches "$_query".', style: context.text.bodyMedium),
                      )
                    else
                      AppGroup(
                        children: [
                          for (final d in shown)
                            AppRow(
                              selected: _pick?.code == d.code,
                              title: d.label,
                              titleColor: d.dnc ? c.problem.fg : null,
                              subtitle: d.dnc
                                  ? 'Adds the number to the do-not-call list'
                                  : (d.callback ? 'Asks when to call back' : null),
                              onTap: () => setState(() => _pick = d),
                            ),
                        ],
                      ),
                    const SizedBox(height: Gap.l),
                    AppGroup(
                      children: [
                        AppRow(
                          title: 'Pause after this call',
                          subtitle: 'Take a break instead of the next call',
                          toggle: p.pauseAfterCall,
                          onToggle: (v) => ref.read(agentProvider.notifier).setPauseAfterCall(v),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.l),
              child: AppButton(
                label: _pick == null ? 'Pick a result' : saveLabel,
                busy: _busy,
                onPressed: _pick == null ? null : _save,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

OutlineInputBorder _wellBorder(BuildContext context, {Color? focus}) => OutlineInputBorder(
  borderRadius: BorderRadius.circular(context.cardRadius),
  borderSide: focus == null ? BorderSide.none : BorderSide(color: focus, width: 1.5),
);

/// Allowed calling hours on the customer's clock: 8 AM to 9 PM, the usual US
/// (TCPA) window.
const _firstHour = 8;
const _lastHour = 21;

bool _inCallingHours(DateTime wall) =>
    wall.hour >= _firstHour && (wall.hour < _lastHour || (wall.hour == _lastHour && wall.minute == 0));

typedef CallbackPick = ({DateTime at, bool onlyMe, String note});

/// Quick picks in the customer's local time; returns the exact moment.
class CallbackSheet extends ConsumerStatefulWidget {
  const CallbackSheet({super.key, required this.call});

  final CallContext call;

  @override
  ConsumerState<CallbackSheet> createState() => _CallbackSheetState();
}

class _CallbackSheetState extends ConsumerState<CallbackSheet> {
  DateTime? _at;
  bool _onlyMe = false;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  double? get _offset => widget.call.lead?.gmtOffset;

  /// "Now" on the customer's wall clock (or the phone's, when unknown), as a
  /// plain local DateTime so pickers compare it with the times they produce.
  DateTime _theirNow() {
    final now = ref.read(nowProvider)();
    final t = localTimeAt(_offset, now: now);
    return t == null ? now : DateTime(t.year, t.month, t.day, t.hour, t.minute, t.second);
  }

  /// A wall-clock time in the customer's zone → the real moment it happens.
  DateTime _toMoment(DateTime wall) {
    final o = _offset;
    if (o == null) return wall;
    final asUtc = DateTime.utc(wall.year, wall.month, wall.day, wall.hour, wall.minute);
    return asUtc.subtract(Duration(minutes: (o * 60).round()));
  }

  DateTime _wallOf(DateTime moment) {
    final o = _offset;
    if (o == null) return moment.toLocal();
    final shifted = moment.toUtc().add(Duration(minutes: (o * 60).round()));
    return DateTime(shifted.year, shifted.month, shifted.day, shifted.hour, shifted.minute);
  }

  List<(String, DateTime)> _quickPicks(bool h24) {
    final now = _theirNow();
    String at(DateTime t) => timeOfDay(t, h24: h24);
    // Five-minute steps read better than 11:14.
    final soon = now.add(Duration(minutes: 60 + (5 - now.minute % 5) % 5));
    final inHour = DateTime(soon.year, soon.month, soon.day, soon.hour, soon.minute);
    final today9 = DateTime(now.year, now.month, now.day, 9);
    final tomorrow9 = DateTime(now.year, now.month, now.day + 1, 9);
    var monday = tomorrow9;
    while (monday.weekday != DateTime.monday) {
      monday = monday.add(const Duration(days: 1));
    }
    return [
      // Never offer a time outside calling hours: before 8 AM the first pick
      // becomes this morning at 9; late in the evening, tomorrow covers it.
      if (inHour.day == now.day && _inCallingHours(inHour))
        ('In 1 hour · ${at(inHour)}', _toMoment(inHour))
      else if (now.isBefore(today9))
        ('This morning · ${at(today9)}', _toMoment(today9)),
      ('Tomorrow · ${at(tomorrow9)}', _toMoment(tomorrow9)),
      if (monday.difference(tomorrow9).inDays > 0) ('Monday · ${at(monday)}', _toMoment(monday)),
    ];
  }

  Future<void> _custom() async {
    final base = _at == null ? _theirNow().add(const Duration(hours: 1)) : _wallOf(_at!);
    final start = DateTime(
      base.year,
      base.month,
      base.day,
      base.hour,
      base.minute - base.minute % 5 + (base.minute % 5 == 0 ? 0 : 5),
    );
    DateTime? wall;
    if (context.ios) {
      var picked = start;
      final done = await showCupertinoModalPopup<bool>(
        context: context,
        builder: (ctx) => Container(
          height: 300,
          color: context.colors.card,
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                Row(
                  children: [
                    CupertinoButton(child: const Text('Cancel'), onPressed: () => Navigator.pop(ctx, false)),
                    const Spacer(),
                    CupertinoButton(
                      child: const Text('Done', style: TextStyle(fontWeight: FontWeight.w600)),
                      onPressed: () => Navigator.pop(ctx, true),
                    ),
                  ],
                ),
                Expanded(
                  child: CupertinoDatePicker(
                    initialDateTime: start,
                    minimumDate: _theirNow().subtract(const Duration(minutes: 1)),
                    minuteInterval: 5,
                    use24hFormat: MediaQuery.alwaysUse24HourFormatOf(context),
                    onDateTimeChanged: (v) => picked = v,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      if (done != true) return;
      wall = picked;
    } else {
      final date = await showDatePicker(
        context: context,
        initialDate: start,
        firstDate: _theirNow(),
        lastDate: _theirNow().add(const Duration(days: 365)),
      );
      if (date == null || !mounted) return;
      final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(start));
      if (time == null) return;
      wall = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    }
    setState(() => _at = _toMoment(wall!));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final name = widget.call.displayName.isEmpty ? 'the customer' : widget.call.displayName.split(' ').first;
    final where = widget.call.lead?.place ?? '';
    final h24 = MediaQuery.alwaysUse24HourFormatOf(context);
    final picks = _quickPicks(h24);
    final chosenWall = _at == null ? null : _wallOf(_at!);
    final custom = chosenWall != null && !picks.any((pk) => pk.$2 == _at);
    final day = DateFormat('EEE d MMM');
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Call back $name',
            style: context.text.titleLarge,
            textAlign: context.ios ? TextAlign.center : TextAlign.start,
          ),
          const SizedBox(height: Gap.xs),
          Text(
            _offset == null
                ? 'Times are your local time.'
                : 'Times are $name’s local time${where.isEmpty ? '' : ' · $where'}.',
            style: context.text.bodyMedium?.copyWith(color: c.ink2),
            textAlign: context.ios ? TextAlign.center : TextAlign.start,
          ),
          const SizedBox(height: Gap.l),
          Wrap(
            spacing: Gap.s,
            runSpacing: Gap.s,
            children: [
              for (final pk in picks)
                Chip2(label: pk.$1, selected: _at == pk.$2, onTap: () => setState(() => _at = pk.$2)),
            ],
          ),
          const SizedBox(height: Gap.l),
          AppGroup(
            children: [
              AppRow(
                leading: AppIcon(Ic.calendar, color: c.ink2, size: 20),
                title: custom
                    ? '${day.format(chosenWall)} · ${timeOfDay(chosenWall, h24: h24)}'
                    : 'Pick a date and time',
                chevron: true,
                onTap: _custom,
              ),
              AppRow(
                title: 'Keep this callback for me',
                subtitle: 'Off: any agent on this campaign can take it',
                toggle: _onlyMe,
                onToggle: (v) => setState(() => _onlyMe = v),
              ),
            ],
          ),
          if (chosenWall != null && !_inCallingHours(chosenWall)) ...[
            const SizedBox(height: Gap.s),
            Semantics(
              liveRegion: true,
              child: Text(
                'That’s outside 8 AM to 9 PM for $name. Calls then may break calling-hour rules.',
                style: context.text.bodySmall?.copyWith(color: c.problem.fg),
              ),
            ),
          ],
          const SizedBox(height: Gap.l),
          TextField(
            controller: _note,
            maxLines: 3,
            minLines: 1,
            maxLength: 200,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: 'Note for the callback (optional)',
              filled: true,
              // A white field on a white Android sheet (or a dark one on a dark
              // sheet) has no edge; only the grey iOS light sheet takes a card.
              fillColor: context.ios && Theme.of(context).brightness == Brightness.light ? c.card : c.fill,
              border: _wellBorder(context),
              enabledBorder: _wellBorder(context),
              focusedBorder: _wellBorder(context, focus: c.ink),
            ),
          ),
          const SizedBox(height: Gap.s),
          AppButton(
            label: chosenWall == null
                ? 'Pick a time'
                : 'Schedule for ${DateFormat.E().format(chosenWall)} ${timeOfDay(chosenWall, h24: h24)}',
            onPressed: _at == null
                ? null
                : () => Navigator.pop<CallbackPick>(context, (at: _at!, onlyMe: _onlyMe, note: _note.text.trim())),
          ),
        ],
      ),
    );
  }
}
