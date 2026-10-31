"""Install Happen's release, stopping the old app before replacement."""
import argparse
import fcntl
import os
from pathlib import Path
import signal
import shutil
import subprocess
import tempfile
import time

import run_flutter

ROOT = run_flutter.ROOT
APP = run_flutter.APP
RELEASE = ROOT / 'build/macos/Build/Products/Release' / APP
REGISTER = Path('/System/Library/Frameworks/CoreServices.framework/Frameworks/'
    'LaunchServices.framework/Support/lsregister')


def run(*command):
    subprocess.run([str(arg) for arg in command], cwd=ROOT, check=True)


def verify(bundle):
    info = run_flutter.bundle_info(bundle)
    required = ['MacOS/' + info['CFBundleExecutable'],
        'Frameworks/App.framework/App', 'Frameworks/FlutterMacOS.framework/FlutterMacOS',
        'Frameworks/sqlite3.framework/sqlite3', 'Frameworks/code_mode.framework/code_mode',
        'Resources/AppIcon.icns']
    for relative in required:
        if not (bundle / 'Contents' / relative).is_file():
            raise RuntimeError(f'Incomplete release bundle: missing {relative}')
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', bundle)


def release_pids(bundle):
    executable = bundle / 'Contents/MacOS' / run_flutter.bundle_info(bundle)['CFBundleExecutable']
    return [pid for pid, command in run_flutter.processes('pid=,comm=')
        if Path(command) == executable]


def require_stopped(bundle):
    pids = release_pids(bundle)
    if pids:
        raise RuntimeError(f'Release still running as PID(s) {pids}; no bundle was replaced.')


def stop_release(bundle, pids):
    print(f'Stopping release PID(s): {pids}', flush=True)
    for pid in pids:
        # Recheck the full executable path before signalling a possibly reused
        # PID. The debug app and other applications are never terminated here.
        if pid not in release_pids(bundle):
            continue
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 15
    while release_pids(bundle):
        if time.monotonic() >= deadline:
            require_stopped(bundle)
        time.sleep(0.1)
    print('Release app process exited.', flush=True)


def install(applications):
    verify(RELEASE)
    applications = applications.expanduser().resolve()
    applications.mkdir(parents=True, exist_ok=True)
    destination = applications / APP
    if destination == RELEASE:
        raise RuntimeError('The installation destination must differ from the build output')
    if destination.is_symlink():
        raise RuntimeError(f'Refusing to replace a symlink: {destination}')
    temporary = Path(tempfile.mkdtemp(prefix='.happen-install-', dir=applications))
    staged, previous = temporary / APP, temporary / 'previous.app'
    succeeded = False
    try:
        run('/usr/bin/ditto', RELEASE, staged)
        verify(staged)
        # Serialize process inspection and replacement with other local tooling.
        with (run_flutter.RUN / 'launch.lock').open('a') as launch_lock:
            fcntl.flock(launch_lock, fcntl.LOCK_EX)
            if len(run_flutter.app_pids('release')) > 1 or len(run_flutter.flutter_pids('release')) > 1:
                raise RuntimeError('Multiple release app/supervisor processes exist; refusing to reinstall.')
            if destination.exists():
                pids = release_pids(destination)
                if pids:
                    stop_release(destination, pids)
                require_stopped(destination)
                destination.rename(previous)
            try:
                staged.rename(destination)
                verify(destination)
            except BaseException:
                if destination.exists():
                    destination.rename(staged)
                if previous.exists():
                    previous.rename(destination)
                raise
        succeeded = True
        result = subprocess.run([str(REGISTER), '-f', str(destination)])
        if result.returncode:
            print('Installed successfully; Launch Services registration could not be refreshed.')
        print(f'Installed release: {destination}', flush=True)
    finally:
        if succeeded or not previous.exists():
            shutil.rmtree(temporary)
        else:
            print(f'Previous installation retained at {previous}', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--applications-dir', type=Path, default=Path('/Applications'))
    args = parser.parse_args()
    run_flutter.RUN.mkdir(parents=True, exist_ok=True)
    lock = os.open(run_flutter.RUN / 'release-reinstall.lock', os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        install(args.applications_dir)
    finally:
        os.close(lock)


if __name__ == '__main__':
    main()
