import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:vicifast_phone/core/clock.dart';
import 'package:vicifast_phone/data/agent_api.dart';
import 'package:vicifast_phone/data/models.dart';
import 'package:vicifast_phone/data/store.dart';
import 'package:vicifast_phone/domain/presence.dart';
import 'package:vicifast_phone/features/call.dart';
import 'package:vicifast_phone/features/calls.dart';
import 'package:vicifast_phone/features/home.dart';
import 'package:vicifast_phone/features/me.dart';
import 'package:vicifast_phone/features/setup.dart';
import 'package:vicifast_phone/features/shell.dart';
import 'package:vicifast_phone/features/shift.dart';
import 'package:vicifast_phone/features/signin.dart';
import 'package:vicifast_phone/features/wrapup.dart';
import 'package:vicifast_phone/platform/phone_setup.dart';
import 'package:vicifast_phone/platform/sip_models.dart';
import 'package:vicifast_phone/state/agent.dart';
import 'package:vicifast_phone/state/line.dart';
import 'package:vicifast_phone/state/services.dart';
import 'package:vicifast_phone/state/session.dart';
import 'package:vicifast_phone/state/shift.dart';
import 'package:vicifast_phone/ui/adaptive.dart';
import 'package:vicifast_phone/ui/theme.dart';

// ---------------------------------------------------------------- sample data

final now = DateTime(2026, 10, 9, 10, 14);
DateTime ago(int m, int s) => now.subtract(Duration(minutes: m, seconds: s));

const lead = Lead(
  id: '86059',
  firstName: 'Robert',
  lastName: 'Hayes',
  phone: '3055550142',
  city: 'Miami',
  state: 'FL',
  comments: 'Asked about the family plan. Prefers mornings.',
  lastResult: 'CALLBK',
  gmtOffset: -4,
);
const customer = CallContext(
  callerId: 'V1009101400000086059',
  uniqueid: '1728483240.1201',
  queueId: 'DID_INBOUND',
  queueName: 'DID Inbound',
  phone: '3055550142',
  waitSec: 14,
  lead: lead,
);

Session session({bool shift = true}) => Session(
  slug: 'acme',
  user: '2001',
  password: 'x',
  expiresAt: DateTime(2026, 10, 9, 22),
  sip: const SipCredentials(username: '2001', password: 's', server: 'pbx.example.com'),
  campaignId: shift ? 'INBOUND' : null,
  campaignName: shift ? 'Inbound support' : null,
  queueIds: shift ? const ['DID_INBOUND', 'P1_INBOUND'] : const [],
);

const stats = TodayStats(
  calls: 23,
  talk: Duration(hours: 1, minutes: 42),
  paused: Duration(minutes: 31),
  waiting: Duration(minutes: 47),
);

final calls = [
  CallRecord(
    id: '1',
    inbound: true,
    at: DateTime(2026, 10, 9, 10, 21),
    phone: '3055550142',
    queueId: 'DID_INBOUND',
    seconds: 266,
    result: 'NI',
  ),
  CallRecord(
    id: '2',
    inbound: true,
    at: DateTime(2026, 10, 9, 10, 9),
    phone: '3055550188',
    queueId: 'P1_INBOUND',
    seconds: 471,
    result: 'SALE',
  ),
  CallRecord(
    id: '3',
    inbound: true,
    at: DateTime(2026, 10, 9, 9, 58),
    phone: '7865550199',
    queueId: 'DID_INBOUND',
    seconds: 38,
    result: 'HU',
  ),
  CallRecord(
    id: '4',
    inbound: true,
    at: DateTime(2026, 10, 9, 9, 44),
    phone: '9545550123',
    queueId: 'DID_INBOUND',
    seconds: 192,
    result: 'CALLBK',
  ),
  CallRecord(
    id: '5',
    inbound: true,
    at: DateTime(2026, 10, 9, 9, 31),
    phone: '3055550111',
    queueId: 'P1_INBOUND',
    seconds: 125,
    result: 'XFER',
  ),
  CallRecord(
    id: '6',
    inbound: true,
    at: DateTime(2026, 10, 9, 9, 20),
    phone: '9545550110',
    queueId: 'DID_INBOUND',
    seconds: 74,
    result: 'DNC',
  ),
];

