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
flutter create --project-name privateget_pg --org com.privateget --platforms android,ios .

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
}
PG_TEST

# Debug-only cleartext HTTP permission for a local/LAN lab.
# DO NOT enable cleartext in release; use HTTPS and audited E2EE for real users.
mkdir -p android/app/src/debug
cat > android/app/src/debug/AndroidManifest.xml <<'MANIFEST'
<manifest xmlns:android="http://schemas.android.com/apk/res/android" xmlns:tools="http://schemas.android.com/tools">
  <uses-permission android:name="android.permission.INTERNET"/>
  <application android:usesCleartextTraffic="true" tools:replace="android:usesCleartextTraffic"/>
</manifest>
MANIFEST

flutter pub get
printf '\nChecking PG Flutter tests...\n'
flutter test test/widget_test.dart
printf '\nChecking PG Flutter analyzer...\n'
flutter analyze
printf '\nPG Flutter setup, tests and analysis completed.\n'
printf 'Build next: flutter build apk --debug --dart-define=PG_API_URL=http://YOUR_SERVER:8787\n'
