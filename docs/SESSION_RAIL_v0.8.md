# PrivateGet PG v0.8 — Named sessions and unread bubbles

Status: **Experimental alpha**. This is not a production-secure messenger.

## New interface

- A compact horizontal **Sessions** strip is visible above the home page and open conversations.
- Each active or pending session has a circular tile, like a messaging app's status row. Tap a circle to jump directly to that conversation.
- The selected conversation has an orange ring. Other active chats have a teal ring.
- Unnamed chats show `01`, `02`, etc. until you give them a name.
- Tap the **pencil** in the conversation toolbar, or long-press its circular tile, to rename it (e.g. **Suitor** or **KwameP**).
- A badge on each circle shows the number of messages received since that chat was last opened. The strip header shows the **total unread message count** across active sessions.
- Opening a conversation resets that session's unread count, without affecting the others.
- **New chat** appears in the strip when fewer than four sessions are active.

## Privacy and limitations

- Chat names, received message counters and message drafts are kept in **RAM only**, not sent to the PG server. They disappear on app restart or when a session ends. They are not synchronized with your other devices.
- Unread totals are not push notifications; the alpha updates them through periodic polling while the app is running. Unread counts may be delayed, and the backend restart can end sessions.
- The session strip hides while the keyboard is open to leave room for messages. It appears again when the keyboard closes, without remounting the chat composer.
- PrivateGet's encryption is experimental and unaudited. Do not exchange sensitive information or represent the app as production-ready.

## Test on Android

1. Start a **new** run of GitHub Actions > **Build PG Android alpha APK** on `main`, supplying your working backend URL.
2. Download and install the new `app-debug.apk`.
3. Create a chat and rename it Suitor; create another and rename it KwameP.
4. Leave Suitor open and receive two messages in KwameP; the KwameP avatar should show **2**, and the strip total should show **2 unread**.
5. Tap KwameP. Its badge should reset to zero. Return to Suitor without ending KwameP.
6. Type with the Android keyboard and confirm the message field retains focus, while the horizontal strip temporarily hides.
7. End one session and confirm the others remain available.

GitHub's **Verify PG Flutter source** workflow tests local nickname state, unread-message isolation and performs Flutter analysis; it does not replace on-device UI testing.