const campaigns = [
  Campaign(
    id: 'INBOUND',
    name: 'Inbound support',
    queues: [
      Queue(id: 'DID_INBOUND', name: 'DID Inbound', waiting: 2),
      Queue(id: 'P1_INBOUND', name: 'P1 Inbound', waiting: 0),
      Queue(id: 'BOT_INBOUND', name: 'Bot Inbound', waiting: 0),
    ],
  ),
  Campaign(id: 'RETAIN', name: 'Retention', queues: []),
];

const results = [
  Disposition(code: 'SALE', label: 'Sale', sale: true),
  Disposition(code: 'NI', label: 'Not interested'),
  Disposition(code: 'CALLBK', label: 'Call back', callback: true),
  Disposition(code: 'DNC', label: 'Do not call', dnc: true),
  Disposition(code: 'WN', label: 'Wrong number'),
  Disposition(code: 'HU', label: 'Hung up'),
  Disposition(code: 'INFO', label: 'Info only'),
];

const pauseCodes = [
  PauseCode(code: 'BREAK', label: 'Break'),
  PauseCode(code: 'LUNCH', label: 'Lunch'),
  PauseCode(code: 'TRAIN', label: 'Training'),
  PauseCode(code: 'MEET', label: 'Meeting'),
  PauseCode(code: 'BIO', label: 'Restroom'),
];

const transferQueues = [
  TransferQueue(id: 'P1_INBOUND', name: 'P1 Inbound', readyAgents: 2),
  TransferQueue(id: 'RETAIN', name: 'Retention', readyAgents: 1),
  TransferQueue(id: 'BILLING', name: 'Billing', readyAgents: 0),
];

Presence paused() => Presence(
  kind: PresenceKind.paused,
  since: ago(18, 42),
  pause: const PauseReason('Lunch', code: 'LUNCH'),
  lineUp: true,
);
Presence ready() => Presence(kind: PresenceKind.ready, since: ago(2, 10), lineUp: true);
Presence offline() => Presence(kind: PresenceKind.paused, since: ago(0, 37), pause: PauseReason.lineDown);
Presence ringing() => Presence(kind: PresenceKind.ringing, since: now, lineUp: true, call: customer);
Presence onCall() =>
    Presence(kind: PresenceKind.onCall, since: ago(3, 12), callStart: ago(3, 12), lineUp: true, call: customer);
Presence held() => Presence(
  kind: PresenceKind.onCall,
  since: ago(4, 1),
  callStart: ago(4, 1),
  lineUp: true,
  call: customer,
  held: true,
  heldSince: ago(0, 42),
  muted: true,
);
Presence wrapUp() =>
    Presence(kind: PresenceKind.wrapUp, since: ago(0, 28), callStart: ago(4, 54), lineUp: true, call: customer);

// ---------------------------------------------------------------- fakes

class FakeSession extends SessionController {
  FakeSession(this.s);
  final Session? s;
  @override
  Future<Session?> build() async => s;
}

class FakeAgent extends AgentController {
  FakeAgent(this.p);
  final Presence p;
  @override
  Presence build() => p;
}

class FakeLine extends LineController {
  FakeLine(this.l);
  final LineState l;
  @override
  LineState build() => l;
}

class FakeTheme extends ThemeController {
  @override
  ThemeMode build() => ThemeMode.system;
}

// ---------------------------------------------------------------- harness

enum Where { full, home, calls, me, detail }

class Shot {
  const Shot(
    this.name,
    this.where, {
    this.screen,
    this.presence,
    this.session,
    this.lineUp = true,
    this.sheet,
    this.open,
    this.textScale = 1,
    this.short = false,
  });
  final String name;
  final Where where;
  final Widget? screen;
  final Presence Function()? presence;
  final Session? Function()? session;
  final bool lineUp;
  final Widget Function()? sheet;

  /// Opens something that isn't an app sheet (the iOS pause action sheet).
  final Future<void> Function(BuildContext)? open;
  final double textScale;

  /// A small phone (iPhone SE, compact Android) instead of a current one.
  final bool short;
}

