import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vicifast_phone/core/clock.dart';
import 'package:vicifast_phone/data/agent_api.dart';
import 'package:vicifast_phone/data/models.dart';
import 'package:vicifast_phone/data/store.dart';
import 'package:vicifast_phone/domain/presence.dart';
import 'package:vicifast_phone/platform/sip_models.dart';
import 'package:vicifast_phone/state/agent.dart';
import 'package:vicifast_phone/state/line.dart';
import 'package:vicifast_phone/state/services.dart';
import 'package:vicifast_phone/state/session.dart';

/// Records what the app asks the server, in order. [pauseLanded] answers each
/// pause in turn: 0 means VICIdial still had the row in a call.
class FakeApi extends AgentApi {
  FakeApi() : super(store: FakeStore(), appVersion: 'test');

  final calls = <String>[];
  List<int> pauseLanded = [];
  String pollAnswer = '';

  @override
  Future<int> setPaused({String? code}) async {
    calls.add(code == null || code.isEmpty ? 'pause' : 'pause:$code');
    return pauseLanded.isEmpty ? 1 : pauseLanded.removeAt(0);
  }

  @override
  Future<ReadyOutcome> activate({bool takeOver = false}) async {
    calls.add('activate');
    return ReadyOutcome.ready;
  }

  @override
  Future<String> setReady() async {
    calls.add('ready');
    return 'READY';
  }

  @override
  Future<SaveOutcome> saveResult({
    required String code,
    String? uniqueid,
    String? leadId,
    String? hungUpBy,
    String? note,
    DateTime? callbackAt,
    bool callbackOnlyMe = false,
  }) async {
    calls.add('result:$code');
    return SaveOutcome.saved;
  }

  @override
  Future<CallContext?> ringingCall() async => null;

  @override
  Future<CallContext?> currentCall({bool poll = false}) async => null;

  @override
  Future<({String status, CallContext? call})> pollStatus({Duration? timeout}) async =>
      (status: pollAnswer, call: null);
}

/// Keeps nothing; the real one needs the platform keychain.
class FakeStore extends Store {
  @override
  Future<PendingWrapUp?> loadPendingWrapUp() async => null;
  @override
  Future<void> savePendingWrapUp(PendingWrapUp w) async {}
  @override
  Future<void> clearPendingWrapUp() async {}
  @override
  Future<void> rememberResult(String campaignId, String code) async {}
}

class FakeSession extends SessionController {
  @override
  Future<Session?> build() async => Session(
    slug: 'acme',
    user: '2001',
    password: 'x',
    expiresAt: DateTime(2030),
    campaignId: 'INBOUND',
    queueIds: const ['DID_INBOUND'],
  );
}

/// A phone line the test drives by hand.
class FakeLine extends LineController {
  @override
  LineState build() => const LineState(reg: RegState.ok);

  void ring() => state = state.copyWith(
    call: const SipCall(
      callId: 'c1',
      remoteUri: 'sip:3055550142@box',
      remoteDisplay: 'RA_2001_3055550142',
      incoming: true,
      state: CallState.incoming,
    ),
  );
  void pickUp() => state = state.copyWith(call: state.call!.withState(CallState.connected));
  void hangUpRemote() => state = state.copyWith(clearCall: true);

  @override
  Future<void> hangUp() async => hangUpRemote();
}

