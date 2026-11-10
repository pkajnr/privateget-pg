# PrivateGet (PG) — Production readiness and controlled alpha

Updated 10 November 2026.

## This UI update
- Built-in emoji picker inserts ordinary Unicode emoji into PG text messages.
- 12 large emoji-style stickers encoded as short text payloads in the existing encrypted message channel (not downloaded image sticker packs).
- Android system Back closes the open picker first, then returns from a chat/invite/waiting screen to the conversation list, then exits the app from the home screen.
- Returning to the list keeps the temporary session alive. Only End Chat (or session expiry) requests destruction.
- Foreground in-app banner "New private message in PG" and OPEN action, no plaintext preview. The app polls the relay while running.
- OS push alerts for a backgrounded, terminated or locked phone are **not yet implemented**.

## Controlled alpha validation
1. Merge branch and run Build PG Android alpha APK with a reachable HTTPS api_url.
2. Verify Flutter tests, analyzer, Android compilation and installation on two phones.
3. Create an invitation, accept and approve, exchange text emoji and stickers.
4. On a second conversation or home view, receive a message and test OPEN banner.
5. Verify Android Back closes picker, returns to list, and exits only from home.
6. Verify End Chat (rather than Back) is responsible for session termination.
7. Test network loss, relay restarts, expiry, rapid navigation, smaller Android screens and tablet sizing.

## Production release blockers
The backend states that it is experimental and not security-reviewed. The current key agreement has no independently reviewed asynchronous Signal-style E2EE protocol, strong identity binding or verified forward secrecy/post-compromise security. The server may mediate unauthenticated device public keys. No confidentiality guarantee should be promised without correcting and auditing these issues.

Other missing capabilities:
- Persistent, securely stored device identities and key lifecycle; audited E2EE and external penetration testing.
- Robust invite authentication, abuse protection, server reliability, secure deployment and observability.
- FCM (Android) / APNs (iOS) push with **metadata-only** notifications, device push tokens, opt-in permissions and tap routing. Never send plaintext message previews to push providers.
- Proper ephemeral delivery handling when app is offline and meaningful deletion semantics for absent or compromised devices.
- Production app signing, app-store distribution, privacy policy, compliance review and incident response.

Do not distribute this debug build as a production-secure messenger. Sharing it with consenting controlled test participants using non-sensitive messages is a different, limited activity.
