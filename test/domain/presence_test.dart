import 'package:flutter_test/flutter_test.dart';
import 'package:vicifast_phone/data/models.dart';
import 'package:vicifast_phone/domain/presence.dart';

void main() {
  final t0 = DateTime(2026, 10, 9, 9);
  DateTime at(int s) => t0.add(Duration(seconds: s));
  const customer = CallContext(
    phone: '3055550142',
    uniqueid: '1728480000.123',
    lead: Lead(id: '86059', firstName: 'Robert', lastName: 'Hayes'),
  );

  Presence ready() => Presence.start(t0).apply(const LineChanged(up: true), t0).apply(const WentReady(), at(1));

  group('going ready', () {
    test('is refused while the phone line is down', () {
      final p = Presence.start(t0).apply(const WentReady(), at(1));
      expect(p.kind, PresenceKind.paused);
      expect(p.canGoReady, isFalse);
    });

    test('works once the line is up, and restarts the timer', () {
      final p = ready();
      expect(p.kind, PresenceKind.ready);
      expect(p.since, at(1));
    });
  });

  group('phone line drops', () {
    test('while ready, the agent is paused automatically and told why', () {
      final p = ready().apply(const LineChanged(up: false), at(5));
      expect(p.kind, PresenceKind.paused);
      expect(p.pause, PauseReason.lineDown);
      expect(p.pause.automatic, isTrue);
      expect(p.canGoReady, isFalse);
    });

    test('coming back does not make the agent ready by itself', () {
      final p = ready().apply(const LineChanged(up: false), at(5)).apply(const LineChanged(up: true), at(9));
      expect(p.kind, PresenceKind.paused);
      expect(p.canGoReady, isTrue);
    });

    test('during a call it does not end the call state', () {
      final p = ready()
          .apply(const Ringing(customer), at(2))
          .apply(const Answered(), at(3))
          .apply(const LineChanged(up: false), at(4));
      expect(p.kind, PresenceKind.onCall);
      expect(p.lineUp, isFalse);
    });
  });

  group('a call', () {
    test('rings, connects, ends in wrap-up with the call kept', () {
      var p = ready().apply(const Ringing(customer), at(2));
      expect(p.kind, PresenceKind.ringing);
      p = p.apply(const Answered(), at(4));
      expect(p.kind, PresenceKind.onCall);
      expect(p.callStart, at(4));
      p = p.apply(const CallEnded(byAgent: false), at(30));
      expect(p.kind, PresenceKind.wrapUp);
      expect(p.call?.uniqueid, '1728480000.123');
      expect(p.since.difference(p.callStart!), const Duration(seconds: 26));
      expect(p.hungUpBy, isNull);
    });

    test('ended by the agent is recorded for the result', () {
      final p = ready()
          .apply(const Ringing(customer), at(2))
          .apply(const Answered(), at(3))
          .apply(const CallEnded(byAgent: true), at(9));
      expect(p.hungUpBy, 'agent');
    });

    test('a missed or declined ring goes back to ready with nothing to wrap up', () {
      final p = ready().apply(const Ringing(customer), at(2)).apply(const CallEnded(byAgent: true), at(5));
      expect(p.kind, PresenceKind.ready);
      expect(p.call, isNull);
    });

    test('a ring that reaches a paused agent returns them to the same pause', () {
      const lunch = PauseReason('Lunch', code: 'LUNCH');
      final paused = ready().apply(const WentPaused(lunch), at(2));
      final missed = paused.apply(const Ringing(customer), at(3)).apply(const CallEnded(byAgent: false), at(9));
      expect(missed.kind, PresenceKind.paused);
      expect(missed.pause.code, 'LUNCH');
      final taken = paused
          .apply(const Ringing(customer), at(3))
          .apply(const Answered(), at(4))
          .apply(const CallEnded(byAgent: false), at(30))
          .apply(const ResultSaved(), at(40));
      expect(taken.kind, PresenceKind.paused);
      expect(taken.pause.code, 'LUNCH');
    });

    test('details that arrive later fill in, without losing what was known', () {
      final p = ready()
          .apply(const Ringing(CallContext(phone: '3055550142')), at(2))
          .apply(
            const CallDetails(
              CallContext(
                queueName: 'DID Inbound',
                lead: Lead(id: '1', firstName: 'Robert'),
              ),
            ),
            at(3),
          );
      expect(p.call?.phone, '3055550142');
      expect(p.call?.queueName, 'DID Inbound');
      expect(p.call?.displayName, 'Robert');
    });

    test('hold keeps its own start time and clears on resume', () {
      var p = ready().apply(const Ringing(customer), at(2)).apply(const Answered(), at(3));
      p = p.apply(const HoldChanged(on: true), at(10));
      expect(p.held, isTrue);
      expect(p.heldSince, at(10));
      p = p.apply(const HoldChanged(on: true), at(12));
      expect(p.heldSince, at(10));
      p = p.apply(const HoldChanged(on: false), at(20));
      expect(p.held, isFalse);
      expect(p.heldSince, isNull);
    });

    test('mute and hold reset when the call ends', () {
      final p = ready()
          .apply(const Ringing(customer), at(2))
          .apply(const Answered(), at(3))
          .apply(const MuteChanged(on: true), at(4))
          .apply(const HoldChanged(on: true), at(5))
          .apply(const CallEnded(byAgent: false), at(6));
      expect(p.muted, isFalse);
      expect(p.held, isFalse);
    });
  });

  group('wrap-up', () {
    Presence wrapUp() => ready()
        .apply(const Ringing(customer), at(2))
        .apply(const Answered(), at(3))
        .apply(const CallEnded(byAgent: false), at(9));

    test('saving the result makes the agent ready again', () {
      final p = wrapUp().apply(const ResultSaved(), at(20));
      expect(p.kind, PresenceKind.ready);
      expect(p.call, isNull);
      expect(p.since, at(20));
    });

    test('"pause after this call" pauses instead', () {
      final p = wrapUp().apply(const PauseAfterCallChanged(on: true), at(10)).apply(const ResultSaved(), at(20));
      expect(p.kind, PresenceKind.paused);
      expect(p.pause, PauseReason.afterCall);
    });

    test('pausing during a call or wrap-up means pause after it, with that reason', () {
      final p = ready()
          .apply(const Ringing(customer), at(2))
          .apply(const Answered(), at(3))
          .apply(const WentPaused(PauseReason('Lunch', code: 'LUNCH')), at(4));
      expect(p.kind, PresenceKind.onCall);
      expect(p.pauseAfterCall, isTrue);
      final saved = p.apply(const CallEnded(byAgent: false), at(9)).apply(const ResultSaved(), at(20));
      expect(saved.kind, PresenceKind.paused);
      expect(saved.pause.code, 'LUNCH');
    });

    test('turning "pause after this call" off forgets the chosen reason', () {
      final p = wrapUp()
          .apply(const WentPaused(PauseReason('Lunch', code: 'LUNCH')), at(10))
          .apply(const PauseAfterCallChanged(on: false), at(11))
          .apply(const ResultSaved(), at(20));
      expect(p.kind, PresenceKind.ready);
    });

    test('if the line dropped meanwhile, saving pauses with the line reason', () {
      final p = wrapUp().apply(const LineChanged(up: false), at(10)).apply(const ResultSaved(), at(20));
      expect(p.kind, PresenceKind.paused);
      expect(p.pause, PauseReason.lineDown);
    });

    test('a new ring cannot replace a call waiting for its result', () {
      final p = wrapUp().apply(const Ringing(CallContext(phone: '7865550199')), at(12));
      expect(p.kind, PresenceKind.wrapUp);
      expect(p.call?.phone, '3055550142');
    });
  });

  group('server status', () {
    test('a supervisor pause while ready is shown as a system pause', () {
      final p = ready().apply(const ServerSaid('PAUSED'), at(30));
      expect(p.kind, PresenceKind.paused);
      expect(p.pause, PauseReason.bySystem);
    });

    test('is ignored during a call, because VICIdial status lags the SIP events', () {
      final p = ready()
          .apply(const Ringing(customer), at(2))
          .apply(const Answered(), at(3))
          .apply(const ServerSaid('PAUSED'), at(4));
      expect(p.kind, PresenceKind.onCall);
    });

    test('ready on the server lifts a pause only when the line is up', () {
      final down = Presence.start(t0).apply(const ServerSaid('READY'), at(1));
      expect(down.kind, PresenceKind.paused);
      final up = Presence.start(t0).apply(const LineChanged(up: true), t0).apply(const ServerSaid('READY'), at(1));
      expect(up.kind, PresenceKind.ready);
    });
  });
}
