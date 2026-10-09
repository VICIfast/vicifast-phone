import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The brand shown before sign-in. Whitelabel builds pass --dart-define=BRAND_NAME=...
const String kBrandName = String.fromEnvironment('BRAND_NAME', defaultValue: 'VICIfast');

/// Where this app's source code is published (GPLv3 requires offering it to
/// everyone who gets the app). Builds for other brands can point elsewhere.
const String kSourceUrl = String.fromEnvironment('SOURCE_URL', defaultValue: 'https://vicifast.com/open-source/phone');

/// True for the Google Play build (`--flavor play`): updates come from Play,
/// so the app never downloads or installs an APK itself.
bool get isPlayBuild => appFlavor == 'play';

const _gpl =
    'This program is free software: you can redistribute it and/or modify it under the terms of the '
    'GNU General Public License as published by the Free Software Foundation, version 3.\n\n'
    'This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without '
    'even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU '
    'General Public License for more details: https://www.gnu.org/licenses/gpl-3.0.html';

/// Adds the notices Flutter can't find on its own: this app and the native
/// SIP engine. Dart packages register their own licences.
void registerAppLicences() {
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks([
      '$kBrandName Phone',
    ], 'Copyright (C) 2026 VICIfast LLC.\n\n$_gpl\n\nSource code: $kSourceUrl');
    yield const LicenseEntryWithLineBreaks([
      'linphone-sdk',
    ], 'Copyright (C) Belledonne Communications SARL. https://linphone.org\n\n$_gpl');
  });
}
