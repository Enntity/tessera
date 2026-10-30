#!/usr/bin/env python3
"""Exercise the real CLI installer in a throwaway home; never touch user configuration."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

cli = Path(sys.argv[1]).resolve()
source = Path(__file__).resolve().parents[1] / "skills"
with tempfile.TemporaryDirectory(prefix="tessera-install-test-") as temporary:
    home = Path(temporary).resolve()
    env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home),
               PATH=str(home / ".local/bin") + ":/usr/bin:/bin")
    env.pop("TESSERA_SKILLS_DIR", None)
    # Packaged checks must use the shipped skills, not silently borrow from this checkout.
    if cli.parent.name != "Helpers":
        env["TESSERA_SKILLS_DIR"] = str(source)
    (home / ".local/bin").mkdir(parents=True)
    # Stub the optional client registration; it must never invoke a user's real client.
    claude = home / ".local/bin/claude"
    claude.write_text("#!/bin/sh\n"
                      "if [ \"$1\" = \"mcp\" ] && [ \"$2\" = \"get\" ]; then exit 1; fi\n"
                      "printf '%s\\n' \"$*\" >> \"$HOME/claude-calls\"\n")
    claude.chmod(0o755)
    # devin answers `mcp get` like a real one with nothing configured, and logs the rest.
    devin = home / ".local/bin/devin"
    devin.write_text("#!/bin/sh\n"
                     "if [ \"$1\" = \"mcp\" ] && [ \"$2\" = \"get\" ]; then exit 1; fi\n"
                     "printf '%s\\n' \"$*\" >> \"$HOME/devin-calls\"\n")
    devin.chmod(0o755)
    (home / ".codex").mkdir()
    config = home / ".codex/config.toml"
    config.write_text('model = "existing-model"\n')
    skill = home / ".agents/skills/tessera"
    skill.mkdir(parents=True)
    (skill / "SKILL.md").write_text("local customization to preserve\n")

    def run(*args):
        return subprocess.run([str(cli), *args], env=env, capture_output=True, text=True, timeout=30)

    preview = run("install", "--dry-run")
    assert preview.returncode == 0, preview.stderr
    # Refuse all writes if Foundation did not honor the isolated home.
    reported = preview.stdout.splitlines()[0].removeprefix("would: link ").split(" → ")[0]
    assert Path(reported).resolve() == home / ".local/bin/tessera", preview.stdout
    assert not (home / ".local/bin/tessera").exists()
    assert not (home / "claude-calls").exists()
    assert not (home / "devin-calls").exists()
    installed = run("install")
    assert installed.returncode == 0, installed.stdout + installed.stderr
    assert (home / ".local/bin/tessera").resolve() == cli
    assert "resources" in (skill / "SKILL.md").read_text()
    backups = list(skill.parent.glob("tessera.backup-*"))
    assert any("local customization" in (p / "SKILL.md").read_text() for p in backups)
    assert (home / ".claude/skills/tessera").resolve() == skill
    assert config.read_text().startswith('model = "existing-model"')
    assert config.read_text().count("[mcp_servers.tessera]") == 1
    assert list(config.parent.glob("config.toml.bak-tessera-*"))
    again = run("install")
    assert again.returncode == 0, again.stderr
    assert config.read_text().count("[mcp_servers.tessera]") == 1
    assert "mcp add --scope user tessera --" in (home / "claude-calls").read_text()
    assert "mcp add --scope user tessera --" in (home / "devin-calls").read_text()
    # Once Devin answers `mcp get`, its configuration is left alone.
    devin.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$HOME/devin-calls\"\nexit 0\n")
    rerun = run("install")
    assert rerun.returncode == 0, rerun.stdout + rerun.stderr
    assert "leave Devin" in rerun.stdout
    # The two earlier installs added it; an answered `mcp get` adds nothing more.
    assert (home / "devin-calls").read_text().count("mcp add") == 2
    # An existing Claude registration may be customized or project-scoped. Never remove it.
    claude.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$HOME/claude-calls\"\nexit 0\n")
    additions = (home / "claude-calls").read_text().count("mcp add")
    preserved = run("install")
    assert preserved.returncode == 0, preserved.stdout + preserved.stderr
    assert "leave Claude Code" in preserved.stdout
    calls = (home / "claude-calls").read_text()
    assert calls.count("mcp add") == additions
    assert "mcp remove" not in calls
    # A real command must not be overwritten or silently treated as our integration.
    link = home / ".local/bin/tessera"
    link.unlink()
    link.write_text("user command")
    refused = run("install")
    assert refused.returncode != 0
    assert link.read_text() == "user command"
    assert "existing file" in refused.stderr
print("Installer checks passed: dry-run, isolated setup, preserved custom skill/config, repeat install, conflict refusal.")
