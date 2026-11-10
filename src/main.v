module main

import os

const help_text = "vaddy 0.1.0 — streaming reverse proxy with automatic HTTPS
Usage: vaddy [run|validate|version] [options]
  --config FILE          Caddyfile (default: ./Caddyfile)
  --adapter caddyfile     Accepted for Caddy CLI compatibility
  --data DIR             Certificate/account storage (default: XDG data/vaddy)
  --bind ADDRESS         Listen address (default: ::, dual IPv4/IPv6)
  --http-port PORT       Override HTTP port (default: 80)
  --https-port PORT      Override HTTPS port (default: 443)
  --max-connections N    Bound active clients (default: 512)
  --workers N            Event-loop workers, 1..64 (default: 1)
  --idle-timeout SEC     Inactive connection timeout (default: 60)
  --header-timeout SEC   Header/handshake timeout (default: 15)
  --staging              Use Let's Encrypt staging CA and separate storage
  --help                 Show this help

Public HTTPS uses ACME HTTP-01. DNS must point to this server and public
TCP ports 80 and 443 must reach it. Starting an ACME-enabled configuration
registers an account agreeing to the configured CA's terms of service.
SIGTERM/SIGINT stop accepts and drain active requests for up to 10 seconds."

fn cli() ! {
	mut opts := Options{}
	mut command := 'run'
	mut i := 1
	if os.args.len > 1 && !os.args[1].starts_with('-') {
		command = os.args[1]
		i++
	}
	if command == 'version' {
		println('vaddy 0.1.0')
		return
	}
	if command !in ['run', 'validate'] { return error('unknown command ${command}; use --help') }
	for i < os.args.len {
		arg := os.args[i]
		if arg in ['--help', '-h'] {
			println(help_text)
			return
		}
		if arg == '--staging' {
			opts.staging = true
			i++
			continue
		}
		if i + 1 >= os.args.len { return error('missing value for ${arg}') }
		value := os.args[i + 1]
		match arg {
			'--config' { opts.config = value }
			'--data' { opts.data = value }
			'--bind' { opts.bind = value }
			'--adapter' {
				if value != 'caddyfile' { return error('only the caddyfile adapter is supported') }
			}
			'--http-port' { opts.http_port = port_value(value)! }
			'--https-port' { opts.https_port = port_value(value)! }
			'--max-connections' { opts.max_connections = port_value(value)! }
			'--workers' {
				opts.workers = port_value(value)!
				if opts.workers > 64 { return error('--workers must be between 1 and 64') }
			}
			'--idle-timeout' { opts.idle_timeout = port_value(value)! }
			'--header-timeout' { opts.header_timeout = port_value(value)! }
			else { return error('unknown option ${arg}') }
		}
		i += 2
	}
	mut cfg := parse_config(os.read_file(opts.config)!)!
	if opts.http_port > 0 { cfg.http_port = opts.http_port }
	if opts.https_port > 0 { cfg.https_port = opts.https_port }
	if cfg.http_port == cfg.https_port { return error('HTTP and HTTPS ports must differ') }
	if opts.staging { cfg.acme_ca = 'https://acme-staging-v02.api.letsencrypt.org/directory' }
	acme_url(cfg.acme_ca)!
	if command == 'validate' {
		println('Valid configuration: ${cfg.sites.len} site(s), HTTP ${cfg.http_port}, HTTPS ${cfg.https_port}')
		return
	}
	if opts.data == '' {
		base := os.getenv('XDG_DATA_HOME')
		opts.data = os.join_path(if base == '' {
			os.join_path(os.home_dir(), '.local', 'share')
		} else {
			base
		}, 'vaddy')
	}
	if opts.staging { opts.data = os.join_path(opts.data, 'staging') }
	opts.data = os.abs_path(opts.data)
	C.vaddy_private_files()
	os.mkdir_all(opts.data, mode: 0o700)!
	os.chmod(opts.data, 0o700)!
	os.mkdir_all(os.join_path(opts.data, 'challenges'), mode: 0o700)!
	lock_fd := C.vaddy_lock(&char(os.join_path(opts.data, 'lock').str))
	if lock_fd < 0 {
		return error('data directory is locked by another vaddy process: ${opts.data}')
	}
	defer { C.close(lock_fd) }
	if site := cfg.tls_site() {
		if site.tls_mode != 'manual' { openssl_executable()! }
	}
	C.vaddy_signals()
	run_server(cfg, opts)!
}

fn main() {
	cli() or {
		eprintln('vaddy: ${err}')
		exit(1)
	}
}
