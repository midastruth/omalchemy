#!/usr/bin/env python3
"""Real Quickshell file-reader regressions, including atomic replacement."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

PLUGIN = Path(__file__).resolve().parents[1]


def wait(log, needle):
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        if needle in log.read_text():
            return
        time.sleep(0.03)
    raise AssertionError(f"missing {needle!r}\n{log.read_text()}")


def atomic(path, document):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(document))
    temporary.replace(path)


with tempfile.TemporaryDirectory(prefix='omalchemy-files-') as directory:
    root = Path(directory)
    socket = '/tmp/display-only.sock'
    socket_hash = 0xcbf29ce484222325
    for byte in socket.encode():
        socket_hash = ((socket_hash ^ byte) * 0x100000001b3) & ((1 << 64)-1)
    source_path = root / f'.cache/tmux-argos/sources/{socket_hash:016x}.json'
    state_path = root / 'state.json'
    qml = root / 'shell.qml'
    qml.write_text('''import QtQuick
import Quickshell
import "''' + PLUGIN.as_uri() + '''" as Plugin
Scope {
    Plugin.Main {
        id: model
        settings: ({ tmuxSocket: "/tmp/display-only.sock", pollIntervalMs: 1000, notifications: false })
    }
    Timer {
        interval: 100
        running: true
        repeat: true
        onTriggered: console.log("SAMPLE", model.source ? model.source.serverPid : 0,
            model.agents.length, model.agents.length ? model.agents[0].serverPid : 0)
    }
}
''')
    log = root / 'quickshell.log'
    commands = root / 'commands.log'
    commands.write_text('')
    binary_dir = root / 'bin'
    binary_dir.mkdir()
    for name in ['tmux', 'tmux-argos-state-daemon']:
        path = binary_dir / name
        path.write_text('#!/bin/sh\necho "unexpected command" >>"$COMMAND_LOG"\nexit 1\n')
        path.chmod(0o755)
    env = dict(os.environ, HOME=str(root), QT_QPA_PLATFORM='offscreen',
               PATH=str(binary_dir)+':'+os.environ['PATH'], COMMAND_LOG=str(commands))
    with log.open('w') as output:
        process = subprocess.Popen(['quickshell', '--no-color', '-p', str(qml)], env=env,
                                   stdout=output, stderr=subprocess.STDOUT)
        try:
            wait(log, 'SAMPLE 0 0 0')
            source = {'serverSocket': socket, 'serverPid': 42, 'stateFile': str(state_path)}
            snapshot = {'serverSocket': socket, 'serverPid': 42, 'panes': [
                {'agent': 'pi', 'paneId': '%1', 'sessionId': '$1', 'agentState': 'working'}]}
            atomic(state_path, snapshot)
            atomic(source_path, source)
            wait(log, 'SAMPLE 42 1 42')
            # Keep the same custom path, but leave the old PID in the snapshot.
            atomic(source_path, dict(source, serverPid=43))
            wait(log, 'SAMPLE 43 0 0')
            atomic(state_path, dict(snapshot, serverPid=43))
            wait(log, 'SAMPLE 43 1 43')
            atomic(source_path, dict(source, serverPid=43, stateFile=None))
            # Reset the log so an earlier empty sample cannot satisfy this step.
            time.sleep(0.2)
            assert 'SAMPLE 43 0 0' in log.read_text().split('SAMPLE 43 1 43')[-1]
            source_path.unlink()
            time.sleep(1.2)
            assert 'SAMPLE 0 0 0' in log.read_text().split('SAMPLE 43 1 43')[-1]
            assert commands.read_text() == '', 'display must not invoke tmux or daemon'
            assert 'Failed to load configuration' not in log.read_text()
            print('ok - real FileView handles late creation, atomic PID change, null exposure and source removal without tmux')
        finally:
            process.terminate()
            process.wait(timeout=5)
