# Signed updates for the Ghostty AI fork

The macOS client reads only
`https://github.com/10yihang/ghostty/releases/latest/download/appcast.xml`.
Its own Ed25519 public key is embedded in the bundle. Official stable/tip feeds,
old persisted feed preferences and the official signing key are not accepted.
Install the first fork-feed build manually; a build trusting the official key
cannot authenticate our first archive. Later updates keep the same fork key.

## Release flow

The **Fork Release** workflow runs on main pushes, manual dispatch and hourly
at minute 17. It detects the highest published stable version in the official
Ghostty appcast, then fetches that exact upstream Git tag. Ghostty's GitHub
Releases contains only the tip prerelease; its latest-release API is not the
stable-release source.

The plan creates a detached merge candidate. The fork's workflow directory is
preserved; other conflicts fail without advancing main or changing the latest
release. The candidate must retain the AI bridge, query approval policy, command
records and native shortcuts. The build job uses a read-only token and runs
chat/TypeScript/Pi tests, core history/prompt tests, the native suite and an
optimized ARM64 macOS build.

Only the publisher has write permission and the signing secret. It runs scripts
from the trusted base commit, rather than candidate code, and independently
downloads/checksums Sparkle 2.9.6. It signs the ZIP via stdin, verifies the archive
against the embedded public key with CryptoKit, and produces appcast/release
metadata using an immutable asset URL. Fast-forward ancestry and an exact-base
lease protect main from races; an atomic push promotes main and the release tag.
A draft's three assets are downloaded and compared before publishing it as
latest. The public feed is read back afterward. Failed merges, tests, signatures,
promotion or upload validation leave the previous update feed usable.

Versions are monotonic UTC `YYYYmmddHHMMSS` build numbers. Metadata distinguishes
the actual source version/commit from the stable upstream tag it includes.
The current package targets ARM64; the appcast declares that requirement.
Archives preserve framework symlinks and are ad-hoc signed local builds, rather
than Apple-notarized distribution builds. Source `SUFeedURL` is XML-escaped
because this project preprocesses Info.plist with a C compiler.

## Repository configuration

- `SPARKLE_PRIVATE_KEY`: encrypted Actions secret, used only by the publisher.
- `SPARKLE_PUBLIC_KEY`: public Actions variable matching the embedded key.
- `GITHUB_TOKEN`: workflow-scoped repository permissions; no long-lived push PAT.

The signing key is retained in this machine's Keychain under the dedicated
`10yihang.ghostty.ai.updates` account. Private keys must never enter the repository,
command arguments or logs. Changing both keys breaks the existing update chain;
keep the initial pair for subsequent releases.

The inherited official release workflows are guarded for `ghostty-org/ghostty`.
No issue or PR is created on a conflict. Inspect the failed Actions run, resolve
and test the conflicting source, then push main or manually rerun Fork Release.
Manual `rebuild=true` publishes an unchanged source snapshot with a fresh build
number. A normal unchanged hourly check skips the macOS build.

## Local verification

Run helper regressions without creating bytecode in the checkout:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s .github/scripts -p 'test_fork_*.py' -v
```

The local native suite passed **383 tests**, with no failures and one existing
benchmark skipped. Real Sparkle fixtures verify the selected feed and failure
paths; a real signed ARM64 ZIP was independently verified with CryptoKit,
extracted and checked with deep/strict codesign verification. Remote CI/release
status is separate from those local checks.
