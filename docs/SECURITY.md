# PrivateGet — alpha security boundaries and product roadmap

## Purpose
Build an invitation-only, one-to-one ephemeral messenger in which users, not PG administrators, hold the decryption keys. Option A has no owner-recovery function, key escrow, master key or encrypted-message archive.

## ALPHA IMPLEMENTED
- X25519 one-time ephemeral keypair per conversation on each device (Dart `cryptography` package, Apache 2.0).
- HKDF-SHA256 derivation of distinct A→B and B→A 256-bit AES-GCM keys using session ID as salt.
- AES-256-GCM with a random 96-bit nonce and authenticated additional data binding conversation ID and sender role.
- 24-byte random single-use invitations hashed before storage and expired after 10 minutes.
- Participant-authenticated API access using random ephemeral bearer tokens, session approval, limited rate rules.
- Short-lived queued ciphertext (3-minute TTL), one-time destructive retrieval, in-memory only, session end drops ciphertext queue.
- No message-body logging; APIs reject plaintext message bodies.
- Displayable fingerprint derived from the two public keys and session ID; users must compare over independent trusted channel.
- Mobile clients keep conversation keys and plaintext messages in volatile application memory only; deletion resets references and UI buffers.

## NOT IMPLEMENTED / CRITICAL RISKS
1. **No audited protocol:** This is NOT Signal Protocol or Double Ratchet. It lacks continuous forward secrecy, post-compromise security, replay protection, identity persistence and rigorous state-machine verification.
2. **Active server MITM:** The server exchanges public keys and can substitute keys. Out-of-band comparison of matching fingerprints is important but insufficient without hardened identity key verification.
3. **Development HTTP:** The backend is HTTP without TLS. Anyone on the same untrusted network can intercept bearer tokens, invitation codes, connection metadata, and attempt impersonation. Use ONLY on a private lab LAN. Production demands HTTPS with proper cert verification, secure reverse proxy, rate limiting and monitoring without content logging.
4. **No secure key zeroization:** Dart garbage collection can leave copies of cryptographic material in application memory. Session-end cleanup is best-effort. Screenshot, memory dumps, device compromise, operating-system clipboard and OS snapshots are beyond guarantees of this version.
5. **Unconfirmed remote erasure:** If either device is offline, broken or compromised, PG cannot force deletion there. Offline peer could retain plaintext already received. No application can prevent someone photographing another screen.
6. **Backend restarts erase all state:** This app version deliberately uses in-memory metadata, devices, session and delivery state. No persistence and no reliable reconnection.
7. **No abuse/hardening:** Demonstration-level per-minute limits, no global distributed limits, anti-automation proof, distributed denial-of-service protections or operational security procedures.
8. **Offline and crash behavior:** The client stores nothing on disk; app restart forgets identity and conversations, but app memory/OS may preserve artifacts outside client control. Both users must be online.
9. **Messages can be lost:** Delivered ciphertext is removed on GET rather than an acknowledged, atomic receipt. Temporary network failure after GET can lose a message permanently. This is acceptable only for an alpha.
10. **Legal access:** The owner has no chat decryption key by design. PG can respond only with data it actually retains and is legally required to provide; it must not claim immunity from all legal orders.

## PRODUCTION RELEASE BLOCKERS
- Audited, licensed Signal-style E2EE stack with authenticated X3DH/PQXDH and Double Ratchet integrated on Android and iOS, including proper identity verification and secure key lifecycle.
- Security review of native crypto bridge/Flutter packages; documented licensing obligations.
- HTTPS/WSS, client pinning policy analysis, anti-abuse, log redaction, secure ops, monitoring and independent penetration test.
- Device-only key storage and backup exclusion, prevention of sensitive content in notifications, screenshots/task snapshots where feasible, accessibility threat documentation.
- Scoped accounts, device verification and recovery policy consistent with no owner key recovery.
- Server-side metadata/database design with ephemeral quotas/TTLs; validated deletion and backup policies.
- Deep links: Android App Links + iOS Universal Links using owned HTTPS domain; no invitation secrets in web server analytics, referrer logs or previews.
- Reconnection and message acknowledgement semantics, sync, crash-restart handling, on-device encryption lifecycle and key rotation.
- Comprehensive threat model and privacy review, independent security audit, beta release checks.

## Three-week target
Week 1: run real backend and Flutter Android builds; both devices invite/accept and connect.
Week 2: integrate production-candidate audited encryption engine and verify both platforms.
Week 3: key deletion tests, backend hardening and internal app distribution. If audits/integration remain incomplete, stay in closed alpha and do NOT make production-security claims.
