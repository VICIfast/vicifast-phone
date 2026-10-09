import 'package:intl/intl.dart';

/// 0:07, 4:26, 1:02:09 — for live timers.
String clock(Duration d) {
  final s = d.inSeconds.abs();
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = (s % 60).toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$sec';
  return '$m:$sec';
}

/// 1h 42m, 31m, 45s — for totals.
String span(Duration d) {
  final s = d.inSeconds.abs();
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  if (h > 0) return m == 0 ? '${h}h' : '${h}h ${m}m';
  if (m > 0) return '${m}m';
  return '${s}s';
}

/// North American numbers get (305) 555-0142; everything else stays as dialled.
String phone(String? raw) {
  if (raw == null || raw.isEmpty) return '';
  final digits = raw.replaceAll(RegExp(r'\D'), '');
  final national = digits.length == 11 && digits.startsWith('1') ? digits.substring(1) : digits;
  if (national.length == 10) {
    return '(${national.substring(0, 3)}) ${national.substring(3, 6)}-${national.substring(6)}';
  }
  return raw.trim();
}

String initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
  final letters = parts.take(2).map((p) => p[0].toUpperCase()).join();
  return letters.isEmpty ? '#' : letters;
}

/// 4m 26s, 38s, 1h 2m — for a finished call's length, where 4:26 next to a
/// time of day would be ambiguous.
String talk(Duration d) {
  final s = d.inSeconds.abs();
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  if (h > 0) return m == 0 ? '${h}h' : '${h}h ${m}m';
  if (m > 0) return sec == 0 ? '${m}m' : '${m}m ${sec}s';
  return '${sec}s';
}

/// 10:21 AM, or 10:21 when the phone is set to 24-hour time.
String timeOfDay(DateTime t, {bool h24 = false}) => (h24 ? DateFormat.Hm() : DateFormat.jm()).format(t);

/// The customer's local time from VICIdial's gmt_offset_now (hours, may be fractional).
DateTime? localTimeAt(double? gmtOffsetHours, {DateTime? now}) {
  if (gmtOffsetHours == null) return null;
  final utc = (now ?? DateTime.now()).toUtc();
  return utc.add(Duration(minutes: (gmtOffsetHours * 60).round()));
}
