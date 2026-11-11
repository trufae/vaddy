#!/usr/bin/env python3
"""Package tested binaries, including the Windows/macOS library closure."""
import argparse
import os
from pathlib import Path
import platform
import re
import shutil
import ssl
import subprocess
import tarfile
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parent.parent
TARGETS = ('linux-x86_64', 'alpine-x86_64', 'macos-arm64', 'macos-x86_64', 'windows-x86_64')


def output(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True).strip()


def copy(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    destination.chmod(destination.stat().st_mode | 0o200)


def macos_dependencies(binary):
    return [line.strip().split(' (compatibility version', 1)[0]
            for line in output('otool', '-L', binary).splitlines()[1:]]


def bundle_macos(stage, binary):
    openssl = Path(output('brew', '--prefix', 'openssl@3')) / 'bin/openssl'
    copies = {binary.resolve(): stage / 'vaddy', openssl.resolve(): stage / 'openssl'}
    pending = list(copies)
    names = {}
    while pending:
        source = pending.pop()
        destination = copies[source]
        copy(source, destination)
        changes = []
        rpaths = None
        for linked in macos_dependencies(source):
            if linked.startswith(('/usr/lib/', '/System/Library/')):
                continue
            if linked.startswith('@loader_path/'):
                dependency = source.parent / linked.removeprefix('@loader_path/')
            elif linked.startswith('@rpath/'):
                if rpaths is None:
                    rpaths = re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset',
                                        output('otool', '-l', source))
                candidates = [Path(path.replace('@loader_path', str(source.parent))) /
                              linked.removeprefix('@rpath/') for path in rpaths]
                dependency = next((path for path in candidates if path.is_file()), None)
                if dependency is None:
                    raise RuntimeError(f'Unresolved library reference in {source}: {linked}')
            elif linked.startswith('/'):
                dependency = Path(linked)
            else:
                raise RuntimeError(f'Unsupported library reference in {source}: {linked}')
            dependency = dependency.resolve(strict=True)
            if dependency == source:  # A dylib's own install name.
                continue
            name = dependency.name
            if name in names and names[name] != dependency:
                raise RuntimeError(f'Conflicting library names: {dependency} and {names[name]}')
            names[name] = dependency
            if dependency not in copies:
                copies[dependency] = stage / 'lib' / name
                pending.append(dependency)
            relative = os.path.relpath(copies[dependency], destination.parent)
            changes.extend(['-change', linked, '@loader_path/' + relative])
        if destination.suffix == '.dylib':
            changes.extend(['-id', '@rpath/' + destination.name])
        if changes:
            subprocess.run(['install_name_tool', *changes, str(destination)], check=True)

    # Copy the notices from each bundled Homebrew package.
    packages = {parent for source in copies for parent in source.parents
                if (parent / 'INSTALL_RECEIPT.json').is_file()}
    packages.add(Path(output('brew', '--prefix', 'ca-certificates')).resolve())
    for package in packages:
        for pattern in ('LICENSE*', 'COPYING*', 'NOTICE*'):
            for notice in package.glob(pattern):
                if notice.is_file():
                    copy(notice, stage / 'licenses' / package.parent.name / notice.name)

    for destination in copies.values():
        # All non-system paths must now resolve inside the extracted archive.
        for linked in macos_dependencies(destination):
            if not linked.startswith(('/usr/lib/', '/System/Library/', '@loader_path/', '@rpath/')):
                raise RuntimeError(f'Unbundled dependency in {destination}: {linked}')
        subprocess.run(['codesign', '--force', '--sign', '-', str(destination)], check=True)
    prefix = Path(output('brew', '--prefix'))
    copy(prefix / 'etc/openssl@3/cert.pem', stage / 'cert.pem')


def bundle_windows(stage, binary):
    # Use the same UCRT64 toolchain as the application, never another PATH's DLLs.
    prefix = Path(shutil.which('gcc')).resolve().parent.parent
    dlls = {path.name.lower(): path for path in (prefix / 'bin').glob('*.dll')}
    system = Path(os.environ['SystemRoot']) / 'System32'
    pending = [binary, prefix / 'bin/openssl.exe']
    copied = set()
    while pending:
        source = pending.pop()
        name = source.name.lower()
        if name in copied:
            continue
        copied.add(name)
        copy(source, stage / source.name)
        imports = re.findall(r'DLL Name:\s*(\S+)', output('objdump', '-p', source))
        for imported in imports:
            dependency = dlls.get(imported.lower())
            if dependency:
                pending.append(dependency)
            elif imported.lower().startswith(('api-ms-win-', 'ext-ms-win-')) or (system / imported).is_file():
                continue
            else:
                raise RuntimeError(f'Missing DLL required by {source.name}: {imported}')
    shutil.copytree(prefix / 'share/licenses', stage / 'licenses/msys2')
    copy(prefix / 'etc/ssl/cert.pem', stage / 'cert.pem')


