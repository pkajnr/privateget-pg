# PG test-alpha notification behavior and security release gate

Updated 10 November 2026.

## UI improvements
- Single rounded InputDecoration on the message TextField; removed the duplicate outer Container border and the non-functional emoji icon inside the field.
- The icon that opens PG's emoji-style sticker tray now uses an emoji face. The Android system keyboard remains the ordinary way to type Unicode emoji.

## Android notifications
- Starting on Android 13, first launch invokes the native POST_NOTIFICATIONS permission dialog if not already granted.
- On older versions, runtime POST_NOTIFICATIONS permission isn't needed.
- Notification permission may be denied: PG can still function for an already-open chat.
- New message while another session/home screen is selected: PG shows its in-app snackbar plus a **local operating-system notification** that contains only "PrivateGet" and "New private message".
- No sender name, message body, session ID or cryptographic material is placed into the OS notification.
- Lockscreen notification visibility is set to SECRET.
- Tapping the notification opens PG. It does not deep-link to an ended session.

**Important limitation**: PG's current app polls every few seconds while Flutter is running. This is NOT a push system. Notifications are not guaranteed when the app is backgrounded, killed, locked or offline. True push requires FCM/APNs, durable token registration, expiration and revocation, and backend delivery without plaintext push payloads. Do not claim WhatsApp-style background delivery.

To test: install the new debug APK on Android 13+, launch PG and accept notifications; with PG running, keep home or another chat selected while a second phone sends to a different chat. Check Android notification settings if the popup does not appear. On Android 12 and below there is no new permission dialog.

## Preliminary code-review security gate

This review is **not** an independent penetration test, formal cryptographic audit, binary analysis, infrastructure audit or OWASP MASVS certification.

Status: **NO-GO for secure production release.** Limited alpha testing with consenting participants using only non-sensitive messages/files/calls is conditionally permitted.

High-priority issues identified from the present source:
1. E2EE protocol is experimental X25519 + static session AES-GCM keys; there is no audited Signal-style key exchange / Double Ratchet, authenticated device identity or verified post-compromise recovery. Relay-mediated public-key substitution is a material risk if safety codes are not independently verified.
2. WebRTC signaling/SDP and ICE data are not independently authenticated to verified participant identities. DTLS-SRTP encrypts media transport, but a malicious signaling relay could undermine endpoint identity. Public STUN can expose IP metadata; TURN isn't configured.
3. The app's device identity and bearer token are volatile; app/server restarts lose sessions. The backend holds registrations, tokens, and queues in memory with limited lifecycle enforcement and no operational production controls.
4. In-app polling is not reliable offline/background push. The relay's destructive retrieval can lose queued ciphertext if delivery fails.
5. Session destruction and cleanup are best-effort. Offline peers, third-party file viewers, OS memory, device backups, malicious clients and screenshots cannot be guaranteed erased.
6. There is no completed external mobile/backend penetration test, supply-chain verification, secure release signing, threat-model approval, or incident-response validation.

Evidence: mobile/lib/main.dart, mobile/lib/pg_media.dart, mobile/lib/pg_calls.dart, server/server.mjs, server/test.mjs, server/media.test.mjs.

Minimum release gates:
- Adopt independently reviewed E2EE protocol and device identity verification; complete cryptography-specific review and key-lifecycle tests.
- Harden backend token/session security, rate limiting, encrypted transport, infrastructure, monitoring and abuse prevention.
- Authenticate call signaling and add trusted TURN service; document metadata exposure.
- Implement authenticated push-token lifecycle and metadata-only background notifications.
- Ensure attachment handling remains encrypted and temporary, including third-party viewer risks.
- Independent security assessment against OWASP MASVS, remediation and re-test.
- Verified signed release builds, controlled rollout, crash/error metrics, privacy policy and incident-response procedure.

Never market this alpha as permanently trace-free or safe for confidential messaging.
