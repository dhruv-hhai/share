#!/usr/bin/env python3
"""Record real sync commands in isolated homes; requires croc on PATH."""
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[2]
OUT = Path(__file__).with_name('sync-session.json')
work = Path(tempfile.mkdtemp(prefix='share-readme-'))
secret = secrets.token_hex(24)
port = int(os.environ.get('DEMO_RELAY_PORT', '49139'))
envs = []
events = []
relay = None

def run(side, command, record=True):
    result = subprocess.run(['bash', '--noprofile', '--norc', '-c', command],
                            cwd=work / side, env=envs['ab'.index(side)],
                            text=True, capture_output=True, timeout=20)
    if result.returncode:
        raise RuntimeError(result.stderr + result.stdout)
    if record:
        output = (result.stdout + result.stderr).replace(str(work / side), '~')
        events.append({'side': side, 'command': command, 'output': output.strip()})
    return result

def wait_content(path, expected):
    for _ in range(90):
        if path.exists() and path.read_text() == expected:
            return
        time.sleep(1)
    raise RuntimeError(f'Timed out waiting for {path}')

try:
    for side in 'ab':
        home = work / side
        for directory in ('notes', 'tmp', 'config'):
            (home / directory).mkdir(parents=True)
        envs.append(dict(os.environ, HOME=str(home), TMPDIR=str(home / 'tmp'),
                         XDG_CONFIG_HOME=str(home / 'config'),
                         PATH=f'{REPO}:{os.environ["PATH"]}',
                         SHARE_SECRET_DEMO_BOB=secret, SHARE_SECRET_DEMO_ALICE=secret,
                         SHARE_AUTO_UPDATE='0', SHARE_FOLLOW_EVERY='3600',
                         SHARE_SYNC_HEARTBEAT='5', SHARE_DISK_RESERVE_MB='64',
                         CROC_RELAY=f'localhost:{port}'))
    with (work / 'relay.log').open('w') as log:
        relay = subprocess.Popen(['croc', 'relay', '--ports', f'{port},{port+1}'],
                                 stdout=log, stderr=log)
        time.sleep(1)
        if relay.poll() is not None:
            raise RuntimeError('Relay failed to start; choose DEMO_RELAY_PORT')
        run('a', 'share sync --friend demo-bob --role a --dir ~/notes')
        run('b', 'share sync --friend demo-alice --role b --dir ~/notes')
        run('a', "echo 'Tea at 4?' > ~/notes/plan.txt")
        wait_content(work / 'b/notes/plan.txt', 'Tea at 4?\n')
        run('b', 'cat ~/notes/plan.txt')
        run('b', "echo 'See you at 4!' >> ~/notes/plan.txt")
        wait_content(work / 'a/notes/plan.txt', 'Tea at 4?\nSee you at 4!\n')
        run('a', 'cat ~/notes/plan.txt')
        assert (work / 'a/notes/plan.txt').read_bytes() == (work / 'b/notes/plan.txt').read_bytes()
        OUT.write_text(json.dumps({'note': 'Real commands and output; isolated homes, pre-paired demo friends, local croc relay. Home paths abbreviated; waits omitted.', 'events': events}, indent=2) + '\n')
        print(f'Recorded and verified both directions: {OUT}')
finally:
    for side, friend in [('a', 'demo-bob'), ('b', 'demo-alice')]:
        if len(envs) > 'ab'.index(side):
            try:
                run(side, f'share sync stop --friend {friend}', record=False)
            except (RuntimeError, subprocess.TimeoutExpired):
                pass
    if relay is not None:
        relay.terminate()
        relay.wait(timeout=10)
    shutil.rmtree(work)
