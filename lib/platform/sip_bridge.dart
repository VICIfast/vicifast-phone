import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'sip_models.dart';

/// Native SIP engine events, typed. The channel contract is unchanged from the
/// native side (LinphoneManager.kt / LinphoneManager.swift).
sealed class SipEvent {
  const SipEvent();

  static SipEvent? parse(Map<dynamic, dynamic> m) {
    switch (m['type']) {
      case 'regState':
        return SipRegEvent(RegState.parse(m['state'] as String?));
      case 'callState':
        final call = m['call'];
        final state = CallState.parse(m['state'] as String?);
        return SipCallEvent(state, call is Map ? SipCall.fromMap(call).withState(state) : null);
      case 'voipToken':
        final token = m['token'] as String?;
        if (token == null || token.isEmpty) return null;
        return SipPushTokenEvent(token, (m['platform'] as String?) ?? (Platform.isIOS ? 'apns' : 'fcm'));
      case 'agentInitiatedHangup':
        return const SipLocalHangupEvent();
      case 'systemRejectedCall':
        return const SipSystemRejectedEvent();
    }
    return null;
  }
}

class SipRegEvent extends SipEvent {
  const SipRegEvent(this.state);
  final RegState state;
}

class SipCallEvent extends SipEvent {
  const SipCallEvent(this.state, this.call);
  final CallState state;
  final SipCall? call;
}

class SipPushTokenEvent extends SipEvent {
  const SipPushTokenEvent(this.token, this.platform);
  final String token;
  final String platform;
}

/// The agent ended the call from the system UI (lock screen, CallKit, headset).
class SipLocalHangupEvent extends SipEvent {
  const SipLocalHangupEvent();
}

/// The OS refused to show an incoming call (Android Telecom limits).
class SipSystemRejectedEvent extends SipEvent {
  const SipSystemRejectedEvent();
}

class SipBridge {
  static const _method = MethodChannel('io.vicifast.phone/sip');
  static const _events = EventChannel('io.vicifast.phone/sip_events');

  Stream<SipEvent> get events => _events
      .receiveBroadcastStream()
      .where((e) => e is Map)
      .map((e) => SipEvent.parse(e as Map<dynamic, dynamic>))
      .where((e) => e != null)
      .cast<SipEvent>();

  Future<void> start() => _method.invokeMethod<void>('start');
  Future<void> register(SipAccount a) => _method.invokeMethod<void>('register', a.toJson());
  Future<void> unregister() => _method.invokeMethod<void>('unregister');
  Future<void> wipeAccount() => _method.invokeMethod<void>('wipeAccount');

  /// REGISTER refresh on the existing socket, falling back to a full rebuild
  /// natively after 5 s. Used on resume.
  Future<void> softReconnect() => _method.invokeMethod<void>('softReconnect');

  /// Rebuilds the account and socket from scratch.
  Future<void> forceRefresh() => _method.invokeMethod<void>('forceRefresh');

  /// Always sends a REGISTER round-trip; a cached "ok" can be stale after the
  /// process was killed while the foreground service kept running.
  Future<void> verifyRegistration() => _method.invokeMethod<void>('verifyRegistration');

  Future<void> answer() => _method.invokeMethod<void>('answer');
  Future<void> hangup() => _method.invokeMethod<void>('hangup');
  Future<void> dtmf(String digit) => _method.invokeMethod<void>('dtmf', {'digit': digit});
  Future<void> setMute(bool muted) => _method.invokeMethod<void>('setMute', {'muted': muted});
  Future<void> setHold(bool on) => _method.invokeMethod<void>('setHold', {'on': on});
  Future<void> setSpeaker(bool on) => _method.invokeMethod<void>('setSpeaker', {'on': on});

  /// The line under the app name in Android's pinned notification. No-op on iOS.
  Future<void> setAgentStatus(String text) async {
    try {
      await _method.invokeMethod<void>('setAgentStatus', {'text': text});
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  Future<RegState> registrationState() async => RegState.parse(await _method.invokeMethod<String>('registrationState'));

  Future<SipCall?> currentCall() async {
    final m = await _method.invokeMethod<Map<dynamic, dynamic>>('currentCall');
    return m == null ? null : SipCall.fromMap(m);
  }
}