void main() {
  late FakeApi api;
  late ProviderContainer c;
  late FakeLine line;

  /// Built inside each test, so its timers and futures run on the test's fake clock.
  Future<void> start() async {
    api = FakeApi();
    c = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        apiProvider.overrideWithValue(api),
        storeProvider.overrideWithValue(FakeStore()),
        sessionProvider.overrideWith(FakeSession.new),
        lineProvider.overrideWith(FakeLine.new),
        nowProvider.overrideWithValue(DateTime.now),
      ],
    );
    c.listen(agentProvider, (_, _) {});
    line = c.read(lineProvider.notifier) as FakeLine;
    await c.read(sessionProvider.future);
  }

  Future<void> takeACall(WidgetTester tester) async {
    await c.read(agentProvider.notifier).goReady();
    expect(c.read(agentProvider).kind, PresenceKind.ready);
    line.ring();
    line.pickUp();
    await tester.pump();
    expect(c.read(agentProvider).kind, PresenceKind.onCall);
    line.hangUpRemote();
    await tester.pump();
    expect(c.read(agentProvider).kind, PresenceKind.wrapUp);
  }

  testWidgets('wrap-up keeps pausing until VICIdial has let go of the call', (tester) async {
    await start();
    api.pauseLanded = [0, 0, 1];
    await takeACall(tester);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 2));
    expect(api.calls, ['activate', 'pause', 'pause', 'pause']);
    await tester.pump(const Duration(seconds: 5));
    expect(api.calls, hasLength(4), reason: 'stops once the pause lands');
    c.dispose();
  });

  testWidgets('saving goes out after the wrap-up pause, never before it', (tester) async {
    await start();
    api.pauseLanded = [0, 0, 0, 0];
    await takeACall(tester);
    final save = c.read(agentProvider.notifier).saveResult(const Disposition(code: 'NI', label: 'Not interested'));
    await tester.pump(const Duration(seconds: 10));
    await save;
    final i = api.calls.indexOf('ready');
    expect(i, greaterThan(0));
    expect(api.calls.sublist(i + 1).where((x) => x.startsWith('pause')), isEmpty);
    expect(c.read(agentProvider).kind, PresenceKind.ready);
    c.dispose();
  });

  testWidgets('a ring during wrap-up is turned away and the pause is sent again', (tester) async {
    await start();
    await takeACall(tester);
    await tester.pump(const Duration(seconds: 1));
    final before = api.calls.length;
    line.ring();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(c.read(lineProvider).call, isNull);
    expect(c.read(agentProvider).kind, PresenceKind.wrapUp);
    expect(api.calls.length, greaterThan(before));
    c.dispose();
  });

  testWidgets('a missed ring while paused tells the server the agent is still paused', (tester) async {
    await start();
    await c.read(agentProvider.notifier).pause(const PauseReason('Lunch', code: 'LUNCH'));
    api.calls.clear();
    line.ring();
    await tester.pump();
    line.hangUpRemote();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(c.read(agentProvider).kind, PresenceKind.paused);
    expect(api.calls, ['pause:LUNCH']);
    c.dispose();
  });

  testWidgets('no agent row before Ready is not held against the agent after it', (tester) async {
    await start();
    api.pollAnswer = 'NONE';
    await tester.pump(const Duration(seconds: 17)); // two polls with no row while paused
    await c.read(agentProvider.notifier).goReady();
    await tester.pump(const Duration(seconds: 8)); // the row isn't there yet
    expect(c.read(agentProvider).kind, PresenceKind.ready);
    await tester.pump(const Duration(seconds: 8)); // still no row: off the floor
    expect(c.read(agentProvider).kind, PresenceKind.paused);
    expect(c.read(agentProvider).pause, PauseReason.bySystem);
    c.dispose();
  });

  testWidgets('a quick save still gets its pause onto the server', (tester) async {
    await start();
    await takeACall(tester);
    c.read(agentProvider.notifier).setPauseAfterCall(true);
    api.pauseLanded = [0, 0, 0, 1];
    final save = c.read(agentProvider.notifier).saveResult(const Disposition(code: 'NI', label: 'Not interested'));
    await tester.pump(const Duration(seconds: 12));
    await save;
    expect(c.read(agentProvider).kind, PresenceKind.paused);
    expect(api.pauseLanded, isEmpty, reason: 'kept trying until a pause landed');
    expect(api.calls.last, startsWith('pause'));
    c.dispose();
  });
}
