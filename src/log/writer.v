module log

import math
import os
import src.caddyfile { Directive }
import strconv
import sync
import time

pub struct Options {
pub mut:
	output string = 'stderr'
mut:
	roll_disabled bool
	roll_size i64 = 100 * 1024 * 1024
	roll_keep int = 10
	roll_keep_days int = 90
	roll_interval time.Duration
	roll_local_time bool
	compress bool = true
	mode int = 0o600
	dir_mode int = 0o700
}

fn parse_size(value string) !i64 {
	text := value.to_lower().replace(' ', '')
	mut end := 0
	for end < text.len && (text[end].is_digit() || text[end] == `.`) { end++ }
	if end == 0 { return error('invalid log size') }
	number := strconv.atof64(text[..end])!
	multiplier := match text[end..] {
		'', 'b' { i64(1) }
		'kb', 'k' { i64(1000) }
		'kib', 'ki' { i64(1024) }
		'mb', 'm' { i64(1000000) }
		'mib', 'mi' { i64(1048576) }
		'gb', 'g' { i64(1000000000) }
		'gib', 'gi' { i64(1073741824) }
		else { return error('invalid log size unit') }
	}
	bytes := number * multiplier
	if bytes < 0 || bytes > 1e15 { return error('log size out of range') }
	return if bytes == 0 { i64(100 * 1024 * 1024) } else { i64(math.ceil(bytes / 1048576)) * 1048576 }
}

fn parse_duration(value string) !time.Duration {
	mut text := value
	// Caddy extends Go-style durations with a day unit equal to 24 hours.
	for i := 0; i < text.len; i++ {
		if text[i] != `d` { continue }
		mut start := i
		for start > 0 && (text[start - 1].is_digit() || text[start - 1] in [u8(`.`), `+`, `-`]) {
			start--
		}
		hours := strconv.f64_to_str_l(strconv.atof64(text[start..i])! * 24)
		text = text[..start] + hours + 'h' + text[i + 1..]
		i = start + hours.len
	}
	duration := time.parse_duration(text)!
	if duration < 0 { return error('invalid duration: "${value}"') }
	return duration
}

fn parse_mode(value string) !int {
	if value.len == 0 || value.len > 4 || value.bytes().any(it < `0` || it > `7`) { return error('invalid log mode') }
	return int(strconv.parse_int(value, 8, 32)!)
}

fn parse_output(d Directive, mut opts Options) ! {
	if d.args.len == 2 && d.args[1] in ['stdout', 'stderr', 'discard'] && d.children.len == 0 {
		opts.output = d.args[1]
		return
	}
	if d.args.len != 3 || d.args[1] != 'file' || d.args[2] == '' { return error('expected output stdout, stderr, discard or file PATH') }
	opts.output = 'file:' + os.abs_path(d.args[2])
	mut seen := map[string]bool{}
	for child in d.children {
		if child.args.len == 0 || child.children.len > 0 { return error('invalid file log option') }
		name := child.args[0]
		if name in seen { return error('duplicate log file option ${name}') }
		seen[name] = true
		if name in ['roll_disabled', 'roll_uncompressed', 'roll_local_time'] {
			if child.args.len != 1 { return error('unexpected log option arguments') }
			match name {
				'roll_disabled' { opts.roll_disabled = true }
				'roll_uncompressed' { opts.compress = false }
				else { opts.roll_local_time = true }
			}
			continue
		}
		if child.args.len != 2 { return error('expected log option value') }
		value := child.args[1]
		match name {
			'roll_size' { opts.roll_size = parse_size(value)! }
			'roll_keep' {
				if value == '' || !value.bytes().all(it.is_digit()) || value.len > 8 { return error('invalid roll_keep') }
				opts.roll_keep = if value.int() == 0 { 10 } else { value.int() }
			}
			'roll_keep_for' {
				days := int(math.ceil(f64(parse_duration(value)!) / f64(24 * time.hour)))
				opts.roll_keep_days = if days == 0 { 90 } else { days }
			}
			'roll_interval' { opts.roll_interval = parse_duration(value)! }
			'roll_compression' {
				if value !in ['gzip', 'none'] { return error('roll_compression supports gzip or none') }
				opts.compress = value == 'gzip'
			}
			'mode' { opts.mode = parse_mode(value)! }
			'dir_mode' { opts.dir_mode = parse_mode(value)! }
			else { return error('unsupported log file option ${name}') }
		}
	}
	if 'roll_compression' in seen { opts.compress = d.children.filter(it.args[0] == 'roll_compression')[0].args[1] == 'gzip' }
}

