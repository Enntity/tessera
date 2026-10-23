# Release Tessera

The app version lives in `Resources/Info.plist`. Release artifacts name their architecture and
include a SHA-256 checksum. Package on the architecture being released; the current script does
not create a universal binary. Do not advertise Intel support from an Apple silicon-only test.

## Verify the source

```sh
swift test --scratch-path .build/release-audit
git diff --check
bash -n scripts/build-app.sh scripts/package-release.sh
python3 scripts/test-installer.py .build/release-audit/debug/tessera-cli
```

The suite includes CLI/MCP round trips against a loopback server, token and browser rejection,
message exchange, questions and answers, privacy, schedule parsing, Steward response handling,
PTY behavior, persistence, and remote-channel checks. A clean build directory avoids caches
containing another checkout's absolute path.

## Local candidate

```sh
scripts/package-release.sh --development
```

This produces `.build/releases/Tessera-<version>-macos-<arch>-development.zip` and its checksum.
It is ad-hoc signed for local testing. It is not a notarized public download and may be rejected
by Gatekeeper after download. Do not tell users to disable Gatekeeper to hide that release gap.

On a logged-in Mac desktop, extract the ZIP and run:

```sh
python3 scripts/test-packaged-app.py /absolute/path/to/extracted/Tessera.app
```

This launches only the supplied app in a disposable home and verifies startup without UI
interaction, a restart, restored terminals, and durable inbox delivery. It never activates a
window to make startup pass. It also checks questions, notes, resource setup status, and endpoint
permissions. Follow with the interactive checks below; this script does not exercise Gatekeeper
or provide credentials for Fleet and Steward.

## Public download

Use a Developer ID Application signing identity and an existing notarytool Keychain profile:

```sh
export TESSERA_CODESIGN_IDENTITY='Developer ID Application: <organization> (<team>)'
export TESSERA_NOTARY_PROFILE='<profile name>'
scripts/package-release.sh
```

The script enables hardened runtime, signs the CLI and app with a timestamp, verifies the
signature, submits to Apple's notary service, staples and validates the ticket, and requires
Gatekeeper acceptance before producing the public ZIP. A development certificate is insufficient.
Credentials belong in Keychain or the release environment, never in this repository.

Extract the exact ZIP into a temporary location and verify its signature again. On a separate
macOS user or clean Mac, place the app in Applications and follow [install.md](install.md).
Check CLI/MCP setup, a two-terminal message exchange, a question and answer, privacy mode,
unconfigured Fleet, and a configured Fleet/Steward if those will be demonstrated. Exercise an
upgrade without deleting board state. Signing checks alone do not prove the onboarding flow.

## Publish

Use the Enntity maintainer account, review the final diff and test results, and keep the source
commit, tag, and packaged source aligned. Attach the ZIP and checksum to the release. Describe
the exact OS and architecture tested, Fleet's LLooM dependency, Steward's advisory role, and the
optional source-built iOS companion. Do not publish a candidate as a stable release while the
public signing or clean installation checks remain open.

The package command never publishes, installs over a running app, restarts existing sessions,
or changes agent configuration. Linux remains a separately tracked future feature.
