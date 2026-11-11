# Platform builds and CI

Run these commands from the repository root. The native build requires C and C++17
compilers, V, `pkg-config`, OpenSSL, RE2, zlib, nghttp2 and Zstandard development libraries, and the `openssl`
executable. Go is only needed for the optional comparison/benchmark drivers;
the three-server comparison also requires Rust/Cargo, CMake, and a C/C++ compiler
for Raddy's release build. See [benchmark setup](TESTING.md).

## GitHub Actions

[ci.yml](../.github/workflows/ci.yml) runs on pushes, pull requests, and manual
dispatch. Jobs fail independently, so a failure on one OS does not cancel the
other platforms. Each native job builds an optimized binary, runs all V test
files, validates the example Caddyfile, and runs the real loopback TCP/TLS
integration test with a temporary local CA.

| Job | Toolchain | Networking backend |
| --- | --- | --- |
| Ubuntu 24.04 | Clang, system OpenSSL | epoll |
| macOS 15, Apple Silicon and Intel | Clang, Homebrew OpenSSL 3 | kqueue |
| Windows Server 2022 | MSYS2 UCRT64 GCC and OpenSSL; native Windows executable | Winsock `WSAPoll` |
| Alpine x86-64 | Clang and musl in an Alpine 3.24 container | epoll |

The Alpine job uses the same Makefile target as a local build. Each platform
uploads an installable archive as an Actions artifact. Build jobs use read-only
repository permissions and do not run a public CA issuance test.

## Tag releases

Push a tag whose first character is a digit to publish a GitHub Release:

```sh
git tag 0.1.0
git push origin 0.1.0
```

The tagged commit must contain the workflow. Branch pushes, pull requests,
manual runs and tags such as `v0.1.0` or `nightly` do not publish releases.
All native and Alpine build, test and packaging jobs must succeed first.
The publishing job alone receives `contents: write` and uses the built-in
`GITHUB_TOKEN`; no release secret is needed.

Each release contains five archives: Windows x86-64, macOS arm64 and x86-64,
Ubuntu 24.04 x86-64 and Alpine 3.24 x86-64, plus `SHA256SUMS`. The archive names
stay constant so `/releases/latest/download/` links keep working.
Numeric tags are published as regular releases and marked latest, with generated
release notes. Tag builds are not cancelled by subsequent pushes.

[`ci/package-release.py`](../ci/package-release.py) packages the tested binaries,
example config, installation instructions, build commit and third-party notices.
On macOS it copies the transitive Homebrew libraries, rewrites their load paths
relative to the executable and applies ad-hoc signatures. On Windows it copies
the transitive UCRT64 DLLs, excluding Windows system DLLs. Both include OpenSSL
and a CA bundle, and smoke-test the package with the build toolchain removed
from `PATH`. macOS packages are not notarized. Linux and Alpine use the runtime
packages listed in [installation instructions](INSTALL.md).

The release assets use the pinned compiler fork from the main CI workflow;
the separate stock-V workflow is a compatibility check. For a local packaging
check after `make`, run (choosing the target for your host):

```sh
python3 ci/package-release.py macos-arm64 ./vaddy
```

Compiler and bootstrap revisions are pinned in [ci/toolchain.env](../ci/toolchain.env):

- V: `trufae/v`, `b7b4dd46eeb3d39cf8d3e8ef757093d872cbc230`.
- C bootstrap: `vlang/vc`, `5e086d589c15060ef9d1d3554d02831dc0172170`.

This is the V fork used by the implementation and the archived measurements.
The jobs build the compiler from source instead of selecting a moving V release.
The operating-system package repositories and action major-version tags can
still receive updates; the complete environment is not bit-for-bit pinned.

## Stock V release check

