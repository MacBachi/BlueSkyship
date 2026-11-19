# Testing

## Automated

`Tests/` runs without network access or a real account:

- Unit tests cover the API client, data models, facets, filters and storage.
- `Tests/MastodonTests.swift` runs the Mastodon client, sign-in, HTML reader and deck actions against a simulated Mastodon server, including hostile links and markup. The mapping was also checked once against 125 real public posts from mastodon.social (none skipped); that data is not part of the repository.
- `Tests/FeedTests.swift` covers RSS, Atom and RDF parsing, hostile feeds, feed discovery, OPML import, the Feedly client and the filter rules against simulated servers.
- `Tests/IOCTests.swift` covers IOC detection (hashes, IPs, CVEs, domains, addresses, defanged forms), false alarms such as file names and clock times, lookup links, hover texts and the IOC filter, and the live info for CVEs, IPs, domains and hashes against simulated services, including private addresses never being sent. The parsing was checked once against the real NVD, FIRST, RIPEstat, Shodan InternetDB, GreyNoise, urlscan.io and CIRCL.
- `Tests/UIDriveTests.swift` and `Tests/UIDriveMoreTests.swift` drive the real window invisibly with mouse and key events against a simulated server.
- The test `writeAllRecordsForValidation` writes every outgoing record to a file. `scripts/validate-records.py <lexicon folder> <file>` checks them against the official Bluesky definitions.

## Manual

These cannot be automated and should be checked before a release:

- Menus and dialogs that open on the real screen, and drag and drop.
- Posting, threads, images, video, direct messages and reply rules against the real server. Delete test posts afterwards.
- **iCloud sync between two Macs.** Not yet verified. Add a favorite on one Mac and check that it appears on the other, then the reverse.
- **The signed DMG on another Mac.** Release 1.0.0 opened on a second Mac with only the usual first-launch question, and started. Not yet checked: the first launch without internet. Repeat this check for every release.
- **Mastodon against a real server.** Sign in through the browser, read home, notifications, local and federated timelines, a hashtag, a profile and a list. Favourite and boost and undo both. Post, reply, a thread with a picture, a content warning and a direct message with a test post, then delete them. Sign out and check that the app is gone under the account's authorized apps on the server.

- **Feeds and Feedly against real servers.** Add a few real feeds (one by website address), an OPML export from Feedly, and, if a token is available, a Feedly category. Check pictures, the article view, filters with saved presets, and the two new widths.
- **IOC hover cards in the real window.** Hover a CVE, an IP and a normal link; the card should appear after a moment, stay while the mouse moves onto it, and close when it leaves. Check its buttons, the right-click menu on a link, and VirusTotal and AbuseIPDB with real keys.

Starting a brand-new conversation and muted words have so far only been tested against the simulated server.
