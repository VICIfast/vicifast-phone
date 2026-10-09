import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import '../core/errors.dart';
import 'models.dart';
import 'store.dart';

const String kApiBase = String.fromEnvironment('API_BASE', defaultValue: 'https://vicifast.com');

sealed class LoginOutcome {
  const LoginOutcome();
}

class LoggedIn extends LoginOutcome {
  const LoggedIn(this.session);
  final Session session;
}

/// The same user is signed in on the web agent screen.
class WebSessionInTheWay extends LoginOutcome {
  const WebSessionInTheWay(this.web);
  final WebSession web;
}

enum ReadyOutcome { ready, phoneLineDown, onCallOnComputer }

enum SaveOutcome { saved, alreadyClosed }

class AgentApi {
  AgentApi({required this.store, required this.appVersion, String? base, http.Client? client})
    : base = base ?? kApiBase,
      _http = client ?? http.Client();

  final Store store;
  final String appVersion;
  final String base;
  final http.Client _http;

  /// Called when the server's probe saw no registration for this phone.
  void Function()? onSipUnreachable;

  Session? session;

  Map<String, String> _queueNames = const {};

  // Sign-in can re-provision the phone on the box (a config rebuild of up to
  // 15 s plus other box calls), and an action's own box call can take 15 s, so
  // the app waits longer than the server does before calling it a failure.
  static const _loginTimeout = Duration(seconds: 60);
  static const _actionTimeout = Duration(seconds: 30);
  static const _readTimeout = Duration(seconds: 15);
  static const _pollTimeout = Duration(seconds: 8);

  // ---------------- sign-in ----------------

  Future<LoginOutcome> login({required String slug, required String user, required String pass, String? code}) async {
    final j = await _post(
      '/api/mobile/login',
      {..._creds(slug, user, pass, code)},
      timeout: _loginTimeout,
      passThrough: const {'WEB_SESSION_CONFLICT'},
    );
    if (j['ok'] != true) {
      final ws = j['web_session'];
      return WebSessionInTheWay(
        ws is Map<String, dynamic> ? WebSession.fromJson(ws) : const WebSession(onCall: false, liveStatus: ''),
      );
    }
    return LoggedIn(
      Session(
        slug: slug.trim().toLowerCase(),
        user: user.trim(),
        password: pass,
        expiresAt: DateTime.tryParse(asStr(j['expiresAt'])) ?? DateTime.now().add(const Duration(hours: 8)),
        sip: SipCredentials.fromJson(j['sip']),
        features: Features.fromJson(j['features']),
      ),
    );
  }

  /// Ends the web agent session so the phone can take over. [hangUp] also ends
  /// a call that session is on.
  Future<void> endWebSession({
    required String slug,
    required String user,
    required String pass,
    String? code,
    required bool hangUp,
  }) async {
    await _post('/api/mobile/login/revoke', {
      ..._creds(slug, user, pass, code),
      'mode': hangUp ? 'force_hangup' : 'soft',
    }, timeout: _loginTimeout);
  }

  Map<String, dynamic> _creds(String slug, String user, String pass, String? code) => {
    'slug': slug.trim().toLowerCase(),
    'user': user.trim(),
    'pass': pass,
    if (code != null && code.isNotEmpty) 'totp': code.trim(),
  };

  // ---------------- shift ----------------

  Future<List<Campaign>> campaigns() async {
    final j = await _get('campaigns', {});
    final names = <String, String>{};
    for (final q in asList(j['all_ingroups'])) {
      names[asStr(q['id'])] = asStr(q['name']);
    }
    final list = asList(j['campaigns']).map(Campaign.fromJson).toList(growable: false);
    for (final c in list) {
      for (final q in c.queues) {
        names[q.id] = q.name;
      }
    }
    rememberQueueNames(names);
    return list;
  }

  void rememberQueueNames(Map<String, String> names) => _queueNames = {..._queueNames, ...names};

