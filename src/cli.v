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
	stop := os.args.index('--')
	separator := if stop < 0 { os.args.len } else { stop }
	mut opts, mut args := flag.to_struct[Options](os.args[..separator], skip: 1)!
	if opts.help {
		print_help()
		return
	}
	if opts.version {
		println('vaddy ${vaddy_version}')
		return
	}

	for arg in args {
		if arg.starts_with('-') { return error('unknown option ${arg}') }
	}
	if separator < os.args.len { args << os.args[separator + 1..] }
	command := args[0] or { 'run' }
	if command !in options { return error('unknown command ${command}. See --help') }
	if command == 'respond' {
		if args.len != 2 { return error('usage: vaddy respond BODY') }
	} else if args.len > 1 {
		return error('unexpected argument ${args[1]}')
	}
	if command == 'version' {
		println('vaddy ${vaddy_version}')
		return
	}
	if opts.adapter != 'caddyfile' { return error('only the caddyfile adapter is supported') }
	if opts.workers !in 1 .. 65 { return error('--workers must be between 1 and 64') }
	for name, value in {
		'max-connections': opts.max_connections
		'idle-timeout': opts.idle_timeout
		'header-timeout': opts.header_timeout
	} {
		if value !in 1 .. 65536 { return error('invalid --${name}: ${value}') }
	}
	if opts.max_keepalive_requests < 1 { return error('--max-keepalive-requests must be positive') }
	if opts.http_port != '' { port_value(opts.http_port)! }
	if opts.https_port != '' { port_value(opts.https_port)! }
	if opts.config == '' && command in ['run', 'validate', 'reload'] { opts.config = 'Caddyfile' }

	if opts.data == '' {
		base := os.getenv('XDG_DATA_HOME')
		opts.data = os.join_path(if base == '' { os.join_path(os.home_dir(), '.local', 'share') } else { base }, 'vaddy')
	}
	if opts.staging { opts.data = os.join_path(opts.data, 'staging') }
	opts.data = os.abs_path(opts.data)

	config := match command {
		'run', 'validate' {
			loaded := load_config(os.read_file(opts.config)!, opts)!
			if command == 'validate' {
				println('Valid configuration: ${loaded.sites.len} site(s), HTTP ${loaded.http_port}, HTTPS ${loaded.https_port}')
				return
			}
			loaded
		}
		'respond' {
			mut cfg := new_config(opts)!
			cfg.sites << Site{plain: true, hosts: ['*'], routes: [Route{respond: args[1]}]}
			cfg
		}
		'file-server' {
			root := os.getwd()
			if data_inside_root(opts.data, root) { return error('--data must be outside the file-server root') }
			mut cfg := new_config(opts)!
			cfg.sites << Site{
				plain: true
				hosts: ['*']
				routes: [Route{
					files: FileConfig{
						enabled: true
						browse: true
					}
					root: root
				}]
			}
			cfg
		}
		'reload' {
			request_reload(opts)!
			return
		}
		else { return error('unknown command ${command}') }
	}

	C.vaddy_private_files()
	os.mkdir_all(opts.data, mode: 0o700)!
	if command == 'file-server' && data_inside_root(os.real_path(opts.data), os.real_path(os.getwd())) {
		return error('--data must be outside the file-server root')
	}
	os.chmod(opts.data, 0o700)!
	os.mkdir_all(os.join_path(opts.data, 'challenges'), mode: 0o700)!
	lock_fd := C.vaddy_lock(&char(os.join_path(opts.data, 'lock').str))
	if lock_fd < 0 {
		return error('data directory is locked by another vaddy process: ${opts.data}')
	}
	defer { C.vaddy_unlock(lock_fd) }
	if site := config.tls_site() {
		if site.tls_mode != 'manual' { openssl_executable()! }
	}
	C.vaddy_signals()
	run_server(config, opts)!
}

fn data_inside_root(data string, root string) bool {
	$if windows { return path_within(data.to_lower(), root.to_lower()) }
	return path_within(data, root)
}

fn path_within(path string, root string) bool {
	return path == root || path.starts_with(root.trim_right(os.path_separator) + os.path_separator)
}

fn print_help() {
	println(help_header)
	println(flag.to_doc[Options]() or {''})
	println('\n${help_footer}')
}
