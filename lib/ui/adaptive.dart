import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'tokens.dart';

enum Ic {
  home(Icons.home_rounded, CupertinoIcons.house_fill),
  calls(Icons.history_rounded, CupertinoIcons.clock_fill),
  me(Icons.person_rounded, CupertinoIcons.person_crop_circle_fill),
  person(Icons.person_rounded, CupertinoIcons.person_fill),
  phone(Icons.call_rounded, CupertinoIcons.phone_fill),
  hangUp(Icons.call_end_rounded, CupertinoIcons.phone_down_fill),
  mic(Icons.mic_rounded, CupertinoIcons.mic_fill),
  micOff(Icons.mic_off_rounded, CupertinoIcons.mic_slash_fill),
  pause(Icons.pause_rounded, CupertinoIcons.pause_fill),
  play(Icons.play_arrow_rounded, CupertinoIcons.play_fill),
  keypad(Icons.dialpad_rounded, CupertinoIcons.circle_grid_3x3_fill),
  speaker(Icons.volume_up_rounded, CupertinoIcons.speaker_2_fill),
  transfer(Icons.phone_forwarded_rounded, CupertinoIcons.phone_fill_arrow_up_right),
  lead(Icons.badge_rounded, CupertinoIcons.person_crop_rectangle_fill),
  check(Icons.check_rounded, CupertinoIcons.check_mark),
  checkCircle(Icons.check_circle_rounded, CupertinoIcons.check_mark_circled_solid),
  chevron(Icons.chevron_right_rounded, CupertinoIcons.chevron_right),
  back(Icons.arrow_back_rounded, CupertinoIcons.chevron_left),
  search(Icons.search_rounded, CupertinoIcons.search),
  calendar(Icons.calendar_today_rounded, CupertinoIcons.calendar),
  clock(Icons.schedule_rounded, CupertinoIcons.clock),
  wifi(Icons.wifi_rounded, CupertinoIcons.wifi),
  alert(Icons.error_rounded, CupertinoIcons.exclamationmark_triangle_fill),
  bell(Icons.notifications_rounded, CupertinoIcons.bell_fill),
  lock(Icons.lock_rounded, CupertinoIcons.lock_fill),
  battery(Icons.battery_charging_full_rounded, CupertinoIcons.battery_full),
  pin(Icons.place_rounded, CupertinoIcons.location_solid),
  people(Icons.groups_rounded, CupertinoIcons.person_2_fill),
  send(Icons.send_rounded, CupertinoIcons.paperplane_fill),
  signOut(Icons.logout_rounded, CupertinoIcons.square_arrow_right),
  refresh(Icons.refresh_rounded, CupertinoIcons.refresh),
  theme(Icons.contrast_rounded, CupertinoIcons.circle_lefthalf_fill),
  wrapUp(Icons.edit_note_rounded, CupertinoIcons.square_pencil),
  eye(Icons.visibility_rounded, CupertinoIcons.eye),
  eyeOff(Icons.visibility_off_rounded, CupertinoIcons.eye_slash),
  close(Icons.close_rounded, CupertinoIcons.xmark);

  const Ic(this.material, this.cupertino);
  final IconData material;
  final IconData cupertino;
}

class AppIcon extends StatelessWidget {
  const AppIcon(this.icon, {super.key, this.size, this.color, this.semanticLabel});

  final Ic icon;
  final double? size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) =>
      Icon(context.ios ? icon.cupertino : icon.material, size: size, color: color, semanticLabel: semanticLabel);
}

/// The screen header: a small top app bar on Android, a navigation row plus a
/// large title on iOS. Place it outside any padded scroll view so the title
/// shares one left edge with the rest of the screen.
class AppHeader extends StatelessWidget {
  const AppHeader({super.key, required this.title, this.backLabel, this.onBack, this.trailing, this.large = true});

  final String title;
  final String? backLabel;
  final VoidCallback? onBack;
  final Widget? trailing;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (!context.ios) {
      return SizedBox(
        height: 64,
        child: Row(
          children: [
            if (onBack != null)
              IconButton(onPressed: onBack, icon: const AppIcon(Ic.back), tooltip: 'Back')
            else
              const SizedBox(width: Gap.l),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(title, style: context.text.titleLarge, overflow: TextOverflow.ellipsis),
              ),
            ),
            if (trailing != null)
              Padding(
                padding: const EdgeInsets.only(right: Gap.l),
                child: trailing,
              ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 44,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // The small title sits in the middle of the bar, whatever the back label's width.
              if (!large)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 96),
                  child: Semantics(
                    header: true,
                    child: Text(title, style: context.text.titleMedium, overflow: TextOverflow.ellipsis),
                  ),
                ),
              Row(
                children: [
                  if (onBack != null)
                    CupertinoButton(
                      padding: const EdgeInsets.only(left: 8, right: 12),
                      onPressed: onBack,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AppIcon(Ic.back, color: c.ink, size: 24),
                          Text(backLabel ?? 'Back', style: TextStyle(color: c.ink, fontSize: 17)),
                        ],
                      ),
                    ),
                  const Spacer(),
                  if (trailing != null)
                    Padding(
                      padding: const EdgeInsets.only(right: Gap.l),
                      child: trailing,
                    ),
                ],
              ),
            ],
          ),
        ),
        if (large)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.s),
            child: Semantics(header: true, child: Text(title, style: context.text.headlineSmall)),
          ),
      ],
    );
  }
}

