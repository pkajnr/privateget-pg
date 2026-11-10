#!/usr/bin/env bash
# PrivateGet PG alpha: idempotent Flutter/Android preparation.
# Run from the repository root: bash scripts/prepare-mobile.sh
set -euo pipefail
cd "$(dirname "$0")/../mobile"

if ! command -v flutter >/dev/null 2>&1; then
  echo 'Flutter SDK not found. See https://docs.flutter.dev/install' >&2
  exit 1
fi

if [ ! -f lib/main.dart ]; then
  echo 'ERROR: mobile/lib/main.dart is missing. Did you upload all PG files?' >&2
  exit 1
fi

# Flutter creates its sample counter-app test when a project has no test file.
# That sample imports flutter_test and refers to MyApp, which is not our app.
# Generate native platform scaffolding, then deliberately replace the test.
flutter create --project-name privateget_pg --org com.privateget --platforms android,ios --no-pub .

# Make this safe even if GitHub still contains the original v0.2 pubspec.yaml.
# Flutter's testing library is provided by the Flutter SDK, not pub.dev.
if ! grep -Eq '^[[:space:]]*flutter_test[[:space:]]*:' pubspec.yaml; then
  if grep -Eq '^dev_dependencies[[:space:]]*:' pubspec.yaml; then
    sed -i '/^dev_dependencies[[:space:]]*:/a\  flutter_test:\n    sdk: flutter' pubspec.yaml
  else
    cat >> pubspec.yaml <<'DEPS'

dev_dependencies:
  flutter_test:
    sdk: flutter
DEPS
  fi
fi

mkdir -p test
cat > test/widget_test.dart <<'PG_TEST'
// PG-specific tests, not Flutter's generated MyApp counter example.
import 'package:flutter_test/flutter_test.dart';
import 'package:privateget_pg/main.dart';

void main() {
  test('PG message model preserves message text and direction', () {
    final outgoing = PgMessage('Hello PG', true);
    final incoming = PgMessage('Received', false);
    expect(outgoing.text, 'Hello PG');
    expect(outgoing.mine, isTrue);
    expect(incoming.text, 'Received');
    expect(incoming.mine, isFalse);
  });

  test('PG API errors contain a readable message', () {
    expect(ApiException('Invitation expired').toString(), 'Invitation expired');
  });

  test('Parallel chats keep messages and invitations isolated', () {
    final first = PgConversation(1)
      ..inviteId = 'first-invite'
      ..messages.add(PgMessage('Message for first chat', true));
    final second = PgConversation(2)
      ..inviteId = 'second-invite'
      ..messages.add(PgMessage('Message for second chat', false));

    expect(first.inviteId, isNot(second.inviteId));
    expect(first.messages.single.text, 'Message for first chat');
    expect(second.messages.single.text, 'Message for second chat');
    first.clearSensitive();
    expect(first.messages, isEmpty);
    expect(second.messages.single.text, 'Message for second chat');
    second.clearSensitive();
  });

  test('Chat labels stay local, allow user names and clear on end', () {
    final suitor = PgConversation(1)..rename('  Suitor  ');
    final kwame = PgConversation(2)..rename('KwameP');
    expect(suitor.title, 'Suitor');
    expect(suitor.initials, 'SU');
    expect(kwame.title, 'KwameP');
    expect(kwame.initials, 'KW');
    suitor.rename('Kwame P');
    expect(suitor.initials, 'KP');
    suitor.clearSensitive();
    expect(suitor.nickname, isNull);
    expect(suitor.unreadCount, 0);
    kwame.clearSensitive();
  });

  test('Unread counters are separate per session and reset on view', () {
    final suitor = PgConversation(1)..page = 'chat';
    final kwame = PgConversation(2)..page = 'chat';
    suitor.receive([
      PgMessage('first', false), PgMessage('second', false),
    ], visible: false);
    kwame.receive([PgMessage('hello', false)], visible: false);
    expect(suitor.unreadCount, 2);
    expect(kwame.unreadCount, 1);
    suitor.markRead();
    expect(suitor.unreadCount, 0);
    expect(kwame.unreadCount, 1);
    suitor.receive([PgMessage('read while open', false)], visible: true);
    expect(suitor.unreadCount, 0);
    expect(suitor.messages.length, 3);
    suitor.clearSensitive();
    kwame.clearSensitive();
    expect(kwame.messages, isEmpty);
  });
}
PG_TEST

