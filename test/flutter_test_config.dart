import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Loads real fonts so golden images show readable text instead of boxes.
/// San Francisco can't be redistributed, so iOS goldens use Roboto in its place.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      loader.addFont(Future.value(ByteData.sublistView(File('test/fonts/$f').readAsBytesSync())));
    }
    await loader.load();
  }

  const roboto = ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf'];
  for (final family in [
    'Roboto',
    'CupertinoSystemText',
    'CupertinoSystemDisplay',
    '.AppleSystemUIFont',
    '.SF UI Text',
    '.SF UI Display',
    '.SF Pro Text',
    '.SF Pro Display',
    'monospace',
  ]) {
    await load(family, roboto);
  }
  await load('MaterialIcons', ['MaterialIcons-Regular.otf']);
  await load('packages/cupertino_icons/CupertinoIcons', ['CupertinoIcons.ttf']);
  await testMain();
}
