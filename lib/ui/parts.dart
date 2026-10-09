import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/clock.dart';
import '../core/format.dart';
import '../data/models.dart';
import 'adaptive.dart';
import 'tokens.dart';

/// The big card on Home: state word, reason, a timer, and one action.
class StatusCard extends StatelessWidget {
  const StatusCard({
    super.key,
    required this.tone,
    required this.label,
    required this.reason,
    required this.timer,
    this.trailing,
    this.actions = const [],
    this.note,
  });

  final StateTone tone;
  final String label;
  final String reason;
  final String timer;
  final Widget? trailing;
  final List<Widget> actions;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      container: true,
      label: '$label, $reason, $timer',
      child: Container(
        padding: const EdgeInsets.fromLTRB(Gap.l + 2, Gap.l, Gap.l + 2, Gap.l + 2),
        decoration: BoxDecoration(color: tone.bg, borderRadius: BorderRadius.circular(context.cardRadius)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(color: tone.fg, shape: BoxShape.circle),
                ),
                const SizedBox(width: Gap.s),
                Text(label.toUpperCase(), style: context.text.labelSmall?.copyWith(color: tone.fg)),
              ],
            ),
            const SizedBox(height: Gap.xs),
            Row(
              children: [
                Expanded(child: Text(reason, style: context.text.titleMedium)),
                ?trailing,
              ],
            ),
            Text(
              timer,
              style: TextStyle(
                fontSize: 46,
                height: 1.1,
                fontWeight: context.ios ? FontWeight.w700 : FontWeight.w600,
                letterSpacing: -1,
                color: c.ink,
                fontFeatures: tabular,
              ),
            ),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: Gap.m),
              for (var i = 0; i < actions.length; i++) ...[if (i > 0) const SizedBox(height: Gap.s), actions[i]],
            ],
            if (note != null) ...[const SizedBox(height: Gap.s), Text(note!, style: context.text.bodySmall)],
          ],
        ),
      ),
    );
  }
}

/// The colored strip at the top of call screens: the state, where the call
/// came from, and (when the screen has no bigger timer) how long it has run.
class StateBand extends StatelessWidget {
  const StateBand({
    super.key,
    required this.tone,
    required this.icon,
    required this.label,
    required this.subtitle,
    this.timer,
  });

  final StateTone tone;
  final Ic icon;
  final String label;
  final String subtitle;
  final String? timer;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return Container(
      color: tone.bg,
      padding: EdgeInsets.fromLTRB(Gap.l + 2, top + Gap.m, Gap.l + 2, Gap.m + 2),
      child: Row(
        children: [
          Expanded(
            // Only the state and subtitle are announced when they change; a
            // ticking timer inside a live region would be read out every second.
            child: Semantics(
              container: true,
              liveRegion: true,
              label: '$label, $subtitle',
              child: ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        AppIcon(icon, size: 16, color: tone.fg),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            label.toUpperCase(),
                            style: context.text.labelSmall?.copyWith(color: tone.fg, fontSize: 13),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: context.text.bodyMedium?.copyWith(color: context.colors.ink2),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (timer != null)
            Text(
              timer!,
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w600,
                color: context.colors.ink,
                fontFeatures: tabular,
              ),
            ),
        ],
      ),
    );
  }
}

class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.name,
    this.size = 46,
    this.background,
    this.foreground,
    this.icon = Ic.person,
  });

  final String name;
  final double size;
  final Color? background;
  final Color? foreground;

  /// Shown when [name] has no letters (a phone number or a numeric user ID).
  final Ic icon;

  @override
  Widget build(BuildContext context) {
    final fg = foreground ?? context.colors.ink;
    final hasLetters = RegExp(r'[A-Za-z]').hasMatch(name);
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: background ?? context.colors.fill, shape: BoxShape.circle),
        child: hasLetters
            ? Text(
                initials(name),
                // The circle has a fixed size, so its letters can't grow with the text setting.
                textScaler: TextScaler.noScaling,
                style: TextStyle(fontSize: size * 0.34, fontWeight: FontWeight.w700, color: fg),
              )
            : AppIcon(icon, size: size * 0.46, color: fg),
      ),
    );
  }
}

