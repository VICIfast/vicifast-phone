import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/clock.dart';
import '../core/errors.dart';
import '../data/agent_api.dart';
import '../data/models.dart';
import '../data/store.dart';
import '../domain/presence.dart';
import 'line.dart';
import 'services.dart';
import 'session.dart';
import 'shift.dart';

class AgentController extends Notifier<Presence> {
  Timer? _poll;
  bool _polling = false;
  bool _activatedThisShift = false;
  bool _endingByTransfer = false;

  // Status changes the app makes itself bump the epoch before and after, and
  // count as busy while in flight. A poll that overlaps one is stale: what the
  // server said may predate the change, so it is dropped.
  int _statusEpoch = 0;
  int _statusBusy = 0;

  // Status changes reach the server one at a time, in the order the app made
  // them, so a slow pause can't land after the Ready that followed it.
  Future<void> _statusTail = Future<void>.value();
  int _statusSeq = 0;

  // Polls in a row that found no agent row on the server.
  int _noRowPolls = 0;

  AgentApi get _api => ref.read(apiProvider);
  DateTime _now() => ref.read(nowProvider)();

  @override
  Presence build() {
    final api = ref.read(apiProvider);
    api.onSipUnreachable = () => ref.read(lineProvider.notifier).verify();
    ref.listen<LineState>(lineProvider, _onLine);
    ref.listen<AsyncValue<Session?>>(sessionProvider, (prev, next) {
      final before = prev?.value;
      final after = next.value;
      if (after == null || before?.campaignId != after.campaignId) _activatedThisShift = false;
      if (after == null) state = Presence.start(_now()).apply(LineChanged(up: ref.read(lineProvider).up), _now());
    });
    _poll = Timer.periodic(const Duration(seconds: 8), (_) => _tick());
    ref.onDispose(() {
      _poll?.cancel();
      api.onSipUnreachable = null;
    });
    unawaited(Future<void>.microtask(_restoreWrapUp));
    return Presence.start(_now()).apply(LineChanged(up: ref.read(lineProvider).up), _now());
  }

  void _apply(PresenceEvent e) => state = state.apply(e, _now());

  /// Queues a status change behind the ones before it. Never call this from
  /// inside an action already running here: it would wait on itself.
  Future<T> _status<T>(Future<T> Function() action) {
    _statusEpoch++;
    _statusBusy++;
    _statusSeq++;
    final run = _statusTail.then((_) => action());
    _statusTail = run.then<void>((_) {}, onError: (Object _) {});
    return run.whenComplete(() {
      _statusBusy--;
      _statusEpoch++;
    });
  }

  /// Pauses the agent on the server. Right after a call VICIdial can still have
  /// the agent's row marked in a call for a couple of seconds, and the pause
  /// then changes nothing; so it retries, until it lands or something newer is
  /// queued behind it.
  Future<void> _pauseOnServer({String? code}) {
    // _status takes the next number; anything queued after this one changes it.
    final mine = _statusSeq + 1;
    return _status(() => _pauseUntilLanded(code: code, mine: mine));
  }

  /// The retry itself, for use inside a running status action.
  Future<void> _pauseUntilLanded({String? code, required int mine}) async {
    for (final wait in const [Duration.zero, Duration(seconds: 1), Duration(seconds: 2), Duration(seconds: 3)]) {
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      if (_statusSeq != mine) return;
      if (await _api.setPaused(code: code) > 0) return;
    }
  }

  void _pauseOnServerLater({String? code}) => unawaited(_pauseOnServer(code: code).catchError((Object _) {}));

  // ---------------- status ----------------

  Future<void> goReady() async {
    if (!state.lineUp) throw const AppError(AppErrorCode.lineDown);
    await _status(() async {
      if (!_activatedThisShift) {
        final outcome = await _api.activate();
        switch (outcome) {
          case ReadyOutcome.ready:
            _activatedThisShift = true;
          case ReadyOutcome.phoneLineDown:
            ref.read(lineProvider.notifier).verify();
            throw const AppError(AppErrorCode.lineDown);
          case ReadyOutcome.onCallOnComputer:
            throw const AppError(AppErrorCode.onCallOnComputer);
        }
      } else if (await _api.setReady() == 'PAUSED') {
        // The server saw no registration and took the agent off the floor;
        // the next attempt has to activate again.
        _activatedThisShift = false;
        ref.read(lineProvider.notifier).verify();
        throw const AppError(AppErrorCode.lineDown);
      }
      _apply(const WentReady());
      // Polls that saw no agent row before this Ready don't count against it.
      _noRowPolls = 0;
    });
  }

  Future<void> pause(PauseReason reason) async {
    if (state.inCall || state.kind == PresenceKind.wrapUp) {
      _apply(WentPaused(reason));
      if (state.kind == PresenceKind.wrapUp) unawaited(_persistWrapUp());
      return;
    }
    await _status(() async {
      await _api.setPaused(code: reason.code);
      _apply(WentPaused(reason));
    });
  }