final shots = <Shot>[
  Shot('01_signin', Where.full, screen: const SignInScreen(), session: () => null),
  Shot('02_code', Where.full, screen: const CodeScreen(), session: () => null),
  Shot('03_setup', Where.full, screen: const SetupScreen(), session: () => session(shift: false), lineUp: false),
  Shot('04_shift', Where.full, screen: const ShiftScreen(), session: () => session(shift: false), lineUp: false),
  const Shot('05_home_paused', Where.home, presence: paused),
  Shot('06_pause_sheet', Where.home, presence: ready, open: (ctx) => pickPauseReason(ctx, pauseCodes)),
  const Shot('07_home_ready', Where.home, presence: ready),
  const Shot('08_home_offline', Where.home, presence: offline, lineUp: false),
  const Shot('09_incoming', Where.full, screen: IncomingScreen(), presence: ringing),
  const Shot('10_call', Where.full, screen: CallScreen(), presence: onCall),
  const Shot('11_hold_muted', Where.full, screen: CallScreen(), presence: held),
  Shot(
    '12_transfer',
    Where.full,
    screen: const CallScreen(),
    presence: onCall,
    sheet: () => const TransferSheet(customer: 'Robert Hayes'),
  ),
  Shot('13_keypad', Where.full, screen: const CallScreen(), presence: onCall, sheet: () => const KeypadSheet()),
  const Shot('14_wrapup', Where.full, screen: WrapUpScreen(), presence: wrapUp),
  Shot(
    '15_callback',
    Where.full,
    screen: const WrapUpScreen(),
    presence: wrapUp,
    sheet: () => const CallbackSheet(call: customer),
  ),
  const Shot('16_calls', Where.calls, presence: ready),
  const Shot('17_call_detail', Where.detail, presence: ready),
  const Shot('18_me', Where.me, presence: ready),
  const Shot('19_call_text200', Where.full, screen: CallScreen(), presence: onCall, textScale: 2),
  const Shot('20_calls_text200', Where.calls, presence: ready, textScale: 2),
  Shot(
    '21_keypad_text200',
    Where.full,
    screen: const CallScreen(),
    presence: onCall,
    sheet: () => const KeypadSheet(),
    textScale: 2,
  ),
  const Shot('22_call_short', Where.full, screen: CallScreen(), presence: held, short: true),
  const Shot('23_wrapup_text200', Where.full, screen: WrapUpScreen(), presence: wrapUp, textScale: 2),
];

GoRouter routerFor(Shot shot) {
  if (shot.where == Where.full) {
    return GoRouter(
      routes: [GoRoute(path: '/', builder: (_, _) => shot.screen!)],
    );
  }
  final initial = switch (shot.where) {
    Where.calls => '/calls',
    Where.detail => '/calls/detail',
    Where.me => '/me',
    _ => '/home',
  };
  return GoRouter(
    initialLocation: initial,
    initialExtra: shot.where == Where.detail ? calls.first : null,
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => TabShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [GoRoute(path: '/home', builder: (_, _) => const HomeScreen())],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/calls',
                builder: (_, _) => const CallsScreen(),
                routes: [
                  GoRoute(
                    path: 'detail',
                    builder: (_, s) => CallDetailScreen(record: s.extra! as CallRecord),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: '/me', builder: (_, _) => const MeScreen())],
          ),
        ],
      ),
    ],
  );
}

