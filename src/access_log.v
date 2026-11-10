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
	shared_mutex bool
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
		proto: c.request.start.all_after_last(' ')
		method: c.request.method
		host: c.request.host
		uri: c.request.uri
		headers: log_headers(c.request.fields.filter(it.lower !in ['host', 'transfer-encoding']))
		transfer_encoding: if c.request.frame.kind == .chunked { ['chunked'] } else { []string{} }
		tls: tls
	}
}

fn parse_access_log(d Directive) !string {
	if d.args.len !in [1, 2] { return error('expected log [name] { output ... }') }
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
		if !logger.shared_mutex { logger.mutex.destroy() }
	}
}

fn (mut s Server) log_access(mut c Connection, _complete bool) {
	if c.access_log == unsafe { nil } || c.access_logged || !c.have_request { return }
	c.access_logged = true
	mut response_headers := log_headers(c.log_response_fields)
	if c.log_empty_content_type && 'Content-Type' !in response_headers { response_headers['Content-Type'] = []string{} }
	record := AccessRecord{
		level: if c.log_status >= 500 { 'error' } else { 'info' }
		ts: f64(time.now().unix_nano()) / 1e9
		logger: 'http.log.access' + if c.log_name == '' { '' } else { '.' + c.log_name }
		request: request_log(c)
		bytes_read: c.log_bytes_read
		duration: f64(time.sys_mono_now() - c.log_started) / 1e9
		size: c.log_size
		status: c.log_status
		resp_headers: response_headers
	}
	line := json2.encode(record, escape_unicode: true, time_as_unix: true)
	mut logger := c.access_log
	logger.mutex.lock()
	defer { logger.mutex.unlock() }
	logger.file.writeln(line) or { eprintln('vaddy: access log write failed: ${err}') }
	logger.file.flush()
}

fn share_log_mutex(logs map[string]&AccessLog, mutex &sync.Mutex) {
	for _, entry in logs {
		mut logger := unsafe { entry }
		logger.mutex.destroy()
		logger.mutex = mutex
		logger.shared_mutex = true
	}
}
