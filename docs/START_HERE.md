# PrivateGet PG — start the REAL app on two Android phones

**9 November 2026 — networked alpha, not a secure production release.**

## Files
- `mobile/lib/main.dart` — actual Flutter mobile code (not an HTML mockup).
- `server/server.mjs` — real temporary invitations and ciphertext relay.
- `server/test.mjs` — two-client network and cryptography test.
- `.github/workflows/android-debug.yml` — on-demand Android APK builder.
- `.github/workflows/server-tests.yml` — test on push / PR.

## Path 1: Build an Android APK using GitHub Actions

1. Create a **private** repository in your own GitHub account, e.g. `privateget-pg`.
2. Upload/push the **contents** of this source ZIP (keep the `.github` folder). Using a laptop, one reproducible route is:
   ```bash
   unzip PrivateGet_PG_Real_App_Source_v0.2.zip -d privateget-pg
   cd privateget-pg
   git init -b main
   git add .
   git commit -m "PrivateGet networked alpha source"
   git remote add origin https://github.com/YOUR_USERNAME/privateget-pg.git
   git push -u origin main
   ```
   Replace `YOUR_USERNAME`; authenticate via GitHub credentials, not by sending a token in chat.
3. In GitHub choose **Actions → Build PG Android alpha APK → Run workflow**.
4. Enter the API URL at compile time, such as `http://192.168.1.20:8787` **for a private Wi-Fi lab only**, where that IP is your server computer's actual LAN IP. The URL is embedded in the APK. **Do not point it to a public HTTP endpoint.**
5. Download the completed **privateget-pg-alpha-android-apk** Actions artifact and extract the `app-debug.apk` to install on both test phones. Android may ask you to permit installing from your selected source.
6. Without a reachable server at the compiled URL, the app will correctly show **Cannot connect**; an APK is not a hosted chat service.

The workflow is source-only and was not executed in the authoring environment. It may need adjustment after its first real Flutter build.

## Path 2: Run from a computer with Flutter

1. Install Node.js 22+, Flutter SDK, and Android Studio with Android SDK.
2. Connect computer and both Android test phones to a private trusted Wi-Fi network.
3. In the terminal:
   ```bash
   cd privateget-pg/server
   node test.mjs   # automated two-client test
   node server.mjs # leave running; listens on TCP 8787
   ```
4. In a second terminal at the repo root, run:
   ```bash
   bash scripts/prepare-mobile.sh
   cd mobile
   flutter devices
   flutter run --dart-define=PG_API_URL=http://YOUR_COMPUTER_LAN_IP:8787
   ```
5. Run the same app on the second test device (or install the built APK on both phones).
6. On A tap **Create invitation**; copy its one-time code to B. On B paste **Accept invitation**. A taps **Approve**. Both verify they see matching safety codes **over an independent trusted channel**. Test messages in both directions and **End session**.

## What is still missing
- **No actual APK was produced in this environment.** Flutter/Android toolchains are absent.
- Deep links are not yet configured: invitation is a one-time *code* in this alpha, not an automatic tap-to-open invite URL.
- No public server, HTTPS certificate, server persistence, or app store distribution.
- **No audited E2EE protocol** or production security guarantee; development plaintext can leak from device memory/clipboard, and HTTP exposes bearer tokens to local network observers.
- No server-side capability to read ciphertext *by design*, but active server key substitution is currently possible; safety-code comparison is essential.

Read `docs/SECURITY.md` before conducting any trials. **Never use this alpha for sensitive conversations.**
