module main

import os
import flag

const options = ['run', 'reload', 'respond', 'file-server', 'validate', 'version']

const help_header = "vaddy 0.1.0 — streaming reverse proxy with automatic HTTPS
Usage: vaddy [${options.join('|')}] [options]"

const help_footer = "Examples:
  # Run a demo HTTP server
  vaddy respond \"It works!\" --http-port 8080
  # Serve the files in the current directory
  vaddy file-server
  # Load and run a config file
  vaddy run --config ./Caddyfile

Public HTTPS uses ACME HTTP-01. DNS must point to this server and public
TCP ports 80 and 443 must reach it. Starting an ACME-enabled configuration
registers an account agreeing to the configured CA's terms of service.
Use reload with the same --data directory to replace request settings live.
On POSIX, SIGHUP reloads the active config file.
SIGTERM/SIGINT stop accepts and drain active requests for up to 10 seconds."

fn cli() ! {
	// Parse flags
	mut opts, other_args := flag.to_struct[Options](os.args, skip: 1)!

	// Help/Version display
	if opts.help {
		print_help()
		return
	}
	if opts.version {
		println('vaddy ${vaddy_version}')
		return
	}

	// Setup data
	if opts.data == '' {
		base := os.getenv_opt('XDG_DATA_HOME') or {
			os.join_path(os.home_dir(), '.local', 'share')
		}
		opts.data = os.join_path(base, 'vaddy')
	}
	if opts.staging { opts.data = os.join_path(opts.data, 'staging') }
	opts.data = os.abs_path(opts.data)

	cfg := match other_args[0] or {
		print_help()
		return
	} {
		'version' {
			println('vaddy ${vaddy_version}')
			return
		}
		'run' {
			if !os.exists(opts.config) {
				return error('config file doesn\'t exist: "${opts.config}"')
			}
			if opts.config == '' {
				return error('run requires a config file, e.g. vaddy run --config ./Caddyfile')
			}
			config_text := os.read_file(opts.config) or {
				return error('error reading config file: ${err.msg()}')
			}
			load_config(config_text, opts)!
		}
		'validate' {
			if !os.exists(opts.config) {
				return error('config file doesn\'t exist: "${opts.config}"')
			}
			if opts.config == '' {
				return error('validate requires a config file, e.g. vaddy validate --config ./Caddyfile')
			}
			config_text := os.read_file(opts.config) or {
				return error('error reading config file: ${err.msg()}')
			}
			cfg := load_config(config_text, opts)!
			println('Valid configuration: ${cfg.sites.len} site(s), HTTP ${cfg.http_port}, HTTPS ${cfg.https_port}')
			return
		}
		'respond' {
			mut cfg := new_config(opts)!
			cfg.sites << Site{
				plain: true
				hosts: ['*']
				routes: [Route{
					patterns: ['*']
					respond: other_args[1] or {
						return error('please provide text to respond with')
					}
					upstream: '${opts.bind}:${opts.http_port}'
				}]
				root: '/'
			}
			cfg
		}
		'file-server' {
			mut cfg := new_config(opts)!
			cfg.sites << Site{
				plain: true
				hosts: ['*']
				routes: [Route{
					files: FileConfig{
						enabled: true
						browse: true
					}
					root: os.getwd()
				}]
			}
			cfg
		}
		'reload' {
			request_reload(opts)!
			return
		}
		else {
			print_help()
			return
		}
	}

	C.vaddy_private_files()
	os.mkdir_all(opts.data, mode: 0o700)!
	os.chmod(opts.data, 0o700)!
	os.mkdir_all(os.join_path(opts.data, 'challenges'), mode: 0o700)!
	lock_fd := C.vaddy_lock(&char(os.join_path(opts.data, 'lock').str))
	if lock_fd < 0 {
		return error('data directory is locked by another vaddy process: ${opts.data}')
	}
	defer { C.vaddy_unlock(lock_fd) }
	if site := cfg.tls_site() {
		if site.tls_mode != 'manual' { openssl_executable()! }
	}
	C.vaddy_signals()
	run_server(cfg, opts)!
}

fn print_help() {
	println(help_header)
	println(flag.to_doc[Options]() or {''})
	println('\n${help_footer}')
}
