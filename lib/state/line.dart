import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../platform/sip_bridge.dart';
import '../platform/sip_models.dart';
import 'services.dart';

/// The phone line: SIP registration and the one active call.
class LineState {
  const LineState({
    this.reg = RegState.none,
    this.settling = false,
    this.call,
    this.endedByAgent = false,
    this.pushToken,
    this.pushPlatform,
  });

  final RegState reg;

  /// Re-registering from a working line (a refresh, or a Wi-Fi to mobile data
  /// switch). The old binding still routes calls, so the line counts as up
  /// until the attempt actually fails.
  final bool settling;
  final SipCall? call;

  /// Set when the agent ended the call from the app or the system call screen.
  final bool endedByAgent;
  final String? pushToken;
  final String? pushPlatform;

  bool get up => reg.isUp || (reg == RegState.progress && settling);

  /// The line moving to [next], keeping it up through a re-register.
  LineState withReg(RegState next) => copyWith(reg: next, settling: next == RegState.progress && up);

  LineState copyWith({
    RegState? reg,
    bool? settling,
    SipCall? call,
    bool clearCall = false,
    bool? endedByAgent,
    String? pushToken,
    String? pushPlatform,
  }) => LineState(
    reg: reg ?? this.reg,
    settling: settling ?? this.settling,
    call: clearCall ? null : (call ?? this.call),
    endedByAgent: endedByAgent ?? this.endedByAgent,
    pushToken: pushToken ?? this.pushToken,
    pushPlatform: pushPlatform ?? this.pushPlatform,
  );
}

class LineController extends Notifier<LineState> with WidgetsBindingObserver {
  StreamSubscription<SipEvent>? _sub;
  bool _started = false;
  Timer? _settleTimer;

  /// A re-register gets this long to come back before the line counts as down.
  static const _settleLimit = Duration(seconds: 15);

  void _setReg(RegState next) {
    final wasSettling = state.settling;
    state = state.withReg(next);
    if (!state.settling) {
      _settleTimer?.cancel();
    } else if (!wasSettling) {
      // Started once per re-register; more progress events don't extend it.
      _settleTimer = Timer(_settleLimit, () {
        if (state.settling) state = state.copyWith(settling: false);
      });
    }
  }

  SipBridge get _bridge => ref.read(sipBridgeProvider);

  @override
  LineState build() {
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() {
      WidgetsBinding.instance.removeObserver(this);
      _sub?.cancel();
      _settleTimer?.cancel();
    });
    return const LineState();
  }

  Future<void> ensureStarted() async {
    if (_started) return;
    _started = true;
    try {
      _sub ??= _bridge.events.listen(_onEvent, onError: (Object _) {});
      await _bridge.start();
    } catch (_) {
      // Let the next connect try again.
      _started = false;
      rethrow;
    }
    final reg = await _bridge.registrationState();
    final call = await _bridge.currentCall();
    state = state.withReg(reg).copyWith(call: call);
    // A cached "ok" can be stale after the process was killed; always prove it.
    if (reg.isUp) unawaited(_bridge.verifyRegistration().catchError((Object _) {}));
  }

  Future<void> connect(SipCredentials sip, String displayName) async {
    await ensureStarted();
    _setReg(RegState.progress);
    try {
      await _bridge.register(sip.toAccount(displayName));
    } catch (_) {
      // No native event will follow a call that threw.
      _setReg(RegState.failed);
      rethrow;
    }
  }

  Future<void> reconnect() async {
    _setReg(RegState.progress);
    try {
      await _bridge.forceRefresh();
    } catch (_) {
      _setReg(RegState.failed);
      rethrow;
    }
  }

  Future<void> disconnect() async {
    if (!_started) return;
    try {
      await _bridge.unregister();
      await _bridge.wipeAccount();
    } catch (_) {
      return;
    } finally {
      state = state.withReg(RegState.cleared).copyWith(clearCall: true);
    }
  }

  Future<void> answer() => _bridge.answer();

  Future<void> hangUp() async {
    state = state.copyWith(endedByAgent: true);
    await _bridge.hangup();
  }

  Future<void> dtmf(String d) => _bridge.dtmf(d);
  Future<void> setMute(bool on) => _bridge.setMute(on);
  Future<void> setHold(bool on) => _bridge.setHold(on);
  Future<void> setSpeaker(bool on) => _bridge.setSpeaker(on);

  /// The server could not see this phone registered; prove it either way.
  void verify() {
    if (_started) unawaited(_bridge.verifyRegistration().catchError((Object _) {}));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _started && this.state.call == null) {
      unawaited(_bridge.softReconnect().catchError((Object _) {}));
    }
  }

  void _onEvent(SipEvent e) {
    switch (e) {
      case SipRegEvent(:final state):
        _setReg(state);
      case SipCallEvent(:final state, :final call):
        // States the app has no use for (early-media updates, REFER) change nothing.
        if (state == CallState.other) return;
        if (state.isOver) {
          this.state = this.state.copyWith(clearCall: true);
          // Reset after the agent controller has seen who ended it.
          Future<void>.microtask(() => this.state = this.state.copyWith(endedByAgent: false));
        } else {
          final next = call ?? this.state.call?.withState(state);
          this.state = this.state.copyWith(call: next, endedByAgent: state == CallState.incoming ? false : null);
        }
      case SipPushTokenEvent(:final token, :final platform):
        state = state.copyWith(pushToken: token, pushPlatform: platform);
      case SipLocalHangupEvent():
        state = state.copyWith(endedByAgent: true);
      case SipSystemRejectedEvent():
        state = state.copyWith(clearCall: true);
    }
  }
}

final lineProvider = NotifierProvider<LineController, LineState>(LineController.new);