  /// The queue's friendly name, or its ID made readable (DID_INBOUND → DID Inbound).
  String queueName(String id) {
    final n = _queueNames[id];
    if (n != null && n.isNotEmpty) return n;
    return id
        .split('_')
        .where((w) => w.isNotEmpty)
        .map((w) => w.length <= 3 ? w.toUpperCase() : w[0].toUpperCase() + w.substring(1).toLowerCase())
        .join(' ');
  }

  Future<SipCredentials?> startShift(String campaignId, List<String> queueIds) async {
    final j = await _post(_agent('setup'), {..._who(), 'campaignId': campaignId, 'ingroups': queueIds});
    return SipCredentials.fromJson(j['sip']);
  }

  /// First "go ready" of a shift registers the remote agent; after that only the
  /// status changes.
  Future<ReadyOutcome> activate({bool takeOver = false}) async {
    final j = await _post(
      _agent('activate'),
      {..._who(), if (takeOver) 'force': true},
      passThrough: const {'WEB_USER_IN_CALL', 'SIP_NOT_REGISTERED'},
    );
    if (j['ok'] == true) return ReadyOutcome.ready;
    final reason = asStr(j['reason'] ?? j['error']).toUpperCase();
    return reason == 'SIP_NOT_REGISTERED' ? ReadyOutcome.phoneLineDown : ReadyOutcome.onCallOnComputer;
  }

  /// Returns the status the server actually set. PAUSED means the server saw
  /// no registration for this phone and kept the agent off the floor.
  Future<String> setReady() async {
    final j = await _post(_agent('status'), {..._who(), 'status': 'ACTIVE'});
    return asStr(j['live_status']).toUpperCase();
  }

  /// Returns how many agent rows the server changed. 0 means VICIdial still had
  /// the agent marked in a call, so the pause didn't land.
  Future<int> setPaused({String? code}) async {
    final j = await _post(_agent('status'), {
      ..._who(),
      'status': 'PAUSED',
      if (code != null && code.isNotEmpty) 'pauseCode': code,
    });
    // Older shims don't report it; take the pause as landed.
    return j.containsKey('live_updated') ? asInt(j['live_updated']) : 1;
  }

  /// Pause reasons for the campaign. Servers without the endpoint yet answer
  /// 404, which simply means "no reasons": pause becomes one tap.
  Future<List<PauseCode>> pauseCodes(String campaignId) async {
    try {
      final j = await _get('pause-codes', {'campaignId': campaignId});
      return asList(j['pause_codes']).map(PauseCode.fromJson).toList(growable: false);
    } on AppError catch (e) {
      if (e.status == 404) return const [];
      rethrow;
    }
  }

  // ---------------- calls ----------------

  Future<CallContext?> currentCall({bool poll = false}) async =>
      (await pollStatus(timeout: poll ? _pollTimeout : _readTimeout)).call;

  /// The agent's VICIdial status (READY, PAUSED, INCALL…) and current call, if any.
  Future<({String status, CallContext? call})> pollStatus({Duration? timeout}) async {
    final j = await _get('current-lead', {}, timeout: timeout ?? _pollTimeout);
    final status = asStr(j['agent_status'] ?? j['live_status']).toUpperCase();
    if (j['lead'] == null && asStr(j['callerid']).isEmpty) return (status: status, call: null);
    return (status: status, call: _named(CallContext.fromJson(j)));
  }

  /// Who is ringing this phone right now (vicidial_live_agents.ring_callerid).
  /// Older servers lack the endpoint; the current-lead lookup is the fallback.
  Future<CallContext?> ringingCall() async {
    try {
      final j = await _get('ringing', {}, timeout: _pollTimeout);
      if (j['ringing'] != true) return null;
      return _named(CallContext.fromJson(j));
    } on AppError catch (e) {
      if (e.status == 404) return currentCall(poll: true);
      rethrow;
    }
  }

  CallContext _named(CallContext c) =>
      c.queueName.isNotEmpty || c.queueId.isEmpty ? c : c.merge(CallContext(queueName: queueName(c.queueId)));

