#!/usr/bin/env python3
"""Race the bundled macOS CLI against a fresh, private, account-free container.

Usage: python3 Scripts/qa/cli-runtime-ownership.py /path/to/Mailternal.app
No production container, account credentials, or GUI session is used.
"""
import concurrent.futures
import json
import os
import pathlib
import plistlib
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time


def verify(bundle, root):
    home = root / 'isolated-home'
    home.mkdir(mode=0o700)
    environment = dict(os.environ, CFFIXED_USER_HOME=str(home))
    for key in ('MAILTERNAL_PASSWORD', 'MAILTERNAL_TOKEN', 'MAILTERNAL_BEARER_TOKEN', 'MAILTERNAL_TLS_FINGERPRINT'):
        environment.pop(key, None)
    with (bundle / 'Contents/Info.plist').open('rb') as handle:
        executable = plistlib.load(handle)['CFBundleExecutable']
    app = str(bundle / 'Contents/MacOS' / executable)
    base = [str(bundle / 'Contents/MacOS/mailternal'), '--container', str(root), '--app', str(bundle)]
    prefix = app + ' --mailternal-engine --mailternal-container '
    pattern = '^' + re.escape(prefix) + '.*' + re.escape('/' + root.name) + '$'

    def run(arguments):
        completed = subprocess.run(base + arguments, env=environment, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, timeout=30)
        response = json.loads(completed.stdout)
        assert completed.returncode == 0, (arguments, response.get('error'), completed.returncode)
        assert response['schema'] == 'mailternal.cli.result.v1' and response['ok']
        return response['result']

    def pids():
        completed = subprocess.run(['pgrep', '-fl', pattern], stdout=subprocess.PIPE, timeout=5,
                                   text=True)
        assert completed.returncode in (0, 1)
        # Foundation may canonicalize /private/tmp back to /tmp. Compare the
        # resolved container, not its spelling, before asserting or terminating.
        matches = set()
        for line in completed.stdout.splitlines():
            pid, _, command = line.partition(' ')
            if command.startswith(prefix) and pathlib.Path(command[len(prefix):]).resolve() == root:
                matches.add(int(pid))
        return matches

    def wait_for_processes(expected):
        deadline = time.monotonic() + 5
        while True:
            alive = pids()
            if alive == expected:
                return
            assert time.monotonic() < deadline, ('unexpected isolated headless processes', alive, expected)
            time.sleep(0.05)

    assert run(['--no-start', 'engine', 'status'])['state'] == 'not-running'
    barrier = threading.Barrier(2)

    def start():
        barrier.wait(timeout=5)
        return run(['engine', 'start'])

    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            starts = list(pool.map(lambda _: start(), range(2)))
        assert all(value['state'] == 'running' for value in starts)
        runtime = run(['--no-start', 'engine', 'status'])
        assert runtime['kind'] == 'daemon' and runtime['ready']
        wait_for_processes({runtime['processID']})
        print('PASS concurrent CLI starts converge on one live headless owner', flush=True)
        run(['--no-start', 'engine', 'stop'])
        wait_for_processes(set())
        print('PASS stopping the owner leaves no headless process behind', flush=True)
    finally:
        # This exact command line can only belong to this temporary container.
        # Clean up even a failed implementation without hiding its failed assertion.
        for pid in pids():
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        wait_for_processes(set())


if __name__ == '__main__':
    if sys.platform != 'darwin' or len(sys.argv) != 2:
        raise SystemExit('Run on macOS: cli-runtime-ownership.py /path/to/Mailternal.app')
    with tempfile.TemporaryDirectory(prefix='mailternal-runtime-qa-') as directory:
        verify(pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(directory).resolve())
