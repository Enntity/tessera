#!/usr/bin/env python3
"""Smoke-test a packaged app in a disposable home on a logged-in macOS desktop.

No UI activation is used to make startup pass. This catches a regression where the
agent server started only after the board's SwiftUI onAppear callback.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

app = Path(sys.argv[1]).resolve()
cli = app / "Contents/Helpers/tessera-cli"
with tempfile.TemporaryDirectory(prefix="tessera-app-test-") as temporary:
    home = Path(temporary).resolve()
    data = home / "Library/Application Support/Tessera"
    data.mkdir(parents=True)
    ids = ["package-demo-a", "package-demo-b"]
    (data / "workspace.json").write_text(json.dumps({
        "tiles": [{"id": tile, "kind": "terminal", "command": "/bin/cat", "cwd": str(home)} for tile in ids],
        "order": ids, "resumeOnLaunch": True,
    }))
    env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home),
               TESSERA_DATA_DIR=str(data), PATH="/usr/bin:/bin")
    for name in ["DSH_HOME", "CODEX_HOME", "TESSERA_TILE_ID", "TESSERA_AS"]:
        env.pop(name, None)
    preview = subprocess.run([str(cli), "install", "--dry-run"], env=env,
                             text=True, capture_output=True, check=True, timeout=15)
    reported = preview.stdout.splitlines()[0].removeprefix("would: link ").split(" → ")[0]
    assert Path(reported).resolve() == home / ".local/bin/tessera", preview.stdout

    def run(*args, tile=ids[0], code=0):
        result = subprocess.run([str(cli), *args], env=dict(env, TESSERA_TILE_ID=tile),
                                text=True, capture_output=True, timeout=15)
        assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
        return result.stdout

    token = None
    for launch in range(2):
        with (home / "app.log").open("a") as log:
            start = time.monotonic()
            proc = subprocess.Popen([str(app / "Contents/MacOS/Tessera"),
                                     "-ApplePersistenceIgnoreState", "YES", "-tessera.agentAPI", "YES",
                                     "-tessera.remoteEnabled", "NO", "-tessera.privacy", "NO"],
                                    env=env, stdout=log, stderr=log)
            try:
                endpoint = data / "agent-api.json"
                while True:
                    assert proc.poll() is None, "app exited before starting the agent API"
                    try:
                        current = json.loads(endpoint.read_text())
                        if current["pid"] == proc.pid:
                            break
                    except (FileNotFoundError, json.JSONDecodeError):
                        pass
                    assert time.monotonic() - start < 15, "agent API did not start without UI interaction"
                    time.sleep(0.1)
                elapsed = time.monotonic() - start
                assert endpoint.stat().st_mode & 0o777 == 0o600
                assert current["token"] != token, "restart must replace the endpoint credential"
                token = current["token"]
                assert all(tile in run("board") for tile in ids)
                assert "You are tile " + ids[0] in run("whoami")
                if launch == 0:
                    assert "inbox" in run("send", ids[1], "Package restart persistence check")
                    assert "not configured" in run("resources")
                    assert "Question id:" in run("ask", "Package demo question?", "--option", "Tests", "--wait", "0", code=2)
                    run("notify", "Package demo note")
                else:
                    assert "Package restart persistence check" in run("inbox", tile=ids[1])
                    assert "No messages" in run("inbox", tile=ids[1])
                print(f"Launch {launch + 1}: API ready in {elapsed:.2f}s without UI interaction; checks passed.", flush=True)
            finally:
                proc.terminate()
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=10)
print("Packaged app passed: startup, restart, restored terminals, identity, durable inbox, resources, question, note.")
