import '../platform/sip_models.dart';

typedef Json = Map<String, dynamic>;

int asInt(Object? v) => switch (v) {
  final int i => i,
  final num n => n.toInt(),
  final String s => int.tryParse(s.trim()) ?? double.tryParse(s.trim())?.toInt() ?? 0,
  _ => 0,
};

String asStr(Object? v) => v == null ? '' : v.toString().trim();

double? asDouble(Object? v) => switch (v) {
  final num n => n.toDouble(),
  final String s => double.tryParse(s.trim()),
  _ => null,
};

bool asBool(Object? v) => v == true || v == 'Y' || v == '1' || v == 1;

/// VICIdial timestamps ("2026-10-08 10:21:07") are in the server's own time zone.
/// They are kept as naive local values and only ever shown, never compared to now.
DateTime? asServerTime(Object? v) {
  final s = asStr(v);
  if (s.isEmpty || s.startsWith('0000')) return null;
  return DateTime.tryParse(s.replaceFirst(' ', 'T'));
}

List<Json> asList(Object? v) => v is List ? v.whereType<Map<String, dynamic>>().toList(growable: false) : const [];

class SipCredentials {
  const SipCredentials({
    required this.username,
    required this.password,
    required this.server,
    this.transport = 'udp',
    this.port,
  });

  final String username;
  final String password;
  final String server;
  final String transport;
  final int? port;

  /// Accepts both the camelCase and snake_case shapes the routes return.
  static SipCredentials? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final server = asStr(raw['registerServer'] ?? raw['register_server'] ?? raw['server']);
    final username = asStr(raw['username']);
    if (server.isEmpty || username.isEmpty) return null;
    final port = asInt(raw['port']);
    return SipCredentials(
      username: username,
      password: asStr(raw['password']),
      server: server,
      transport: asStr(raw['transport']).isEmpty ? 'udp' : asStr(raw['transport']).toLowerCase(),
      port: port == 0 ? null : port,
    );
  }

  Json toJson() => {
    'username': username,
    'password': password,
    'server': server,
    'transport': transport,
    if (port != null) 'port': port,
  };

  SipAccount toAccount(String displayName) => SipAccount(
    username: username,
    password: password,
    domain: server,
    transport: transport,
    port: port,
    displayName: displayName,
  );
}

class Features {
  const Features({this.showStats = true, this.showCalls = true});

  final bool showStats;
  final bool showCalls;

  factory Features.fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return const Features();
    bool on(String k) => raw[k] is bool ? raw[k] as bool : true;
    return Features(
      showStats: on('mobileShowStats'),
      showCalls: on('mobileShowOutboundCalls') || on('mobileShowInboundCalls'),
    );
  }

  Json toJson() => {
    'mobileShowStats': showStats,
    'mobileShowOutboundCalls': showCalls,
    'mobileShowInboundCalls': showCalls,
  };
}

class Session {
  const Session({
    required this.slug,
    required this.user,
    required this.password,
    required this.expiresAt,
    this.sip,
    this.features = const Features(),
    this.campaignId,
    this.campaignName,
    this.queueIds = const [],
  });

  final String slug;
  final String user;

  /// Replayed to renew the session. To be replaced by a refresh token.
  final String password;
  final DateTime expiresAt;
  final SipCredentials? sip;
  final Features features;
  final String? campaignId;
  final String? campaignName;
  final List<String> queueIds;

  bool get hasShift => campaignId != null && campaignId!.isNotEmpty;

  Session copyWith({
    DateTime? expiresAt,
    SipCredentials? sip,
    Features? features,
    String? campaignId,
    String? campaignName,
    List<String>? queueIds,
  }) => Session(
    slug: slug,
    user: user,
    password: password,
    expiresAt: expiresAt ?? this.expiresAt,
    sip: sip ?? this.sip,
    features: features ?? this.features,
    campaignId: campaignId ?? this.campaignId,
    campaignName: campaignName ?? this.campaignName,
    queueIds: queueIds ?? this.queueIds,
  );

  /// A renewed login carries no shift; keep the one the agent already chose.
  Session renewedFrom(Session fresh) =>
      copyWith(expiresAt: fresh.expiresAt, sip: fresh.sip ?? sip, features: fresh.features);

