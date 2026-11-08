# Security

## Reporting a vulnerability

Please do not open a public issue for security problems. Use [private vulnerability reporting](https://github.com/MacBachi/BlueSkyship/security/advisories/new) instead, and include the steps to reproduce the problem. This is a spare-time project, so a response may take a few days.

## How the app handles your data

- Passwords are used only to sign in and are never stored.
- Session tokens are kept in the macOS Keychain.
- Network requests go to Bluesky's services, the PLC directory and the server your account lives on. The app has no analytics and no server of its own.
- If iCloud sync is on, favorites, decks and draft text are stored in your iCloud key-value store. Sign-ins and images are not synced.
- Posts are treated as untrusted. Showing a post triggers no action. Only `http` and `https` links are clickable, a link whose text names another site asks first, and link targets appear when you hover over them.
- Images are downscaled before upload, which removes metadata such as the GPS location.

Always sign in with an [app password](https://bsky.app/settings/app-passwords), not your main password.
