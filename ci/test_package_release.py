"""Check dependency bundling without requiring a Windows host."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('package_release', Path(__file__).with_name('package-release.py'))
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)


class WindowsBundleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.prefix = self.root / 'ucrt64'
        self.stage = self.root / 'bundle'
        self.stage.mkdir()
        self.binary = self.root / 'vaddy.exe'
        self.binary.write_bytes(b'application')
        for relative in ('bin/gcc.exe', 'bin/openssl.exe', 'bin/libssl.dll', 'bin/libcrypto.dll',
                         'share/licenses/openssl/LICENSE', 'etc/ssl/cert.pem'):
            path = self.prefix / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(relative.encode())
        self.system = self.root / 'Windows'
        (self.system / 'System32').mkdir(parents=True)
        (self.system / 'System32/KERNEL32.dll').write_bytes(b'system')
        self.imports = {
            'vaddy.exe': ['LIBSSL.dll', 'KERNEL32.dll'],
            'openssl.exe': ['libcrypto.dll'],
            'libssl.dll': ['libcrypto.dll'],
            # Cycles must terminate, and API sets come from Windows itself.
            'libcrypto.dll': ['libssl.dll', 'api-ms-win-crt-runtime-l1-1-0.dll'],
        }

    def bundle(self):
        def objdump(*args):
            self.assertEqual(args[:2], ('objdump', '-p'))
            return '\n'.join('DLL Name: ' + name for name in self.imports[Path(args[2]).name])

        with patch.object(packaging.shutil, 'which', return_value=str(self.prefix / 'bin/gcc.exe')), \
                patch.object(packaging, 'output', side_effect=objdump), \
                patch.dict(os.environ, {'SystemRoot': str(self.system)}):
            packaging.bundle_windows(self.stage, self.binary)

    def test_transitive_imports_are_bundled_without_system_dlls(self):
        self.bundle()
        self.assertEqual({path.name for path in self.stage.glob('*.dll')}, {'libssl.dll', 'libcrypto.dll'})
        self.assertEqual((self.stage / 'vaddy.exe').read_bytes(), b'application')
        self.assertTrue((self.stage / 'openssl.exe').is_file())
        self.assertTrue((self.stage / 'licenses/msys2/openssl/LICENSE').is_file())
        self.assertTrue((self.stage / 'cert.pem').is_file())

    def test_missing_transitive_dependency_stops_packaging(self):
        self.imports['libcrypto.dll'].append('missing.dll')
        with self.assertRaisesRegex(RuntimeError, 'Missing DLL.*missing.dll'):
            self.bundle()


if __name__ == '__main__':
    unittest.main()