  Json toJson() => {
    'slug': slug,
    'user': user,
    'password': password,
    'expiresAt': expiresAt.toIso8601String(),
    if (sip != null) 'sip': sip!.toJson(),
    'features': features.toJson(),
    if (campaignId != null) 'campaignId': campaignId,
    if (campaignName != null) 'campaignName': campaignName,
    'queueIds': queueIds,
  };

  static Session? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final expires = DateTime.tryParse(asStr(raw['expiresAt']));
    if (expires == null || asStr(raw['slug']).isEmpty || asStr(raw['user']).isEmpty) return null;
    return Session(
      slug: asStr(raw['slug']),
      user: asStr(raw['user']),
      password: asStr(raw['password']),
      expiresAt: expires,
      sip: SipCredentials.fromJson(raw['sip']),
      features: Features.fromJson(raw['features']),
      campaignId: raw['campaignId'] as String?,
      campaignName: raw['campaignName'] as String?,
      queueIds: (raw['queueIds'] as List?)?.map((e) => e.toString()).toList() ?? const [],
    );
  }
}

class WebSession {
  const WebSession({required this.onCall, required this.liveStatus, this.campaignId = ''});

  final bool onCall;
  final String liveStatus;
  final String campaignId;

  factory WebSession.fromJson(Json j) => WebSession(
    onCall: j['on_call'] == true,
    liveStatus: asStr(j['live_status']),
    campaignId: asStr(j['campaign_id']),
  );
}

class Queue {
  const Queue({required this.id, required this.name, this.waiting});

  final String id;
  final String name;
  final int? waiting;

  factory Queue.fromJson(Json j) => Queue(
    id: asStr(j['id']),
    name: asStr(j['name']).isEmpty ? asStr(j['id']) : asStr(j['name']),
    waiting: j['waiting'] == null ? null : asInt(j['waiting']),
  );
}

class Campaign {
  const Campaign({required this.id, required this.name, required this.queues});

  final String id;
  final String name;
  final List<Queue> queues;

  factory Campaign.fromJson(Json j) => Campaign(
    id: asStr(j['id']),
    name: asStr(j['name']).isEmpty ? asStr(j['id']) : asStr(j['name']),
    queues: asList(j['ingroups']).map(Queue.fromJson).toList(growable: false),
  );
}

class Disposition {
  const Disposition({
    required this.code,
    required this.label,
    this.sale = false,
    this.dnc = false,
    this.callback = false,
  });

  final String code;
  final String label;
  final bool sale;
  final bool dnc;
  final bool callback;

  factory Disposition.fromJson(Json j) => Disposition(
    code: asStr(j['code']),
    label: asStr(j['label']).isEmpty ? asStr(j['code']) : asStr(j['label']),
    sale: asBool(j['sale']),
    dnc: asBool(j['dnc']),
    callback: asBool(j['callback']),
  );
}

class PauseCode {
  const PauseCode({required this.code, required this.label});

  final String code;
  final String label;

  factory PauseCode.fromJson(Json j) =>
      PauseCode(code: asStr(j['code']), label: asStr(j['label']).isEmpty ? asStr(j['code']) : asStr(j['label']));
}

class Lead {
  const Lead({
    required this.id,
    this.firstName = '',
    this.lastName = '',
    this.phone = '',
    this.city = '',
    this.state = '',
    this.comments = '',
    this.lastResult = '',
    this.gmtOffset,
  });

  final String id;
  final String firstName;
  final String lastName;
  final String phone;
  final String city;
  final String state;
  final String comments;
  final String lastResult;
  final double? gmtOffset;

  String get name => '$firstName $lastName'.trim();
  String get place => [city, state].where((s) => s.isNotEmpty).join(', ');

  factory Lead.fromFields(Json f) => Lead(
    id: asStr(f['lead_id']),
    firstName: asStr(f['first_name']),
    lastName: asStr(f['last_name']),
    phone: asStr(f['phone_number']),
    city: asStr(f['city']),
    state: asStr(f['state']),
    comments: asStr(f['comments']),
    lastResult: asStr(f['status']),
    gmtOffset: asDouble(f['gmt_offset_now']),
  );
}