# Add only the permissions needed for camera/photos and experimental calls.
# flutter create may recreate these files, so patch the generated platform apps.
python3 - <<'PY'
from pathlib import Path
manifest = Path('android/app/src/main/AndroidManifest.xml')
xml = manifest.read_text()
permissions = [
    ('android.permission.INTERNET','<uses-permission android:name="android.permission.INTERNET"/>'),
    ('android.permission.POST_NOTIFICATIONS','<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>'),
    ('android.permission.CAMERA','<uses-permission android:name="android.permission.CAMERA"/>'),
    ('android.permission.RECORD_AUDIO','<uses-permission android:name="android.permission.RECORD_AUDIO"/>'),
    ('android.permission.MODIFY_AUDIO_SETTINGS','<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS"/>'),
    ('android.permission.ACCESS_NETWORK_STATE','<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>'),
    ('android.permission.CHANGE_NETWORK_STATE','<uses-permission android:name="android.permission.CHANGE_NETWORK_STATE"/>'),
]
for name, tag in permissions:
    if name not in xml:
        xml = xml.replace('<application', tag + '\n    <application', 1)
if 'android.hardware.camera' not in xml:
    xml = xml.replace('<application',
      '<uses-feature android:name="android.hardware.camera" android:required="false"/>\n    <application', 1)
manifest.write_text(xml)

ios_plist = Path('ios/Runner/Info.plist')
if ios_plist.exists():
    plist = ios_plist.read_text()
    usage = {
        'NSCameraUsageDescription':'PG uses the camera only when you take a photo or start a video call.',
        'NSMicrophoneUsageDescription':'PG uses the microphone only during an accepted voice or video call.',
        'NSPhotoLibraryUsageDescription':'PG accesses photos that you explicitly choose to share.',
    }
    for key, value in usage.items():
        if '<key>' + key + '</key>' not in plist:
            plist = plist.replace('</dict>',
                '    <key>' + key + '</key>\n    <string>' + value + '</string>\n</dict>', 1)
    ios_plist.write_text(plist)
PY

# Flutter regenerates MainActivity on each CI build. Keep our native notification
# bridge in version control and install it after native scaffold generation.
test -f native/MainActivity.kt
install -D native/MainActivity.kt \
  android/app/src/main/kotlin/com/privateget/privateget_pg/MainActivity.kt

# Debug-only cleartext HTTP permission for a local/LAN lab.
# DO NOT enable cleartext in release; use HTTPS and audited E2EE for real users.
mkdir -p android/app/src/debug
cat > android/app/src/debug/AndroidManifest.xml <<'MANIFEST'
<manifest xmlns:android="http://schemas.android.com/apk/res/android" xmlns:tools="http://schemas.android.com/tools">
  <uses-permission android:name="android.permission.INTERNET"/>
  <application android:usesCleartextTraffic="true" tools:replace="android:usesCleartextTraffic"/>
</manifest>
MANIFEST

# Render committed PG brand vector as platform launcher PNGs.
# Use a local isolated Python environment only when CairoSVG is unavailable.
if python3 -c 'import cairosvg' >/dev/null 2>&1; then
  python3 branding/render_launcher.py
else
  python3 -m venv .pg-icon-venv
  .pg-icon-venv/bin/python -m pip install --disable-pip-version-check --quiet 'cairosvg==2.8.2'
  .pg-icon-venv/bin/python branding/render_launcher.py
fi

flutter pub get
printf '\nChecking PG Flutter tests...\n'
flutter test
printf '\nChecking PG Flutter analyzer...\n'
flutter analyze
printf '\nPG Flutter setup, tests and analysis completed.\n'
printf 'Build next: flutter build apk --debug --dart-define=PG_API_URL=http://YOUR_SERVER:8787\n'