  void setPauseAfterCall(bool on) {
    _apply(PauseAfterCallChanged(on: on));
    if (state.kind == PresenceKind.wrapUp) unawaited(_persistWrapUp());
  }

  // ---------------- call controls ----------------

  Future<void> answer() => ref.read(lineProvider.notifier).answer();

  Future<void> decline() => ref.read(lineProvider.notifier).hangUp();

  Future<void> endCall() async {
    unawaited(_api.hangUpOnServer(state.call?.callerId).catchError((Object _) {}));
    await ref.read(lineProvider.notifier).hangUp();
  }

  Future<void> toggleHold() async {
    final on = !state.held;
    await ref.read(lineProvider.notifier).setHold(on);
    _apply(HoldChanged(on: on));
  }

  Future<void> toggleMute() async {
    final on = !state.muted;
    await ref.read(lineProvider.notifier).setMute(on);
    _apply(MuteChanged(on: on));
  }

  Future<void> toggleSpeaker() async {
    final on = !state.speaker;
    await ref.read(lineProvider.notifier).setSpeaker(on);
    _apply(SpeakerChanged(on: on));
  }

  Future<void> dtmf(String digit) => ref.read(lineProvider.notifier).dtmf(digit);

  Future<void> transferToQueue(TransferQueue q) async {
    _endingByTransfer = true;
    try {
      await _api.transferToQueue(q.id);
    } catch (_) {
      _endingByTransfer = false;
      rethrow;
    }
  }

  Future<void> transferToNumber(String number) async {
    _endingByTransfer = true;
    try {
      await _api.transferToNumber(number);
    } catch (_) {
      _endingByTransfer = false;
      rethrow;
    }
  }

  // ---------------- wrap-up ----------------

  /// Saves the result, then sends the agent ready or keeps them paused. Runs
  /// here rather than in the screen, because the screen closes the moment the
  /// state leaves wrap-up.
  Future<void> saveResult(Disposition d, {String? note, DateTime? callbackAt, bool callbackOnlyMe = false}) async {
    final call = state.call;
    final store = ref.read(storeProvider);
    final campaign = ref.read(sessionProvider).value?.campaignId;
    await _api.saveResult(
      code: d.code,
      uniqueid: call?.uniqueid,
      leadId: call?.lead?.id,
      hungUpBy: state.hungUpBy,
      note: note,
      callbackAt: callbackAt,
      callbackOnlyMe: callbackOnlyMe,
    );
    await store.clearPendingWrapUp();
    if (campaign != null) unawaited(store.rememberResult(campaign, d.code).catchError((Object _) {}));
    ref.invalidate(todayStatsProvider);
    ref.invalidate(todayCallsProvider);
    final chosen = state.nextPause;
    final mine = _statusSeq + 1;
    // Queued behind the wrap-up pause, so the server sees pause, then this.
    await _status(() async {
      _apply(const ResultSaved());
      try {
        if (state.kind == PresenceKind.ready) {
          if (await _api.setReady() == 'PAUSED') {
            _activatedThisShift = false;
            _apply(const WentPaused(PauseReason.lineDown));
            ref.read(lineProvider.notifier).verify();
          }
        } else {
          // Always sent, and retried like the wrap-up pause: a quick save can
          // still find the row in the call. Records the reason the agent chose.
          await _pauseUntilLanded(code: chosen?.code ?? state.pause.code, mine: mine);
        }
      } catch (_) {
        // The next status poll reconciles with the server.
      }
    });
  }

  /// VICIdial puts a remote agent back to READY when a call ends. Pause them
  /// on the server for the wrap-up, so the next call can't ring meanwhile.
  void _holdOffCalls() => _pauseOnServerLater();

  // ---------------- phone line events ----------------

  void _onLine(LineState? prev, LineState next) {
    if (prev?.up != next.up) {
      final wasReady = state.kind == PresenceKind.ready;
      _apply(LineChanged(up: next.up));
      // Keep the server in step with the automatic pause.
      if (wasReady && state.kind == PresenceKind.paused) _pauseOnServerLater();
    }

    final before = prev?.call;
    final after = next.call;
    if (after != null && before == null && after.incoming) {
      if (state.kind == PresenceKind.wrapUp) {
        // The server should have stopped this; never let a call replace one
        // that still needs its result. VICIdial offers it to someone else,
        // and the pause goes out again in case the first one didn't land.
        unawaited(ref.read(lineProvider.notifier).hangUp().catchError((Object _) {}));
        _holdOffCalls();
        return;
      }
      _apply(Ringing(CallContext(phone: after.phoneHint)));
      unawaited(_loadRinging());
    }
    if (after != null && after.state.isLive && state.kind == PresenceKind.ringing) {
      _apply(const Answered());
      unawaited(_loadCallDetails());
    }
    if (before != null && after == null) {
      final byAgent = next.endedByAgent || _endingByTransfer;
      _endingByTransfer = false;
      final wasOnCall = state.kind == PresenceKind.onCall;
      final wasRinging = state.kind == PresenceKind.ringing;
      _apply(CallEnded(byAgent: byAgent));
      if (wasOnCall && state.kind == PresenceKind.wrapUp) {
        _holdOffCalls();
        unawaited(_persistWrapUp());
      } else if (wasRinging && state.kind == PresenceKind.paused) {
        // A missed ring left the agent paused; tell the server, or its READY
        // flips the app back to Ready on the next poll.
        _pauseOnServerLater(code: state.pause.code);
      }
    }
  }

