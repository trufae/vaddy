module main

import os
import sync
import time
import json2

@[heap]
struct AccessLog {
mut:
	mutex &sync.Mutex = sync.new_mutex()
	file os.File
	owned bool
}

struct AccessRecord {
	ts i64
	remote_ip string
	method string
	host string
	uri string
	status int
	bytes_written i64
	duration_ms i64
	upstream string
	complete bool
}

fn parse_access_log(d Directive) !string {
	if d.args.len != 1 { return error('expected log or log { output ... }') }
	mut output := 'stderr'
	mut seen := false
	for child in d.children {
		if child.children.len > 0 { return error('nested log options are unsupported') }
		if child.args == ['format', 'json'] { continue }
		if child.args.len >= 2 && child.args[0] == 'output' && !seen {
			seen = true
			if child.args.len == 2 && child.args[1] in ['stdout', 'stderr'] {
				output = child.args[1]
			} else if child.args.len == 3 && child.args[1] == 'file' && child.args[2] != '' {
				output = 'file:' + os.abs_path(child.args[2])
			} else { return error('log output must be stdout, stderr or file PATH') }
		} else { return error('unsupported log option') }
	}
	return output
}

fn prepare_access_logs(cfg Config) !map[string]&AccessLog {
	mut logs := map[string]&AccessLog{}
	mut complete := false
	defer { if !complete { close_access_logs(logs) } }
	for site in cfg.sites {
		output := site.log_output
		if output == '' || output in logs { continue }
		mut file := match output {
			'stderr' { os.stderr() }
			'stdout' { os.stdout() }
			else { os.open_file(output.trim_string_left('file:'), 'a', 0o600)! }
		}
		logs[output] = &AccessLog{file: file, owned: output.starts_with('file:')}
	}
	complete = true
	return logs
}

fn close_access_logs(logs map[string]&AccessLog) {
	for _, entry in logs {
		mut logger := unsafe { entry }
		if logger.owned { logger.file.close() }
		logger.mutex.destroy()
	}
}

fn (mut s Server) log_access(mut c Connection, complete bool) {
	if c.access_log == unsafe { nil } || c.access_logged || !c.have_request { return }
	c.access_logged = true
	record := AccessRecord{time.now().unix_milli(), c.ip, c.request.method, c.request.host, c.request.uri,
		c.log_status, c.bytes_written, mono_ms() - c.log_started, c.log_upstream, complete}
	line := json2.encode(record, escape_unicode: true, time_as_unix: true)
	mut logger := c.access_log
	logger.mutex.lock()
	defer { logger.mutex.unlock() }
	logger.file.writeln(line) or { eprintln('vaddy: access log write failed: ${err}') }
	logger.file.flush()
}
