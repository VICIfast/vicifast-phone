# VICIfast Phone

The agent phone for VICIdial call centers on [VICIfast](https://vicifast.com).
Agents sign in with their company code, pick a campaign and queues, and take
inbound calls on Android or iPhone, with the lock screen ringing like a
normal phone call.

It is deliberately small: go ready or pause with a reason, answer, mute,
hold, keypad, transfer to a queue or a number, then pick a result (with
callbacks in the customer's local time). It is not a full replacement for
VICIdial's agent screen.

## Licence

This app is free software under the **GNU General Public License, version 3**
(see [LICENSE](LICENSE)). It is built on
[linphone-sdk](https://linphone.org) by Belledonne Communications, also
GPLv3. Every release's source is tagged in this repository as `v<version>`;
the app's **Me → Source code** row links here.

The VICIfast platform the app talks to is a separate service and is not part
of this repository.

## How it fits together

```
Flutter (Dart): screens, agent state, VICIfast API
        │  platform channels (io.vicifast.phone/sip, /sip_events, /app)
        ├── Android (Kotlin): LinphoneManager, SipConnectionService (Telecom),
        │                     SipForegroundService, VoipFcmService
        └── iOS (Swift):      LinphoneManager, CallKitManager, PushKitManager
```

- `lib/domain/presence.dart`: the agent's state (paused, ready, ringing, on a
  call, wrap-up) as one immutable value with tested transitions.
- `lib/state/`: Riverpod controllers for the session, the phone line and the
  agent.
- `lib/data/agent_api.dart`: the VICIfast mobile API (`/api/mobile/*`).
- `lib/features/`: one file per screen; `lib/ui/` holds the theme and the
  shared Android/iPhone widgets.

## Building

Requires Flutter 3.35 or newer (developed on 3.47) and, for Android, JDK 21
and Android SDK 36.

```sh
flutter pub get

# Direct download: updates itself from vicifast.com
flutter build apk --release --flavor direct

# Google Play: no self-updater, no install-packages permission
flutter build appbundle --release --flavor play
```

Android needs `android/app/google-services.json` from your own Firebase
project for push wake-ups. iOS needs a Mac with Xcode, CocoaPods and a VoIP
push certificate or key.

Build-time options (`--dart-define=NAME=value`):

| Name         | Default                                  | Purpose                          |
| ------------ | ---------------------------------------- | -------------------------------- |
| `API_BASE`   | `https://vicifast.com`                   | The platform the app signs in to |
| `BRAND_NAME` | `VICIfast`                               | Name shown in the app            |
| `SOURCE_URL` | `https://vicifast.com/open-source/phone` | Where Me → Source code points    |

## Tests

```sh
flutter analyze
flutter test test/domain test/data test/state
# Screenshots of every screen, Android and iPhone, light and dark, into test/goldens/out
GOLDENS=1 flutter test test/goldens --update-goldens
```

## Publishing a release's source

From the platform repository, after tagging a release:

```sh
apps/mobile/tool/export-source.sh <release-ref> <clone-of-this-repo>
```

It copies only this app's files at that ref, refuses anything that looks like
a key or credential file, commits, and tags `v<version>`. It never pushes.
