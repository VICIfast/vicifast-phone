import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

enum SetupItem { microphone, notifications, lockScreenCalls, battery }

class SetupStatus {
  const SetupStatus(this.granted);

  final Map<SetupItem, bool> granted;

  bool isOn(SetupItem item) => granted[item] ?? true;

  /// Items that apply on this platform, in display order.
  List<SetupItem> get items => granted.keys.toList(growable: false);

  int get missing => granted.values.where((v) => !v).length;
  bool get ready => missing == 0;
}

/// Everything that stops a call from ringing. iOS needs only the microphone and
/// notifications; the lock screen is CallKit's job there.
class PhoneSetupService {
  static const _app = MethodChannel('io.vicifast.phone/app');

  Future<SetupStatus> check() async {
    final status = <SetupItem, bool>{
      SetupItem.microphone: await Permission.microphone.isGranted,
      SetupItem.notifications: await Permission.notification.isGranted,
    };
    if (Platform.isAndroid) {
      status[SetupItem.lockScreenCalls] = await _bool('canUseFullScreenIntent', fallback: true);
      status[SetupItem.battery] = await _bool('isIgnoringBatteryOptimizations', fallback: false);
    }
    return SetupStatus(status);
  }

  Future<void> request(SetupItem item) async {
    switch (item) {
      case SetupItem.microphone:
        final r = await Permission.microphone.request();
        if (r.isPermanentlyDenied) await openAppSettings();
      case SetupItem.notifications:
        final r = await Permission.notification.request();
        if (r.isPermanentlyDenied) await openAppSettings();
      case SetupItem.lockScreenCalls:
        await _app.invokeMethod<void>('requestFullScreenIntentPermission');
      case SetupItem.battery:
        await _app.invokeMethod<void>('requestIgnoreBatteryOptimizations');
    }
  }

  /// Puts the app in the background instead of closing it, so the phone line
  /// stays registered when the agent presses back on Home.
  Future<void> moveToBackground() async {
    if (!Platform.isAndroid) return;
    try {
      await _app.invokeMethod<void>('moveToBackground');
    } on PlatformException {
      return;
    }
  }

  Future<bool> _bool(String method, {required bool fallback}) async {
    try {
      return await _app.invokeMethod<bool>(method) ?? fallback;
    } on PlatformException {
      return fallback;
    } on MissingPluginException {
      return fallback;
    }
  }
}
