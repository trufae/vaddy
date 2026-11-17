module log

import src.caddyfile { Directive }

@[heap; noinit]
pub struct Config {
	format Format
	no_hostname bool
	hostnames []string
pub:
	name string
	output Options
	level int = 1
}

pub struct Target {
pub:
	config &Config
	writer &Writer
}

pub fn level(value string) !int {
	return match value.to_lower() {
		'debug' { 0 }
		'info' { 1 }
		'warn', 'warning' { 2 }
		'error' { 3 }
		else { return error('log level must be DEBUG, INFO, WARN or ERROR') }
	}
}

pub fn parse(d Directive, default_name string) !&Config {
	if d.args.len !in [1, 2] { return error('expected log [name] { output ... }') }
	mut output := Options{}
	mut format := Format{}
	mut minimum_level := 1
	mut no_hostname := false
	mut hostnames := []string{}
	mut seen := map[string]bool{}
	for child in d.children {
		if child.args.len == 0 { return error('empty log option') }
		name := child.args[0]
		if name in seen && name != 'hostnames' { return error('duplicate log option ${name}') }
		seen[name] = true
		match name {
			'output' { output = parse_output(child)! }
			'format' { format = parse_format(child)! }
			'level' { if child.args.len != 2 || child.children.len > 0 { return error('expected log level LEVEL') }; minimum_level = level(child.args[1])! }
			'no_hostname' { if child.args.len != 1 || child.children.len > 0 { return error('no_hostname takes no arguments') }; no_hostname = true }
			'hostnames' { if child.args.len < 2 || child.children.len > 0 { return error('expected hostnames') }; hostnames << child.args[1..] }
			else { return error('unsupported log option ${name}') }
		}
	}
	custom := d.children.any(it.args.len > 0 && it.args[0] !in ['no_hostname', 'hostnames'])
	return &Config{
		name: if d.args.len == 2 { d.args[1] } else if custom { default_name } else { '' }
		output: output
		format: format
		level: minimum_level
		no_hostname: no_hostname
		hostnames: hostnames
	}
}

pub fn (config &Config) matches(names []string, host string, same_site bool) bool {
	if names.len > 0 { return config.name in names }
	if config.hostnames.len > 0 { return config.hostnames.any(host_matches(it, host)) }
	return !config.no_hostname && same_site
}

fn host_matches(pattern string, host string) bool {
	labels := pattern.to_lower().trim_right('.').split('.')
	actual := host.to_lower().trim_right('.').split('.')
	if labels.len != actual.len { return false }
	for i, label in labels { if label != '*' && label != actual[i] { return false } }
	return true
}
