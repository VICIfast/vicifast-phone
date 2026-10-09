import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/agent_api.dart';
import '../data/store.dart';
import '../platform/phone_setup.dart';
import '../platform/sip_bridge.dart';
import '../app/brand.dart';
import '../platform/updater.dart';

/// Real instances are supplied by main(); tests override them with fakes.
final storeProvider = Provider<Store>((_) => throw UnimplementedError('storeProvider'));
final apiProvider = Provider<AgentApi>((_) => throw UnimplementedError('apiProvider'));
final sipBridgeProvider = Provider<SipBridge>((_) => SipBridge());
final phoneSetupServiceProvider = Provider<PhoneSetupService>((_) => PhoneSetupService());
final appVersionProvider = Provider<String>((_) => '1.0.0');
final updaterProvider = Provider<Updater>((ref) => Updater(base: kApiBase, installed: ref.watch(appVersionProvider)));

/// A newer Android build on the release manifest, or null. Never throws.
final updateAvailableProvider = FutureProvider.autoDispose<AppUpdate?>((ref) async {
  // Play delivers updates itself and doesn't allow apps to install their own.
  if (isPlayBuild) return null;
  try {
    return await ref.read(updaterProvider).check();
  } catch (_) {
    return null;
  }
});
