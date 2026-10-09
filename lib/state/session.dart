import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors.dart';
import '../data/agent_api.dart';
import '../data/models.dart';
import '../domain/presence.dart';
import 'agent.dart';
import 'services.dart';

sealed class SignInResult {
  const SignInResult();
}

class SignedIn extends SignInResult {
  const SignedIn();
}

class NeedsCode extends SignInResult {
  const NeedsCode();
}

class WebSessionConflict extends SignInResult {
  const WebSessionConflict(this.web);
  final WebSession web;
}

/// Why the app last returned to sign-in, shown once on the sign-in screen.
class SignOutNotice extends Notifier<String?> {
  @override
  String? build() => null;
  void show(String? message) => state = message;
}

final signOutNoticeProvider = NotifierProvider<SignOutNotice, String?>(SignOutNotice.new);

/// True when renewing the session needs a fresh two-factor code from the agent.
class RenewNeedsCode extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool v) => state = v;
}

final renewNeedsCodeProvider = NotifierProvider<RenewNeedsCode, bool>(RenewNeedsCode.new);

typedef PendingSignIn = ({String slug, String user, String pass, String? code, bool remember});

/// Credentials between the sign-in screen and the code or web-session steps.
/// Cleared as soon as sign-in completes.
class PendingSignInNotifier extends Notifier<PendingSignIn?> {
  @override
  PendingSignIn? build() => null;
  void set(PendingSignIn? v) => state = v;
}

final pendingSignInProvider = NotifierProvider<PendingSignInNotifier, PendingSignIn?>(PendingSignInNotifier.new);

class SessionController extends AsyncNotifier<Session?> {
  Timer? _renewTimer;
  int _renewFailures = 0;
  Future<void>? _renewing;

  /// Bumped on sign-out, so a renewal that was already in flight can't bring
  /// the session back.
  int _generation = 0;

  DateTime? _lastRenewAt;
  DateTime? _signOutWaitingSince;

  AgentApi get _api => ref.read(apiProvider);
  bool get _inCall => ref.read(agentProvider).inCall;

  @override
  Future<Session?> build() async {
    // Timers stall while the phone sleeps; check the session's age on return.
    final life = AppLifecycleListener(onResume: _renewIfDue);
    ref.onDispose(() {
      _renewTimer?.cancel();
      life.dispose();
    });
    final stored = await ref.read(storeProvider).loadSession();
    if (stored == null) return null;
    _api.session = stored;
    if (stored.expiresAt.isBefore(DateTime.now())) {
      unawaited(Future<void>.microtask(renewNow));
    } else {
      _scheduleRenew(stored);
    }
    return stored;
  }

  Future<SignInResult> signIn({
    required String slug,
    required String user,
    required String pass,
    String? code,
    bool remember = true,
  }) async {
    ref.read(pendingSignInProvider.notifier).set((slug: slug, user: user, pass: pass, code: code, remember: remember));
    final LoginOutcome outcome;
    try {
      outcome = await _api.login(slug: slug, user: user, pass: pass, code: code);
    } on AppError catch (e) {
      if (e.code == AppErrorCode.codeRequired) return const NeedsCode();
      rethrow;
    }
    switch (outcome) {
      case WebSessionInTheWay(:final web):
        return WebSessionConflict(web);
      case LoggedIn(:final session):
        final store = ref.read(storeProvider);
        if (remember) {
          await store.saveRemembered(session.slug, session.user);
        } else {
          await store.forgetRemembered();
        }
        await _adopt(session);
        ref.read(signOutNoticeProvider.notifier).show(null);
        ref.read(pendingSignInProvider.notifier).set(null);
        return const SignedIn();
    }
  }

  /// Moves the agent's web session to this phone, then signs in.
  Future<SignInResult> takeOverWebSession({required bool hangUp}) async {
    final p = ref.read(pendingSignInProvider);
    if (p == null) throw const AppError(AppErrorCode.sessionEnded);
    await _api.endWebSession(slug: p.slug, user: p.user, pass: p.pass, code: p.code, hangUp: hangUp);
    return signIn(slug: p.slug, user: p.user, pass: p.pass, code: p.code, remember: p.remember);
  }

  Future<void> setShift({
    required String campaignId,
    required String campaignName,
    required List<String> queueIds,
    SipCredentials? sip,
  }) async {
    final s = state.value;
    if (s == null) return;
    await _adopt(s.copyWith(campaignId: campaignId, campaignName: campaignName, queueIds: queueIds, sip: sip));
  }

  Future<void> signOut({String? notice}) async {
    _generation++;
    _signOutWaitingSince = null;
    _renewTimer?.cancel();
    await _api.endShift();
    _api.session = null;
    await ref.read(storeProvider).clearSession();
    await ref.read(storeProvider).clearPendingWrapUp();
    ref.read(renewNeedsCodeProvider.notifier).set(false);
    ref.read(signOutNoticeProvider.notifier).show(notice);
    state = const AsyncData(null);
  }

