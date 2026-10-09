import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../platform/phone_setup.dart';
import '../state/services.dart';
import '../state/shift.dart';
import '../ui/adaptive.dart';
import '../ui/tokens.dart';

/// Set once the agent has been through phone setup in this app run.
class SetupSeen extends Notifier<bool> {
  @override
  bool build() => false;
  void done() => state = true;
}

final setupSeenProvider = NotifierProvider<SetupSeen, bool>(SetupSeen.new);

extension SetupCopy on SetupItem {
  Ic get icon => switch (this) {
    SetupItem.microphone => Ic.mic,
    SetupItem.notifications => Ic.bell,
    SetupItem.lockScreenCalls => Ic.lock,
    SetupItem.battery => Ic.battery,
  };

  String get title => switch (this) {
    SetupItem.microphone => 'Microphone',
    SetupItem.notifications => 'Notifications',
    SetupItem.lockScreenCalls => 'Calls on lock screen',
    SetupItem.battery => 'Unrestricted battery',
  };

  String get why => switch (this) {
    SetupItem.microphone => 'Customers hear you',
    SetupItem.notifications => 'Shows your status and missed calls',
    SetupItem.lockScreenCalls => 'Rings you while the phone is locked',
    SetupItem.battery => 'Keeps the line open all shift',
  };

  bool get required => this == SetupItem.microphone;
}

class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    // Coming back from the system settings page is the moment a switch changed.
    _life = AppLifecycleListener(onResume: () => ref.invalidate(setupStatusProvider));
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  void _continue() {
    ref.read(setupSeenProvider.notifier).done();
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/home');
    }
  }

  Future<void> _allow(SetupItem item) async {
    await ref.read(phoneSetupServiceProvider).request(item);
    ref.invalidate(setupStatusProvider);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final status = ref.watch(setupStatusProvider);
    final s = status.value;
    final micOk = s?.isOn(SetupItem.microphone) ?? false;
    final missing = s?.missing ?? 0;
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AppHeader(title: 'Phone setup'),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: Gap.l),
                children: [
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: context.ios ? Gap.l : Gap.xs, vertical: Gap.s),
                    child: Text(
                      'Turn these on so calls reach you. Only the microphone is required.',
                      style: context.text.bodyLarge?.copyWith(color: c.ink2),
                    ),
                  ),
                  const SizedBox(height: Gap.s),
                  if (s == null)
                    const Padding(
                      padding: EdgeInsets.all(Gap.xl),
                      child: Center(child: CircularProgressIndicator.adaptive()),
                    )
                  else
                    AppGroup(
                      children: [
                        for (final item in s.items)
                          AppRow(
                            leading: _RowIcon(item.icon),
                            title: item.title,
                            subtitle: s.isOn(item) ? 'On' : item.why,
                            trailing: s.isOn(item)
                                ? AppIcon(Ic.checkCircle, color: c.ready.fg, semanticLabel: 'On')
                                : _AllowButton(onPressed: () => _allow(item)),
                          ),
                      ],
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.l),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppButton(
                    label: missing == 0 ? 'Continue' : 'Skip for now',
                    kind: missing == 0 ? ButtonKind.primary : ButtonKind.secondary,
                    onPressed: micOk ? _continue : null,
                  ),
                  if (!micOk && s != null) ...[
                    const SizedBox(height: Gap.s),
                    Text(
                      'The microphone is needed to take calls.',
                      textAlign: TextAlign.center,
                      style: context.text.bodySmall?.copyWith(color: c.muted),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RowIcon extends StatelessWidget {
  const _RowIcon(this.icon);
  final Ic icon;

  @override
  Widget build(BuildContext context) => Container(
    width: 32,
    height: 32,
    decoration: BoxDecoration(color: context.colors.fill, borderRadius: BorderRadius.circular(context.cardRadius - 4)),
    child: AppIcon(icon, size: 18, color: context.colors.ink),
  );
}

class _AllowButton extends StatelessWidget {
  const _AllowButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => FilledButton(
    onPressed: () => unawaited(Future<void>.sync(onPressed)),
    style: FilledButton.styleFrom(
      minimumSize: const Size(72, 40),
      padding: const EdgeInsets.symmetric(horizontal: Gap.l),
      shape: context.ios
          ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(context.cardRadius - 4))
          : const StadiumBorder(),
    ),
    child: const Text('Allow'),
  );
}
