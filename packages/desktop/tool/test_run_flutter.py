"""Exercise the launcher CLI with real processes, locks, and a local Flutter stand-in."""
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


@unittest.skipUnless(sys.platform == 'darwin', 'The desktop launcher targets macOS')
class LauncherTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='happen-launch-')
        checkout = Path(self.temporary.name).resolve() / 'checkout with spaces'
        self.desktop = checkout / 'packages/desktop'
        tool = self.desktop / 'tool'
        tool.mkdir(parents=True)
        self.launcher = tool / 'run_flutter.py'
        # Give fixtures their own app identity so the real desktop can stay open.
        self.app_name = 'Happen-' + Path(self.temporary.name).name
        self.launcher.write_text(Path(__file__).with_name('run_flutter.py').read_text().replace(
            "APP = 'Happen.app'", f"APP = '{self.app_name}.app'"))
        config = self.desktop / 'macos/Runner/Configs/AppInfo.xcconfig'
        config.parent.mkdir(parents=True)
        config.write_text(f'PRODUCT_NAME = {self.app_name}\nPRODUCT_BUNDLE_IDENTIFIER = com.adelnz.happen\n')
        binaries = checkout / 'bin'
        binaries.mkdir()
        self.flutter = binaries / 'flutter'
        self.flutter.write_text(r'''#!/usr/bin/env python3
import os
from pathlib import Path
import signal
import sys
import time
with Path(__file__).with_name("starts").open("a") as output:
    output.write(str(os.getpid()) + "\n")
# Keep the shell-entrypoint identity throughout startup, before any VM exists.
time.sleep(0.3)
while True:
    command = os.read(0, 1)
    if not command:
        signal.pause()
    elif command == b"q":
        break
    elif command == b"x":
        sys.exit(42)
    else:
        os.write(1, b"received:" + command + b"\n")
''')
        self.flutter.chmod(0o700)
        self.environment = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ['PATH'],
            TMPDIR=self.temporary.name)
        self.direct = []

    def tearDown(self):
        for pid in self.starts():
            command = subprocess.run(['ps', '-p', str(pid), '-o', 'command='],
                capture_output=True, text=True).stdout
            if str(self.flutter) in command:
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        for child in self.direct:
            if child.poll() is None:
                child.terminate()
            child.wait(timeout=5)
            for stream in (child.stdin, child.stdout, child.stderr):
                if stream is not None:
                    stream.close()
        self.temporary.cleanup()

    def starts(self):
        trace = self.flutter.with_name('starts')
        return [int(line) for line in trace.read_text().splitlines()] if trace.exists() else []

    def status(self):
        result = subprocess.run([sys.executable, str(self.launcher), '--status'],
            cwd=self.desktop, env=self.environment, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def launch(self, *arguments, launcher=None):
        launcher = launcher or self.launcher
        child = subprocess.Popen([sys.executable, str(launcher), *arguments],
            cwd=launcher.parent.parent, env=self.environment, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        self.direct.append(child)
        return child, json.loads(self.read_line(child))

    def read_line(self, child):
        self.assertTrue(select.select([child.stdout], [], [], 10)[0], 'Timed out waiting for output')
        return child.stdout.readline()

    def send(self, child, command):
        child.stdin.write(command)
        child.stdin.flush()

    def run_launcher(self, *arguments):
        result = subprocess.run([sys.executable, str(self.launcher), *arguments],
            cwd=self.desktop, env=self.environment, capture_output=True, text=True, timeout=10)
        return result.returncode, json.loads(result.stdout)

    def wait_for(self, predicate):
        deadline = time.monotonic() + 5
        while not predicate():
            if time.monotonic() >= deadline:
                self.fail('Timed out waiting for the owned process')
            time.sleep(0.02)

    def start_app(self, configuration):
        executable = (Path(self.temporary.name).resolve() / configuration /
            (self.app_name + '.app') / 'Contents/MacOS' / self.app_name)
        executable.parent.mkdir(parents=True)
        # A native sleeper exposes the app's full executable path in macOS ps.
        subprocess.run(['cc', '-x', 'c', '-o', str(executable), '-'],
            input='#include <unistd.h>\nint main(void) { pause(); return 0; }\n',
            check=True, capture_output=True, text=True)
        child = subprocess.Popen([str(executable)])
        self.direct.append(child)
        self.wait_for(lambda: str(executable) in subprocess.run(
            ['ps', '-p', str(child.pid), '-o', 'comm='],
            capture_output=True, text=True).stdout)
        return child

    def test_concurrent_start_reuse_input_and_relaunch_after_exit(self):
        self.assertEqual((self.status()['flutter_pids'], self.starts()), ([], []))
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: self.launch(), range(8)))
        self.assertTrue(all(child.poll() is None for child, _ in results), results)
        launched = [(child, value) for child, value in results if not value.get('reused')]
        self.assertEqual(len(launched), 1, results)
        owner, first = launched[0]
        self.wait_for(lambda: self.starts() == [first['pid']])
        self.assertEqual(first['pid'], owner.pid)
        self.assertEqual(os.getsid(first['pid']), os.getsid(0))
        self.assertTrue(all(value['pid'] == first['pid'] for _, value in results))
        self.assertEqual(self.status()['flutter_pids'], [owner.pid])
        for command in (b'r', b'R'):
            self.send(owner, command)
            self.assertEqual(self.read_line(owner), b'received:' + command + b'\n')
        self.send(owner, b'q')
        for child, _ in results:
            self.assertEqual(child.wait(timeout=5), 0)
        self.assertEqual(self.status()['flutter_pids'], [])
        relaunched, second = self.launch()
        self.assertNotEqual(first['pid'], second['pid'])
        self.wait_for(lambda: len(self.starts()) == 2)
        self.send(relaunched, b'q')
        self.assertEqual(relaunched.wait(timeout=5), 0)

    def test_flutter_failure_exit_status_is_preserved(self):
        child, _ = self.launch()
        self.send(child, b'x')
        self.assertEqual(child.wait(timeout=5), 42)
        self.assertEqual(self.status()['flutter_pids'], [])

    def test_concurrent_checkouts_share_one_flutter_start(self):
        other = Path(self.temporary.name).resolve() / 'other checkout/packages/desktop'
        shutil.copytree(self.desktop / 'tool', other / 'tool')
        shutil.copytree(self.desktop / 'macos', other / 'macos')
        launchers = [self.launcher, other / 'tool/run_flutter.py']
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda launcher: self.launch(launcher=launcher), launchers))
        launched = [(child, value) for child, value in results if not value.get('reused')]
        self.assertEqual(len(launched), 1, results)
        owner, first = launched[0]
        self.wait_for(lambda: self.starts() == [first['pid']])
        reused = next(value for _, value in results if value.get('reused'))
        self.assertEqual(reused['flutter_pids'], [owner.pid])
        self.send(owner, b'q')
        for child, _ in results:
            self.assertEqual(child.wait(timeout=5), 0)

    def test_stopping_reuse_keeps_the_original_session_running(self):
        owner, first = self.launch()
        self.wait_for(lambda: self.starts() == [first['pid']])
        reused, status = self.launch()
        self.assertTrue(status.get('reused'), status)
        self.assertIsNone(reused.poll())
        reused.send_signal(signal.SIGINT)
        self.assertEqual(reused.wait(timeout=5), 130)
        self.assertIsNone(owner.poll())
        self.send(owner, b'q')
        self.assertEqual(owner.wait(timeout=5), 0)

    def test_terminating_foreground_session_leaves_no_flutter_process(self):
        child, first = self.launch()
        self.wait_for(lambda: self.starts() == [first['pid']])
        child.terminate()
        self.assertEqual(child.wait(timeout=5), -signal.SIGTERM)
        self.assertEqual(self.status()['flutter_pids'], [])

    def test_existing_duplicate_supervisors_refuse_another_launch(self):
        for _ in range(2):
            self.direct.append(subprocess.Popen([str(self.flutter), 'run', '-d', 'macos', '--debug'],
                cwd=self.desktop, env=self.environment, stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        self.wait_for(lambda: len(self.starts()) == 2)
        code, status = self.run_launcher()
        self.assertEqual(code, 2)
        self.assertEqual(set(status['flutter_pids']), {child.pid for child in self.direct})
        self.assertEqual(len(self.starts()), 2)

    def test_existing_release_supervisor_is_reused_before_app_starts(self):
        existing = subprocess.Popen([str(self.flutter), 'run', '-d', 'macos', '--release'],
            cwd=self.desktop, env=self.environment, stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.direct.append(existing)
        self.wait_for(lambda: self.starts() == [existing.pid])
        reused, status = self.launch()
        self.assertTrue(status.get('reused'), status)
        self.assertEqual(status['flutter_pids'], [existing.pid])
        self.assertEqual(self.starts(), [existing.pid])
        self.send(existing, b'q')
        self.assertEqual(existing.wait(timeout=5), 0)
        self.assertEqual(reused.wait(timeout=5), 0)

    def test_existing_app_from_any_build_is_reused(self):
        for configuration in ('Debug', 'Profile', 'Release', 'Applications'):
            with self.subTest(configuration=configuration):
                # Use another build location to cover apps outside this checkout.
                existing = self.start_app(configuration)
                try:
                    reused, status = self.launch()
                    self.assertTrue(status.get('reused'), status)
                    self.assertEqual(status['app_pids'], [existing.pid])
                    self.assertEqual(self.starts(), [])
                    existing.terminate()
                    existing.wait(timeout=5)
                    self.assertEqual(reused.wait(timeout=5), 0)
                finally:
                    if existing.poll() is None:
                        existing.terminate()
                    existing.wait(timeout=5)

    def test_existing_apps_from_different_builds_refuse_another_launch(self):
        apps = [self.start_app(configuration) for configuration in ('Debug', 'Applications')]
        code, status = self.run_launcher()
        self.assertEqual(code, 2)
        self.assertEqual(set(status['app_pids']), {child.pid for child in apps})
        self.assertEqual(self.starts(), [])

    def test_flutter_in_path_with_apostrophe_is_reused(self):
        binaries = self.flutter.parent / "owner's tools"
        binaries.mkdir()
        self.flutter = self.flutter.rename(binaries / 'flutter')
        self.environment['PATH'] = str(binaries) + os.pathsep + os.environ['PATH']
        owner, first = self.launch()
        self.wait_for(lambda: self.starts() == [first['pid']])
        reused, status = self.launch()
        self.assertTrue(status.get('reused'), status)
        self.assertEqual(status['flutter_pids'], [owner.pid])
        self.assertEqual(self.starts(), [owner.pid])
        self.send(owner, b'q')
        self.assertEqual(owner.wait(timeout=5), 0)
        self.assertEqual(reused.wait(timeout=5), 0)


if __name__ == '__main__':
    unittest.main()
