# Testing

## Automated

`Tests/` runs without network access or a real account:

- Unit tests cover the API client, data models, facets, filters and storage.
- `Tests/UIDriveTests.swift` and `Tests/UIDriveMoreTests.swift` drive the real window invisibly with mouse and key events against a simulated server.
- The test `writeAllRecordsForValidation` writes every outgoing record to a file. `scripts/validate-records.py <lexicon folder> <file>` checks them against the official Bluesky definitions.

## Manual

These cannot be automated and should be checked before a release:

- Menus and dialogs that open on the real screen, and drag and drop.
- Posting, threads, images, video, direct messages and reply rules against the real server. Delete test posts afterwards.
- **iCloud sync between two Macs.** Not yet verified. Add a favorite on one Mac and check that it appears on the other, then the reverse.
- **The signed DMG on another Mac.** Not yet verified. `scripts/release.sh` checks the signature, tickets and Gatekeeper on the build machine, but only another Mac proves it. Open the DMG there, copy the app to Applications and start it, once with internet and once without. It should open without a warning.

Starting a brand-new conversation and muted words have so far only been tested against the simulated server.