def smoke_test(stage, windows, bundled):
    env = os.environ.copy()
    # Prove that the executables do not depend on the build toolchain's PATH.
    system_path = str(Path(env['SystemRoot']) / 'System32') if windows else '/usr/bin:/bin'
    env['PATH'] = str(stage) + os.pathsep + system_path
    for key in ('DYLD_LIBRARY_PATH', 'DYLD_FALLBACK_LIBRARY_PATH', 'LD_LIBRARY_PATH'):
        env.pop(key, None)
    suffix = '.exe' if windows else ''
    if bundled:
        env['VADDY_OPENSSL'] = str(stage / ('openssl' + suffix))
        env['OPENSSL_CONF'] = str(stage / 'openssl.cnf')
        env['SSL_CERT_FILE'] = str(stage / 'cert.pem')
        assert ssl.create_default_context(cafile=env['SSL_CERT_FILE']).get_ca_certs()
        subprocess.run([env['VADDY_OPENSSL'], 'version'], env=env, check=True)
        with tempfile.TemporaryDirectory() as temporary:
            subprocess.run([env['VADDY_OPENSSL'], 'req', '-new', '-x509', '-newkey', 'ec',
                            '-pkeyopt', 'ec_paramgen_curve:P-256', '-nodes', '-subj', '/CN=localhost',
                            '-keyout', str(Path(temporary) / 'key.pem'),
                            '-out', str(Path(temporary) / 'cert.pem'), '-days', '1'], env=env, check=True)
    subprocess.run([str(stage / ('vaddy' + suffix)), 'version'], env=env, check=True)
    subprocess.run([str(stage / ('vaddy' + suffix)), 'validate', '--config', str(stage / 'Caddyfile')],
                   env=env, check=True)


def package(target, binary, destination):
    system, arch = target.split('-', 1)
    native_arch = {'amd64': 'x86_64', 'aarch64': 'arm64'}.get(platform.machine().lower(), platform.machine().lower())
    native_system = {'Darwin': 'macos', 'Windows': 'windows', 'Linux': 'linux'}.get(platform.system())
    if arch != native_arch or (system != native_system and not (system == 'alpine' and native_system == 'linux')):
        raise RuntimeError(f'{target} does not match the packaging host')
    destination.mkdir(parents=True, exist_ok=True)
    name = 'vaddy-' + target
    with tempfile.TemporaryDirectory() as temporary:
        stage = Path(temporary) / name
        stage.mkdir()
        copy(ROOT / 'Caddyfile', stage / 'Caddyfile')
        copy(ROOT / 'LICENSE', stage / 'LICENSE')
        copy(ROOT / 'doc/INSTALL.md', stage / 'README.md')
        copy(ROOT / 'doc/THIRD_PARTY.md', stage / 'THIRD_PARTY.md')
        shutil.copytree(ROOT / 'doc/licenses', stage / 'licenses')
        revision = output('git', '-C', ROOT, 'rev-parse', 'HEAD')
        (stage / 'BUILD.txt').write_text(f'Target: {target}\nCommit: {revision}\nRef: {os.getenv("GITHUB_REF", "local")}\n')
        if system == 'macos':
            bundle_macos(stage, binary)
        elif system == 'windows':
            bundle_windows(stage, binary)
        else:
            copy(binary, stage / 'vaddy')
            (stage / 'vaddy').chmod(0o755)
        bundled = system in ('macos', 'windows')
        if bundled:
            (stage / 'openssl.cnf').write_text('[req]\ndistinguished_name = dn\n[dn]\n')
        # Alpine already passed the runtime-only container check in its Dockerfile.
        if system != 'alpine':
            smoke_test(stage, system == 'windows', bundled)
        archive = destination / (name + ('.zip' if system == 'windows' else '.tar.gz'))
        if system == 'windows':
            with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as bundle:
                for path in sorted(stage.rglob('*')):
                    if path.is_file():
                        bundle.write(path, path.relative_to(stage.parent))
        else:
            with tarfile.open(archive, 'w:gz') as bundle:
                bundle.add(stage, arcname=name)
    print(archive)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', choices=TARGETS)
    parser.add_argument('binary', type=Path)
    parser.add_argument('--output', type=Path, default=ROOT / 'dist')
    args = parser.parse_args()
    package(args.target, args.binary.resolve(strict=True), args.output.resolve())
