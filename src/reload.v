module main

import os
import time
import sync
import sync.stdatomic
import json2
import crypto.rand as crypto_rand
import encoding.hex

@[heap]
struct Runtime {
	id i64
	cfg Config
	backends map[string]Backend
	logs map[string]&AccessLog
mut:
	users i64
}

@[heap]
struct RuntimeStore {
mut:
	mutex &sync.Mutex = sync.new_mutex()
	log_mutex &sync.Mutex = sync.new_mutex()
	current &Runtime = unsafe { nil }
}

fn load_config(input string, opts Options) !Config {
	mut cfg := parse_config(input)!
	if opts.http_port > 0 { cfg.http_port = opts.http_port }
	if opts.https_port > 0 { cfg.https_port = opts.https_port }
	if cfg.http_port == cfg.https_port { return error('HTTP and HTTPS ports must differ') }
	if opts.staging { cfg.acme_ca = 'https://acme-staging-v02.api.letsencrypt.org/directory' }
	acme_url(cfg.acme_ca)!
	return cfg
}

fn prepare_runtime(cfg Config, id i64, log_mutex &sync.Mutex) !&Runtime {
	backends := prepare_backends(cfg)!
	// Even validation briefly opens log files; serialize it with rotations.
	log_mutex.lock()
	defer { log_mutex.unlock() }
	logs := prepare_access_logs(cfg) or {
		free_backends(backends)
		return err
	}
	share_log_mutex(logs, log_mutex)
	return &Runtime{id: id, cfg: cfg, backends: backends, logs: logs}
}

fn (mut store RuntimeStore) acquire() &Runtime {
	store.mutex.lock()
	defer { store.mutex.unlock() }
	mut current := store.current
	stdatomic.add_i64(&current.users, 1)
	return current
}

fn release_runtime(mut c Connection) {
	if c.runtime != unsafe { nil } {
		stdatomic.sub_i64(&c.runtime.users, 1)
		c.runtime = unsafe { nil }
	}
}

fn destroy_runtime(runtime &Runtime) {
	free_backends(runtime.backends)
	close_access_logs(runtime.logs)
}

fn (mut s Server) reap_runtimes() {
	mut active := []&Runtime{}
	for runtime in s.retired {
		if stdatomic.load_i64(&runtime.users) == 0 { destroy_runtime(runtime) }
		else { active << runtime }
	}
	s.retired = active
}

fn (mut s Server) close_runtimes() {
	s.reap_runtimes()
	destroy_runtime(s.runtime_store.current)
	s.runtime_store.mutex.destroy()
	s.runtime_store.log_mutex.destroy()
}

fn reload_tls_policy(cfg Config) string {
	site := cfg.tls_site() or { return '' }
	names := cfg.domains()
	return '${site.tls_mode}\n${site.cert}\n${site.key}\n${cfg.acme_ca}\n${cfg.email}\n${names.join('\n')}'
}

fn (mut s Server) replace_config(input string) ! {
	cfg := load_config(input, s.opts)!
	if cfg.http_port != s.cfg.http_port || cfg.https_port != s.cfg.https_port {
		return error('listener port changes require a restart')
	}
	if reload_tls_policy(cfg) != reload_tls_policy(s.cfg) {
		return error('HTTPS hostname or certificate-policy changes require a restart')
	}
	// All fallible resource preparation precedes publication. Existing requests
	// retain their generation until completion, including long-lived streams.
	candidate := prepare_runtime(cfg, s.runtime_store.current.id + 1, s.runtime_store.log_mutex)!
	s.runtime_store.mutex.lock()
	previous := s.runtime_store.current
	s.runtime_store.current = candidate
	s.runtime_store.mutex.unlock()
	s.retired << previous
	s.cfg = cfg
	s.backends = candidate.backends
	s.access_logs = candidate.logs
	eprintln('vaddy: configuration reloaded (generation ${candidate.id})')
}

struct ReloadRequest {
	id string
	run_id string
	config string
	path string
}

struct ReloadResult {
	id string
	ok bool
	message string
}

fn new_reload_id() !string { return hex.encode(crypto_rand.bytes(16)!) }

fn (mut s Server) check_reload() {
	if C.vaddy_take_reload() != 0 {
		input := os.read_file(s.opts.config) or {
			eprintln('vaddy: reload rejected: ${err}')
			return
		}
		s.replace_config(input) or { eprintln('vaddy: reload rejected: ${err}') }
	}
	path := os.join_path(s.opts.data, 'reload.request')
	if !os.exists(path) { return }
	input := os.read_file(path) or { return }
	os.rm(path) or { return }
	request := json2.decode[ReloadRequest](input) or {
		eprintln('vaddy: invalid reload request')
		return
	}
	if request.id.len != 32 || !request.id.bytes().all(it.is_hex_digit()) { return }
	mut message := ''
	if request.run_id != s.run_id { message = 'server restarted; retry reload' }
	else {
		s.replace_config(request.config) or { message = err.msg() }
	}
	if message == '' { s.opts.config = request.path }
	else { eprintln('vaddy: reload rejected: ${message}') }
	result := ReloadResult{request.id, message == '', message}
	atomic_write(os.join_path(s.opts.data, 'reload.result'), json2.encode(result)) or {
		eprintln('vaddy: cannot publish reload result: ${err}')
	}
}

fn request_reload(opts Options) ! {
	// The existing server owns this lock. Never leave a request for a future run.
	probe := C.vaddy_lock(&char(os.join_path(opts.data, 'lock').str))
	if probe >= 0 {
		C.vaddy_unlock(probe)
		return error('no running vaddy server owns this data directory')
	}
	run_id := os.read_file(os.join_path(opts.data, 'run.id'))!
	lock_fd := C.vaddy_lock(&char(os.join_path(opts.data, 'reload.lock').str))
	if lock_fd < 0 { return error('another reload is in progress') }
	defer { C.vaddy_unlock(lock_fd) }
	id := new_reload_id()!
	request := ReloadRequest{id, run_id, os.read_file(opts.config)!, os.abs_path(opts.config)}
	atomic_write(os.join_path(opts.data, 'reload.request'), json2.encode(request))!
	deadline := mono_ms() + 30000
	for mono_ms() < deadline {
		if result := json2.decode[ReloadResult](os.read_file(os.join_path(opts.data, 'reload.result')) or { '' }) {
			if result.id == id {
				if !result.ok { return error(result.message) }
				println('Configuration reloaded')
				return
			}
		}
		time.sleep(50 * time.millisecond)
	}
	return error('reload result timed out; inspect server logs before retrying')
}
