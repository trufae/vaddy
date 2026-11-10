#!/usr/bin/env python3
"""Measure real Vaddy reactors in a child process using inherited socket pairs."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--seconds", type=int, default=5)
    p.add_argument("--runs", type=int, default=3)
    p.add_argument("--workers", default="1,2")
    p.add_argument("--clients", type=int, default=32)
    p.add_argument("--size", type=int, default=512)
    p.add_argument("--plain", action="store_true")
    p.add_argument("--profile", help="V function profile output; use one worker")
    p.add_argument("--output", default="benchmark-workers.json")
    args = p.parse_args()
    workers = [int(n) for n in args.workers.split(",")]
    if not 1 <= args.clients <= 512 or args.seconds < 1 or args.runs < 1 or args.size < 1 or any(n < 1 or n > 64 for n in workers):
        p.error("positive duration/runs/size, 1..512 clients and 1..64 workers required")
    with tempfile.TemporaryDirectory(prefix="vaddy-ipc-") as folder:
        root = Path(folder)
        (root / "src").mkdir()
        for source in (ROOT / "src").glob("*"):
            if source.name != "main.v" and not source.name.endswith("_test.v") and source.suffix in (".v", ".h"):
                shutil.copyfile(source, root / "src" / source.name)
        shutil.copyfile(ROOT / "tests/ipc_server.v", root / "src/main.v")
        for name in ("v.mod", "Caddyfile"):
            shutil.copyfile(ROOT / name, root / name)
        server, driver = root / "vaddy-ipc", root / "driver"
        subprocess.run([os.getenv("V", "v"), *(["-profile", args.profile] if args.profile else []), "-prod", "-cc", "clang", "-gc", "boehm", "-d", "use_openssl", "-o", str(server), str(root / "src")], check=True)
        subprocess.run(["go", "build", "-trimpath", "-o", str(driver), str(ROOT / "tests/ipc_driver.go")], check=True)
        cert, key = "-", "-"
        if not args.plain:
            cert, key = str(root / "cert.pem"), str(root / "key.pem")
            subprocess.run([os.getenv("VADDY_OPENSSL", "openssl"), "req", "-new", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost", "-days", "1", "-keyout", key, "-out", cert], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        results = []
        for run in range(args.runs):
            for count in workers if run % 2 == 0 else workers[::-1]:
                raw = subprocess.check_output([str(driver), "-server", str(server), "-workers", str(count), "-clients", str(args.clients), "-duration", f"{args.seconds}s", "-size", str(args.size), "-cert", cert, "-key", key], text=True, timeout=args.seconds + 40)
                result = json.loads(raw)
                result["run"] = run + 1
                results.append(result)
                print(json.dumps(result), flush=True)
        Path(args.output).write_text(json.dumps({"transport": "anonymous Unix socket pairs", "results": results}, indent=2) + "\n")


if __name__ == "__main__":
    main()
