import '../data/models.dart';

enum PresenceKind { paused, ready, ringing, onCall, wrapUp }

/// Why the agent is paused. [automatic] pauses were not the agent's choice.
class PauseReason {
  const PauseReason(this.label, {this.code = '', this.automatic = false});

  final String code;
  final String label;
  final bool automatic;

  static const notReady = PauseReason('Not ready yet');
  static const lineDown = PauseReason('Paused while the line is down', automatic: true);
  static const afterCall = PauseReason('Paused after your last call');
  static const bySystem = PauseReason('Paused by your supervisor or the system', automatic: true);
}

/// The agent's working state. Immutable; every change goes through [Presence.apply].
class Presence {
  const Presence({
    required this.kind,
    required this.since,
    this.pause = PauseReason.notReady,
    this.lineUp = false,
    this.call,
    this.callStart,
    this.held = false,
    this.heldSince,
    this.muted = false,
    this.speaker = false,
    this.pauseAfterCall = false,
    this.nextPause,
    this.hungUpBy,
  });

  factory Presence.start(DateTime now) => Presence(kind: PresenceKind.paused, since: now);

  final PresenceKind kind;
  final DateTime since;
  final PauseReason pause;
  final bool lineUp;
  final CallContext? call;
  final DateTime? callStart;
  final bool held;
  final DateTime? heldSince;
  final bool muted;
  final bool speaker;
  final bool pauseAfterCall;

  /// The reason to pause with once the result is saved, when the agent chose
  /// one during the call or was already paused when it rang.
  final PauseReason? nextPause;

  /// 'agent' when the agent ended the call; null when the customer did.
  final String? hungUpBy;

  bool get canGoReady => kind == PresenceKind.paused && lineUp;
  bool get inCall => kind == PresenceKind.ringing || kind == PresenceKind.onCall;

  Presence _copy({
    PresenceKind? kind,
    DateTime? since,
    PauseReason? pause,
    bool? lineUp,
    CallContext? call,
    bool clearCall = false,
    DateTime? callStart,
    bool? held,
    DateTime? heldSince,
    bool clearHeldSince = false,
    bool? muted,
    bool? speaker,
    bool? pauseAfterCall,
    PauseReason? nextPause,
    bool clearNextPause = false,
    String? hungUpBy,
    bool clearHungUpBy = false,
  }) => Presence(
    kind: kind ?? this.kind,
    since: since ?? this.since,
    pause: pause ?? this.pause,
    lineUp: lineUp ?? this.lineUp,
    call: clearCall ? null : (call ?? this.call),
    callStart: clearCall ? null : (callStart ?? this.callStart),
    held: held ?? this.held,
    heldSince: clearHeldSince ? null : (heldSince ?? this.heldSince),
    muted: muted ?? this.muted,
    speaker: speaker ?? this.speaker,
    pauseAfterCall: pauseAfterCall ?? this.pauseAfterCall,
    nextPause: clearNextPause ? null : (nextPause ?? this.nextPause),
    hungUpBy: clearHungUpBy ? null : (hungUpBy ?? this.hungUpBy),
  );

  Presence _paused(PauseReason reason, DateTime now) => _copy(
    kind: PresenceKind.paused,
    since: now,
    pause: reason,
    clearCall: true,
    held: false,
    clearHeldSince: true,
    muted: false,
    speaker: false,
    pauseAfterCall: false,
    clearNextPause: true,
    clearHungUpBy: true,
  );

  Presence _ready(DateTime now) => _copy(
    kind: PresenceKind.ready,
    since: now,
    clearCall: true,
    held: false,
    clearHeldSince: true,
    muted: false,
    speaker: false,
    pauseAfterCall: false,
    clearNextPause: true,
    clearHungUpBy: true,
  );