  Future<void> hangUpOnServer(String? callerId) => _post(_agent('call-control'), {
    ..._who(),
    'stage': 'HANGUP',
    if (callerId != null && callerId.isNotEmpty) 'value': callerId,
  });

  Future<List<TransferQueue>> transferQueues() async {
    final j = await _get('xfer-options', {if (session?.campaignId != null) 'campaignId': session!.campaignId!});
    final seen = <String>{};
    final out = <TransferQueue>[];
    for (final id in (j['ingroups'] as List? ?? const []).map((e) => e.toString())) {
      if (id.isEmpty || id.startsWith('AGENTDIRECT') || !seen.add(id)) continue;
      out.add(TransferQueue(id: id, name: queueName(id)));
    }
    for (final c in asList(j['closer_campaigns'])) {
      final id = asStr(c['ingroup']);
      if (id.isEmpty || !seen.add(id)) continue;
      out.add(TransferQueue(id: id, name: asStr(c['name']).isEmpty ? queueName(id) : asStr(c['name'])));
    }
    return out;
  }

  Future<void> transferToQueue(String queueId) =>
      _post(_agent('call-control'), {..._who(), 'stage': 'INGROUPTRANSFER', 'ingroup': queueId});

  /// The server accepts digits only.
  Future<void> transferToNumber(String number) => _post(_agent('call-control'), {
    ..._who(),
    'stage': 'EXTENSIONTRANSFER',
    'phoneNumber': number.replaceAll(RegExp(r'\D'), ''),
  });

  // ---------------- wrap-up ----------------

  Future<List<Disposition>> results(String campaignId) async {
    final j = await _get('dispositions', {'campaignId': campaignId});
    return asList(j['dispositions']).map(Disposition.fromJson).toList(growable: false);
  }

  Future<SaveOutcome> saveResult({
    required String code,
    String? uniqueid,
    String? leadId,
    String? hungUpBy,
    String? note,
    DateTime? callbackAt,
    bool callbackOnlyMe = false,
  }) async {
    try {
      await _post(_agent('disposition'), {
        ..._who(),
        'status': code,
        if (uniqueid != null && uniqueid.isNotEmpty) 'uniqueid': uniqueid,
        if (leadId != null && leadId.isNotEmpty) 'leadId': leadId,
        'hangupBy': ?hungUpBy,
        if (callbackAt != null)
          'callback': {
            'datetime': DateFormat('yyyy-MM-dd HH:mm:ss').format(callbackAt.toLocal()),
            'datetimeIso': callbackAt.toUtc().toIso8601String(),
            'type': callbackOnlyMe ? 'USERONLY' : 'ANYONE',
            if (callbackOnlyMe) 'callbackUser': session?.user,
            if (note != null && note.isNotEmpty) 'comments': fitUtf16(note, 200),
          },
      });
      return SaveOutcome.saved;
    } on AppError catch (e) {
      if (e.code == AppErrorCode.noCallRow) return SaveOutcome.alreadyClosed;
      rethrow;
    }
  }

  // ---------------- the agent's day ----------------

  Future<TodayStats> todayStats() async => TodayStats.fromJson(await _get('stats', _today()));

  Future<List<CallRecord>> todayCalls() async {
    final s = session;
    if (s == null || !s.features.showCalls) return const [];
    final results = await Future.wait([
      _calls('inbound-calls', inbound: true),
      _calls('outbound-calls', inbound: false),
    ]);
    final all = [...results[0], ...results[1]];
    all.sort((a, b) => (b.at ?? DateTime(0)).compareTo(a.at ?? DateTime(0)));
    return all;
  }

  Future<List<CallRecord>> _calls(String path, {required bool inbound}) async {
    try {
      final j = await _get(path, _today());
      return asList(j['calls']).map((r) => CallRecord.fromJson(r, inbound: inbound)).toList(growable: false);
    } on AppError catch (e) {
      if (e.code == AppErrorCode.featureOff) return const [];
      rethrow;
    }
  }

