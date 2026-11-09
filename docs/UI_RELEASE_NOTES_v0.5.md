# PrivateGet PG — UI Release v0.5

## Design intent

An original, AWS-console-inspired presentation with deep navy surfaces, crisp panels, warm orange primary actions, teal connection statuses, and high-contrast typography. This is **not an official AWS design or AWS-affiliated product** and does not incorporate AWS branding.

## Visible changes

- Replaces all user-facing Party A and Party B labels with **Start a private chat**, **Join a conversation**, **Your contact**, **You**, and **Contact**.
- Modernized header, status indicators, intro, invite cards, form fields, invitation detail, approval screen, chat bubbles, and session-complete screen.
- Adds a confirmation dialog before ending a conversation.
- Improves error presentation and offline/retry state.
- Adds a user-accessible sheet explaining the alpha security limitations.
- Keeps the invitation workflow, API contracts, encrypted relay implementation, and session lifecycle unchanged.

## Testing status

The existing Node.js backend's 23 behavior tests passed locally. The updated Flutter UI has been statically checked for removal of Party A/B labels; **Flutter was not installed in this environment, so Flutter analysis, widget tests, and Android compilation must run in GitHub Actions after uploading the file**.

## How to apply the one-file update

1. In your GitHub repository `pkajnr/privateget-pg`, open `mobile/lib/main.dart`.
2. Replace its contents with the supplied `main.dart` from the ZIP or `PrivateGet_PG_UI_v0.5_main.dart`.
3. Commit with a message such as `Redesign PG mobile UI with AWS-inspired visual system`.
4. Run `Actions > Build PG Android alpha APK > Run workflow`. Enter the same working HTTPS `api_url` as your previous successful build.
5. After the workflow succeeds, download the `privateget-pg-alpha-android-apk` artifact, extract `app-debug.apk`, and install it to replace your previous alpha.

## Production release blockers

This is **production-inspired UI, not production-secure messaging**. The current system still needs audited E2EE and authentication, protection against identity-key substitution, durable identity/device management, HTTPS-only transport, independent security review, reliable session lifecycle, release signing, and a production backend before deployment to the public.