  Presence apply(PresenceEvent e, DateTime now) {
    switch (e) {
      case LineChanged(:final up):
        if (!up && kind == PresenceKind.ready) {
          return _paused(PauseReason.lineDown, now)._copy(lineUp: false);
        }
        return _copy(lineUp: up);

      case WentReady():
        if (!lineUp || inCall || kind == PresenceKind.wrapUp) return this;
        return _ready(now);

      case WentPaused(:final reason):
        if (inCall || kind == PresenceKind.wrapUp) return _copy(pauseAfterCall: true, nextPause: reason);
        return _paused(reason, now);

      case ServerSaid(:final status):
        return _reconcile(status, now);

      case Ringing(:final context):
        if (kind == PresenceKind.onCall || kind == PresenceKind.wrapUp) return this;
        if (kind == PresenceKind.ringing) return _copy(call: (call ?? context).merge(context));
        // A call can still reach an agent who just paused. Afterwards they go
        // back to the same pause, not to Ready.
        if (kind == PresenceKind.paused) {
          // An automatic reason (line down, supervisor) may no longer hold
          // afterwards, so it isn't carried over.
          return _copy(
            kind: PresenceKind.ringing,
            since: now,
            call: context,
            pauseAfterCall: true,
            nextPause: pause.automatic ? null : pause,
            clearNextPause: pause.automatic,
          );
        }
        return _copy(kind: PresenceKind.ringing, since: now, call: context);

      case CallDetails(:final context):
        if (!inCall && kind != PresenceKind.wrapUp) return this;
        return _copy(call: (call ?? context).merge(context));

      case Answered():
        if (kind == PresenceKind.onCall) return this;
        return _copy(kind: PresenceKind.onCall, since: now, callStart: now, call: call ?? const CallContext());

      case CallEnded(:final byAgent):
        if (kind == PresenceKind.ringing) {
          // A missed or declined ring never reached the agent; nothing to wrap up.
          if (pauseAfterCall) return _paused(nextPause ?? PauseReason.afterCall, now);
          return lineUp ? _ready(now) : _paused(PauseReason.lineDown, now);
        }
        if (kind != PresenceKind.onCall) return this;
        return _copy(
          kind: PresenceKind.wrapUp,
          since: now,
          held: false,
          clearHeldSince: true,
          muted: false,
          speaker: false,
          hungUpBy: byAgent ? 'agent' : null,
          clearHungUpBy: !byAgent,
        );

      case HoldChanged(:final on):
        if (kind != PresenceKind.onCall) return this;
        return on ? _copy(held: true, heldSince: heldSince ?? now) : _copy(held: false, clearHeldSince: true);

      case MuteChanged(:final on):
        return kind == PresenceKind.onCall ? _copy(muted: on) : this;

      case SpeakerChanged(:final on):
        return kind == PresenceKind.onCall ? _copy(speaker: on) : this;

      case PauseAfterCallChanged(:final on):
        return _copy(pauseAfterCall: on, clearNextPause: !on);

      case ResultSaved():
        if (kind != PresenceKind.wrapUp) return this;
        if (!lineUp) return _paused(PauseReason.lineDown, now);
        if (pauseAfterCall) return _paused(nextPause ?? PauseReason.afterCall, now);
        return _ready(now);
    }
  }

  /// The server is the source of truth outside a call. During a call the phone's
  /// own call state wins, because VICIdial's status lags the SIP events.
  Presence _reconcile(String status, DateTime now) {
    final s = status.toUpperCase();
    if (inCall || kind == PresenceKind.wrapUp) return this;
    if (s == 'PAUSED' && kind == PresenceKind.ready) return _paused(PauseReason.bySystem, now);
    if ((s == 'READY' || s == 'CLOSER') && kind == PresenceKind.paused && lineUp) return _ready(now);
    return this;
  }
}

sealed class PresenceEvent {
  const PresenceEvent();
}

class LineChanged extends PresenceEvent {
  const LineChanged({required this.up});
  final bool up;
}

class WentReady extends PresenceEvent {
  const WentReady();
}

class WentPaused extends PresenceEvent {
  const WentPaused(this.reason);
  final PauseReason reason;
}

class ServerSaid extends PresenceEvent {
  const ServerSaid(this.status);
  final String status;
}

class Ringing extends PresenceEvent {
  const Ringing(this.context);
  final CallContext context;
}

class CallDetails extends PresenceEvent {
  const CallDetails(this.context);
  final CallContext context;
}

class Answered extends PresenceEvent {
  const Answered();
}

class CallEnded extends PresenceEvent {
  const CallEnded({required this.byAgent});
  final bool byAgent;
}

class HoldChanged extends PresenceEvent {
  const HoldChanged({required this.on});
  final bool on;
}

class MuteChanged extends PresenceEvent {
  const MuteChanged({required this.on});
  final bool on;
}

class SpeakerChanged extends PresenceEvent {
  const SpeakerChanged({required this.on});
  final bool on;
}

class PauseAfterCallChanged extends PresenceEvent {
  const PauseAfterCallChanged({required this.on});
  final bool on;
}

class ResultSaved extends PresenceEvent {
  const ResultSaved();
}
