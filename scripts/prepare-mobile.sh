#!/usr/bin/env bash
# Run from repository root after installing Flutter SDK, Android/iOS build tools.
set -euo pipefail
cd "$(dirname "$0")/../mobile"
if ! command -v flutter >/dev/null; then echo 'Flutter SDK not found. Install from https://docs.flutter.dev/install'; exit 1; fi
# Create native Android/iOS projects, keeping our existing Flutter app source.
flutter create --project-name privateget_pg --org com.privateget --platforms android,ios .
# Debug-only cleartext HTTP permission for LAN testing. Production MUST use HTTPS.
mkdir -p android/app/src/debug
cat > android/app/src/debug/AndroidManifest.xml <<'MANIFEST'
<manifest xmlns:android="http://schemas.android.com/apk/res/android" xmlns:tools="http://schemas.android.com/tools">
  <uses-permission android:name="android.permission.INTERNET"/>
  <application android:usesCleartextTraffic="true" tools:replace="android:usesCleartextTraffic"/>
</manifest>
MANIFEST
flutter pub get
flutter analyze
printf '\nMobile sources and native platform scaffold prepared.\n'
printf 'For a real phone, use: flutter run --dart-define=PG_API_URL=http://YOUR_LAN_IP:8787\n'
