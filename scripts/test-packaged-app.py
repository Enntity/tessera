#!/usr/bin/env python3
"""Exercise the complete bundle in a disposable HOME; never replace the user's launchd service."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid

app = Path(sys.argv[1]).resolve()
cli = app / 'Contents/Helpers/tessera-cli'
node = app / 'Contents/Helpers/node'
accord = app / 'Contents/Resources/Accord/src/cli.mjs'

def eventually(check, timeout=60):
    end = time.monotonic() + timeout
    last = None
    while time.monotonic() < end:
        try:
            value = check()
            if value:
                return value
        except (OSError, ValueError, AssertionError) as error:
            last = error
        time.sleep(.2)
    raise AssertionError(f'Timed out: {last}')

def stop(proc):
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=12)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=10)

with tempfile.TemporaryDirectory(prefix='tessera-app-test-') as temporary:
    home = Path(temporary).resolve()
    data = home / 'Library/Application Support/Tessera'
    data.mkdir(parents=True)
    ids = ['package-demo-a', 'package-demo-b']
    (data / 'workspace.json').write_text(json.dumps({
        'tiles': [{'id': tile, 'kind': 'terminal', 'command': '/bin/cat', 'cwd': str(home)} for tile in ids],
        'order': ids, 'resumeOnLaunch': True,
    }))
    (home / '.codex').mkdir()
    (home / '.agents/skills/tessera').mkdir(parents=True)
    (home / '.agents/skills/tessera/SKILL.md').write_text('Old customized skill\n')
    env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home),
               XDG_CONFIG_HOME=str(home / '.config'), TESSERA_DATA_DIR=str(data),
               TESSERA_NO_AUTO_SETUP='1', PATH='/usr/bin:/bin')
    for name in ['DSH_HOME', 'CODEX_HOME', 'TESSERA_TILE_ID', 'TESSERA_AS', 'ACCORD_PROFILE',
                 'ACCORD_SESSION_FILE', 'ACCORD_CONTEXT_FILE', 'ACCORD_URL', 'ACCORD_DATA',
                 'CODEX_THREAD_ID', 'CLAUDE_SESSION_ID']:
        env.pop(name, None)
    def command(argv, code=0, extra=None):
        result = subprocess.run([str(v) for v in argv], env=dict(env, **(extra or {})),
                                text=True, capture_output=True, timeout=30)
        assert result.returncode == code, (argv[0:2], result.returncode, result.stderr, result.stdout)
        return result.stdout
    def run(*args, tile=ids[0], code=0):
        return command([cli, *args], code, {'TESSERA_TILE_ID': tile})

    run('install', '--dry-run')
    assert not (home / '.config/accord/connection.json').exists()
    run('install', '--no-start')
    assert not (home / '.agents/skills/tessera').exists()
    assert list((home / '.config/accord/retired-skills').glob('*/SKILL.md'))
    assert (home / '.agents/skills/accord/SKILL.md').exists()
    assert not (app / 'Contents/Resources/skills/tessera').exists()
    profile = home / '.config/accord/connection.json'
    (data / 'accord-connection.json').write_bytes(profile.read_bytes())
    p = json.loads(profile.read_text())
    host_data = Path(p['endpointFile']).parent
    # All execution paths point into the app. No system Node or sibling checkout is available.
    assert str(node) in (home / '.codex/config.toml').read_text()
    hostlog = (home / 'host.log').open('w')
    daemon = subprocess.Popen([str(node), str(accord), 'up', '--data', str(host_data), '--port', '0', '--driver-port', '0'],
                              env=env, stdout=hostlog, stderr=hostlog)
    try:
        endpoint = eventually(lambda: json.loads(Path(p['endpointFile']).read_text()))
        base = endpoint['coordinator']
        admin = (host_data / 'admin.token').read_text().strip()
        def request(path, credential=admin, body=None):
            raw = None if body is None else json.dumps(body).encode()
            req = urllib.request.Request(base + path, data=raw, headers={
                'Authorization': 'Bearer ' + credential, 'Content-Type': 'application/json'})
            with urllib.request.urlopen(req, timeout=6) as response:
                return json.load(response)
        def op(operation, args=None, credential=admin):
            return request('/v1/collaboration', credential, {'operation': operation, 'args': args or {}})
        agents = []
        for i, tile in enumerate(ids):
            session = home / f'agent-{i}.json'
            command([node, accord, 'session', 'open', '--label', f'Package agent {i}', '--session-file', session], extra={'TESSERA_TILE_ID': tile})
            agents.append(json.loads(session.read_text()))
        a, b = agents
        for i, agent in enumerate(agents):
            op('announce', {'key': str(uuid.uuid4()), 'label': f'Package agent {i}', 'activity': 'Testing packaged collaboration'}, agent['credential'])
        op('send', {'key': 'restart-message', 'to': p['authority'] + '/' + b['sessionId'], 'text': 'Package restart persistence check'}, a['credential'])
        question = op('ask', {'key': 'question', 'question': 'Package demo question?', 'options': ['Tests']}, a['credential'])
        op('notify', {'key': 'note', 'text': 'Package demo note'}, a['credential'])
        op('session-report', {'key': 'history', 'title': 'Packaged shared search marker', 'state': 'working',
                             'events': [{'key': 'event', 'kind': 'progress', 'text': 'History survives native app restart'}]}, a['credential'])
        token = None
        for launch in range(2):
            with (home / 'app.log').open('a') as log:
                start = time.monotonic()
                proc = subprocess.Popen([str(app / 'Contents/MacOS/Tessera'), '-ApplePersistenceIgnoreState', 'YES',
                                         '-tessera.agentAPI', 'YES', '-tessera.remoteEnabled', 'NO', '-tessera.privacy', 'NO'],
                                        env=env, stdout=log, stderr=log)
                try:
                    def native_ready():
                        assert proc.poll() is None, 'app exited'
                        current = json.loads((data / 'agent-api.json').read_text())
                        return current if current['pid'] == proc.pid else None
                    current = eventually(native_ready)
                    assert current['token'] != token
                    token = current['token']
                    assert all(tile in run('board') for tile in ids)
                    assert 'You are tile ' + ids[0] in run('whoami')
                    eventually(lambda: 'Package demo question?' in run('board') and 'Package demo note' in run('board'))
                    for old in ['send', 'inbox', 'ask', 'answer', 'notify', 'resources']:
                        run(old, code=1)
                    inbox = op('inbox', credential=b['credential'])['messages']
                    assert len(inbox) == 1 and inbox[0]['text'] == 'Package restart persistence check'
                    assert any(s['title'] == 'Packaged shared search marker' for s in op('sessions', {'query':'Packaged shared search marker'})['sessions'])
                    assert op('telemetry')['host'], 'bundled host supplies telemetry'
                    if launch == 1:
                        op('answer', {'key':'operator-answer', 'id':question['id'], 'answer':'Tests'})
                        assert op('question', {'id':question['id']}, a['credential'])['answer'] == 'Tests'
                        eventually(lambda: 'Package demo question?' not in run('board', '--waiting'))
                        op('read', {'deliveryId':inbox[0]['deliveryId']}, b['credential'])
                        assert op('inbox', credential=b['credential'])['messages'] == []
                    print(f'Launch {launch + 1}: native API ready in {time.monotonic()-start:.2f}s; canonical state verified.', flush=True)
                finally:
                    stop(proc)
    finally:
        stop(daemon)
        hostlog.close()
print('Packaged app passed: standalone bundled installation, one skill, two agents, discovery, native questions/notes, unread persistence, shared search, telemetry, restart and no legacy commands. launchd activation was not performed.')
