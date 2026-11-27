"""Exercise installer guards and download integrity without root or a database."""
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / 'scripts/portable/install.sh'
SCRIPT = INSTALLER.read_text()
PYTHON_BLOCKS = re.findall(r"<<'PY'\n(.*?)\nPY", SCRIPT, re.S)


class InstallerTests(unittest.TestCase):
    def test_all_embedded_python_parses(self):
        self.assertEqual(len(PYTHON_BLOCKS), 3)
        for block in PYTHON_BLOCKS:
            compile(block, str(INSTALLER), 'exec')

    def test_help_is_available_without_root(self):
        result = subprocess.run(['bash', str(INSTALLER), '--help'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('--port', result.stdout)

    def test_invalid_arguments_stop_before_install(self):
        for arguments in (['--port', '0'], ['--port', '65536'], ['--port', '5432;touch /tmp/unsafe'],
                          ['--port'], ['--version', '17.12.0.005-cli-rc1'], ['--unknown']):
            result = subprocess.run(['bash', str(INSTALLER), *arguments], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, arguments)
            self.assertNotIn('安装运行依赖', result.stdout)

    def test_nonroot_is_rejected_before_side_effects(self):
        import os
        if os.geteuid() == 0:
            self.skipTest('This check is intended for a non-root GitHub runner')
        result = subprocess.run(['bash', str(INSTALLER)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('sudo bash', result.stderr)

    def fixture(self, architecture='linux-arm64', unsafe=False):
        tag = 'postgres-17.12.0.005-cli'
        bundle = f'supabase-{tag}-{architecture}'
        manifest = {'release_tag': tag, 'extensions': {
            'pg_duckdb': {'sql_version': '1.2.2'}, 'pg_durable': {'sql_version': '0.2.9'}}}
        inventory = {'platform': architecture, 'release': manifest,
                     'extensions': {'pg_duckdb': '1.2.2', 'pg_durable': '0.2.9'}}
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w:gz') as output:
            files = {'portable-release.json': json.dumps(manifest), 'extensions.json': json.dumps(inventory)}
            for name, extension in manifest['extensions'].items():
                files[f'share/postgresql/extension/{name}.control'] = f"default_version = '{extension['sql_version']}'\n"
            for name in ('postgres', 'initdb', 'pg_ctl', 'pg_isready', 'psql'):
                files[f'bin/{name}'] = 'fixture, never executed'
            if unsafe:
                files['../outside'] = 'must not be extracted'
            for name, text in files.items():
                data = text.encode()
                entry = tarfile.TarInfo(f'{bundle}/{name}')
                entry.size = len(data)
                output.addfile(entry, io.BytesIO(data))
        archive = stream.getvalue()
        archive_name = bundle + '.tar.gz'
        downloads = {archive_name: archive,
                     archive_name + '.sha256': f'{hashlib.sha256(archive).hexdigest()}  {archive_name}\n'.encode(),
                     bundle + '.extensions.json': json.dumps(inventory).encode()}
        base = f'https://github.com/deluxebear/postgres/releases/download/{tag}/'
        release = {'tag_name': tag, 'name': tag, 'draft': False, 'prerelease': False,
                   'assets': [{'name': name, 'state': 'uploaded', 'browser_download_url': base + name,
                               'digest': 'sha256:' + hashlib.sha256(data).hexdigest()}
                              for name, data in downloads.items()]}
        return bundle, release, {base + name: data for name, data in downloads.items()}

    def run_download(self, directory, release, downloads, requested='', architecture='linux-arm64'):
        calls = []
        def urlopen(request, **_kwargs):
            url = request.full_url
            calls.append(url)
            if '/releases?' in url:
                # Global Latest can be a server release, and prereleases must be excluded.
                server = dict(release, tag_name='postgres-17.99.0.999')
                candidate = dict(release, tag_name='postgres-17.99.0.999-cli', prerelease=True)
                return io.BytesIO(json.dumps([server, candidate, release]).encode())
            if '/releases/tags/' in url:
                return io.BytesIO(json.dumps(release).encode())
            return io.BytesIO(downloads[url])
        argv = ['installer', 'deluxebear/postgres', requested, architecture, str(directory)]
        with patch.object(sys, 'argv', argv), patch('urllib.request.urlopen', side_effect=urlopen), \
             patch('time.sleep'):
            exec(compile(PYTHON_BLOCKS[1], str(INSTALLER), 'exec'), {'__name__': '__installer_test__'})
        return calls

    def test_latest_stable_bundle_and_architecture(self):
        for architecture in ('linux-x64', 'linux-arm64'):
            bundle, release, downloads = self.fixture(architecture)
            with tempfile.TemporaryDirectory() as directory:
                self.run_download(directory, release, downloads, architecture=architecture)
                self.assertEqual((Path(directory) / 'bundle-name').read_text(), bundle)
                self.assertTrue((Path(directory) / 'unpacked' / bundle / 'bin/postgres').is_file())

    def test_tampered_download_is_rejected_before_extraction(self):
        _bundle, release, downloads = self.fixture()
        archive = next(url for url in downloads if url.endswith('.tar.gz'))
        downloads[archive] += b'tampered'
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(SystemExit, '哈希不匹配'):
                self.run_download(directory, release, downloads)
            self.assertFalse((Path(directory) / 'unpacked').exists())

    def test_traversal_is_rejected_even_with_valid_checksum(self):
        _bundle, release, downloads = self.fixture(unsafe=True)
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(SystemExit, '顶层目录'):
                self.run_download(directory, release, downloads)
            self.assertFalse((Path(directory) / 'outside').exists())

    def test_requested_prerelease_is_rejected(self):
        _bundle, release, downloads = self.fixture()
        release['prerelease'] = True
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(SystemExit, '不是稳定'):
                self.run_download(directory, release, downloads, requested='17.12.0.005-cli')

    def test_preserves_preload_libraries(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'postgresql.conf'
            path.write_text("shared_preload_libraries = 'pg_cron, supautils, pg_duckdb'\n")
            with patch.object(sys, 'argv', ['installer', str(path)]):
                exec(compile(PYTHON_BLOCKS[2], str(INSTALLER), 'exec'), {'__name__': '__installer_test__'})
            text = path.read_text()
            self.assertIn('pg_cron, supautils, pg_duckdb, pg_durable', text)
            self.assertEqual(text.count('pg_duckdb'), 1)


if __name__ == '__main__':
    unittest.main()