/// The call this agent is ringing for or talking on, as the server sees it.
class CallContext {
  const CallContext({
    this.callerId = '',
    this.uniqueid = '',
    this.queueId = '',
    this.queueName = '',
    this.phone = '',
    this.waitSec,
    this.lead,
  });

  final String callerId;
  final String uniqueid;
  final String queueId;
  final String queueName;
  final String phone;
  final int? waitSec;
  final Lead? lead;

  String get displayName {
    final n = lead?.name ?? '';
    return n.isNotEmpty ? n : phone;
  }

  factory CallContext.fromJson(Json j) {
    final leadRaw = j['lead'];
    final lead = leadRaw is Map<String, dynamic> ? Lead.fromFields(leadRaw) : null;
    final phone = asStr(j['phone_number']).isNotEmpty ? asStr(j['phone_number']) : (lead?.phone ?? '');
    return CallContext(
      callerId: asStr(j['callerid']),
      uniqueid: asStr(j['uniqueid']),
      queueId: asStr(j['campaign_id']),
      queueName: asStr(j['queue_name']),
      phone: phone,
      waitSec: j['wait_sec'] == null ? null : asInt(j['wait_sec']),
      lead: lead,
    );
  }

  /// Same shape as the server's current-lead response, so [CallContext.fromJson] reads it back.
  Json toJson() => {
    'callerid': callerId,
    'uniqueid': uniqueid,
    'campaign_id': queueId,
    'queue_name': queueName,
    'phone_number': phone,
    if (waitSec != null) 'wait_sec': waitSec,
    if (lead != null)
      'lead': {
        'lead_id': lead!.id,
        'first_name': lead!.firstName,
        'last_name': lead!.lastName,
        'phone_number': lead!.phone,
        'city': lead!.city,
        'state': lead!.state,
        'comments': lead!.comments,
        'status': lead!.lastResult,
        if (lead!.gmtOffset != null) 'gmt_offset_now': lead!.gmtOffset,
      },
  };

  CallContext merge(CallContext? fresher) {
    if (fresher == null) return this;
    return CallContext(
      callerId: fresher.callerId.isNotEmpty ? fresher.callerId : callerId,
      uniqueid: fresher.uniqueid.isNotEmpty ? fresher.uniqueid : uniqueid,
      queueId: fresher.queueId.isNotEmpty ? fresher.queueId : queueId,
      queueName: fresher.queueName.isNotEmpty ? fresher.queueName : queueName,
      phone: fresher.phone.isNotEmpty ? fresher.phone : phone,
      waitSec: fresher.waitSec ?? waitSec,
      lead: fresher.lead ?? lead,
    );
  }
}

class TransferQueue {
  const TransferQueue({required this.id, required this.name, this.readyAgents});

  final String id;
  final String name;
  final int? readyAgents;
}

class CallRecord {
  const CallRecord({
    required this.id,
    required this.inbound,
    this.at,
    this.phone = '',
    this.leadId = '',
    this.queueId = '',
    this.seconds = 0,
    this.result = '',
  });

  final String id;
  final bool inbound;
  final DateTime? at;
  final String phone;
  final String leadId;
  final String queueId;
  final int seconds;
  final String result;

  factory CallRecord.fromJson(Json j, {required bool inbound}) => CallRecord(
    id: inbound ? asStr(j['close_call_id']) : asStr(j['uniqueid']),
    inbound: inbound,
    at: asServerTime(j['call_date']),
    phone: asStr(j['phone_number']),
    leadId: asStr(j['lead_id']),
    queueId: asStr(j['campaign_id']),
    seconds: asInt(j['length_in_sec']),
    result: asStr(j['status']).toUpperCase(),
  );
}

class TodayStats {
  const TodayStats({
    this.calls = 0,
    this.talk = Duration.zero,
    this.paused = Duration.zero,
    this.waiting = Duration.zero,
  });

  final int calls;
  final Duration talk;
  final Duration paused;
  final Duration waiting;

  Duration get average => calls == 0 ? Duration.zero : Duration(seconds: talk.inSeconds ~/ calls);

  factory TodayStats.fromJson(Json j) => TodayStats(
    calls: asInt(j['total_calls']),
    talk: Duration(seconds: asInt(j['talk_sec'])),
    paused: Duration(seconds: asInt(j['pause_sec'])),
    waiting: Duration(seconds: asInt(j['wait_sec'])),
  );
}