/// Who the agent is talking to. With [header] off, only the facts and notes
/// show, for screens that already put the name and number above.
class LeadCard extends ConsumerWidget {
  const LeadCard({super.key, required this.call, this.header = true, this.lastResultLabel});

  final CallContext call;
  final bool header;

  /// The human label for the lead's last result, when the caller knows it.
  final String? lastResultLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final lead = call.lead;
    final name = call.displayName.isEmpty ? 'Unknown caller' : call.displayName;
    final number = phone(call.phone);
    final local = localTimeAt(lead?.gmtOffset, now: ref.watch(nowProvider)());
    final facts = <(Ic, String)>[
      if (lead != null && (lead.place.isNotEmpty || local != null))
        (
          Ic.pin,
          [
            if (lead.place.isNotEmpty) lead.place,
            if (local != null) '${timeOfDay(local, h24: MediaQuery.alwaysUse24HourFormatOf(context))} local',
          ].join(' · '),
        ),
      if (lead != null && lead.lastResult.isNotEmpty && lead.lastResult != 'NEW')
        (Ic.clock, 'Last result: ${lastResultLabel ?? lead.lastResult}'),
    ];
    final notes = lead?.comments ?? '';
    if (!header && lead != null && facts.isEmpty && notes.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Gap.l),
      decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(context.cardRadius)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (header)
            Row(
              children: [
                Avatar(name: name, icon: Ic.person),
                const SizedBox(width: Gap.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: context.text.titleMedium, overflow: TextOverflow.ellipsis),
                      if (number.isNotEmpty && number != name)
                        Text(
                          number,
                          style: context.text.bodyMedium?.copyWith(color: c.ink2, fontFeatures: tabular),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          if (facts.isNotEmpty) ...[
            if (header) const SizedBox(height: Gap.m),
            for (var i = 0; i < facts.length; i++)
              Padding(
                padding: EdgeInsets.only(top: i == 0 ? 0 : 6),
                child: Row(
                  children: [
                    AppIcon(facts[i].$1, size: 15, color: c.muted),
                    const SizedBox(width: Gap.s),
                    Expanded(child: Text(facts[i].$2, style: context.text.bodySmall)),
                  ],
                ),
              ),
          ],
          if (notes.isNotEmpty) ...[
            if (header || facts.isNotEmpty) const SizedBox(height: Gap.m),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
              decoration: BoxDecoration(color: c.fill, borderRadius: BorderRadius.circular(context.cardRadius - 6)),
              child: Text(notes, style: context.text.bodySmall, maxLines: 4, overflow: TextOverflow.ellipsis),
            ),
          ],
          if (lead == null) ...[
            if (header) const SizedBox(height: Gap.s),
            Text('Looking up the customer…', style: context.text.bodySmall?.copyWith(color: c.muted)),
          ],
        ],
      ),
    );
  }
}

class StatsGrid extends StatelessWidget {
  const StatsGrid({super.key, required this.stats});

  final TodayStats stats;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget cell(String value, String label) => Container(
      color: c.card,
      padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.s + 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600, color: c.ink, fontFeatures: tabular),
          ),
          Text(label, style: context.text.bodySmall),
        ],
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(context.cardRadius),
      child: ColoredBox(
        color: c.line,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(child: cell('${stats.calls}', 'Calls')),
                const SizedBox(width: 1),
                Expanded(child: cell(span(stats.talk), 'Talk time')),
              ],
            ),
            const SizedBox(height: 1),
            Row(
              children: [
                Expanded(child: cell(clock(stats.average), 'Average call')),
                const SizedBox(width: 1),
                Expanded(child: cell(span(stats.paused), 'Paused')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class Chip2 extends StatelessWidget {
  const Chip2({super.key, required this.label, this.selected = false, this.onTap});

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final chip = Container(
      constraints: const BoxConstraints(minHeight: 40),
      padding: const EdgeInsets.symmetric(horizontal: Gap.m + 2, vertical: Gap.s),
      decoration: BoxDecoration(
        color: selected ? c.ink : (context.ios ? c.fill : c.card),
        borderRadius: BorderRadius.circular(context.ios ? 999 : 10),
        border: context.ios || selected ? null : Border.all(color: c.line2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: context.text.bodyMedium?.copyWith(fontWeight: FontWeight.w500, color: selected ? c.bg : c.ink),
          ),
        ],
      ),
    );
    if (onTap == null) return chip;
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(onTap: onTap, behavior: HitTestBehavior.opaque, child: chip),
    );
  }
}

