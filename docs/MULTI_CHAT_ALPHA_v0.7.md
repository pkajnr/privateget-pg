# PrivateGet PG v0.7 — Multiple chats and Android keyboard fixes

**Status:** Experimental alpha, not security-audited and not production-ready.

## What changed

- Each temporary conversation has its own ephemeral X25519 key pair, derived send and receive keys, session ID, messages, invitation, safety code and draft.
- Home has a **Your conversations** list. Opening one chat does not end the others.
- Up to **four live conversations** are available in this alpha. Backend session/invite permissions remain scoped to each participant.
- A closed conversation loses its application-held session keys and messages without clearing the other open chats.
- The chat screen no longer shows the large **Private contact / Temporary conversation / Connected** panel.
- An unobtrusive connection dot appears by **PrivateGet** in the app bar; the safety code and End Conversation controls are available through icons.
- The message composer stays in the same Flutter widget position while the Android keyboard opens; the earlier dynamic removal of children above it could destroy input focus.
- A compact two-line composer sits above the keyboard, with the message list taking the available height.

## Limitations

- Chats and decryption state are **RAM-only**. Force closing the app or a backend restart can lose sessions. This is intentional for the alpha but is not a complete secure lifecycle design.
- Invite and message delivery are based on periodic polling. Use real phones to assess responsiveness, keyboard stability and multi-session navigation.
- Ending a chat destroys the app's references to keys and messages; it cannot guarantee removal of screenshots or copies made by a compromised device.
- PG's experimental encryption is **not** an audited messaging protocol. Do not send confidential information.
- The relay is not yet production-hardened. Public HTTPS, persistent device management, native OS key storage, formal E2EE and independent security review are still required.

## Validation

GitHub Actions workflow **Verify PG Flutter source** passed on 9 November 2026 for commit `f9a59a5`, including a per-chat isolation test, the PG widget/unit tests and Flutter static analysis. This does **not** replace actual Android device or E2EE security testing.

## Build the new APK

1. In [GitHub Actions](https://github.com/pkajnr/privateget-pg/actions), open **Build PG Android alpha APK**.
2. Use **Run workflow** on the `main` branch (not **Re-run all jobs** on an old commit).
3. Enter your working PG backend URL in `api_url`.
4. Download the generated Android APK ZIP from the run's **Artifacts**.
5. Install on Android and verify: type without losing keyboard focus; create a chat, return to Home, start a second chat, switch back, end only one and verify the other still works.

If the phone still loses keyboard focus, record a short screen recording and share the device's Android version, because keyboard behavior cannot be fully validated by a Flutter analyzer alone.