fn open_file(opts Options) !os.File {
	path := opts.output.trim_string_left('file:')
	os.mkdir_all(os.dir(path), mode: u32(opts.dir_mode))!
	mut file := os.open_file(path, 'a', opts.mode)!
	$if !windows {
		os.chmod(path, opts.mode) or { file.close(); return err }
	}
	return file
}

fn prune_backups(path string, opts Options) ! {
	ext := os.file_ext(path)
	base := os.file_name(path).trim_string_right(ext)
	mut names := []string{}
	for name in os.ls(os.dir(path))! {
		plain := name.trim_string_right('.gz')
		if !plain.starts_with(base + '-') || !plain.ends_with(ext) { continue }
		stamp := plain[base.len + 1..].trim_string_right(ext)
		// Only prune our timestamped rotations; unrelated files are never candidates.
		if stamp.len != 28 || stamp[4] != `-` || stamp[7] != `-` || stamp[10] != `T` || stamp[13] != `-` || stamp[16] != `-` || stamp[19] != `.` || !stamp.ends_with('-size') { continue }
		if stamp[..23].bytes().any(!it.is_digit() && it !in [u8(`-`), `T`, `.`]) { continue }
		names << name
	}
	names.sort(a > b)
	cutoff := time.now().unix() - i64(opts.roll_keep_days) * 86400
	for i, name in names {
		file := os.join_path(os.dir(path), name)
		if i >= opts.roll_keep || os.file_last_mod_unix(file) < cutoff { os.rm(file)! }
	}
}

pub fn (mut logger Writer) write_line(line string) ! {
	logger.mutex.lock()
	defer { logger.mutex.unlock() }
	output := logger.options.output
	if output == 'discard' { return }
	mut file := match output {
		'stdout' { os.stdout() }
		'stderr' { os.stderr() }
		else { open_file(logger.options)! }
	}
	defer { if output.starts_with('file:') { file.close() } }
	if output.starts_with('file:') { logger.rotate(mut file, i64(line.len) + 1)! }
	file.writeln(line)!
	file.flush()
}

fn (mut logger Writer) rotate(mut file os.File, size i64) ! {
	opts := logger.options
	if opts.roll_disabled { return }
	if size > opts.roll_size { return error('log record exceeds roll_size') }
	path := opts.output.trim_string_left('file:')
	length := i64(os.file_size(path))
	elapsed := time.Duration(time.sys_mono_now() - logger.opened)
	if length == 0 || (length + size <= opts.roll_size && (opts.roll_interval <= 0 || elapsed < opts.roll_interval)) { return }
	file.close()
	ext := os.file_ext(path)
	base := path.trim_string_right(ext)
	mut now := if opts.roll_local_time { time.now() } else { time.utc() }
	mut backup := ''
	for {
		stamp := now.format_ss_milli().replace(' ', 'T').replace(':', '-')
		backup = '${base}-${stamp}-size${ext}'
		if !os.exists(backup) && !os.exists(backup + '.gz') { break }
		now = now.add(time.millisecond)
	}
	os.rename(path, backup)!
	file = open_file(opts)!
	logger.opened = time.sys_mono_now()
	if opts.compress {
		temporary := backup + '.gz.tmp'
		if C.vaddy_gzip_file(&char(backup.str), &char(temporary.str)) == 0 {
			os.chmod(temporary, opts.mode)!
			os.rename(temporary, backup + '.gz')!
			os.rm(backup)!
		} else {
			os.rm(temporary) or {}
			eprintln('vaddy: compression failed for ${backup}; keeping original')
		}
	}
	prune_backups(path, opts) or { eprintln('vaddy: log retention failed: ${err}') }
}

@[heap]
pub struct Writer {
mut:
	mutex &sync.Mutex
	options Options
	opened i64
}

pub fn prepare(configs []Config, mutex &sync.Mutex) !map[string]&Writer {
	mut logs := map[string]&Writer{}
	for config in configs {
		output := config.output.output
		if output == '' { continue }
		if previous := logs[output] {
			if previous.options != config.output { return error('conflicting options for shared log output') }
			continue
		}
		// Validate without retaining a handle that blocks Windows rotations.
		if output.starts_with('file:') {
			mut file := open_file(config.output)!
			file.close()
		}
		logs[output] = &Writer{mutex: mutex, options: config.output, opened: time.sys_mono_now()}
	}
	return logs
}