/// A fake status bar drawn into the top inset, so the images read as phones.
class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.ios, required this.dark, required this.child, required this.top, this.notch = true});
  final bool ios;
  final bool notch;
  final bool dark;
  final double top;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final fg = dark ? Colors.white : Colors.black;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          child,
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: top,
            child: IgnorePointer(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: ios ? 34 : 22),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      '9:41',
                      style: TextStyle(
                        fontFamily: 'Roboto',
                        color: fg,
                        fontSize: ios ? 16 : 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    if (ios && notch)
                      Container(
                        width: 118,
                        height: 34,
                        decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(20)),
                      ),
                    const Spacer(),
                    Icon(Icons.signal_cellular_alt_rounded, size: 15, color: fg),
                    const SizedBox(width: 4),
                    Icon(Icons.wifi_rounded, size: 15, color: fg),
                    const SizedBox(width: 4),
                    Icon(Icons.battery_full_rounded, size: 15, color: fg),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> capture(WidgetTester tester, Shot shot, {required bool ios, required bool dark}) async {
  final platform = ios ? TargetPlatform.iOS : TargetPlatform.android;
  debugDefaultTargetPlatformOverride = platform;
  final size = shot.short
      ? (ios ? const Size(375, 667) : const Size(360, 640))
      : (ios ? const Size(393, 852) : const Size(412, 915));
  final top = shot.short ? 20.0 : (ios ? 59.0 : 30.0);
  final bottom = shot.short ? 0.0 : (ios ? 34.0 : 20.0);
  tester.platformDispatcher.textScaleFactorTestValue = shot.textScale;
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = size * 2;
  tester.view.padding = FakeViewPadding(top: top * 2, bottom: bottom * 2);
  tester.view.viewPadding = FakeViewPadding(top: top * 2, bottom: bottom * 2);

  final api = AgentApi(store: Store(), appVersion: '1.0.0')
    ..rememberQueueNames({'DID_INBOUND': 'DID Inbound', 'P1_INBOUND': 'P1 Inbound', 'BOT_INBOUND': 'Bot Inbound'});
  final s = shot.session == null ? session() : shot.session!();
  api.session = s;
  final setupStatus = SetupStatus(
    ios
        ? const {SetupItem.microphone: true, SetupItem.notifications: true}
        : const {
            SetupItem.microphone: true,
            SetupItem.notifications: true,
            SetupItem.lockScreenCalls: false,
            SetupItem.battery: false,
          },
  );
  final homeSetup = SetupStatus(
    ios
        ? const {SetupItem.microphone: true, SetupItem.notifications: true}
        : const {
            SetupItem.microphone: true,
            SetupItem.notifications: true,
            SetupItem.lockScreenCalls: true,
            SetupItem.battery: true,
          },
  );

  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        storeProvider.overrideWithValue(Store()),
        apiProvider.overrideWithValue(api),
        appVersionProvider.overrideWithValue('1.0.0 (100)'),
        nowProvider.overrideWithValue(() => now),
        tickProvider.overrideWith((ref) => Stream.value(now)),
        sessionProvider.overrideWith(() => FakeSession(s)),
        agentProvider.overrideWith(() => FakeAgent((shot.presence ?? paused)())),
        lineProvider.overrideWith(() => FakeLine(LineState(reg: shot.lineUp ? RegState.ok : RegState.failed))),
        themeModeProvider.overrideWith(FakeTheme.new),
        todayStatsProvider.overrideWith((ref) async => stats),
        todayCallsProvider.overrideWith((ref) async => calls),
        campaignsProvider.overrideWith((ref) async => campaigns),
        resultsProvider.overrideWith((ref, _) async => results),
        pauseCodesProvider.overrideWith((ref, _) async => pauseCodes),
        transferQueuesProvider.overrideWith((ref) async => transferQueues),
        setupStatusProvider.overrideWith((ref) async => shot.name == '03_setup' ? setupStatus : homeSetup),
      ],
      child: _StatusBar(
        ios: ios,
        notch: !shot.short,
        dark: dark || shot.name == '09_incoming',
        top: top,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light, platform),
          darkTheme: buildTheme(Brightness.dark, platform),
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          routerConfig: routerFor(shot),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (shot.sheet != null || shot.open != null) {
    final ctx = tester.element(find.byType(Scaffold).last);
    unawaited(shot.open != null ? shot.open!(ctx) : showAppSheet<void>(ctx, (_) => shot.sheet!()));
    await tester.pumpAndSettle();
  }
  final name = '${ios ? 'ios' : 'android'}_${dark ? 'dark' : 'light'}_${shot.name}';
  await expectLater(find.byType(ProviderScope), matchesGoldenFile('out/$name.png'));
  debugDefaultTargetPlatformOverride = null;
}

final _goldens = Platform.environment['GOLDENS'] == '1';

void main() {
  for (final ios in [false, true]) {
    for (final dark in [false, true]) {
      for (final shot in shots) {
        // Review screenshots, not baselines: run with GOLDENS=1 flutter test test/goldens --update-goldens
        testWidgets('${ios ? 'iPhone' : 'Android'} ${dark ? 'dark' : 'light'} ${shot.name}', skip: !_goldens, (
          tester,
        ) async {
          addTearDown(() {
            tester.view.reset();
            tester.platformDispatcher.clearTextScaleFactorTestValue();
            debugDefaultTargetPlatformOverride = null;
          });
          await capture(tester, shot, ios: ios, dark: dark);
        });
      }
    }
  }
}
