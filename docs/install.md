# Install Tessera on macOS

Requires macOS 15 or newer. Use a release asset whose architecture matches your Mac; `arm64`
means Apple silicon. No Python, Node, or Swift toolchain is needed to run a packaged app.

## Packaged app

1. Download the macOS ZIP from [Releases](https://github.com/Enntity/tessera/releases).
   A draft or development candidate is not a notarized public download.
2. Expand the ZIP and drag `Tessera.app` to Applications **before** installing agent integrations.
3. Open Tessera. Grant Notifications if you want attention alerts. Accessibility is optional and
   used to position desktop agent windows. The iPhone link is off by default.
4. Open Settings → Agents → **Install Command, Skill & MCP**. Read its result; failures are shown.
5. Restart agent sessions so they discover the new skill and MCP server.

The installer links `~/.local/bin/tessera` to the bundled command, copies the skill to
`~/.agents/skills/tessera`, links it for Claude Code, and registers MCP for detected Claude Code
and Codex configurations. It preserves previous skills and configuration backups. Existing
Codex Tessera registration is retained. If you move the app later, run the installer again.
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

## Build from source

Install Xcode 26 with Swift 6, then from a checkout:

```sh
swift test
scripts/build-app.sh
open .build/app/Tessera.app
```

A local development signature is not a Developer ID distribution signature. Public release
signing and notarization are described in [releasing.md](releasing.md). If build caches contain
an old checkout path, set `TESSERA_SCRATCH_PATH` to a fresh folder for `build-app.sh`, or pass
`--scratch-path` to `swift test`.

## Optional services and removal

Fleet requires a separately configured LLooM head. Steward requires an inference endpoint;
neither is needed for local messages or questions. Configure those under Fleet and Agents.

To remove integrations, remove the Tessera MCP registration in your clients and the Tessera
symlinks and skill installed above. Preserve any skill backups you need. Deleting the app does
not delete its board or conversations. Tessera's state is under
`~/Library/Application Support/Tessera`; provider keys are in Keychain. Do not delete state just
to upgrade or reinstall.
