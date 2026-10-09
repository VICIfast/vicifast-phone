import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../core/errors.dart';
import '../data/models.dart';

class AppUpdate {
  const AppUpdate({required this.version, required this.sizeBytes, this.sha256});

  final String version;
  final int sizeBytes;

  /// Hex SHA-256 of the APK file, when the release manifest carries one.
  final String? sha256;
}

class UpdateNeedsPermission implements Exception {
  const UpdateNeedsPermission();
}

/// Android sideload updates from the release manifest. iOS updates through the App Store.
class Updater {
  Updater({required this.base, required this.installed, http.Client? client}) : _http = client ?? http.Client();

  final String base;
  final String installed;
  final http.Client _http;
  static const _app = MethodChannel('io.vicifast.phone/app');

  Future<AppUpdate?> check() async {
    if (!Platform.isAndroid) return null;
    final res = await _http.get(Uri.parse('$base/api/releases/android')).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final Object? body;
    try {
      body = jsonDecode(res.body);
    } catch (_) {
      return null;
    }
    final current = body is Map<String, dynamic> ? body['current'] : null;
    if (current is! Map<String, dynamic>) return null;
    final version = asStr(current['version']);
    final size = asInt(current['sizeBytes']);
    if (version.isEmpty || size <= 0 || !isNewer(version, installed)) return null;
    final sha = asStr(current['apkSha256']).toLowerCase();
    return AppUpdate(version: version, sizeBytes: size, sha256: RegExp(r'^[0-9a-f]{64}$').hasMatch(sha) ? sha : null);
  }

  /// Downloads, verifies, and opens Android's installer. [onProgress] gets 0..1.
  Future<void> install(AppUpdate u, void Function(double) onProgress) async {
    final allowed = await _app.invokeMethod<bool>('canInstallApks') ?? false;
    if (!allowed) {
      await _app.invokeMethod<void>('openInstallSettings');
      throw const UpdateNeedsPermission();
    }
    final dirs = await getExternalCacheDirectories();
    final dir = (dirs == null || dirs.isEmpty) ? await getTemporaryDirectory() : dirs.first;
    final file = File('${dir.path}/vicifast-${u.version}.apk');
    final res = await _http
        .send(http.Request('GET', Uri.parse('$base/api/downloads/android')))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw AppError(AppErrorCode.unknown, status: res.statusCode, detail: 'download');
    final sink = file.openWrite();
    final digest = _DigestSink();
    final hashInput = sha256.startChunkedConversion(digest);
    var received = 0;
    try {
      await for (final chunk in res.stream.timeout(const Duration(seconds: 30))) {
        sink.add(chunk);
        hashInput.add(chunk);
        received += chunk.length;
        onProgress((received / u.sizeBytes).clamp(0, 1).toDouble());
      }
    } finally {
      await sink.close();
      hashInput.close();
    }
    final badSize = received != u.sizeBytes;
    final badHash = u.sha256 != null && digest.value?.toString() != u.sha256;
    if (badSize || badHash) {
      await file.delete();
      throw AppError(AppErrorCode.unknown, detail: badSize ? 'size mismatch' : 'checksum mismatch');
    }
    await _app.invokeMethod<void>('installApk', {'path': file.path});
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// True when [a] (X.Y.Z, build suffix ignored) is newer than [b].
bool isNewer(String a, String b) {
  List<int> parts(String v) => v.split(RegExp(r'[+-]')).first.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  final x = parts(a);
  final y = parts(b);
  for (var i = 0; i < 3; i++) {
    final xi = i < x.length ? x[i] : 0;
    final yi = i < y.length ? y[i] : 0;
    if (xi != yi) return xi > yi;
  }
  return false;
}
