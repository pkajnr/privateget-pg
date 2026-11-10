# PG 0.10.1 — launcher branding and video-call layout

## Updated branding
- The installed app label and iOS display name are **PG**.
- The chat header and Flutter app title are **PG**.
- A new original PG shield/monogram icon uses a midnight-navy background, warm gold and electric teal. Source: `mobile/branding/pg_icon.svg`.
- `mobile/branding/render_launcher.py` rasterizes the SVG into Android launcher icon densities, the Flutter in-app icon, and iOS AppIcon images after `flutter create`. Android and iOS share the same design.
- The Dart package name and Android app identifier are intentionally unchanged so existing debug installations may upgrade without breaking their application package identity.

## Replies
- Removed the small Reply arrow from each individual message bubble.
- **Long-press any message** to quote and reply. The earlier reply preview/cancel control remains.

## Video calls
- Replaced the 270-pixel-high dialog with a fullscreen call window.
- Incoming video occupies the screen and uses `RTCVideoViewObjectFitContain` so the whole frame remains visible; some letterboxing is expected when phone and camera aspect ratios differ.
- The outgoing self-preview is a small window at top-right.
- Microphone, camera controls and hang up float at the bottom and do not shrink the incoming video.
- Remote video track handling now supports RTC track events without a populated MediaStream list.
- If the remote video track hasn't arrived, the call displays a waiting message instead of silently suggesting the call is showing live video.

## Verification
Run the `Verify PG media and calling changes` CI job, which exercises Flutter tests, analyzer and an Android APK build. Install the result on **two actual Android phones** and validate both portrait and landscape camera framing, camera permission, Wi-Fi/mobile networks, long-press replies, and the launcher icon/label.

**Limitations:** The call protocol and signaling are still experimental and lack independent end-to-end authentication review. STUN without TURN can fail across some mobile or restrictive NAT networks. No actual two-phone call/video quality test has been performed from CI. PG remains a non-sensitive testing alpha, not a production-secure messenger.
