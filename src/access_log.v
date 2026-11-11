module main

import os
import sync
import time

@[heap]
struct AccessLog {
mut:
	mutex &sync.Mutex = sync.new_mutex()
	file os.File
	owned bool
	shared_mutex bool
	options LogOptions
	opened i64
}

struct LogTLS {
	resumed bool
	version int
	cipher_suite int
	proto string
	server_name string
	ech bool
}

struct LogRequest {
	remote_ip string
	remote_port string
	client_ip string
	proto string
	method string
	host string
	uri string
	headers map[string][]string
	transfer_encoding []string @[omitempty]
	tls ?LogTLS
}

struct AccessRecord {
	level string
	ts f64
	logger string
	msg string = 'handled request'
	request LogRequest
	bytes_read i64
	user_id string
	duration f64
	size i64
	status int
	resp_headers map[string][]string
}

fn log_headers(fields []Field) map[string][]string {
	mut headers := map[string][]string{}
	for field in fields {
		name := field.lower.split('-').map(it.capitalize()).join('-')
		if field.lower in ['authorization', 'proxy-authorization', 'cookie', 'set-cookie'] {
			headers[name] = ['REDACTED']
		} else { headers[name] << field.value }
	}
	return headers
}

fn request_log(c &Connection) LogRequest {
	mut tls := ?LogTLS(none)
	if c.tls != unsafe { nil } {
		mut version := 0
		mut cipher := 0
		mut resumed := 0
		mut name := [256]char{}
		mut proto := [256]char{}
		C.vaddy_tls_details(c.tls, &version, &cipher, &resumed, &name[0], name.len, &proto[0], proto.len)
		tls = LogTLS{resumed != 0, version, cipher, unsafe { cstring_to_vstring(&proto[0]) }, unsafe { cstring_to_vstring(&name[0]) }, false}
	}
	return LogRequest{
		remote_ip: c.ip
		remote_port: c.remote_port
		client_ip: c.ip
		proto: if c.h2_id != 0 { 'HTTP/2.0' } else { c.request.start.all_after_last(' ') }
		method: c.request.method
		host: c.request.host
		uri: c.request.uri
		headers: log_headers(c.request.fields.filter(it.lower !in ['host', 'transfer-encoding']))
		transfer_encoding: if c.request.frame.kind == .chunked { ['chunked'] } else { []string{} }
		tls: tls
	}
}

fn parse_access_log(d Directive) !LogConfig {
	if d.args.len !in [1, 2] { return error('expected log [name] { output ... }') }
	mut config := LogConfig{}
	mut seen := map[string]bool{}
	for child in d.children {
		if child.args.len == 0 { return error('empty log option') }
		name := child.args[0]
		if name in seen && name != 'hostnames' { return error('duplicate log option ${name}') }
		seen[name] = true
		match name {
			'output' { parse_log_output(child, mut config.output)! }
			'format' { config.format = parse_log_format(child)! }
			'level' { if child.args.len != 2 || child.children.len > 0 { return error('expected log level LEVEL') }; config.level = log_level(child.args[1])! }
			'no_hostname' { if child.args.len != 1 || child.children.len > 0 { return error('no_hostname takes no arguments') }; config.no_hostname = true }
			'hostnames' { if child.args.len < 2 || child.children.len > 0 { return error('expected hostnames') }; config.hostnames << child.args[1..] }
			else { return error('unsupported log option ${name}') }
		}
	}
	return config
}

fn prepare_access_logs(cfg Config) !map[string]&AccessLog {
	mut logs := map[string]&AccessLog{}
	mut complete := false
	defer { if !complete { close_access_logs(logs) } }
	for site in cfg.sites {
		for config in site.logs {
			output := config.output.output
			if output == '' { continue }
			if previous := logs[output] {
				if previous.options != config.output { return error('conflicting options for shared log output') }
				continue
			}
			mut file := match output {
				'stderr' { os.stderr() }
				'stdout' { os.stdout() }
				'discard' { os.File{} }
				else { open_log_file(config.output)! }
			}
			logs[output] = &AccessLog{file: file, owned: output.starts_with('file:'), options: config.output, opened: time.sys_mono_now()}
		}
	}
	complete = true
	return logs
}

fn close_access_logs(logs map[string]&AccessLog) {
	for _, entry in logs {
		mut logger := unsafe { entry }
		if logger.owned { logger.file.close() }
		if !logger.shared_mutex { logger.mutex.destroy() }
	}
}

fn (mut s Server) log_access(mut c Connection, _complete bool) {
	if c.access_targets.len == 0 || c.access_logged || !c.have_request { return }
	c.access_logged = true
	mut level := if c.log_status >= 500 { 3 } else { 1 }
	for rule in c.log_rules {
		if !header_edit_matches(rule.match, [], c.header_values, 0) { continue }
		if rule.kind in ['log_skip', 'skip_log'] { return }
		if rule.kind == 'log_level' { level = log_level(rule.args[0]) or { level } }
	}
	mut response_headers := log_headers(c.log_response_fields)
	if c.log_empty_content_type && 'Content-Type' !in response_headers { response_headers['Content-Type'] = []string{} }
	for target in c.access_targets {
		if level < target.config.level { continue }
		record := AccessRecord{
			level: ['debug', 'info', 'warn', 'error'][level]
			ts: f64(time.now().unix_nano()) / 1e9
			logger: 'http.log.access' + if target.config.name == '' { '' } else { '.' + target.config.name }
			request: request_log(c)
			bytes_read: c.log_bytes_read
			duration: f64(time.sys_mono_now() - c.log_started) / 1e9
			size: c.log_size
			status: c.log_status
			resp_headers: response_headers
		}
		mut extra := c.log_early.clone()
		// Deferred append handlers unwind in reverse order.
		for rule in c.log_rules.reverse() {
			if rule.kind == 'log_append' && !rule.args[0].starts_with('<') && header_edit_matches(rule.match, [], c.header_values, 0) {
				extra[rule.args[0].trim_string_left('<')] = log_append_value(rule.args[1], c)
			}
		}
		line := encode_access_record(record, target.config.format, extra) or { eprintln('vaddy: log encoding failed: ${err}'); continue }
		mut logger := target.writer
		logger.mutex.lock()
		logger.write_line(line) or { eprintln('vaddy: access log write failed: ${err}') }
		logger.mutex.unlock()
	}
}

fn share_log_mutex(logs map[string]&AccessLog, mutex &sync.Mutex) {
	for _, entry in logs {
		mut logger := unsafe { entry }
		logger.mutex.destroy()
		logger.mutex = mutex
		logger.shared_mutex = true
	}
}