[setup-v.yml](../.github/workflows/setup-v.yml) is a second, independent workflow.
Instead of bootstrapping the fork, it downloads an official prebuilt release from
[`vlang/v`](https://github.com/vlang/v/releases) and runs the same build,
unit tests, Caddyfile validation, integration test, and HTTP/2, encoding and
file suites. It runs on Ubuntu 24.04 and macOS 15. It checks whether Vaddy builds
and passes its tests without the fork's patches.

The matrix selects `v_linux.zip` for Ubuntu x86-64 and `v_macos_arm64.zip` for
macOS arm64. The release is pinned by `V_VERSION` in
[ci/toolchain.env](../ci/toolchain.env). Override it for a manual run with the
`v-version` dispatch input, using a release tag with those assets. Branches and
commit IDs are not supported. The workflow installs under `.tools/stock-v`
and adds the extracted compiler directory to `PATH`.

`vlang/setup-v@v1.7` downloads source even when given a release tag, then builds
it using the current `vc` bootstrap. That bootstrap can be incompatible with
older V sources. Downloading the release binaries avoids that moving dependency.

To try that release locally into a separate directory:

```sh
curl -fL -o /tmp/v.zip https://github.com/vlang/v/releases/download/0.5.2/v_macos_arm64.zip
mkdir -p .tools/stock-v
unzip -q /tmp/v.zip -d .tools/stock-v
make -B V="$PWD/.tools/stock-v/v/v"
make test V="$PWD/.tools/stock-v/v/v"
```

To build the pinned fork's compiler locally into a new directory:

```sh
sh ci/bootstrap-v.sh .tools/v
make V="$PWD/.tools/v/v"
make test V="$PWD/.tools/v/v"
make integration V="$PWD/.tools/v/v"
```

The script requires Git and network access, and refuses to overwrite an existing
destination. `CC` selects the Unix bootstrap C compiler, defaulting to Clang.
`V_REPOSITORY`, `V_REVISION`, `VC_REPOSITORY`, and `VC_REVISION` can override the
pins for an explicit toolchain experiment. Revisions must be full commit IDs.

## Native Windows build

Use an MSYS2 **UCRT64** shell with these packages:

```sh
pacman -S --needed git make mingw-w64-ucrt-x86_64-gcc \
    mingw-w64-ucrt-x86_64-pkgconf mingw-w64-ucrt-x86_64-openssl mingw-w64-ucrt-x86_64-re2 mingw-w64-ucrt-x86_64-zlib mingw-w64-ucrt-x86_64-nghttp2 mingw-w64-ucrt-x86_64-zstd \
    mingw-w64-ucrt-x86_64-python
sh ci/bootstrap-v.sh .tools/v
make V="$PWD/.tools/v/v.exe" VFLAGS='-prod -cc gcc -gc boehm'
make test V="$PWD/.tools/v/v.exe" VTESTFLAGS='-cc gcc -gc boehm'
make integration V="$PWD/.tools/v/v.exe" VFLAGS='-prod -cc gcc -gc boehm'
```

The result is `vaddy.exe`, using Winsock rather than WSL or a POSIX-emulation
runtime. Run it with the matching UCRT64 OpenSSL, RE2, zlib, nghttp2, Zstandard and C++ runtime DLLs on `PATH`; automatic
certificate management also needs the UCRT64 `openssl.exe`. CI packages these
dependencies in a ZIP that can run outside MSYS2; see [installation instructions](INSTALL.md).

Worker notifications and socket-I/O tests use private loopback TCP pairs on
Windows, where the POSIX `socketpair` call is unavailable. Each reactor owns its
polling array. Windows handles retain their width across the V/C boundary, and
socket, event-queue, and storage-lock cleanup use separate functions. Certificate
publication uses Windows file replacement rather than a rename that fails when
the destination exists.

Ctrl+C/Ctrl+Break request shutdown. Terminating a process with Windows
`TerminateProcess` is a forced stop, so it does not exercise graceful draining.
Certificate-directory privacy follows Windows ACLs; POSIX `chmod` mode bits do
not configure those ACLs. Use a private user or service data directory.

The Windows polling backend has not been performance-compared with epoll/kqueue.
The historical macOS benchmarks do not establish Windows throughput or memory
use.

## Alpine Linux x86-64 binary

With Docker and Buildx available:

```sh
make alpine
# Equivalent explicit architecture target:
make alpine-x86_64
```

Output: **`dist/vaddy-alpine-x86_64`**. The build always requests `linux/amd64`,
including on an ARM Mac. An ARM host needs x86-64 execution support in its
container runtime; Docker Desktop commonly supplies it. On an x86-64 Linux
host no architecture emulation is required.

The [Dockerfile](../build/alpine.Dockerfile) compiles against Alpine's musl libc,
keeps Boehm GC enabled, runs the V suite and TCP/TLS integration test, then
checks the binary in a fresh Alpine stage containing only runtime packages.
The final BuildKit export contains only the binary. V's musl flag avoids using
a glibc-specific GC archive or requiring musl's absent `getcontext` implementation.

This is a dynamically linked **musl** executable, not a glibc executable or a
fully static binary. On a matching Alpine system, install its library runtimes
and CA trust store:

```sh
apk add --no-cache openssl re2 libstdc++ zlib nghttp2-libs zstd-libs ca-certificates
chmod +x ./vaddy-alpine-x86_64
./vaddy-alpine-x86_64 validate --config ./Caddyfile
```

The container runtime and build toolchain are not needed to run the exported
binary. The OpenSSL executable remains necessary for certificate operations.
The `chmod` also restores executable permission after downloading an Actions
artifact.

Build controls:

```sh
make alpine ALPINE_OUTPUT=dist/alpine
make alpine ALPINE_BUILD_ARGS='--progress=plain --no-cache'
# Explicit compiler override; replace the value with a full commit ID:
make alpine ALPINE_BUILD_ARGS='--build-arg V_REVISION=FULL_COMMIT_ID'
```

`CONTAINER_ENGINE` selects the Docker-compatible command, defaulting to `docker`.
`ALPINE_BUILD_ARGS` also accepts `--build-arg ALPINE_IMAGE=alpine:3.24` and the
compiler/bootstrap repository and revision overrides. The default Alpine image
tag receives patch updates; select an image digest for stricter reproducibility.

## Validation status when this workflow was added

The pinned compiler was bootstrapped locally on macOS, then used to build Vaddy,
pass all four V test files, validate the Caddyfile, and pass the real TCP/TLS
integration test. The Windows adapter and generated Windows C passed MinGW
syntax checks; a Windows executable was not linked or run locally.

The local Alpine attempt stopped because Docker Desktop could not start.
Windows, Linux and Alpine runtime results still need an Actions run or another
host. The presence of the workflow is not a record of a successful hosted run.

References: [MSYS2 GitHub Actions setup](https://www.msys2.org/docs/ci/),
[Microsoft WSAPoll documentation](https://learn.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-wsapoll),
and [Alpine release branches](https://www.alpinelinux.org/releases/).

See [third-party notices](THIRD_PARTY.md) for the Caddy HTML template and linked libraries.
