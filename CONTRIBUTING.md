# Contributing

Bug reports and pull requests are welcome. For larger changes, please open an issue first so we can agree on the approach.

## Setup

You need macOS 14 or later, Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The Xcode project is generated from `project.yml` and is not checked in.

```bash
git config core.hooksPath .githooks
xcodegen generate
open BlueSkyship.xcodeproj
```

The first command turns on the secret checks described below.

To build with your own Apple Developer account, change `DEVELOPMENT_TEAM` in `project.yml` and `TEAM` in `scripts/release.sh`, and use your own bundle identifier. iCloud sync needs a paid developer account. Without one, remove the iCloud key from `BlueSkyship.entitlements`.

## Tests

```bash
xcodebuild test -project BlueSkyship.xcodeproj -scheme BlueSkyship -destination 'platform=macOS' -allowProvisioningUpdates
```

Tests never reach Bluesky. They run against a simulated server, and the UI tests drive the real window invisibly, without using your mouse, focus or account. See [TESTING.md](TESTING.md).

Please add a test for every bug fix and new feature, and never test against a real account in automated code.

## Conventions

- No third-party dependencies.
- Swift 6 with strict concurrency.
- User-facing text is written as a pair in the code: `tr("Deutsch", "English")`. Please provide both. If you do not speak German, leave a note in your pull request and it will be translated.
- Field names follow the official [AT Protocol lexicons](https://atproto.com/specs/lexicon).

## Secrets

Never commit tokens, app passwords, private keys or signing files. `scripts/check-secrets.py` blocks them before every commit and push, and runs again on GitHub. For a proven false alarm, add the comment `secret-scan:allow` to that one line.

If a real secret was committed, deleting it is not enough: revoke it with its provider.

## License

By contributing, you agree that your contributions are licensed under the [GNU GPL v3.0 or later](LICENSE).
