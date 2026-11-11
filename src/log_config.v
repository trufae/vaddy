module main

import x.json2

struct LogConfig {
mut:
	name string
	output LogOptions
	format LogFormat
	level int = 1
	no_hostname bool
	hostnames []string
}

struct LogRule {
mut:
	kind string
	args []string
	match HeaderEdit
}

struct AccessTarget {
	config LogConfig
	writer &AccessLog = unsafe { nil }
}

fn log_level(value string) !int {
	return match value.to_lower() {
		'debug' { 0 }
		'info' { 1 }
		'warn', 'warning' { 2 }
		'error' { 3 }
		else { return error('log level must be DEBUG, INFO, WARN or ERROR') }
	}
}

fn parse_log_rule(d Directive) !LogRule {
	if d.children.len > 0 { return error('log request directives do not accept blocks') }
	mut args := d.args[1..].clone()
	mut matcher := HeaderEdit{}
	if args.len > 0 && (args[0] == '*' || args[0].starts_with('/') || args[0].starts_with('@')) {
		if args[0].starts_with('@') { matcher = HeaderEdit{matcher: args[0]} }
		else if args[0] != '*' { matcher = HeaderEdit{patterns: [args[0]]} }
		args.delete(0)
	}
	kind := d.args[0]
	match kind {
		'log_skip', 'skip_log' { if args.len != 0 { return error('log_skip accepts only a matcher') } }
		'log_level' { if args.len != 1 { return error('expected log_level [matcher] LEVEL') }; log_level(args[0])! }
		'log_append' { if args.len != 2 || args[0].trim_string_left('<') == '' { return error('expected log_append [matcher] KEY VALUE') } }
		'log_name' { if args.len == 0 { return error('expected log_name [matcher] NAME...') } }
		else { return error('unknown log request directive') }
	}
	return LogRule{kind, args, matcher}
}

fn resolve_log_rules(mut rules []LogRule, matchers map[string][]string) ! {
	for mut rule in rules {
		mut headers := [rule.match]
		resolve_header_matchers(mut headers, matchers)!
		rule.match = headers[0]
	}
}

fn access_targets(cfg Config, site Site, writers map[string]&AccessLog, rules []LogRule, values HeaderValues) []AccessTarget {
	mut names := []string{}
	for rule in rules {
		if rule.kind == 'log_name' && header_edit_matches(rule.match, [], values, 0) { names = rule.args.clone() }
	}
	mut targets := []AccessTarget{}
	if names.len > 0 {
		for candidate in cfg.sites {
			for config in candidate.logs {
				if config.name in names {
					if writer := writers[config.output.output] { targets << AccessTarget{config, writer} }
				}
			}
		}
	} else {
		for candidate in cfg.sites {
			for config in candidate.logs {
				if config.hostnames.len > 0 {
					if !config.hostnames.any(log_host_matches(it, values.host)) { continue }
				} else if config.no_hostname || candidate.hosts != site.hosts { continue }
				if writer := writers[config.output.output] { targets << AccessTarget{config, writer} }
			}
		}
	}
	return targets
}

fn log_host_matches(pattern string, host string) bool {
	labels := pattern.to_lower().trim_right('.').split('.')
	actual := host.to_lower().trim_right('.').split('.')
	if labels.len != actual.len { return false }
	for i, label in labels { if label != '*' && label != actual[i] { return false } }
	return true
}

fn log_append_value(value string, c &Connection) json2.Any {
	if value.starts_with('{') && value.ends_with('}') && value.count('{') == 1 {
		name := value[1..value.len - 1]
		return placeholder_value(name, c.header_values) or { return json2.null }
	}
	return value
}

fn (mut c Connection) capture_early_logs(rules []LogRule) {
	for rule in rules {
		if rule.kind == 'log_append' && rule.args[0].starts_with('<') && header_edit_matches(rule.match, [], c.header_values, 0) {
			value := rule.args[1]
			c.log_early[rule.args[0][1..]] = if value.starts_with('{http.response.') { json2.Any(json2.null) } else { log_append_value(value, c) }
		}
	}
}
