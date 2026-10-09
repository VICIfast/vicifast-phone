/// Names mirror liblinphone's RegistrationState / Call.State so the strings
/// cross the platform channel without a translation table.
library;

enum RegState {
  none,
  progress,
  ok,
  cleared,
  failed;

  static RegState parse(String? raw) => switch (raw?.toLowerCase()) {
    'progress' => RegState.progress,
    // Refreshing keeps the existing binding valid; treating it as down
    // flashed the line offline on every periodic REGISTER.
    'refreshing' || 'ok' => RegState.ok,
    'cleared' => RegState.cleared,
    'failed' => RegState.failed,
    _ => RegState.none,
  };

  bool get isUp => this == RegState.ok;
}

enum CallState {
  idle,
  outgoing,
  incoming,
  connected,
  paused,
  ended,
  error,

  /// Any state the app doesn't act on. It neither starts nor ends a call.
  other;

  static CallState parse(String? raw) => switch (raw?.toLowerCase()) {
    'outgoinginit' || 'outgoingprogress' || 'outgoingringing' || 'outgoingearlymedia' => CallState.outgoing,
    'incomingreceived' || 'incomingearlymedia' => CallState.incoming,
    'connected' || 'streamsrunning' || 'updating' || 'updatedbyremote' => CallState.connected,
    // Resuming is on the way back from hold; it must not read as "no call".
    'paused' || 'pausing' || 'pausedbyremote' || 'resuming' => CallState.paused,
    'end' || 'released' => CallState.ended,
    'error' => CallState.error,
    'idle' => CallState.idle,
    _ => CallState.other,
  };

  bool get isLive => this == CallState.connected || this == CallState.paused;
  bool get isOver => this == CallState.ended || this == CallState.error;
}

class SipCall {
  const SipCall({
    required this.callId,
    required this.remoteUri,
    required this.remoteDisplay,
    required this.incoming,
    required this.state,
  });

  final String? callId;
  final String? remoteUri;
  final String? remoteDisplay;
  final bool incoming;
  final CallState state;

  factory SipCall.fromMap(Map<dynamic, dynamic> m) => SipCall(
    callId: m['callId'] as String?,
    remoteUri: m['remoteUri'] as String?,
    remoteDisplay: m['remoteDisplay'] as String?,
    incoming: (m['direction'] as String?) == 'incoming',
    state: CallState.parse(m['state'] as String?),
  );

  SipCall withState(CallState s) =>
      SipCall(callId: callId, remoteUri: remoteUri, remoteDisplay: remoteDisplay, incoming: incoming, state: s);

  /// The customer's number as far as the INVITE tells us. VICIdial puts tracking
  /// labels in the display name (Y0123…, RINGAGENT…, `RA_<user>_<phone>`), so the
  /// display name is used only when it carries the number itself.
  String get phoneHint {
    final disp = remoteDisplay ?? '';
    final ra = RegExp(r'^RA_[^_]+_(\d{6,})$').firstMatch(disp);
    if (ra != null) return ra.group(1)!;
    final ring = RegExp(r'^RINGAGENT_(\d{6,})$').firstMatch(disp);
    if (ring != null) return ring.group(1)!;
    final user = sipUserPart(remoteUri) ?? '';
    if (RegExp(r'^\+?\d{6,}$').hasMatch(user)) return user;
    if (RegExp(r'^\+?\d{6,}$').hasMatch(disp)) return disp;
    return '';
  }
}

class SipAccount {
  const SipAccount({
    required this.username,
    required this.password,
    required this.domain,
    this.transport = 'udp',
    this.port,
    this.displayName,
  });

  final String username;
  final String password;
  final String domain;
  final String transport;
  final int? port;
  final String? displayName;

  Map<String, dynamic> toJson() => {
    'username': username,
    'password': password,
    'domain': domain,
    'transport': transport,
    if (port != null) 'port': port,
    if (displayName != null) 'display': displayName,
  };
}

String? sipUserPart(String? uri) {
  if (uri == null || uri.isEmpty) return null;
  var s = uri.trim();
  if (s.startsWith('sips:')) {
    s = s.substring(5);
  } else if (s.startsWith('sip:')) {
    s = s.substring(4);
  }
  final at = s.indexOf('@');
  if (at != -1) s = s.substring(0, at);
  final semi = s.indexOf(';');
  if (semi != -1) s = s.substring(0, semi);
  return s;
}
