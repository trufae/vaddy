module main

import src.log
import time
import x.json2

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

fn request_log(c &Connection) log.Request {
	mut tls := ?log.TLS(none)
	if !isnil(c.tls) {
		mut version := 0
		mut cipher := 0
		mut resumed := 0
		mut name := [256]char{}
		mut proto := [256]char{}
		mut name_len := 0
		mut proto_len := 0
		C.vaddy_tls_details(c.tls, &version, &cipher, &resumed, &name[0], name.len, &name_len,
			&proto[0], proto.len, &proto_len)
		tls = log.TLS{resumed != 0, version, cipher, copy_platform_string(&proto[0], proto_len),
			copy_platform_string(&name[0], name_len), false}
	}
	return log.Request{
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

fn (mut c Connection) log_access() {
	if c.access_targets.len == 0 || c.access_logged || !c.have_request { return }
	c.access_logged = true
	mut level := if c.log_status >= 500 { 3 } else { 1 }
	for rule in &c.log_rules {
		if !header_edit_matches(rule.match, [], c.header_values, 0) { continue }
		if rule.kind in ['log_skip', 'skip_log'] { return }
		if rule.kind == 'log_level' { level = log.level(rule.args[0]) or { level } }
	}
	if !c.access_targets.any(level >= it.config.level) { return }
	mut response_headers := log_headers(c.log_response_fields)
	if c.log_empty_content_type && 'Content-Type' !in response_headers { response_headers['Content-Type'] = []string{} }
	// Final logging consumes the early fields once for all outputs.
	mut extra := c.log_early.move()
	// Deferred append handlers unwind in reverse order.
	for i := c.log_rules.len - 1; i >= 0; i-- {
		rule := &c.log_rules[i]
		if rule.kind == 'log_append' && !rule.args[0].starts_with('<') && header_edit_matches(rule.match, [], c.header_values, 0) {
			extra[rule.args[0].trim_string_left('<')] = log_append_value(rule.args[1], c.header_values)
		}
	}
	request := request_log(c)
	for target in c.access_targets {
		if level < target.config.level { continue }
		record := log.Record{
			level: ['debug', 'info', 'warn', 'error'][level]
			ts: f64(time.now().unix_nano()) / 1e9
			logger: 'http.log.access' + if target.config.name == '' { '' } else { '.' + target.config.name }
			request: request
			bytes_read: c.log_bytes_read
			duration: f64(time.sys_mono_now() - c.log_started) / 1e9
			size: c.log_size
			status: c.log_status
			resp_headers: response_headers
		}
		line := target.config.encode(record, extra) or { eprintln('vaddy: log encoding failed: ${err}'); continue }
		mut logger := target.writer
		logger.write_line(line) or { eprintln('vaddy: access log write failed: ${err}') }
	}
}

fn access_targets(cfg &Config, site &Site, writers map[string]&log.Writer, rules []LogRule, values HeaderValues) []log.Target {
	mut names := []string{}
	for rule in &rules {
		if rule.kind == 'log_name' && header_edit_matches(rule.match, [], values, 0) { names = rule.args }
	}
	mut targets := []log.Target{}
	for candidate in &cfg.sites {
		for config in candidate.logs {
			if !config.matches(names, values.host, candidate.hosts == site.hosts) { continue }
			if writer := writers[config.output.output] { targets << log.Target{config, writer} }
		}
	}
	return targets
}

fn log_append_value(value string, values &HeaderValues) json2.Any {
	if value.starts_with('{') && value.ends_with('}') && value.count('{') == 1 {
		return placeholder_value(value[1..value.len - 1], values) or { return json2.null }
	}
	return value
}

fn (mut c Connection) capture_early_logs(rules []LogRule) {
	for rule in &rules {
		if rule.kind == 'log_append' && rule.args[0].starts_with('<') && header_edit_matches(rule.match, [], c.header_values, 0) {
			value := rule.args[1]
			c.log_early[rule.args[0][1..]] = if value.starts_with('{http.response.') { json2.Any(json2.null) } else { log_append_value(value, c.header_values) }
		}
	}
}
