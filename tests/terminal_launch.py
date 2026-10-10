#!/usr/bin/env python3
"""Desktop regression: jump to a detached agent through the real terminal launcher.

Briefly opens an isolated test terminal; never touches the user's tmux server.
Requires a running Omarchy desktop and omarchy-launch-terminal.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

PLUGIN = Path(__file__).resolve().parents[1]


def wait(predicate):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError('desktop terminal did not attach and report Seen')


with tempfile.TemporaryDirectory(prefix='omalchemy-terminal-') as directory:
    root = Path(directory)
    socket = str(root / 'tmux.sock')
    env = dict(os.environ)
    env.pop('TMUX', None)

    def tmux(*args):
        return subprocess.check_output(['tmux', '-S', socket, *args], env=env,
                                       text=True, timeout=5).strip()

    tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'detached-agent', 'sleep 120')
    try:
        pid = tmux('display-message', '-p', '#{pid}')
        pane = tmux('display-message', '-p', '#{pane_id}')
        session = tmux('display-message', '-p', '#{session_id}')
        seen = root / 'seen.json'
        daemon = root / 'daemon'
        daemon.write_text('#!/usr/bin/env python3\nimport json,os,sys\n'
                          'assert sys.argv[1] == "send"\n'
                          f'open({str(seen)!r}, "w").write(json.dumps([os.environ["TMUX"], json.loads(sys.argv[2])]))\n')
        daemon.chmod(0o755)
        tmux('set-option', '-g', '@agent_daemon_binary', str(daemon))
        assert tmux('list-clients') == ''
        subprocess.run(['bash', str(PLUGIN / 'jump-agent.sh'), socket, pid, pane,
                        session, 'detached-agent'], env=env, check=True,
                       capture_output=True, text=True, timeout=5)
        wait(lambda: tmux('list-clients', '-F', '#{pane_id}') == pane and seen.exists())
        assert json.loads(seen.read_text()) == [f'{socket},{pid},0',
                                               {'type': 'Seen', 'pane_id': pane}]
        tmux('detach-client', '-s', session)
        wait(lambda: tmux('list-clients') == '')
        print('ok - real desktop launcher preserves the session identity, attaches and reports Seen')
    finally:
        subprocess.run(['tmux', '-S', socket, 'kill-server'], env=env,
                       capture_output=True, timeout=5)
