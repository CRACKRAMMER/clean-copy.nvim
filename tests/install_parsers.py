#!/usr/bin/env python3
"""Explicit development-only installer. Never called by the plugin."""
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import tarfile

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
    source = CACHE / 'sources' / lang
    source.mkdir(parents=True, exist_ok=True)
    archive = CACHE / (lang + '.tar.gz')
    subprocess.run(['curl', '--fail', '--location', '--silent', '--show-error',
                    '--retry', '2', '--max-time', '120',
                    f'https://codeload.github.com/{repo}/tar.gz/{info["revision"]}',
                    '-o', str(archive)], check=True)
    with tarfile.open(archive) as tar:
        tar.extractall(source, filter='data')
    base = next(source.iterdir()) / info.get('location', '')
    src = base / 'src'
    files = [str(src / 'parser.c')]
    if (src / 'scanner.c').exists():
        files.append(str(src / 'scanner.c'))
    if (src / 'scanner.cc').exists():
        raise RuntimeError(f'{lang}: C++ scanner needs explicit build support')
    subprocess.run([os.environ.get('CC', 'cc'), '-O2', '-fPIC', '-shared',
                    '-I' + str(src), *files, '-o', str(target)], check=True)
    return lang + ': installed'

if __name__ == '__main__':
    PARSERS.mkdir(parents=True, exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for result in pool.map(install, LOCK.items()):
            print(result, flush=True)
