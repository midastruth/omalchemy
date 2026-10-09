#!/usr/bin/env python3
"""Verify the guarded tmux queue and asynchronous attachment on a real server."""
import fcntl
import json
import os
from pathlib import Path
import pty
import subprocess
import tempfile
import termios
import time

PLUGIN = Path(__file__).resolve().parents[1]


def wait(predicate):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.02)
    raise AssertionError('real tmux operation did not converge')


with tempfile.TemporaryDirectory(prefix='omalchemy-operations-') as directory:
    root = Path(directory)
    socket = str(root / 'tmux.sock')
    env = dict(os.environ, TERM='xterm-256color', TMUX='/tmp/wrong.sock,999,0')

    def tmux(*args):
        return subprocess.check_output(['tmux', '-S', socket, *args], env=env,
                                       text=True, timeout=5).strip()

    tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'target', 'sleep 120')
    pid = tmux('display-message', '-p', '#{pid}')
    pane = tmux('display-message', '-p', '#{pane_id}')
    session = tmux('display-message', '-p', '#{session_id}')
    master, slave = pty.openpty()
    attachment = None
    try:
        # A true command queued for the wrong PID must not touch options.
        script = '. "$1/server.sh"; server_socket="$2"; server_pid="$3"; tmux_server set-option -g @guarded unsafe'
        result = subprocess.run(['bash', '-c', script, 'bash', str(PLUGIN), socket, str(int(pid)+1)],
                                env=env, text=True, capture_output=True, timeout=5)
        assert result.returncode != 0
        assert tmux('show-option', '-gqv', '@guarded') == ''
        script = '. "$1/server.sh"; bind_tmux_server "$2" "$3" && tmux_server set-option -g @guarded "$4"'
        expected = "quoted 'value'; not a command"
        result = subprocess.run(['bash', '-c', script, 'bash', str(PLUGIN), socket, pid, expected],
                                env=env, text=True, capture_output=True, timeout=5)
        assert result.returncode == 0, result.stderr
        assert tmux('show-option', '-gqv', '@guarded') == expected
        log = root / 'seen.json'
        daemon = root / 'daemon'
        daemon.write_text('#!/usr/bin/env python3\nimport json,os,sys\n'
                          'assert sys.argv[1] == "send"\n'
                          f'open({str(log)!r}, "w").write(json.dumps([os.environ["TMUX"], json.loads(sys.argv[2])]))\n')
        daemon.chmod(0o755)
        tmux('set-option', '-g', '@agent_daemon_binary', str(daemon))

        def terminal_session():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        attachment = subprocess.Popen(['bash', str(PLUGIN / 'attach-agent.sh'), socket, pid, pane, session],
                                      env=env, stdin=slave, stdout=slave, stderr=slave,
                                      preexec_fn=terminal_session)
        wait(lambda: tmux('list-clients', '-F', '#{pane_id}') == pane)
        wait(log.exists)
        assert json.loads(log.read_text()) == [f'{socket},{pid},0', {'type': 'Seen', 'pane_id': pane}]
        tmux('detach-client', '-s', session)
        attachment.wait(timeout=5)
        assert attachment.returncode == 0
        print('ok - real tmux queue quotes values safely and terminal attachment reports Seen only after attaching')
    finally:
        if attachment is not None and attachment.poll() is None:
            attachment.terminate()
            attachment.wait(timeout=5)
        os.close(master)
        os.close(slave)
        subprocess.run(['tmux', '-S', socket, 'kill-server'], env=env,
                       capture_output=True, timeout=5)
