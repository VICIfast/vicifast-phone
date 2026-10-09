import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'app/app.dart';
import 'app/brand.dart';
import 'data/agent_api.dart';
import 'data/store.dart';
import 'state/services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerAppLicences();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  final info = await PackageInfo.fromPlatform();
  final store = Store();
  final api = AgentApi(store: store, appVersion: info.version);
  runApp(
    ProviderScope(
      // Failures are shown to the agent with a retry; no silent background retries.
      retry: (_, _) => null,
      overrides: [
        storeProvider.overrideWithValue(store),
        apiProvider.overrideWithValue(api),
        appVersionProvider.overrideWithValue(info.version),
      ],
      child: const AgentApp(),
    ),
  );
}
