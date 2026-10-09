import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/brand.dart';
import '../state/agent.dart';
import '../state/line.dart';
import '../state/session.dart';
import '../state/shift.dart';
import '../ui/theme.dart';
import 'router.dart';

class AgentApp extends ConsumerStatefulWidget {
  const AgentApp({super.key});

  @override
  ConsumerState<AgentApp> createState() => _AgentAppState();
}

class _AgentAppState extends ConsumerState<AgentApp> {
  @override
  void initState() {
    super.initState();
    // The native engine must listen for calls as soon as there is a session,
    // even before any screen that shows the line is built.
    ref.listenManual(sessionProvider, (_, next) {
      if (next.value != null) ref.read(lineProvider.notifier).ensureStarted();
    }, fireImmediately: true);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(lineKeeperProvider);
    ref.watch(agentProvider.select((p) => p.kind));
    final platform = defaultTargetPlatform;
    return MaterialApp.router(
      title: kBrandName,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light, platform),
      darkTheme: buildTheme(Brightness.dark, platform),
      themeMode: ref.watch(themeModeProvider),
      routerConfig: ref.watch(routerProvider),
    );
  }
}