class Banner2 extends StatelessWidget {
  const Banner2({super.key, required this.tone, required this.title, required this.body, this.action, this.onAction});

  final StateTone tone;
  final String title;
  final String body;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(Gap.m + 2),
        decoration: BoxDecoration(color: tone.bg, borderRadius: BorderRadius.circular(context.cardRadius)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppIcon(Ic.alert, color: tone.fg, size: 20),
            const SizedBox(width: Gap.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: context.text.bodyMedium?.copyWith(fontWeight: FontWeight.w700, color: tone.fg),
                  ),
                  const SizedBox(height: 2),
                  Text(body, style: context.text.bodyMedium),
                ],
              ),
            ),
            if (action != null) ...[
              const SizedBox(width: Gap.s),
              FilledButton(
                onPressed: onAction,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(64, 40),
                  padding: const EdgeInsets.symmetric(horizontal: Gap.l),
                  backgroundColor: tone.fg,
                  foregroundColor: context.colors.onState,
                  shape: context.ios
                      ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(context.cardRadius - 4))
                      : const StadiumBorder(),
                ),
                child: Text(action!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A call's result. Neutral, because color means agent state; only Do not
/// call is red, since it stops the number being dialled again.
class ResultTag extends StatelessWidget {
  const ResultTag({super.key, required this.code, required this.label});

  final String code;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final upper = code.toUpperCase();
    final (fg, bg) = switch (upper) {
      'DNC' || 'DNCL' => (c.problem.fg, c.problem.bg),
      _ => (c.ink2, c.fill),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg),
      ),
    );
  }
}

class StatePill extends StatelessWidget {
  const StatePill({super.key, required this.tone, required this.label});

  final StateTone tone;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(color: tone.bg, borderRadius: BorderRadius.circular(999)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: tone.fg, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: tone.fg, fontFeatures: tabular),
        ),
      ],
    ),
  );
}

/// A labelled round call control. A [toggle] (mute, speaker, hold) shows its
/// on state by filling in, keeps its name, and reads as on or off to screen
/// readers; the other controls open something and read as plain buttons.
class CallControl extends StatelessWidget {
  const CallControl({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.toggle = false,
    this.on = false,
    this.onTone,
  });

  final Ic icon;
  final String label;
  final VoidCallback? onTap;
  final bool toggle;
  final bool on;
  final StateTone? onTone;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final size = context.ios ? 66.0 : 62.0;
    final lit = toggle && on;
    final bg = lit ? (onTone?.fg ?? c.ink) : (context.ios ? c.fill : c.card);
    final fg = lit ? (onTone != null ? c.onState : c.bg) : c.ink;
    return Semantics(
      button: true,
      enabled: onTap != null,
      toggled: toggle ? on : null,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: bg,
                shape: context.ios ? BoxShape.circle : BoxShape.rectangle,
                borderRadius: context.ios ? null : BorderRadius.circular(context.cardRadius + 4),
                border: context.ios || lit ? null : Border.all(color: c.line),
              ),
              child: Opacity(
                opacity: onTap == null ? 0.4 : 1,
                child: AppIcon(icon, color: fg, size: 26),
              ),
            ),
            const SizedBox(height: 6),
            ExcludeSemantics(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: lit ? FontWeight.w600 : FontWeight.w500,
                  color: onTap == null ? c.muted : (lit ? c.ink : c.ink2),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
