# PrivateGet PG 0.10.0 — DNS repair, reply-to-message and status stickers

## Why notifications stopped

The phone screenshot shows `SocketException: Failed host lookup: privateget-pg-api.onrender.com`. PG cannot resolve the relay hostname, so it cannot receive messages and therefore cannot fire a new-message notification. The previous URL was only an example. The real URL is available in the Render dashboard on the web service detail page.

**Recovery on the phone:** If the app shows the connection screen, tap **Change server address**, paste the actual Render HTTPS URL, and accept the session reset. When connected, go to **About this PG build → Test Android notification** and verify Android delivery. If the permission is off, enable it in Android Settings → Apps → PrivateGet → Notifications.

The server address is saved locally via shared_preferences. Switching the server discards local alpha chat sessions and keys. It cannot confirm deletion on an unreachable old relay.

## Reply to a specific message

Tap the small curved Reply arrow inside a message, or long-press the message. A quoted preview appears above the composer. Type and send; the quote travels **inside the existing encrypted session envelope** with the new reply text. Tap X to cancel. Quotes are limited to 160 characters. Replies to older messages without IDs preserve the quote snippet but do not navigate to a historical message.

## Five PG-exclusive status stickers

- Contract agreed
- Date fixed
- Terms agreed
- On the move
- Eating

They appear in the **PG EXCLUSIVE** row of the emoji/sticker tray, with distinct color and icons, followed by the existing classic emojis. They are versioned structured text markers inside the encrypted chat and render as icons in an upgraded receiving app. Other clients must upgrade to display them; older PG releases will show a raw marker rather than artwork.

## Notification limitations

The current Android native notification bridge requests permission and can post **local alerts only while the PG app is alive and receiving message polls**. It intentionally does not place plaintext in the OS notification. Notifications are suppressed when the conversation containing the message is already open, just as many messaging applications do.

True notifications with PG closed, backgrounded or locked require **FCM/APNs push, persistent device identity and push token registration**, none of which are implemented in this release. The server is in-memory and sessions disappear on restart.

## Privacy and production status

This remains an **experimental alpha** with unaudited encryption. A successful APK build or unit tests do not qualify as a security audit, production acceptance, or proof of permanent erasure.

## Test checklist

1. Android 13+ notification permission granted, or enable from system settings if previously denied.
2. In About, trigger **Test Android notification** — confirm Android posted an alert even without another phone.
3. With the correct HTTPS Render address and both devices joined, send a message while the recipient is in the conversation list; expect a local notification if PG is alive.
4. Open a chat on each device, tap Reply on an earlier message and send. Confirm the quote and author label appear correctly.
5. Send all five PG-exclusive statuses from one upgraded device; they should render on the other upgraded PG app.
6. Verify legacy plain-text messages, emoji stickers, files and call controls are unaffected.
7. Confirm the backend URL is remembered across app restart. Changing it clears volatile chat state.