enum ButtonKind { primary, ready, secondary, danger }

class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.kind = ButtonKind.primary,
    this.icon,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final ButtonKind kind;
  final Ic? icon;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final child = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (busy)
          SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator.adaptive(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(c.ink2)),
          )
        else if (icon != null)
          AppIcon(icon!, size: 20),
        if (busy || icon != null) const SizedBox(width: Gap.s),
        Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
      ],
    );
    final pressed = busy ? null : onPressed;
    switch (kind) {
      case ButtonKind.secondary:
        return OutlinedButton(onPressed: pressed, child: child);
      case ButtonKind.primary:
        return FilledButton(onPressed: pressed, child: child);
      case ButtonKind.ready:
      case ButtonKind.danger:
        // Disabled looks the same for every kind, so a greyed button never reads as a state color.
        return FilledButton(
          onPressed: pressed,
          style: FilledButton.styleFrom(
            backgroundColor: kind == ButtonKind.ready ? c.ready.fg : c.decline,
            foregroundColor: kind == ButtonKind.ready ? c.onState : Colors.white,
            disabledBackgroundColor: c.fill,
            disabledForegroundColor: c.ink2,
          ),
          child: child,
        );
    }
  }
}

/// Material switch on Android; iOS switch (green when on) on iPhone.
class AppSwitch extends StatelessWidget {
  const AppSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    if (context.ios) {
      return CupertinoSwitch(value: value, onChanged: onChanged, activeTrackColor: context.colors.ready.fg);
    }
    return Switch(value: value, onChanged: onChanged);
  }
}

class AppSegmented<T extends Object> extends StatelessWidget {
  const AppSegmented({super.key, required this.segments, required this.value, required this.onChanged});

  final Map<T, String> segments;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    if (context.ios) {
      // iOS's own segment colors: they already adapt to light, dark and sheets.
      return SizedBox(
        width: double.infinity,
        child: CupertinoSlidingSegmentedControl<T>(
          groupValue: value,
          children: {
            for (final e in segments.entries)
              e.key: Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text(e.value)),
          },
          onValueChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      );
    }
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<T>(
        showSelectedIcon: false,
        segments: [for (final e in segments.entries) ButtonSegment(value: e.key, label: Text(e.value))],
        selected: {value},
        onSelectionChanged: (s) => onChanged(s.first),
      ),
    );
  }
}

/// Marks content shown inside a bottom sheet, so grouped lists can lift
/// themselves off the sheet in iOS dark mode, where sheet and card share a color.
class SheetScope extends InheritedWidget {
  const SheetScope({super.key, required super.child});

  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<SheetScope>() != null;

  @override
  bool updateShouldNotify(SheetScope oldWidget) => false;
}

/// A rounded card of rows: Material list card on Android, inset grouped list on iOS.
class AppGroup extends StatelessWidget {
  const AppGroup({super.key, required this.children, this.header, this.footer});

  final List<Widget> children;
  final String? header;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final lifted = context.ios && Theme.of(context).brightness == Brightness.dark && SheetScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (header != null)
          Padding(
            padding: EdgeInsets.fromLTRB(context.ios ? Gap.l : Gap.xs, 0, Gap.l, Gap.s),
            child: Semantics(
              header: true,
              child: Text(
                context.ios ? header!.toUpperCase() : header!,
                style: context.ios
                    ? TextStyle(fontSize: 13, color: c.muted, letterSpacing: 0.2)
                    : context.text.titleSmall?.copyWith(color: c.ink2, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: lifted ? c.fill : c.card,
            borderRadius: BorderRadius.circular(context.cardRadius),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(context.cardRadius),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  children[i],
                  if (i < children.length - 1) Divider(height: 1, indent: context.ios ? Gap.l : 0),
                ],
              ],
            ),
          ),
        ),
        if (footer != null)
          Padding(
            padding: EdgeInsets.fromLTRB(context.ios ? Gap.l : Gap.xs, Gap.s, Gap.l, 0),
            child: Text(footer!, style: context.text.bodySmall),
          ),
      ],
    );
  }
}

