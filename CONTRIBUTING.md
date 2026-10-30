# Contributing to Tessera

Tessera is a macOS host with a shared Swift core and an optional iOS companion. Start with the
[installation guide](docs/install.md) and [architecture](README.md#architecture). All build
dependencies are public; developing the board and agent tools needs no private Enntity services.

## Build and verify

Use macOS 15+ and Xcode 26 or newer. From a clean checkout:

```sh
swift test --scratch-path .build/check
python3 scripts/test-installer.py .build/check/debug/tessera-cli
TESSERA_SCRATCH_PATH=.build/check scripts/package-release.sh --development
git diff --check
bash -n scripts/build-app.sh scripts/package-release.sh
```

The installer test uses a disposable home and stub client commands. It must not register MCP
against a contributor's actual clients. Extract the ZIP to a fresh directory and run
`python3 scripts/test-packaged-app.py /absolute/path/to/Tessera.app` on a logged-in Mac desktop
to verify startup, restart, restored terminals, and the agent API in an isolated board.

For UI work, `scripts/debug-run.sh` runs a separate debug board; set `TESSERA_DEBUG_HOME` to a
temporary directory so it does not read your real agent sessions. See the README for scripted
actions and screenshot generation. Never use personal work as a test fixture or screenshot.

## Source and privacy checks

Install [Gitleaks](https://github.com/gitleaks/gitleaks) 8.25 or newer (`brew install gitleaks`), then:

```sh
gitleaks git --redact --config .gitleaks.toml .
```

The configuration extends the default rules and exempts only two exact synthetic credentials
in the redaction test. Do not exclude whole test directories or silence a finding before checking
it. Also inspect new fixtures, screenshots, local paths, hostnames, and account details manually;
a credential scan cannot recognize all private content. Keep signing material, app state,
personal transcripts, and endpoint keys out of commits and release artifacts.

## Pull requests and releases

Explain the user-visible change and record the checks you ran. Keep related behavior tests with
the change, use invented fixtures, and document external-service requirements. A green unit
suite does not establish live Fleet/model compatibility or downloaded Gatekeeper behavior.

CI tests the macOS app, isolated integration installer, public-source secret scan, and development
package. Source can merge independently of a binary release. Public downloads additionally need
Developer ID signing, notarization, and clean installation checks in [releasing.md](docs/releasing.md).

Report vulnerabilities through [private security advisories](https://github.com/Enntity/tessera/security/advisories/new).
