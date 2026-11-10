# PG 0.11 — Optional device PIN, password, face or fingerprint app lock

## User feature
- Open PG → three-dot menu → **About this PG build** → **PG App Lock**.
- Tap Enable. PG verifies your *existing phone credential* and remembers your choice.
- When enabled, PG uses Android's system biometric/device-credential prompt (fingerprint, supported face recognition, PIN, pattern or password).
- Every subsequent cold launch requires an unlock. Returning from the background requires unlock again, while the in-memory chat session remains alive.
- A canceled challenge never opens the chat.
- To disable, repeat the same settings action and authorize with the phone again.
- No separately chosen PG passcode is created, and PG does not receive or store your phone PIN, password or fingerprint data.
- If the device lacks a working lock screen/biometric authentication, PG refuses to activate App Lock.

## Android privacy
- The native MainActivity is a FlutterFragmentActivity to support the standard local_auth plugin.
- Android USE_BIOMETRIC permission and the AppCompat LaunchTheme are configured during project scaffolding.
- FLAG_SECURE is enabled for the full PG window to prevent ordinary screenshots, screen recording, and recent-app preview captures. Screenshots will no longer work in PG on Android (including when app lock is disabled).
- This is best-effort against normal OS behavior, not a defense against a rooted device, spyware, physical photographing, or OS compromise.

## Test on phones
1. Install PG v0.11 and ensure old messaging still works with App Lock OFF.
2. Configure a phone PIN or fingerprint if needed.
3. About → PG App Lock → Enable; authenticate with phone OS. Then background and return: a PG lock screen and OS prompt appear.
4. Test wrong/canceled authentication: PG stays locked. Test correct PIN/biometric: PG unlocks.
5. Test fresh app restart; verify lock setting persists. Test turn off: requires OS reauth.
6. Verify app-switcher preview is shielded, notifications contain no plaintext, replies work, and session state is not erased when locking.
7. On Android 8 / older devices check theme compatibility. Test an interrupted biometric prompt and an incoming phone call.

## Next milestone: real background push and stable voice/video
Current message alerts run only while PG is alive. Production push needs Firebase Cloud Messaging device registration, an admin-controlled Firebase project, short-lived push tokens and a backend event stream that sends metadata-only notifications. The next deliverable is a Firebase opt-in configuration and relay integration, which requires owner-managed Firebase credentials and a secure persistent device identity.
Calls currently use public STUN only. Cross-network reliability needs a TURN relay and authenticated, short-lived credentials; public static TURN passwords in the APK are prohibited.

## Security
PG App Lock is a *UI access barrier*, not a guarantee that conversation data is encrypted at rest, deleted, or inaccessible to a compromised OS. PG's E2EE and WebRTC signaling remain experimental, not independently audited. Controlled test users and non-sensitive data only.
