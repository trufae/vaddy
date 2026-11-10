#!/usr/bin/env python3
"""Matched Caddy/Vaddy HTTP/1.1 benchmark. Requires TCP listeners and ps access.

Uses an external Go backend and load process. CPU/RSS measurements cover only
the server being compared; certificate creation and load generation are excluded.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import socket
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def unused_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def cpu_seconds(pid):
    if platform.system() == "Linux":
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")
    value = subprocess.check_output(["ps", "-p", str(pid), "-o", "time="], text=True).strip()
    days = 0
    if "-" in value:
        day, value = value.split("-", 1)
        days = int(day)
    total = 0.0
    for component in value.split(":"):
        total = total * 60 + float(component)
    return days * 86400 + total


def rss_kib(pid):
    return int(subprocess.check_output(["ps", "-p", str(pid), "-o", "rss="], text=True).strip())


def stop(proc):
    if proc.poll() is None:
        proc.terminate()
    try:
        proc.wait(timeout=12)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()


def measure(name, binary, config, root, driver, url, concurrency, seconds, size, vaddy_workers):
    data = root / f"data-{name}"
    data.mkdir(exist_ok=True)
    env = dict(os.environ, XDG_DATA_HOME=str(data), XDG_CONFIG_HOME=str(data))
    command = [binary, "run", "--config", str(config), "--adapter", "caddyfile"]
    if name == "vaddy":
        command += ["--data", str(data), "--bind", "127.0.0.1", "--workers", str(vaddy_workers)]
    with (root / f"{name}.log").open("w+") as log:
        server = subprocess.Popen(command, stdout=log, stderr=log, env=env)
        try:
            port = int(url.split(":")[2].split("/")[0])
            for _ in range(100):
                if server.poll() is not None:
                    log.seek(0)
                    raise RuntimeError(log.read())
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                        break
                except OSError:
                    time.sleep(0.05)
            else:
                raise RuntimeError(f"{name} failed to listen")
            idle_start = cpu_seconds(server.pid)
            time.sleep(2)
            idle_cpu = (cpu_seconds(server.pid) - idle_start) / 2 * 100
            idle_rss = rss_kib(server.pid)
            load_command = [str(driver), "-url", url, "-concurrency", str(concurrency), "-size", str(size)]
            subprocess.run(load_command + ["-seconds", "1"], check=True, stdout=subprocess.DEVNULL)
            cpu_start = cpu_seconds(server.pid)
            peak_rss = rss_kib(server.pid)
            load = subprocess.Popen(load_command + ["-seconds", str(seconds)], stdout=subprocess.PIPE, text=True)
            while load.poll() is None:
                peak_rss = max(peak_rss, rss_kib(server.pid))
                time.sleep(0.1)
            output, _ = load.communicate()
            if load.returncode:
                raise RuntimeError(f"load generator exited {load.returncode}")
            cpu_used = cpu_seconds(server.pid) - cpu_start
            result = json.loads(output)
            result.update(server=name, concurrency=concurrency,
                          cpu_seconds=cpu_used,
                          cpu_percent=100 * cpu_used / result["wall_seconds"],
                          cpu_us_per_request=1e6 * cpu_used / max(1, result["requests"]),
                          idle_cpu_percent=idle_cpu,
                          idle_rss_mib=idle_rss / 1024,
                          sampled_peak_rss_mib=peak_rss / 1024)
            if result["errors"]:
                raise RuntimeError(f"invalid benchmark: {result}")
            return result
        finally:
            stop(server)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--caddy", default=str(ROOT / "caddy-bench"))
    parser.add_argument("--vaddy", default=str(ROOT / "vaddy"))
    parser.add_argument("--seconds", type=float, default=10)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--concurrency", default="1,32")
    parser.add_argument("--size", type=int, default=512)
    parser.add_argument("--vaddy-workers", type=int, default=1, help="Vaddy event-loop workers, 1..64 (default: 1)")
    parser.add_argument("--plain", action="store_true", help="HTTP instead of TLS 1.3")
    parser.add_argument("--output", default="benchmark-results.json")
    args = parser.parse_args()
    binaries = {"caddy": shutil.which(args.caddy), "vaddy": shutil.which(args.vaddy)}
    if not all(binaries.values()):
        parser.error("build both binaries first: make && make caddy-bench")
    concurrency = [int(value) for value in args.concurrency.split(",")]
    if args.seconds <= 0 or args.runs < 1 or args.size < 1 or not 1 <= args.vaddy_workers <= 64 or any(c < 1 or c > 512 for c in concurrency):
        parser.error("positive duration/runs/size, concurrency 1..512 and Vaddy workers 1..64 required")
    with tempfile.TemporaryDirectory(prefix="vaddy-compare-") as directory:
        root = Path(directory)
        driver = root / "driver"
        subprocess.run(["go", "build", "-trimpath", "-o", str(driver), str(ROOT / "tests/bench_driver.go")], check=True)
        backend = subprocess.Popen([str(driver), "-mode", "backend", "-size", str(args.size)], stdout=subprocess.PIPE, text=True)
        try:
            upstream = backend.stdout.readline().strip()
            if not upstream:
                raise RuntimeError("backend failed to start")
            port, secure_port = unused_port(), unused_port()
            while port == secure_port:
                secure_port = unused_port()
            config = (ROOT / "Caddyfile").read_text()
            config = config.replace("admin off", f"admin off\n        http_port {port}\n        https_port {secure_port}")
            config = config.replace("localhost:8001", upstream)
            if args.plain:
                config = config.replace("example.org", "http://localhost")
                url = f"http://localhost:{port}/assets/bench.js"
            else:
                cert, key = root / "cert.pem", root / "key.pem"
                subprocess.run([os.getenv("VADDY_OPENSSL", "openssl"), "req", "-new", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost", "-days", "1", "-keyout", str(key), "-out", str(cert)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                config = config.replace("example.org {", f'localhost {{\n        tls "{cert}" "{key}"')
                url = f"https://localhost:{secure_port}/assets/bench.js"
            config_path = root / "Caddyfile"
            config_path.write_text(config)
            results = []
            for run in range(args.runs):
                for c in concurrency:
                    names = ["caddy", "vaddy"] if run % 2 == 0 else ["vaddy", "caddy"]
                    for name in names:
                        result = measure(name, binaries[name], config_path, root, driver, url, c, args.seconds, args.size, args.vaddy_workers)
                        result["run"] = run + 1
                        results.append(result)
                        print(json.dumps(result), flush=True)
            report = {"platform": platform.platform(), "tls": not args.plain, "http_version": "1.1", "response_bytes": args.size, "vaddy_workers": args.vaddy_workers, "results": results}
            Path(args.output).write_text(json.dumps(report, indent=2) + "\n")
            print("\nMedians (CPU%=100 means one fully used core; peak RSS sampled every 100ms):")
            print("server  clients     req/s    CPU%    CPU us/req   latency ms   idle MiB   peak MiB")
            for c in concurrency:
                for name in ("caddy", "vaddy"):
                    rows = [row for row in results if row["server"] == name and row["concurrency"] == c]
                    median = lambda key: statistics.median(row[key] for row in rows)
                    print(f'{name:7} {c:7} {median("requests_per_second"):9.0f} {median("cpu_percent"):7.1f} {median("cpu_us_per_request"):13.2f} {median("mean_latency_ms"):12.3f} {median("idle_rss_mib"):10.1f} {median("sampled_peak_rss_mib"):10.1f}')
        finally:
            stop(backend)


if __name__ == "__main__":
    main()
