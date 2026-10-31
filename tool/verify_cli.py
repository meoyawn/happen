"""Verify a standalone Happen release: native cache, startup, SQLite and Code Mode."""
import argparse
import gzip
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile
from threading import Thread
import time


class Model(BaseHTTPRequestHandler):
    calls = 0
    saw_code_output = False

    def log_message(self, *args):
        pass

    def do_POST(self):
        if self.headers.get('transfer-encoding') == 'chunked':
            chunks = []
            while True:
                size = int(self.rfile.readline().split(b';', 1)[0], 16)
                if not size:
                    self.rfile.readline()
                    break
                chunks.append(self.rfile.read(size))
                self.rfile.read(2)
            raw = b''.join(chunks)
        else:
            raw = self.rfile.read(int(self.headers['content-length']))
        body = json.loads(gzip.decompress(raw) if self.headers.get('content-encoding') == 'gzip' else raw)
        type(self).calls += 1
        outputs = [item for item in body['input'] if item.get('type') == 'custom_tool_call_output']
        if outputs:
            type(self).saw_code_output = '42' in outputs[-1]['output']
            item = {'type': 'message', 'id': 'message', 'role': 'assistant',
                    'content': [{'type': 'output_text', 'text': 'NATIVE_OK'}]}
        else:
            item = {'type': 'custom_tool_call', 'id': 'cell', 'call_id': 'cell',
                    'namespace': 'functions', 'name': 'exec', 'input': 'text(40 + 2);'}
        events = [{'type': 'response.output_item.done', 'output_index': 0, 'item': item},
                  {'type': 'response.completed', 'response': {'id': 'response', 'status': 'completed',
                   'output': [item], 'usage': {'input_tokens': 1, 'output_tokens': 1}}}]
        payload = ''.join(f'data: {json.dumps(event)}\n\n' for event in events).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def verify(executable):
    with tempfile.TemporaryDirectory(prefix='happen-cli-verify-') as temporary:
        root = Path(temporary)
        binary = root / 'happen'
        shutil.copy2(executable, binary)
        cache = root / 'native'
        # Running a copied executable away from its bundle with no Dart on PATH
        # proves that both native assets and the AOT program are self-contained.
        env = dict(os.environ, HAPPEN_NATIVE_CACHE=str(cache), HAPPEN_BOOTSTRAP_REPORT='1', PATH='/usr/bin:/bin')

        def launch(cache_path=cache):
            started = time.perf_counter()
            result = subprocess.run([str(binary), '--version'], cwd=root,
                env=dict(env, HAPPEN_NATIVE_CACHE=str(cache_path)), capture_output=True, text=True, timeout=30)
            elapsed = (time.perf_counter() - started) * 1000
            if result.returncode or result.stdout.strip() != 'happen 0.1.0':
                raise RuntimeError(f'Standalone CLI launch failed: {result.stderr}')
            return dict(wall_ms=elapsed, **json.loads(result.stderr))

        cold = launch()
        assert cold['installed'], 'Cold launch did not install its native assets'
        metadata = {str(path.relative_to(cache)): path.stat().st_mtime_ns for path in cache.rglob('*.dylib')}
        warm = [launch() for _ in range(10)]
        assert all(not run['installed'] for run in warm), 'Warm launch extracted native assets again'
        assert metadata == {str(path.relative_to(cache)): path.stat().st_mtime_ns for path in cache.rglob('*.dylib')}
        with ThreadPoolExecutor(max_workers=8) as pool:
            simultaneous = list(pool.map(lambda _: launch(root / 'concurrent-native'), range(8)))
        assert sum(run['installed'] for run in simultaneous) == 1, 'Concurrent launch did not share one installation'
        next(cache.rglob('libcode_mode.dylib')).unlink()
        assert launch()['installed'], 'An incomplete cache was not repaired'

        peer = ThreadingHTTPServer(('127.0.0.1', 0), Model)
        worker = Thread(target=peer.serve_forever, daemon=True)
        worker.start()
        try:
            data = root / 'data'
            data.mkdir()
            (data / 'auth.json').write_text(json.dumps({'type': 'chatgpt',
                'access_token': 'fixture', 'refresh_token': 'fixture', 'account_id': 'fixture',
                'expires_at': int((time.time() + 3600) * 1000)}))
            config = root / 'config.yaml'
            config.write_text(json.dumps({'mcp_servers': {}, 'providers': {'openai': {
                'endpoint': f'http://127.0.0.1:{peer.server_port}/responses'}}}))
            task = subprocess.run([str(binary), '--data-dir', str(data), '--config', str(config),
                'exec', '--json', '--model', 'gpt-6.1-sol', '--reasoning', 'low', '--cwd', str(root),
                'Verify native code mode.'], cwd=root, env=env, capture_output=True, text=True, timeout=45)
            if task.returncode or 'NATIVE_OK' not in task.stdout or not Model.saw_code_output:
                failures = [json.loads(line).get('data', {}).get('error') for line in task.stdout.splitlines()
                    if line.startswith('{') and json.loads(line).get('type') == 'turn.failed']
                raise RuntimeError(f'AOT task did not execute Code Mode: {task.stderr[:1000]} {failures}')
            assert list(data.rglob('*.sqlite')), 'Task did not persist through the native SQLite binding'
        finally:
            peer.shutdown()
            peer.server_close()
            worker.join()
        return {'cold': cold, 'warm_median_ms': statistics.median(run['wall_ms'] for run in warm),
                'warm_maximum_ms': max(run['wall_ms'] for run in warm),
                'warm_bootstrap_median_us': statistics.median(run['bootstrap_microseconds'] for run in warm),
                'concurrent_launches': len(simultaneous), 'cache_repair': True,
                'native_sqlite_and_code_mode': True, 'no_sdk_on_path': True}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', nargs='?', default='build/cli/happen', type=Path)
    args = parser.parse_args()
    report = verify(args.executable.resolve())
    destination = args.executable.resolve().parent / 'verification.json'
    destination.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
