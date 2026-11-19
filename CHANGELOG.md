# Changelog

## Unreleased

- RSS and Atom feeds as columns, one feed or several mixed, newest first. A website address is enough; the app finds the feed. The whole article opens inside the column as plain text, without loading the publisher's page, and can be opened in the browser or shared on Bluesky or Mastodon.
- Feedly: import the OPML export (one column per folder, in a new deck), or connect directly with a Feedly access token to read categories, single feeds or everything.
- Filters: "Always show" terms beat every other rule. Filters can be saved under a name and ticked in any column; a change applies to every column using it. Saved filters sync through iCloud.
- Two wider column widths: Extra Wide and Widest.
- Decks containing feed columns or saved filters need this version on every Mac that syncs them through iCloud.

## 1.1.0

- Mastodon accounts next to Bluesky accounts, in the same decks. Sign-in runs on the server's own page in the browser (OAuth with PKCE); the app never sees the password.
- Mastodon columns: home, notifications, mentions, local and federated timelines, lists, hashtags, search, profiles, own posts, favourites, bookmarks and direct messages.
- Boost, favourite, bookmark, follow, mute, block and delete on Mastodon. Threads, replies and quotes with pictures or video, visibility and content warnings.
- Content warnings and server filters cover posts until opened. Mastodon post HTML is read by a small reader of its own: only text, hashtags, mentions named by the server and plain web links survive.
- Searches and hashtags without their own account mix Bluesky and Mastodon in one column, newest first. Each post is liked, answered and opened through the account that found it.
- Every account has a colour, chosen in Settings; a thin strip at the edge of each post shows which account it came from.
- Decks containing Mastodon columns need this version on every Mac that syncs them through iCloud.

## 1.0.0

First release.

- Column deck for home, notifications, mentions, searches, profiles, feeds, lists, likes, bookmarks and direct messages
- Several decks, column filters and an indicator for columns out of view
- Favorites that take up no column
- Composer with threads, drafts, scheduled posts, images, video and reply rules
- Multiple accounts, keyboard control and notifications
- German and English interface with built-in help
- iCloud sync for favorites, decks and drafts
