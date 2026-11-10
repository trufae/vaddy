// Compiled by ipc_bench.py in a temporary copy of the production source.
// Only listener setup is replaced: inherited socket pairs enter the real reactors.
module main

import os

fn C.vaddy_nonblock(int) int

fn ipc_server() ! {
	count := os.args[1].int()
	workers := os.args[2].int()
	cert := os.args[3]
	key := os.args[4]
	use_tls := cert != '-'
	mut cfg := parse_config(os.read_file(os.join_path(@VMODROOT, 'Caddyfile'))!.replace('example.org', 'localhost'))!
	cfg.sites[0].plain = !use_tls
	mut s := Server{cfg: cfg, opts: Options{workers: workers, max_connections: count, max_keepalive_requests: 100000000}, queue: C.vaddy_queue()}
	if s.queue < 0 { return error('event queue failed') }
	defer { C.close(s.queue) }
	if use_tls {
		s.ctx = C.vaddy_tls_context(&char(cert.str), &char(key.str))
		if s.ctx == unsafe { nil } { return error('TLS context failed') }
	}
	defer {
		for _, mut c in s.clients.clone() { s.close_client(mut c) }
		if s.ctx != unsafe { nil } { C.vaddy_tls_ctx_free(s.ctx) }
	}
	C.vaddy_signals()
	defer { s.stop_workers() }
	s.start_workers()!
	for i in 0 .. count {
		fd := 3 + i * 2
		backend := fd + 1
		if C.vaddy_nonblock(fd) != 0 || C.vaddy_nonblock(backend) != 0 { return error('nonblock failed') }
		mut c := &Connection{fd: fd, backend: backend, backend_name: 'localhost:8001', ip: '127.0.0.1', started: mono_ms(), last_activity: mono_ms()}
		if use_tls {
			c.tls = C.vaddy_tls_new(s.ctx, fd)
			if c.tls == unsafe { nil } { return error('TLS allocation failed') }
			c.handshake = true
		}
		s.dispatch_client(mut c)
	}
	s.serve_events()!
}

fn main() {
	ipc_server() or { eprintln(err); exit(1) }
}