/// A list row.
///
/// * [selected] makes a choice row: a radio (or a checkbox with [multi]) in
///   front on Android, a checkmark at the end on iOS.
/// * [toggle] makes a switch row: the whole row flips it and reads as one control.
/// * [value] puts a quiet secondary value at the end.
class AppRow extends StatelessWidget {
  const AppRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.titleColor,
    this.chevron = false,
    this.selected,
    this.multi = false,
    this.toggle,
    this.onToggle,
    this.value,
    this.valueColor,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? titleColor;
  final bool chevron;
  final bool? selected;
  final bool multi;
  final bool? toggle;
  final ValueChanged<bool>? onToggle;
  final String? value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final ios = context.ios;
    var lead = leading;
    var trail = trailing;
    var tap = onTap;
    if (selected != null) {
      if (ios) {
        trail = SizedBox(width: 22, child: selected! ? AppIcon(Ic.check, color: c.ink, size: 20) : null);
      } else {
        lead = multi ? CheckMark(checked: selected!) : ChoiceMark(selected: selected!);
      }
    }
    if (toggle != null) {
      final flip = onToggle;
      trail = AppSwitch(value: toggle!, onChanged: flip);
      tap = flip == null ? null : () => flip(!toggle!);
    }
    if (value != null) {
      trail = Text(
        value!,
        style: context.text.bodyMedium?.copyWith(
          color: valueColor ?? c.ink2,
          fontWeight: ios ? FontWeight.w400 : FontWeight.w500,
          fontFeatures: tabular,
        ),
      );
    }
    final row = ConstrainedBox(
      constraints: BoxConstraints(minHeight: subtitle == null ? Touch.min(context) + 4 : 60),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.s),
        child: Row(
          children: [
            if (lead != null) ...[lead, const SizedBox(width: Gap.m)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: context.text.bodyLarge?.copyWith(color: titleColor)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!, style: context.text.bodySmall?.copyWith(color: c.muted)),
                  ],
                ],
              ),
            ),
            if (trail != null) ...[const SizedBox(width: Gap.m), trail],
            if (chevron) ...[const SizedBox(width: Gap.xs), AppIcon(Ic.chevron, color: c.muted, size: 18)],
          ],
        ),
      ),
    );
    Widget result = tap == null
        ? row
        : Material(
            type: MaterialType.transparency,
            child: InkWell(onTap: tap, child: row),
          );
    if (selected != null) {
      result = Semantics(
        selected: multi ? null : selected,
        checked: multi ? selected : null,
        inMutuallyExclusiveGroup: multi ? null : true,
        child: result,
      );
    }
    if (toggle != null) result = MergeSemantics(child: result);
    return result;
  }
}

/// Radio mark for single-choice rows on Android.
class ChoiceMark extends StatelessWidget {
  const ChoiceMark({super.key, required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ExcludeSemantics(
      child: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: selected ? c.ink : c.muted, width: 2),
        ),
        alignment: Alignment.center,
        child: selected
            ? Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(shape: BoxShape.circle, color: c.ink),
              )
            : null,
      ),
    );
  }
}

/// Checkbox mark for multi-choice rows on Android.
class CheckMark extends StatelessWidget {
  const CheckMark({super.key, required this.checked});

  final bool checked;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ExcludeSemantics(
      child: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: checked ? c.ink : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: checked ? c.ink : c.muted, width: 2),
        ),
        child: checked ? AppIcon(Ic.check, color: c.bg, size: 15) : null,
      ),
    );
  }
}

Future<T?> showAppSheet<T>(BuildContext context, WidgetBuilder builder) {
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => SheetScope(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: SafeArea(top: false, child: builder(ctx)),
      ),
    ),
  );
}

/// A yes/no question with the safe answer first. Returns true for the action.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
  bool destructive = false,
}) async {
  final r = await showAdaptiveDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog.adaptive(
      title: Text(title),
      content: Text(body),
      actions: [
        _dialogAction(ctx, 'Cancel', () => Navigator.pop(ctx, false)),
        _dialogAction(ctx, action, () => Navigator.pop(ctx, true), destructive: destructive, primary: true),
      ],
    ),
  );
  return r ?? false;
}

Widget _dialogAction(
  BuildContext ctx,
  String label,
  VoidCallback onTap, {
  bool destructive = false,
  bool primary = false,
}) {
  if (isIOS(ctx)) {
    return CupertinoDialogAction(
      onPressed: onTap,
      isDestructiveAction: destructive,
      isDefaultAction: primary,
      child: Text(label),
    );
  }
  return TextButton(
    onPressed: onTap,
    child: Text(label, style: destructive ? TextStyle(color: ctx.colors.problem.fg) : null),
  );
}

void showMessage(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