  Future<void> _loadRinging() async {
    try {
      final ctx = await _api.ringingCall();
      if (ctx != null) _apply(CallDetails(ctx));
    } catch (_) {
      return;
    }
  }

  /// VICIdial links the lead to the agent a moment after the answer, so retry briefly.
  Future<void> _loadCallDetails() async {
    for (final wait in const [Duration.zero, Duration(milliseconds: 700), Duration(seconds: 2)]) {
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      if (state.kind != PresenceKind.onCall) return;
      try {
        final ctx = await _api.currentCall(poll: true);
        if (ctx != null) {
          _apply(CallDetails(ctx));
          if (ctx.uniqueid.isNotEmpty && ctx.lead != null) return;
        }
      } catch (_) {
        continue;
      }
    }
  }

  Future<void> _persistWrapUp() async {
    final p = state;
    final call = p.call;
    if (call == null) return;
    await ref
        .read(storeProvider)
        .savePendingWrapUp(
          PendingWrapUp(
            at: p.since,
            call: call.toJson(),
            callStart: p.callStart,
            hungUpBy: p.hungUpBy,
            pauseAfterCall: p.pauseAfterCall,
            nextPauseCode: p.nextPause?.code,
            nextPauseLabel: p.nextPause?.label,
          ),
        );
  }

  Future<void> _restoreWrapUp() async {
    final store = ref.read(storeProvider);
    final pending = await store.loadPendingWrapUp();
    if (pending == null) return;
    if (_now().difference(pending.at) > const Duration(minutes: 10) || ref.read(sessionProvider).value == null) {
      await store.clearPendingWrapUp();
      return;
    }
    if (state.inCall) return;
    state = Presence(
      kind: PresenceKind.wrapUp,
      since: pending.at,
      lineUp: state.lineUp,
      call: CallContext.fromJson(pending.call),
      callStart: pending.callStart,
      hungUpBy: pending.hungUpBy,
      pauseAfterCall: pending.pauseAfterCall,
      nextPause: pending.nextPauseLabel == null
          ? null
          : PauseReason(pending.nextPauseLabel!, code: pending.nextPauseCode ?? ''),
    );
    _holdOffCalls();
  }

  Future<void> _tick() async {
    if (_polling || state.kind == PresenceKind.onCall) return;
    final s = ref.read(sessionProvider).value;
    if (s == null || !s.hasShift) return;
    _polling = true;
    final epoch = _statusEpoch;
    try {
      if (state.kind == PresenceKind.ringing && (state.call?.lead == null)) {
        await _loadRinging();
      } else {
        final r = await _api.pollStatus();
        final fresh = _statusBusy == 0 && epoch == _statusEpoch;
        if (r.status == 'NONE') {
          // No agent row: the server took the agent off the floor. The next
          // Ready has to activate again; twice in a row while Ready is a pause.
          // (Right after activating, the row takes a couple of seconds to appear.)
          if (fresh) _activatedThisShift = false;
          if (state.kind == PresenceKind.ready) _noRowPolls++;
          if (_noRowPolls >= 2 && state.kind == PresenceKind.ready && fresh) {
            _apply(const ServerSaid('PAUSED'));
            ref.read(lineProvider.notifier).verify();
          }
        } else {
          _noRowPolls = 0;
          if (r.status.isNotEmpty && _statusBusy == 0 && epoch == _statusEpoch) _apply(ServerSaid(r.status));
        }
      }
    } on AppError catch (e) {
      if (e.endsSession) unawaited(ref.read(sessionProvider.notifier).serverEndedSession(e));
    } catch (_) {
      // A missed poll is retried on the next tick.
    } finally {
      _polling = false;
    }
  }
}

final agentProvider = NotifierProvider<AgentController, Presence>(AgentController.new);

/// A failed load is kept for a short while only, so the next open retries.
void _retryAfterFailure(Ref ref) {
  final t = Timer(const Duration(seconds: 15), ref.invalidateSelf);
  ref.onDispose(t.cancel);
}

/// Results for a campaign, cached for the session.
final resultsProvider = FutureProvider.family<List<Disposition>, String>((ref, campaignId) async {
  try {
    return await ref.read(apiProvider).results(campaignId);
  } catch (_) {
    _retryAfterFailure(ref);
    rethrow;
  }
});

final pauseCodesProvider = FutureProvider.family<List<PauseCode>, String>((ref, campaignId) async {
  try {
    return await ref.read(apiProvider).pauseCodes(campaignId);
  } catch (_) {
    _retryAfterFailure(ref);
    rethrow;
  }
});

final transferQueuesProvider = FutureProvider.autoDispose<List<TransferQueue>>((ref) {
  return ref.read(apiProvider).transferQueues();
});
