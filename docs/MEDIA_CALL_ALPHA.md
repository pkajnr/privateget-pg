# PG 0.9.0 — media attachments and voice/video calls (experimental alpha)

## What changed

- WhatsApp-inspired chat composer with a + attachment picker, rounded text field, small emoji button, sticker tray, camera shortcut and send.
- Emoji button focuses the device keyboard so users can use the phone's full built-in emoji UI rather than the old PG emoji grid.
- The sticker tray remains a separate inline sheet of 12 simple emoji-style stickers.
- One-file-at-a-time image (gallery/camera), video (gallery), PDF/Word/Excel/other file picker. **12 MB maximum** for this early version.
- The sender AES-GCM-encrypts file bytes with a fresh per-file secret and nonce, then uploads ciphertext only to an in-memory relay. Random file key, metadata and filename are carried inside the pre-existing encrypted chat message.
- The recipient opens images inside PG. Opening other files uses an external file viewer from a temporary decrypted cache. Such viewers may retain files and cannot provide guaranteed erasure.
- The server keeps at most four encrypted attachment blobs per active session, up to 10 minutes each, and discards them at session end.
- 1:1 experimental WebRTC audio/video call buttons in the chat header. Users receive an incoming call acceptance dialog when PG is open.
- WebRTC media uses DTLS-SRTP transport encryption. PG's current endpoint identity model and custom chat encryption are **not externally audited**.
- The call uses a public STUN service for lab connectivity and may expose network addresses; STUN alone cannot reach all cellular/NAT networks. Set up independently operated TURN before considering wider testing.

## Required steps to test
1. Merge the PR and deploy the updated server.mjs to your PG relay service. Rebuilding the APK alone is not sufficient because the backend needs /attachments and /call routes.
2. Run GitHub Actions -> Build PG Android alpha APK from main with your live HTTPS api_url.
3. Install the debug APK on two consenting test phones. A debug APK may use a different signature across CI runners; uninstalling the previous debug APK may be necessary. Doing so removes local ephemeral sessions.
4. Join one chat, send an image, small video and document; confirm the recipient can open them.
5. Start voice and video calls with both devices online in PG and camera/mic permission granted; observe any NAT connectivity failures.
6. Verify Android Back, message expiry, attachment expiry, invite replay protection and End Chat.
7. Use non-sensitive sample data ONLY.

## Not implemented
- Voice note recording, audio-file preview inside PG, GIF/image sticker packs.
- Push notifications when PG is backgrounded or terminated, incoming-call system UI, calling when the recipient is offline.
- Full video compression, multipart large-file uploads, resumable delivery, encrypted object storage, or a TURN service.
- Independent encryption/security audit, verified device identity, production app signing, iOS QA and app-store distribution.

## Security release decision
DO NOT advertise PG 0.9.0 as secure production messaging.
The current chat handshake is experimental, doesn't implement an audited ratcheting messaging protocol, and the relay might substitute unauthenticated public keys.
Encrypted attachments depend on the chat session's confidentiality. System caches and external file viewers can retain plaintext, even if PG removes its temporary cache. WebRTC and STUN expose some metadata. Users must not share confidential conversations or files at this stage.
