# Install a release

Download an archive from [GitHub Releases](https://github.com/trufae/vaddy/releases/latest)
and extract it. No V compiler is needed. Each archive includes `vaddy` (or
`vaddy.exe`), an example `Caddyfile`, build information and third-party notices.
The release's `SHA256SUMS` file covers all five archives.

| Download | Supported system |
| --- | --- |
| `vaddy-windows-x86_64.zip` | Windows x86-64; includes UCRT64 DLLs and OpenSSL |
| `vaddy-macos-arm64.tar.gz` | macOS 15 or newer, Apple Silicon |
| `vaddy-macos-x86_64.tar.gz` | macOS 15 or newer, Intel |
| `vaddy-linux-x86_64.tar.gz` | Ubuntu 24.04 x86-64, glibc |
| `vaddy-alpine-x86_64.tar.gz` | Alpine 3.24 x86-64, musl |

Linux and Alpine binaries use system libraries. Other distributions may work
with compatible library versions; these are the build and test baselines.

## Linux

On Ubuntu 24.04, install the runtime packages and extract the download:

```sh
sudo apt-get update
sudo apt-get install -y openssl libre2-10 libstdc++6 zlib1g libnghttp2-14 libzstd1 ca-certificates
tar -xzf vaddy-linux-x86_64.tar.gz
cd vaddy-linux-x86_64
./vaddy validate --config Caddyfile
```

## Alpine Linux

```sh
apk add --no-cache openssl re2 libstdc++ zlib nghttp2-libs zstd-libs ca-certificates
tar -xzf vaddy-alpine-x86_64.tar.gz
cd vaddy-alpine-x86_64
./vaddy validate --config Caddyfile
```

## macOS

Extract the archive for your CPU, then enter its directory. Keep `lib/` beside
`vaddy`: it contains the bundled native libraries, so Homebrew is not needed.
Set the paths to the included OpenSSL and CA bundle before starting Vaddy:

```sh
export VADDY_OPENSSL="$PWD/openssl"
export OPENSSL_CONF="$PWD/openssl.cnf"
export SSL_CERT_FILE="$PWD/cert.pem"
./vaddy validate --config Caddyfile
```

The executables have ad-hoc signatures; they are not Apple-notarized. macOS may
require approval in System Settings → Privacy & Security for downloaded code.

## Windows

Extract the ZIP and open PowerShell in the extracted directory. Keep the DLLs
alongside `vaddy.exe`; MSYS2 is not needed to run the download.

```powershell
$env:VADDY_OPENSSL = "$PWD\openssl.exe"
$env:OPENSSL_CONF = "$PWD\openssl.cnf"
$env:SSL_CERT_FILE = "$PWD\cert.pem"
.\vaddy.exe validate --config Caddyfile
```

The Windows and macOS bundles include a snapshot of public CA certificates.
Update `cert.pem` or point `SSL_CERT_FILE` at your maintained CA bundle when
updating trust roots. OpenSSL is used for certificate management as well as TLS.

## Run

Edit `Caddyfile` for your domain and backend, then run:

```sh
./vaddy run --config Caddyfile --data ./data
```

Use `.\vaddy.exe` in PowerShell. For public HTTPS, point the domain at this
machine and allow inbound TCP ports 80 and 443. Those ports may require elevated
privileges; preserve the OpenSSL environment settings when running as a service.
For a first local test, use this configuration and open `http://localhost:8080`:

```caddyfile
http://localhost:8080 {
    redir * https://example.org
}
```

Full configuration and operational guidance is in the
[usage guide](https://github.com/trufae/vaddy/blob/main/doc/USAGE.md).

## Verify a download

Download `SHA256SUMS` from the same release as the archive. On Linux/Alpine run
`sha256sum --check --ignore-missing SHA256SUMS`; on macOS run
`shasum -a 256 vaddy-macos-arm64.tar.gz` (or the Intel filename) and compare its
hash with the matching line. On Windows use
`Get-FileHash .\vaddy-windows-x86_64.zip -Algorithm SHA256`.
