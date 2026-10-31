"""Launch or reuse one Happen debug desktop instance."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
RUN = ROOT.parent.parent / '.local/run'
APP = 'Happen.app'
BUNDLE_ID = 'com.adelnz.happen'


def processes(columns):
    result = subprocess.run(['ps', '-axo', columns], check=True, capture_output=True, text=True)
    rows = []
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2:
            rows.append((int(parts[0]), parts[1]))
    return rows


def app_pids(mode):
    found = []
    debug = ROOT / 'build/macos/Build/Products/Debug' / APP / 'Contents/MacOS/Happen'
    for pid, command in processes('pid=,comm='):
        executable = Path(command)
        if executable.name != 'Happen':
            continue
        if mode == 'debug' and executable == debug:
            found.append(pid)
        elif mode == 'release' and not any(command.endswith(
            f'/Build/Products/{configuration}/{APP}/Contents/MacOS/Happen')
            for configuration in ('Debug', 'Profile')):
            found.append(pid)
    return found


def flutter_pids(mode):
    found = []
    for pid, command in processes('pid=,command='):
        try:
            arguments = shlex.split(command)
        except ValueError:
            continue
        # Include Flutter's shell entrypoint while it is still starting, before
        # it execs the snapshot. A second launch must also reuse that process.
        entry = next((index for index, argument in enumerate(arguments)
            if Path(argument).name in ('flutter', 'flutter_tools.snapshot', 'flutter_tools.dart')), None)
        if entry is None or 'run' not in arguments[entry + 1:]:
            continue
        selected = 'release' if '--release' in arguments else 'debug'
        if selected != mode:
            continue
        cwd = subprocess.run(['lsof', '-a', '-p', str(pid), '-d', 'cwd', '-Fn'],
            capture_output=True, text=True)
        if any(f'n{directory}' in cwd.stdout.splitlines() for directory in (ROOT, ROOT.parent.parent)):
            found.append(pid)
    return found


def bundle_info(bundle):
    with (bundle / 'Contents/Info.plist').open('rb') as source:
        info = plistlib.load(source)
    if info.get('CFBundleIdentifier') != BUNDLE_ID or info.get('CFBundleExecutable') != 'Happen':
        raise RuntimeError(f'Refusing a bundle with a different application identity: {bundle}')
    return info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--status', action='store_true', help='Inspect without launching anything')
    args = parser.parse_args()
    mode = 'debug'
    RUN.mkdir(parents=True, exist_ok=True)
    lock = os.open(RUN / 'launch.lock', os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        apps, supervisors = app_pids(mode), flutter_pids(mode)
        if len(apps) > 1 or len(supervisors) > 1:
            print(json.dumps({'error': 'Multiple existing instances; stop extras before continuing',
                'mode': mode, 'app_pids': apps, 'flutter_pids': supervisors}))
            return 2
        if args.status or apps or supervisors:
            value = {'mode': mode, 'reused': not args.status and bool(apps or supervisors),
                'app_pids': apps, 'flutter_pids': supervisors}
            metadata = RUN / 'supervisor.json'
            if metadata.exists():
                with metadata.open() as source:
                    managed = json.load(source)
                if managed.get('pid') in supervisors:
                    value.update(managed)
            print(json.dumps(value), flush=True)
            if args.status:
                return 0
        else:
            flutter = shutil.which('flutter')
            if flutter is None:
                raise RuntimeError('Flutter is not on PATH')
            value = {'pid': os.getpid(), 'mode': mode, 'cwd': str(ROOT)}
            pending = RUN / 'supervisor.json.tmp'
            fd = os.open(pending, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
            with os.fdopen(fd, 'w') as output:
                json.dump(value, output)
            os.replace(pending, RUN / 'supervisor.json')
            print(json.dumps(value), flush=True)
            os.chdir(ROOT)
            # exec preserves the terminal and exit status. The non-inheritable
            # lock closes only once Flutter's discoverable entrypoint replaces us.
            os.execv(flutter, [flutter, 'run', '-d', 'macos', '--debug', '--hot', '--no-pub', '--print-dtd'])
    finally:
        os.close(lock)

    # Reusing a session must also keep the Moon task open. Its original terminal
    # retains Flutter's input and output; --status remains a one-shot inspection.
    existing = set(supervisors or apps)
    try:
        while any(pid in existing and not state.startswith('Z') for pid, state in processes('pid=,stat=')):
            time.sleep(0.25)
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
