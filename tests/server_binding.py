#!/usr/bin/env python3
"""Approved regressions: operations bind the row's socket, PID and stable IDs."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

PLUGIN = Path(__file__).resolve().parents[1]
MOCK_TMUX = r'''#!/usr/bin/env python3
import json, os, shlex, sys
args = sys.argv[1:]
with open(os.environ['COMMAND_LOG'], 'a') as log:
    log.write(json.dumps(['tmux', args]) + '\n')
assert args[:2] == ['-S', '/tmp/selected.sock'], args
args = args[2:]
pid = os.environ.get('SERVER_PID', '42')
if args[0] == 'if-shell':
    assert args[1:3] == ['-F', '#{==:#{pid},42}'], args
    if os.environ.get('RESTART_IN_QUEUE'):
        print('midas.omalchemy: tmux server restarted; refresh first')
        sys.exit(0)
    args = shlex.split(args[3])
    with open(os.environ['COMMAND_LOG'], 'a') as log:
        log.write(json.dumps(['queued', args]) + '\n')
command = args[0]
if command == 'display-message':
    if os.environ.get('MISSING_PANE') and '-t' in args and args[args.index('-t')+1] == '%1':
        sys.exit(1)
    values = {'#{socket_path},#{pid},0': '/tmp/selected.sock,'+pid+',0',
              '#{pid}': pid, '#{session_id}\x1f#{session_name}': '$1\x1frenamed-agent',
              '#{pane_id}': '%1', '#{session_name}': 'renamed-agent', '#{session_id}': '$1'}
    print(values[args[-1]])
elif command == 'show-option':
    if args[-1] == '@agent_daemon_binary': print(os.environ['MOCK_DAEMON'])
elif command == 'list-clients':
    print('/dev/pts/test\t100\t99\t$1\trenamed-agent\t@1\t%1')
elif command not in ['has-session', 'switch-client', 'attach-session', 'set-option', 'display-popup']:
    raise AssertionError(args)
'''
MOCK_DAEMON = r'''#!/usr/bin/env python3
import json, os, sys
assert os.environ['TMUX'] == '/tmp/selected.sock,42,0'
assert sys.argv[1] == 'send'
assert json.loads(sys.argv[2]) == {'type':'Seen', 'pane_id':'%1'}
with open(os.environ['COMMAND_LOG'], 'a') as log:
    log.write(json.dumps(['daemon', sys.argv[1:]]) + '\n')
'''


def run(script, arguments, env):
    return subprocess.run(['bash', str(PLUGIN / script), *arguments], env=env,
                          text=True, capture_output=True, timeout=5)


def entries(log):
    return [json.loads(line) for line in log.read_text().splitlines()]


with tempfile.TemporaryDirectory(prefix='omalchemy-binding-') as directory:
    root = Path(directory)
    log = root / 'commands.jsonl'
    log.write_text('')
    for name, content in [('tmux', MOCK_TMUX), ('daemon', MOCK_DAEMON),
                          ('hyprctl', '#!/bin/sh\nexit 1\n'), ('notify-send', '#!/bin/sh\nexit 0\n')]:
        path = root / name
        path.write_text(content)
        path.chmod(0o755)
    env = dict(os.environ, PATH=str(root)+':'+os.environ['PATH'], TMUX='/tmp/wrong.sock,999,0',
               COMMAND_LOG=str(log), MOCK_DAEMON=str(root / 'daemon'))
    jump = ['/tmp/selected.sock', '42', '%1', '$1', 'old-session-name', '', '', '', '']
    for script, args in [('jump-agent.sh', jump), ('popup-agent.sh', ['/tmp/selected.sock', '42', '$1']),
                         ('attach-agent.sh', ['/tmp/selected.sock', '42', '%1', '$1'])]:
        log.write_text('')
        result = run(script, args, env)
        assert result.returncode == 0, result.stderr
        commands = entries(log)
        assert all(args[:2] == ['-S', '/tmp/selected.sock'] for kind, args in commands if kind == 'tmux')
        assert any(kind == 'queued' and ('switch-client' in args or 'attach-session' in args)
                   for kind, args in commands)
        if script == 'jump-agent.sh':
            assert any(kind == 'daemon' for kind, _ in commands)
        assert not any('old-session-name' in args for kind, args in commands if kind in ['tmux', 'queued'])
        log.write_text('')
        result = run(script, args, dict(env, SERVER_PID='43'))
        assert result.returncode != 0, 'stale PID must reject operations'
        assert all(kind == 'tmux' and 'display-message' in args for kind, args in entries(log))
    print('ok - jump, popup and Seen bind socket/PID and survive session rename without name targeting')
    log.write_text('')
    result = run('jump-agent.sh', jump, dict(env, MISSING_PANE='1'))
    assert result.returncode != 0
    assert not any(kind == 'daemon' or 'switch-client' in args or 'attach-session' in args
                   for kind, args in entries(log)), 'missing IDs must not fall back to names or indices'
    print('ok - deleted pane never falls back to a reusable target')
    log.write_text('')
    result = run('jump-agent.sh', jump, dict(env, RESTART_IN_QUEUE='1'))
    assert not any(kind == 'daemon' or kind == 'queued' for kind, _ in entries(log))
    print('ok - command-queue PID guard blocks a restart between validation and operation')
    log.write_text('')
    result = run('seen-agent.sh', ['/tmp/selected.sock', '42', '%1'], dict(env, SERVER_PID='43'))
    assert result.returncode != 0
    assert not any(kind == 'daemon' for kind, _ in entries(log))
    print('ok - delayed Seen and terminal attachment reject a replacement PID')
