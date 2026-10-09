import 'dart:convert';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import 'models.dart';

/// Everything the app keeps on the phone. Secrets and settings share one
/// keychain-backed store that stays on this device (not in backups).
class Store {
  Store([FlutterSecureStorage? storage])
    : _s =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
          );

  final FlutterSecureStorage _s;
  String? _deviceId;

  static const _session = 'v2.session';
  static const _remembered = 'v2.remembered';
  static const _theme = 'v2.theme';
  static const _device = 'device_id_v1';
  static const _wrapUp = 'v2.pending_wrapup';
  static const _recent = 'v2.recent_results';

  Future<Session?> loadSession() async => Session.fromJson(await _readJson(_session));

  Future<void> saveSession(Session s) => _write(_session, jsonEncode(s.toJson()));

  Future<void> clearSession() async {
    try {
      await _s.delete(key: _session);
    } catch (_) {
      return;
    }
  }

  /// Company code and username, so after the first day agents type only a password.
  Future<({String slug, String user})?> loadRemembered() async {
    final j = await _readJson(_remembered);
    if (j == null) return null;
    final slug = asStr(j['slug']);
    final user = asStr(j['user']);
    return slug.isEmpty ? null : (slug: slug, user: user);
  }

  Future<void> saveRemembered(String slug, String user) =>
      _write(_remembered, jsonEncode({'slug': slug, 'user': user}));

  Future<void> forgetRemembered() async {
    try {
      await _s.delete(key: _remembered);
    } catch (_) {
      return;
    }
  }

  Future<ThemeMode> loadTheme() async {
    final v = await _read(_theme);
    return ThemeMode.values.firstWhere((m) => m.name == v, orElse: () => ThemeMode.system);
  }

  Future<void> saveTheme(ThemeMode m) => _write(_theme, m.name);

  /// The call waiting for a result, so a restart mid-wrap-up returns to it.
  Future<PendingWrapUp?> loadPendingWrapUp() async {
    final j = await _readJson(_wrapUp);
    final at = DateTime.tryParse(asStr(j?['at']));
    final call = j?['call'];
    if (j == null || at == null || call is! Map<String, dynamic>) return null;
    return PendingWrapUp(
      at: at,
      call: call,
      callStart: DateTime.tryParse(asStr(j['callStart'])),
      hungUpBy: j['hungUpBy'] as String?,
      pauseAfterCall: j['pauseAfterCall'] == true,
      nextPauseCode: j['nextPauseCode'] as String?,
      nextPauseLabel: j['nextPauseLabel'] as String?,
    );
  }

  Future<void> savePendingWrapUp(PendingWrapUp w) => _write(
    _wrapUp,
    jsonEncode({
      'at': w.at.toIso8601String(),
      'call': w.call,
      'callStart': w.callStart?.toIso8601String(),
      'hungUpBy': w.hungUpBy,
      'pauseAfterCall': w.pauseAfterCall,
      'nextPauseCode': w.nextPauseCode,
      'nextPauseLabel': w.nextPauseLabel,
    }),
  );

  Future<void> clearPendingWrapUp() async {
    try {
      await _s.delete(key: _wrapUp);
    } catch (_) {
      return;
    }
  }

  /// The agent's last few results per campaign, newest first.
  Future<List<String>> recentResults(String campaignId) async {
    final j = await _readJson(_recent);
    final list = j?[campaignId];
    return list is List ? list.map((e) => e.toString()).toList() : const [];
  }

  Future<void> rememberResult(String campaignId, String code) async {
    final j = await _readJson(_recent) ?? <String, dynamic>{};
    final list = (j[campaignId] is List ? (j[campaignId] as List).map((e) => e.toString()) : const <String>[])
        .where((c) => c != code)
        .toList();
    j[campaignId] = [code, ...list].take(3).toList();
    await _write(_recent, jsonEncode(j));
  }

  /// A per-install ID the server uses to tell this phone from the agent's other devices.
  /// The key name is shared with the previous app version so an upgrade keeps it.
  Future<String> deviceId() async {
    if (_deviceId != null) return _deviceId!;
    final stored = await _read(_device);
    if (stored != null && stored.isNotEmpty) return _deviceId = stored;
    final fresh = const Uuid().v4();
    await _write(_device, fresh);
    return _deviceId = fresh;
  }

  Future<String?> _read(String key) async {
    try {
      return await _s.read(key: key);
    } catch (_) {
      return null;
    }
  }

  Future<Json?> _readJson(String key) async {
    final raw = await _read(key);
    if (raw == null) return null;
    try {
      final v = jsonDecode(raw);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(String key, String value) async {
    try {
      await _s.write(key: key, value: value);
    } catch (_) {
      return;
    }
  }
}

class PendingWrapUp {
  const PendingWrapUp({
    required this.at,
    required this.call,
    this.callStart,
    this.hungUpBy,
    this.pauseAfterCall = false,
    this.nextPauseCode,
    this.nextPauseLabel,
  });

  final DateTime at;
  final Json call;
  final DateTime? callStart;
  final String? hungUpBy;
  final bool pauseAfterCall;
  final String? nextPauseCode;
  final String? nextPauseLabel;
}
