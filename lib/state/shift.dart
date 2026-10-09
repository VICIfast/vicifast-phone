import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../domain/presence.dart';
import 'agent.dart';
import '../platform/phone_setup.dart';
import 'line.dart';
import 'services.dart';
import 'session.dart';

final campaignsProvider = FutureProvider.autoDispose<List<Campaign>>((ref) {
  return ref.read(apiProvider).campaigns();
});

class ShiftActions extends Notifier<void> {
  @override
  void build() {}

  Future<void> start(Campaign campaign, List<String> queueIds) async {
    final api = ref.read(apiProvider);
    final sip = await api.startShift(campaign.id, queueIds);
    await ref
        .read(sessionProvider.notifier)
        .setShift(campaignId: campaign.id, campaignName: campaign.name, queueIds: queueIds, sip: sip);
    final session = ref.read(sessionProvider).value;
    final creds = sip ?? session?.sip;
    if (creds != null && session != null) {
      await ref.read(lineProvider.notifier).connect(creds, session.user);
    }
  }
}

final shiftActionsProvider = NotifierProvider<ShiftActions, void>(ShiftActions.new);

final todayStatsProvider = FutureProvider.autoDispose<TodayStats>((ref) {
  return ref.read(apiProvider).todayStats();
});

final todayCallsProvider = FutureProvider.autoDispose<List<CallRecord>>((ref) {
  return ref.read(apiProvider).todayCalls();
});

final setupStatusProvider = FutureProvider.autoDispose<SetupStatus>((ref) {
  return ref.read(phoneSetupServiceProvider).check();
});

class ThemeController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    unawaited(ref.read(storeProvider).loadTheme().then((m) => state = m));
    return ThemeMode.system;
  }

  Future<void> set(ThemeMode m) async {
    state = m;
    await ref.read(storeProvider).saveTheme(m);
  }
}

final themeModeProvider = NotifierProvider<ThemeController, ThemeMode>(ThemeController.new);

/// Keeps the phone line connected whenever there is a session with SIP credentials,
/// and hands the push token to the server.
final lineKeeperProvider = Provider<void>((ref) {
  ref.listen<AsyncValue<Session?>>(sessionProvider, (prev, next) {
    final s = next.value;
    final line = ref.read(lineProvider.notifier);
    if (s == null) {
      if (prev?.value != null) unawaited(line.disconnect());
      return;
    }
    final changed = prev?.value?.sip?.username != s.sip?.username || prev?.value?.sip?.password != s.sip?.password;
    if (s.hasShift && s.sip != null && (changed || !ref.read(lineProvider).up)) {
      unawaited(line.connect(s.sip!, s.user).catchError((Object _) {}));
    }
    // A new sign-in starts without the token on the server; send the one we have.
    final token = ref.read(lineProvider).pushToken;
    if (token != null && prev?.value?.user != s.user) {
      final platform = ref.read(lineProvider).pushPlatform ?? (Platform.isIOS ? 'apns' : 'fcm');
      unawaited(ref.read(apiProvider).registerPushToken(token, platform).catchError((Object _) {}));
    }
  }, fireImmediately: true);
  ref.listen<Presence>(agentProvider, (prev, next) {
    final text = statusLine(next);
    if (prev == null || statusLine(prev) != text) unawaited(ref.read(sipBridgeProvider).setAgentStatus(text));
  });
  ref.listen<LineState>(lineProvider, (prev, next) {
    final token = next.pushToken;
    if (token != null && token != prev?.pushToken && ref.read(sessionProvider).value != null) {
      final platform = next.pushPlatform ?? (Platform.isIOS ? 'apns' : 'fcm');
      unawaited(ref.read(apiProvider).registerPushToken(token, platform).catchError((Object _) {}));
    }
  });
});

/// What the pinned notification says about the agent outside a call.
String statusLine(Presence p) => switch (p.kind) {
  PresenceKind.ready => 'Ready · waiting for calls',
  PresenceKind.paused => p.lineUp ? 'Paused · ${p.pause.label}' : 'Phone line offline · reconnecting',
  PresenceKind.wrapUp => 'Wrapping up the last call',
  PresenceKind.ringing || PresenceKind.onCall => 'On a call',
};
