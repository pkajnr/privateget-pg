# PrivateGet (PG) — actual networked mobile app ALPHA

**Version 0.3 (GitHub Actions analyzer fix):** A PG-specific Flutter test and `flutter_test` dependency replace the generated counter app test. The mobile build has not yet been verified.\n\n**Status as of 9 November 2026:** Real server source, real Flutter mobile source, tested two-client networked encryption-relay flow. See [start instructions](docs/START_HERE.md). **Not yet a compiled APK, publicly hosted service, or production-secure messenger.**

> ⚠️ **NOT FOR SENSITIVE MESSAGES.** This build uses standard X25519, HKDF-SHA256 and AES-256-GCM primitives, but the *protocol is experimental, not independently audited and does not implement Double Ratchet or Signal*. The server can substitute public keys; users must compare matching safety codes on both phones. Dev HTTP leaks authentication tokens and metadata to the network. Use only on an isolated, trusted development network.

## What's real (not a UI simulation)

- Two different Flutter mobile app installations contact one running Node.js server.
- Each installation registers a temporary anonymous device identity on the server.
- Party A creates a single-use, 10-minute invitation code and shares it with Party B (copy/paste for alpha).
- Party B accepts; Party A approves; the two independently generate X25519 keys and derive directional AES-256-GCM keys by HKDF-SHA256.
- The server only accepts `{iv,ciphertext,mac}` envelopes, delivers ciphertext to the intended recipient, and removes delivered messages from its short-lived queue.
- The recipient decrypts locally. The visible safety code should be the same on both devices and should be verified through another channel.
- Either participant can end the session; server drops the queue; apps discard in-memory session state when they detect termination.

## What is NOT in this alpha

- No phone-installable APK included (Flutter SDK and Android SDK are not available in the authoring environment).
- No production backend deployment, public URL, universal-link association, app store listing, or signing credentials.
- The invite is presently a secure **copy/paste code**, not a tappable universal link.
- No user identity durability across relaunch, persistent mailbox, push notifications, offline delivery, group calls, file sharing or multi-device sync.
- No formal security review, Double Ratchet, key continuity protection, replay-proof message protocol, anti-abuse hardening, production rate-limiting or external penetration test.
- No guarantee that app memory, OS snapshots, screenshots, system clipboards, or compromised recipient devices retain no traces.
- The in-memory backend loses all accounts, invites and sessions when restarted. This is a deliberate alpha limitation, not a production storage design.

## Run the real backend (Node.js 22+; no npm install)

```bash
cd server
node server.mjs
# health check from the same computer:
curl http://localhost:8787/health
# test the live flow with two real cryptographic clients:
node test.mjs  # 23 automated API and cryptography checks
```

The backend listens on port 8787 of your computer. **Do not port-forward this HTTP server to the public internet.** For mobile phones on the same trusted Wi-Fi, find the computer's LAN IPv4 address (e.g. `192.168.1.20`). Ensure the firewall permits connections to TCP 8787.

## Build and run the ACTUAL Flutter app on two phones

You need a computer with Flutter SDK and Android Studio / Android SDK, and two Android devices connected by USB or configured for wireless debugging. For iOS you need macOS + Xcode and Apple signing. Flutter install: https://docs.flutter.dev/install

```bash
# Run at repository root ON YOUR COMPUTER:
bash scripts/prepare-mobile.sh
cd mobile
flutter devices
flutter run --dart-define=PG_API_URL=http://192.168.1.20:8787
# Run the same command for the second phone in another terminal
```

Replace `192.168.1.20` with your computer's **actual** Wi-Fi LAN IPv4. If using an Android emulator on the same machine, the URL can instead be `http://10.0.2.2:8787`.

**Android APK for local installation:**

```bash
cd mobile
flutter build apk --debug --dart-define=PG_API_URL=http://192.168.1.20:8787
# file: mobile/build/app/outputs/flutter-apk/app-debug.apk
```

**GitHub Actions alternative:** Push this project to a private GitHub repository. Go to **Actions → Build PG Android alpha APK → Run workflow**, provide the backend URL and download the APK artifact after the workflow succeeds. This workflow has not been executed here; its generated Android scaffold and Flutter build require validation on GitHub.

## How to test on two phones

1. Start `node server.mjs` on a computer accessible to both phones.
2. Install/run the Flutter app on **Phone A** and **Phone B** pointing to the same backend address.
3. On Phone A tap **Create invitation**; copy the long code and send it to Phone B through an existing channel.
4. On Phone B paste the code and tap **Accept invitation**.
5. On A, verify the intended recipient accepted and tap **Approve this connection**.
6. Compare the **safety code** displayed on both devices. If it differs, stop.
7. Send messages from A and B; they travel through the real backend, encrypted as ciphertext.
8. Tap **End session**; both apps erase their in-memory chat state. An offline peer might not receive the end instruction until reconnecting.

## Repo layout

```
server/server.mjs         actual API and encrypted delivery relay (Node built-ins)
server/test.mjs           automated two-client API + cryptography integration test
mobile/lib/main.dart     Flutter mobile app with real network requests + encryption
mobile/pubspec.yaml      Flutter dependencies
scripts/prepare-mobile.sh  native project scaffolding + debug HTTP lab setting
.github/workflows/android-debug.yml  optional GitHub Actions APK builder
docs/SECURITY.md         threat model, limits and production blockers
```

## Security caution

The code demonstrates **two actual communicating clients**, not a finished secure product. It MUST NOT be deployed for confidential, critical or production traffic. For production, adopt an externally vetted E2EE protocol/implementation, HTTPS/WSS, authenticated key binding, device trust and replay handling, platform secure storage/backup exclusions, signed builds, abuse protections, and independent mobile/server reviews.

PG source code is yours to maintain and deploy, subject to the dependency licenses. No proprietary vendor platform is required for this alpha.
