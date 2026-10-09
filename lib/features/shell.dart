import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../state/services.dart';
import '../ui/adaptive.dart';
import '../ui/tokens.dart';

/// Back on a call screen sends the app to the background instead of closing
/// its screen, which on older Android would drop the phone line's link to the
/// app mid-call and lose the hang-up that leads to wrap-up.
class StayInApp extends ConsumerWidget {
  const StayInApp({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) ref.read(phoneSetupServiceProvider).moveToBackground();
    },
    child: child,
  );
}

/// Home, Calls and Me. A call takes over the whole screen instead.
class TabShell extends ConsumerWidget {
  const TabShell({super.key, required this.shell});

  final StatefulNavigationShell shell;

  static const _tabs = [(Ic.home, 'Home'), (Ic.calls, 'Calls'), (Ic.me, 'Me')];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    void go(int i) => shell.goBranch(i, initialLocation: i == shell.currentIndex);
    final bar = context.ios
        ? CupertinoTabBar(
            currentIndex: shell.currentIndex,
            onTap: go,
            activeColor: c.ink,
            iconSize: 26,
            inactiveColor: c.muted,
            backgroundColor: c.card.withValues(alpha: 0.94),
            border: Border(top: BorderSide(color: c.line2, width: 0.5)),
            items: [for (final t in _tabs) BottomNavigationBarItem(icon: AppIcon(t.$1), label: t.$2)],
          )
        : NavigationBar(
            selectedIndex: shell.currentIndex,
            onDestinationSelected: go,
            height: 76,
            destinations: [for (final t in _tabs) NavigationDestination(icon: AppIcon(t.$1), label: t.$2)],
          );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (shell.currentIndex != 0) {
          go(0);
        } else {
          // Closing the app would drop the phone line; send it to the background.
          ref.read(phoneSetupServiceProvider).moveToBackground();
        }
      },
      child: Scaffold(body: shell, bottomNavigationBar: bar),
    );
  }
}
