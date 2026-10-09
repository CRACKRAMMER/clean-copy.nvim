#!/usr/bin/env python3
"""Explicit development-only installer. Never called by the plugin."""
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / '.test'
PARSERS = CACHE / 'runtime' / 'parser'
LOCK = json.loads((ROOT / 'tests/parsers.lock.json').read_text())

def install(item):
    lang, info = item
    target = PARSERS / (lang + '.so')
    if target.exists():
        return lang + ': cached'
    repo = info['url'].removeprefix('https://github.com/')
    PARSERS.mkdir(parents=True, exist_ok=True)
    # Each attempt has fresh sources. Leftovers from a previous revision cannot
    # choose the archive root or be reused by simultaneous installations.
    with tempfile.TemporaryDirectory(prefix=lang + '-', dir=CACHE) as temporary:
        workspace = Path(temporary)
        source = workspace / 'source'
        source.mkdir()
        archive = workspace / 'source.tar.gz'
        subprocess.run(['curl', '--fail', '--location', '--silent', '--show-error',
                        '--retry', '2', '--max-time', '120',
                        f'https://codeload.github.com/{repo}/tar.gz/{info["revision"]}',
                        '-o', str(archive)], check=True)
        with tarfile.open(archive) as tar:
            tar.extractall(source, filter='data')
        roots = list(source.iterdir())
        if len(roots) != 1 or not roots[0].is_dir():
            raise RuntimeError(f'{lang}: expected one archive root directory')
        src = roots[0] / info.get('location', '') / 'src'
        if not (src / 'parser.c').is_file():
            raise RuntimeError(f'{lang}: archive is missing src/parser.c')
        files = [str(src / 'parser.c')]
        if (src / 'scanner.c').exists():
            files.append(str(src / 'scanner.c'))
        if (src / 'scanner.cc').exists():
            raise RuntimeError(f'{lang}: C++ scanner needs explicit build support')
        built = workspace / (lang + '.so')
        subprocess.run([os.environ.get('CC', 'cc'), '-O2', '-fPIC', '-shared',
                        '-I' + str(src), *files, '-o', str(built)], check=True)
        if not built.is_file() or built.stat().st_size == 0:
            raise RuntimeError(f'{lang}: compiler did not produce a parser binary')
        # Publish only complete builds. A compiler failure can never leave a
        # partial .so that a later invocation mistakes for a cached parser.
        os.replace(built, target)
    return lang + ': installed'

if __name__ == '__main__':
    PARSERS.mkdir(parents=True, exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        for result in pool.map(install, LOCK.items()):
            print(result, flush=True)