  /// The server refused a request because the session is over. An expired
  /// session is renewed with the stored password; a phone that another
  /// sign-in replaced is signed out, once any call on it has finished.
  Future<void> serverEndedSession(AppError e) async {
    if (state.value == null) return;
    if (e.code == AppErrorCode.sessionEnded) {
      // The status poll reports this every few seconds; let the backoff (or
      // the agent's code) drive the retries instead of logging in each time.
      final recent = _lastRenewAt != null && DateTime.now().difference(_lastRenewAt!) < const Duration(minutes: 1);
      final backingOff = _renewFailures > 0 && (_renewTimer?.isActive ?? false);
      if (_renewing != null || recent || backingOff || ref.read(renewNeedsCodeProvider)) return;
      return renewNow();
    }
    // Another phone took over: this one can't save a result anymore, so only
    // a live call is worth waiting for. Otherwise finish the wrap-up first.
    await _signOutWhenFree(e.message, finishWrapUp: e.code != AppErrorCode.signedInElsewhere);
  }

  /// Renews by replaying the stored password. On failure it always re-arms,
  /// backing off from 1 to 10 minutes, until it succeeds or the session ends.
  /// A [code] the agent typed always gets its own attempt, after any renewal
  /// already in flight.
  Future<void> renewNow({String? code}) async {
    if (code == null) return _renewing ??= _renew().whenComplete(() => _renewing = null);
    while (_renewing != null) {
      await _renewing!.catchError((Object _) {});
    }
    final mine = _renewing = _renew(code: code);
    try {
      await mine;
    } finally {
      if (identical(_renewing, mine)) _renewing = null;
    }
  }

  Future<void> _renew({String? code}) async {
    final s = state.value;
    if (s == null) return;
    final gen = _generation;
    // Renewing mid-call can re-provision the phone; wait for the call to end
    // unless the session is about to run out.
    if (code == null && _inCall && s.expiresAt.isAfter(DateTime.now().add(const Duration(minutes: 2)))) {
      _renewTimer?.cancel();
      _renewTimer = Timer(const Duration(minutes: 1), renewNow);
      return;
    }
    // A phone replaced by a sign-in elsewhere must not take the session back,
    // which a fresh login would do.
    try {
      await _api.campaigns();
    } on AppError catch (e) {
      if (e.code == AppErrorCode.signedInElsewhere) {
        await _signOutWhenFree(e.message, finishWrapUp: false);
        return;
      }
    } catch (_) {
      // Unreachable or slow: the login below decides.
    }
    if (gen != _generation) return;
    _lastRenewAt = DateTime.now();
    try {
      final outcome = await _api.login(slug: s.slug, user: s.user, pass: s.password, code: code);
      final current = state.value;
      if (gen != _generation || current == null) return;
      if (outcome is LoggedIn) {
        _renewFailures = 0;
        ref.read(renewNeedsCodeProvider.notifier).set(false);
        await _adopt(current.renewedFrom(outcome.session));
        return;
      }
      _retryRenewLater();
    } on AppError catch (e) {
      if (gen != _generation || state.value == null) return;
      if (e.code == AppErrorCode.codeRequired) {
        ref.read(renewNeedsCodeProvider.notifier).set(true);
        _retryRenewLater();
        return;
      }
      if (e.endsSession || e.code == AppErrorCode.invalidCredentials) {
        await _signOutWhenFree(
          e.code == AppErrorCode.invalidCredentials ? 'Your password changed. Sign in again.' : e.message,
          finishWrapUp: false,
        );
        return;
      }
      _retryRenewLater();
    }
  }

  void _renewIfDue() {
    final s = state.value;
    if (s != null && s.expiresAt.subtract(const Duration(minutes: 30)).isBefore(DateTime.now())) {
      unawaited(renewNow());
    }
  }

  /// Signing out ends the phone line, so never do it under a live call. With
  /// [finishWrapUp], a call waiting for its result also holds it off (the
  /// server still takes results then), for up to 10 minutes.
  Future<void> _signOutWhenFree(String? notice, {bool finishWrapUp = true}) async {
    final kind = ref.read(agentProvider).kind;
    final since = _signOutWaitingSince ??= DateTime.now();
    final wrapping = finishWrapUp && kind == PresenceKind.wrapUp;
    if (_inCall || (wrapping && DateTime.now().difference(since) < const Duration(minutes: 10))) {
      _renewTimer?.cancel();
      _renewTimer = Timer(const Duration(seconds: 30), () => _signOutWhenFree(notice, finishWrapUp: finishWrapUp));
      return;
    }
    _signOutWaitingSince = null;
    await signOut(notice: notice);
  }

  Future<void> _adopt(Session s) async {
    _signOutWaitingSince = null;
    _api.session = s;
    await ref.read(storeProvider).saveSession(s);
    state = AsyncData(s);
    _scheduleRenew(s);
  }

  void _scheduleRenew(Session s) {
    _renewTimer?.cancel();
    final due = s.expiresAt.subtract(const Duration(minutes: 30)).difference(DateTime.now());
    _renewTimer = Timer(due.isNegative ? const Duration(seconds: 30) : due, renewNow);
  }

  void _retryRenewLater() {
    _renewFailures++;
    final minutes = min(10, 1 << min(_renewFailures - 1, 4));
    _renewTimer?.cancel();
    _renewTimer = Timer(Duration(minutes: minutes), renewNow);
  }
}

final sessionProvider = AsyncNotifierProvider<SessionController, Session?>(SessionController.new);
