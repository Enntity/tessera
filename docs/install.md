# Install Tessera on macOS

Requires macOS 15 or newer. The supported installation path today is a source build with Xcode
26 or newer. There is no notarized public download yet. Everything described below is included
in the public source; Fleet, Steward, provider accounts, and the iOS companion are optional.

## Build from source

Install Xcode, open it once to finish setup, and select it under Xcode → Settings → Locations →
Command Line Tools. The standalone Command Line Tools package is insufficient. Then run:

```sh
git clone https://github.com/Enntity/tessera.git
cd tessera
swift test
scripts/build-app.sh
open .build/app
```

The first build downloads the public SwiftTerm and zstd dependencies. Drag `Tessera.app` from
the Finder window into Applications (or `~/Applications`), then open it. Keep it in that location
before installing the agent integrations. The build uses a local signing identity if available,
or an ad-hoc signature if none exists; no Apple developer account is needed for a local build.

Continue with **First-run setup** below. To update, quit Tessera normally so it saves your board,
run `git pull --ff-only` and `scripts/build-app.sh`, then replace the app and reopen it. If its
location changed, rerun the integration installer. Preserve the application-data folder.

A local development signature is not a Developer ID distribution signature. Public release
signing and notarization are described in [releasing.md](releasing.md). If build caches contain
an old checkout path, set `TESSERA_SCRATCH_PATH` to a fresh folder for `build-app.sh`, or pass
`--scratch-path` to `swift test`.

## Packaged app

When a signed release is available, this path will not require Xcode, Swift, Python, or Node.
Use an asset matching your Mac; `arm64` means Apple silicon.

1. Download a signed macOS ZIP and its checksum from [Releases](https://github.com/Enntity/tessera/releases).
   Verify it with `shasum -a 256 -c <downloaded-file>.zip.sha256` in the download folder.
   CI artifacts and development candidates are not notarized public downloads.
2. Expand the ZIP and drag `Tessera.app` to Applications **before** installing agent integrations.
3. Open Tessera. Grant Notifications if you want attention alerts. Accessibility is optional and
   used to position desktop agent windows. The iPhone link is off by default.
4. Follow the first-run setup below.

## First-run setup

1. **Connect your agents.** Install and sign in to whichever agent CLIs or desktop apps you use.
   Tessera detects installed tools; it does not include their subscriptions or credentials.
   In Settings → Agents, leave **Let agents on this Mac use Tessera** enabled, then choose
   **Install Command, Skill & MCP**. Read the result and restart your agent sessions.
2. **Open a workspace.** Use ⌘T for a shell or the New menu for an installed agent. Recent Claude
   and Codex desktop sessions appear automatically. Devin launched inside a terminal resumes
   its bound conversation after a normal quit/restart. Other commands can run in any shell tile.
3. **Try the decision queue.** From a Tessera terminal, run
   `tessera ask 'What should I try next?' --option 'Messages' --option 'Steward' --wait 0`.
   Answer in the Needs-you lane, then retrieve it with `tessera answer '<question id>' --wait 0`.
   ⇧⌘J opens keyboard triage. The [messaging walkthrough](control-plane.md#a-working-conversation)
   shows how two agents exchange messages.
4. **Enable Steward summaries.** In Settings → Agents, enter your inference base URL ending in
   `/v1`, an actual model name served there, and its key if required. Enable summaries and Save.
   The default model text `tessera` is only an example alias; your server must provide it or you
   must replace it. Use an endpoint supporting the [documented request format](control-plane.md#steward-the-advisory-coordinator).
   Leave a tile settled for at least 20 seconds; the board brief runs about once a minute.
   Any request failure appears in Settings. Selected board text is sent to this endpoint.
5. **Add the extras you use.** Settings → Fleet connects a LLooM head. Only jobs needing attention
   become tiles by default; **Show agents' jobs as tiles** enables all jobs. Settings → Machines
   adds your SSH hosts. Accounts are optional and use your own provider keys. The source-built
   [iOS companion](../README.md#build-and-run) pairs through Settings → iPhone; it has no background
   push notifications and needs a reachable Mac.

Local terminals, agent discovery, messages, questions, triage, and session restoration work
without Steward, Fleet, or a Tessera account. Grant Notifications for alerts; Accessibility is
needed only to position desktop-app windows. Local Network access is used for the iPhone link.

## What the integration installer changes

The installer links `~/.local/bin/tessera` to the bundled command, copies the skill to
`~/.agents/skills/tessera`, links it for Claude Code, and registers MCP for detected Claude Code,
Codex and Devin clients. It preserves previous skills and backs up changed Codex configuration.
Existing Tessera MCP registrations are retained, including customized commands. If a retained
registration points at an old app, update it in that client or remove that Tessera registration
and rerun the installer. If you move the app later, run the installer again to update its symlink.
An existing real file at a required symlink path is left untouched and reported as a conflict.

For direct shell use, ensure `~/.local/bin` is on PATH. For zsh, add this line to `~/.zshrc` if needed:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Open a new terminal, then run:

```sh
tessera --help
tessera whoami
tessera board
```

A shell outside Tessera may have no tile identity. That is expected; board reads still work.
Follow [identity setup](control-plane.md#identity-when-agents-share-a-folder) for inbox access.
In an agent sandbox, local loopback or application-data access may need the harness's permission.
An `Operation not permitted` error alone does not mean the app is broken.

## Manual integration

Preview installation without changing files:

```sh
/Applications/Tessera.app/Contents/Helpers/tessera-cli install --dry-run
```

Any MCP client supporting stdio can launch this executable with the argument `mcp`:

```json
{
  "mcpServers": {
    "tessera": {
      "command": "/Applications/Tessera.app/Contents/Helpers/tessera-cli",
      "args": ["mcp"]
    }
  }
}
```

Adapt the enclosing configuration to your client. Use at least a 70-second tool timeout for
human questions. Agents that can run shell commands can use the CLI without MCP. The bundled
skill is in `Tessera.app/Contents/Resources/skills/tessera/SKILL.md`.

## Troubleshooting

- **The CLI is missing:** add `~/.local/bin` to PATH and start a new shell. MCP uses an absolute
  path and does not need this PATH change. Read the Settings installer output for conflicts.
- **The app is unavailable:** open Tessera and check that its Agent API is enabled. Tool
  discovery works while the app is closed, but board operations require the running app.
- **Identity is ambiguous:** use the exact tile id from `board`, as described in the identity
  guide above. A display name passed with `--as` does not assign an inbox.
- **A model returns 400 or empty summaries:** check the model name and supported request options
  against the control-plane guide. An OpenAI-compatible URL alone is not sufficient.
- **Permissions recur after a rebuild:** an ad-hoc signature can require Accessibility permission
  again. A stable local signing identity avoids changing identity on every build.

## Optional services and removal

Fleet requires a separately configured LLooM head. Steward requires an inference endpoint;
neither is needed for local messages or questions. Configure those under Fleet and Agents.

To remove integrations, remove the Tessera MCP registration in your clients and the Tessera
symlinks and skill installed above. Preserve any skill backups you need. Deleting the app does
not delete its board or conversations. Tessera's state is under
`~/Library/Application Support/Tessera`; provider keys are in Keychain. Do not delete state just
to upgrade or reinstall.
