"""Exercise the launcher CLI with real processes, locks, and a local Flutter stand-in."""
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
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
        shutil.copyfile(Path(__file__).with_name('run_flutter.py'), self.launcher)
        binaries = checkout / 'bin'
        binaries.mkdir()
        self.flutter = binaries / 'flutter'
        self.flutter.write_text('''#!/usr/bin/env python3
import os
from pathlib import Path
import signal
import time
with Path(__file__).with_name("starts").open("a") as output:
    output.write(str(os.getpid()) + "\\n")
# Keep the shell-entrypoint identity throughout startup, before any VM exists.
time.sleep(0.3)
while True:
    command = os.read(0, 1)
    if not command:
        signal.pause()
    elif command == b"q":
        break
    else:
        os.write(1, b"received:" + command + b"\\n")
''')
        self.flutter.chmod(0o700)
        self.environment = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ['PATH'])
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
            child.wait(timeout=5)
        self.temporary.cleanup()

    def starts(self):
        trace = self.flutter.with_name('starts')
        return [int(line) for line in trace.read_text().splitlines()] if trace.exists() else []

    def launch(self, *arguments):
        result = subprocess.run([sys.executable, str(self.launcher), *arguments],
            cwd=self.desktop, env=self.environment, capture_output=True, text=True, timeout=10)
        return result.returncode, json.loads(result.stdout)

    def wait_for(self, predicate):
        deadline = time.monotonic() + 5
        while not predicate():
            if time.monotonic() >= deadline:
                self.fail('Timed out waiting for the owned process')
            time.sleep(0.02)

    def test_concurrent_start_reuse_input_and_relaunch_after_exit(self):
        code, status = self.launch('--status')
        self.assertEqual((code, status['flutter_pids'], self.starts()), (0, [], []))
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: self.launch(), range(8)))
        self.assertTrue(all(code == 0 for code, _ in results), results)
        launched = [value for _, value in results if not value.get('reused')]
        self.assertEqual(len(launched), 1, results)
        first = launched[0]
        self.wait_for(lambda: self.starts() == [first['pid']])
        self.assertTrue(all(value['pid'] == first['pid'] for _, value in results))
        with open(first['input'], 'wb', buffering=0) as pipe:
            pipe.write(b'r')
            self.wait_for(lambda: b'received:r' in Path(first['log']).read_bytes())
            pipe.write(b'q')
        self.wait_for(lambda: not self.launch('--status')[1]['flutter_pids'])
        code, second = self.launch()
        self.assertEqual(code, 0)
        self.assertNotEqual(first['pid'], second['pid'])
        self.wait_for(lambda: len(self.starts()) == 2)

    def test_existing_duplicate_supervisors_refuse_another_launch(self):
        for _ in range(2):
            self.direct.append(subprocess.Popen([str(self.flutter), 'run', '-d', 'macos', '--debug'],
                cwd=self.desktop, env=self.environment, stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        self.wait_for(lambda: len(self.starts()) == 2)
        code, status = self.launch()
        self.assertEqual(code, 2)
        self.assertEqual(set(status['flutter_pids']), {child.pid for child in self.direct})
        self.assertEqual(len(self.starts()), 2)


if __name__ == '__main__':
    unittest.main()
