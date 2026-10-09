#!/usr/bin/env python3
"""Installer regression tests using local archives and mocked commands only."""
import importlib.util
import io
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location(
    'clean_copy_test_installer', Path(__file__).with_name('install_parsers.py'))
installer = importlib.util.module_from_spec(SPEC)
sys.dont_write_bytecode = True
SPEC.loader.exec_module(installer)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='clean-copy-installer-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.cache = self.root / '.test'
        self.parsers = self.cache / 'runtime' / 'parser'
        self.target = self.parsers / 'fixture.so'
        self.info = {'url': 'https://github.com/example/grammar', 'revision': 'new-revision'}
        self.archive = self.root / 'fixture.tar.gz'
        self.commands, self.compiled = [], []
        self.compile_error = self.download_error = False
        self.binary = b'complete parser binary'
        patcher = mock.patch.multiple(installer, CACHE=self.cache, PARSERS=self.parsers)
        patcher.start()
        self.addCleanup(patcher.stop)
        environment_patcher = mock.patch.dict(installer.os.environ, {'CC': 'fixture-cc'})
        environment_patcher.start()
        self.addCleanup(environment_patcher.stop)
        command_patcher = mock.patch.object(installer.subprocess, 'run', side_effect=self.run_command)
        command_patcher.start()
        self.addCleanup(command_patcher.stop)
        self.make_archive({'grammar-new-revision/src/parser.c': 'current source'})

    def make_archive(self, files):
        with tarfile.open(self.archive, 'w:gz') as archive:
            for name, contents in files.items():
                data = contents.encode()
                entry = tarfile.TarInfo(name)
                entry.size = len(data)
                archive.addfile(entry, io.BytesIO(data))

    def run_command(self, command, *, check):
        self.assertTrue(check)
        self.commands.append(command)
        output = Path(command[command.index('-o') + 1])
        self.assertFalse(self.target.exists(), 'a partial parser was published before command success')
        if command[0] == 'curl':
            if self.download_error:
                output.write_bytes(b'partial download')
                raise subprocess.CalledProcessError(1, command)
            shutil.copyfile(self.archive, output)
        else:
            self.compiled = [Path(value).read_text() for value in command if value.endswith('.c')]
            if self.binary is not None:
                output.write_bytes(self.binary)
            if self.compile_error:
                raise subprocess.CalledProcessError(1, command)
        return subprocess.CompletedProcess(command, 0)

    def install(self):
        return installer.install(('fixture', self.info))

    def assert_workspace_cleaned(self, expected=('runtime',)):
        self.assertEqual(sorted(path.name for path in self.cache.iterdir()), sorted(expected))

    def test_cached_parser_never_downloads_or_compiles(self):
        self.parsers.mkdir(parents=True)
        self.target.write_bytes(b'existing parser')
        self.assertEqual(self.install(), 'fixture: cached')
        self.assertEqual(self.commands, [])
        self.assertEqual(self.target.read_bytes(), b'existing parser')

    def test_fresh_archive_ignores_old_revision_sources(self):
        stale = self.cache / 'sources' / 'fixture' / 'grammar-old-revision' / 'src'
        stale.mkdir(parents=True)
        (stale / 'parser.c').write_text('stale source')
        with mock.patch.object(installer.os, 'replace', wraps=installer.os.replace) as replace:
            self.assertEqual(self.install(), 'fixture: installed')
            replace.assert_called_once()
            self.assertEqual(Path(replace.call_args.args[1]), self.target)
        self.assertEqual(self.compiled, ['current source'])
        self.assertIn('new-revision', self.commands[0][-3])
        self.assertEqual((stale / 'parser.c').read_text(), 'stale source')
        self.assertEqual(self.target.read_bytes(), self.binary)
        self.assert_workspace_cleaned(('runtime', 'sources'))

    def test_nested_grammar_location_and_c_scanner_are_used(self):
        self.info['location'] = 'typescript'
        self.make_archive({'grammar-new-revision/typescript/src/parser.c': 'typed parser',
                           'grammar-new-revision/typescript/src/scanner.c': 'C scanner'})
        self.assertEqual(self.install(), 'fixture: installed')
        self.assertEqual(self.compiled, ['typed parser', 'C scanner'])
        self.assert_workspace_cleaned()

    def test_failed_compilation_leaves_no_cached_parser_and_retry_is_fresh(self):
        self.compile_error = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.install()
        self.assertFalse(self.target.exists())
        self.assert_workspace_cleaned()
        old_archive_path = self.commands[0][-1]
        self.compile_error = False
        self.assertEqual(self.install(), 'fixture: installed')
        self.assertNotEqual(old_archive_path, self.commands[2][-1])
        self.assertEqual(self.target.read_bytes(), self.binary)
        self.assert_workspace_cleaned()

    def test_failed_download_cleans_partial_archive_without_compiling(self):
        self.download_error = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.install()
        self.assertEqual(len(self.commands), 1)
        self.assertFalse(self.target.exists())
        self.assert_workspace_cleaned()

    def test_multiple_archive_roots_are_rejected(self):
        self.make_archive({'first/src/parser.c': 'first', 'second/src/parser.c': 'second'})
        with self.assertRaisesRegex(RuntimeError, 'one archive root'):
            self.install()
        self.assertEqual(len(self.commands), 1)
        self.assertFalse(self.target.exists())
        self.assert_workspace_cleaned()

    def test_missing_generated_parser_is_rejected_before_compilation(self):
        self.make_archive({'grammar-new-revision/README': 'missing generated source'})
        with self.assertRaisesRegex(RuntimeError, 'missing src/parser.c'):
            self.install()
        self.assertEqual(len(self.commands), 1)
        self.assert_workspace_cleaned()

    def test_cpp_scanner_still_requires_explicit_build_support(self):
        self.make_archive({'grammar-new-revision/src/parser.c': 'parser',
                           'grammar-new-revision/src/scanner.cc': 'C++ scanner'})
        with self.assertRaisesRegex(RuntimeError, r'C\+\+ scanner'):
            self.install()
        self.assertEqual(len(self.commands), 1)
        self.assert_workspace_cleaned()

    def test_success_without_a_nonempty_binary_is_not_published(self):
        for binary in (None, b''):
            with self.subTest(binary=binary):
                self.binary = binary
                with self.assertRaisesRegex(RuntimeError, 'did not produce a parser binary'):
                    self.install()
                self.assertFalse(self.target.exists())
                self.assert_workspace_cleaned()

    def test_atomic_publish_failure_leaves_no_cached_parser(self):
        with mock.patch.object(installer.os, 'replace', side_effect=OSError('publish failed')):
            with self.assertRaisesRegex(OSError, 'publish failed'):
                self.install()
        self.assertFalse(self.target.exists())
        self.assert_workspace_cleaned()


if __name__ == '__main__':
    unittest.main(verbosity=2)
