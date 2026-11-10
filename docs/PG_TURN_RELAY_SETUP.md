# PrivateGet (PG) — WebRTC TURN relay configuration

## Why calls sometimes fail on different networks
WebRTC direct peer-to-peer calls may fail when phones are behind symmetric NAT or restrictive mobile networks. STUN helps discover addresses but cannot relay media when direct paths fail. TURN provides a relay path; it is **not** a cryptographic identity verification substitute.

## Implementation in this update
- An authenticated, active chat participant requests `GET /v1/sessions/:id/ice`.
- The backend responds with public STUN plus an optional TURN configuration.
- When `PG_TURN_URLS` and a secret of at least 32 characters are set on the backend, TURN credentials are minted for **15 minutes** using coturn's time-limited REST credentials: `username = expiryUnix:random-looking-device-id`, `password = base64(HMAC-SHA1(secret,username))`.
- Those temporary credentials are never hard-coded in Android/iOS bundles. The coturn shared secret remains a private environment variable on the backend and TURN host.
- The API checks device authentication, session membership and active state, and rate-limits ICE requests. It returns a `Cache-Control: no-store` response.
- The Flutter WebRTC engine uses the returned ICE servers. If the backend is old or unavailable, it keeps the existing public STUN-only fallback for lab compatibility.

## Required deployment (not included automatically)
1. Obtain a TURN-capable server/VPS with a real public IP, DNS name and an appropriate network/firewall configuration. The PG API's existing Render HTTPS service is **not** itself a UDP/TURN relay.
2. Install audited/current coturn; refer to `server/turnserver.conf.example`. Configure `use-auth-secret`, a strong shared secret, realm, public/external IP and relay port range.
3. On the PG backend, add environment variables:
   - `PG_TURN_SECRET`: the **same** 40+ character secret as the coturn host.
   - `PG_TURN_URLS`: comma-separated endpoints such as `turn:turn.example.com:3478?transport=udp,turn:turn.example.com:3478?transport=tcp`.
4. Deploy the backend and verify that its `/v1/sessions/:id/ice` response includes `turnConfigured: true` for an authenticated participant in an active session. Never paste the secret into a chat, GitHub, APK or client config.
5. Test two phones (different carriers/Wi-Fi) with voice and video. Measure connection failures, latency and bandwidth; TURN may incur data and compute costs.
6. Before wider use add TLS TURN URIs (`turns:`), resource limits, abuse controls, IP-data retention policies, and peer identity binding/signaling security testing.

## Validation
Run `node server/test.mjs` and `node server/media.test.mjs`; the latter verifies credential HMAC and participant-only ICE access, including after session end.
Flutter analyzer/tests and APK compiler also run in CI.

## Security limitation
TURN is an availability improvement, not end-to-end encryption proof. PG's custom messaging crypto, identity verification and WebRTC signaling remain experimental; TURN/STUN operators see network metadata. No provider is deployed or configured by this code change. Do not claim PG production-secure.