  Map<String, String> _today() {
    final day = DateFormat('yyyy-MM-dd').format(DateTime.now());
    return {
      'begin': day,
      'end': day,
      'preset': 'today',
      'tz_offset_min': DateTime.now().timeZoneOffset.inMinutes.toString(),
    };
  }

  // ---------------- lifecycle ----------------

  Future<void> endShift() async {
    try {
      await _post(_agent('teardown'), _who(), timeout: _pollTimeout);
    } catch (_) {
      return;
    }
  }

  Future<void> registerPushToken(String token, String platform) async {
    try {
      await _post(_agent('push-token'), {
        ..._who(),
        'token': token,
        'platform': platform,
        'deviceId': await store.deviceId(),
      });
    } catch (_) {
      return;
    }
  }

  // ---------------- transport ----------------

  String _agent(String path) => '/api/mobile/agent/$path';

  Map<String, dynamic> _who() {
    final s = session;
    if (s == null) throw const AppError(AppErrorCode.sessionEnded, detail: 'no session');
    return {'slug': s.slug, 'user': s.user};
  }

  Future<Map<String, String>> _headers({bool json = false}) async => {
    'accept': 'application/json',
    if (json) 'content-type': 'application/json',
    'X-Device-Id': await store.deviceId(),
    'X-App-Version': appVersion,
    'X-App-Platform': Platform.isIOS ? 'ios' : 'android',
  };

  Future<Map<String, dynamic>> _get(String path, Map<String, String> query, {Duration timeout = _readTimeout}) async {
    final uri = Uri.parse('$base${_agent(path)}').replace(queryParameters: {...?_whoQuery(), ...query});
    return _send(() async => _http.get(uri, headers: await _headers()), timeout, const {});
  }

  Map<String, String>? _whoQuery() {
    final s = session;
    return s == null ? null : {'slug': s.slug, 'user': s.user};
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    Duration timeout = _actionTimeout,
    Set<String> passThrough = const {},
  }) async {
    final uri = Uri.parse('$base$path');
    final payload = path.startsWith('/api/mobile/login') ? {...body, 'deviceId': await store.deviceId()} : body;
    return _send(
      () async => _http.post(uri, headers: await _headers(json: true), body: jsonEncode(payload)),
      timeout,
      passThrough,
    );
  }

  Future<Map<String, dynamic>> _send(
    Future<http.Response> Function() request,
    Duration timeout,
    Set<String> passThrough,
  ) async {
    final http.Response res;
    try {
      res = await request().timeout(timeout);
    } on TimeoutException {
      throw const AppError(AppErrorCode.noInternet, detail: 'timeout');
    } catch (e) {
      throw AppError(AppErrorCode.noInternet, detail: e.runtimeType.toString());
    }
    Map<String, dynamic> j;
    try {
      final decoded = jsonDecode(res.body);
      j = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      if (res.statusCode == 404) throw const AppError(AppErrorCode.unknown, status: 404, detail: 'not found');
      throw AppError(AppErrorCode.phoneSystemDown, status: res.statusCode, detail: 'non-JSON response');
    }
    if (j['sip_reachable'] == false && j['sip_probe'] != 'unknown') onSipUnreachable?.call();
    if (res.statusCode < 400 && j['ok'] == true) return j;
    final reason = asStr(j['reason']).isNotEmpty ? asStr(j['reason']) : asStr(j['error']);
    if (passThrough.contains(reason.toUpperCase())) return j;
    throw AppError(
      AppError.parseReason(reason),
      status: res.statusCode,
      detail: [reason, asStr(j['detail'])].where((s) => s.isNotEmpty).join(': '),
    );
  }
}

/// [s] cut to at most [max] UTF-16 units (how the server measures length),
/// never splitting a character in two.
String fitUtf16(String s, int max) {
  if (s.length <= max) return s;
  final out = StringBuffer();
  var used = 0;
  for (final r in s.runes) {
    final size = r > 0xFFFF ? 2 : 1;
    if (used + size > max) break;
    out.writeCharCode(r);
    used += size;
  }
  return out.toString();
}
