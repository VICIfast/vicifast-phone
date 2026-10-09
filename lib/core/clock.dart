import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Wall-clock source. Overridden in tests so timers render fixed values.
final nowProvider = Provider<DateTime Function()>((_) => DateTime.now);

/// Ticks once a second while something is watching it.
final tickProvider = StreamProvider.autoDispose<DateTime>((ref) {
  final now = ref.watch(nowProvider);
  final controller = StreamController<DateTime>();
  controller.add(now());
  final timer = Timer.periodic(const Duration(seconds: 1), (_) => controller.add(now()));
  ref.onDispose(() {
    timer.cancel();
    controller.close();
  });
  return controller.stream;
});
