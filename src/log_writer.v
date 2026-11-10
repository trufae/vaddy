module main

import os
import time
import strconv
import math

struct LogOptions {
mut:
	output string = 'stderr'
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

fn log_size(value string) !i64 {
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

fn log_duration(value string) !time.Duration {
	if value.ends_with('d') {
		days := strconv.atof64(value[..value.len - 1])!
		if days < 0 || days > 100000 { return error('invalid duration') }
		return time.Duration(days * f64(24 * time.hour))
	}
	duration := time.parse_duration(value)!
	if duration < 0 { return error('negative duration') }
	return duration
}

fn log_mode(value string) !int {
	if value.len == 0 || value.len > 4 || value.bytes().any(it < `0` || it > `7`) { return error('invalid log mode') }
	return int(strconv.parse_int(value, 8, 32)!)
}

fn parse_log_output(d Directive, mut opts LogOptions) ! {
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
			'roll_size' { opts.roll_size = log_size(value)! }
			'roll_keep' {
				if !all_digits(value) || value.len > 8 { return error('invalid roll_keep') }
				opts.roll_keep = if value.int() == 0 { 10 } else { value.int() }
			}
			'roll_keep_for' {
				days := int(math.ceil(f64(log_duration(value)!) / f64(24 * time.hour)))
				opts.roll_keep_days = if days == 0 { 90 } else { days }
			}
			'roll_interval' { opts.roll_interval = log_duration(value)! }
			'roll_compression' {
				if value !in ['gzip', 'none'] { return error('roll_compression supports gzip or none') }
				opts.compress = value == 'gzip'
			}
			'mode' { opts.mode = log_mode(value)! }
			'dir_mode' { opts.dir_mode = log_mode(value)! }
			else { return error('unsupported log file option ${name}') }
		}
	}
	if 'roll_compression' in seen { opts.compress = d.children.filter(it.args[0] == 'roll_compression')[0].args[1] == 'gzip' }
}

fn open_log_file(opts LogOptions) !os.File {
	path := opts.output.trim_string_left('file:')
	os.mkdir_all(os.dir(path), mode: u32(opts.dir_mode))!
	mut file := os.open_file(path, 'a', opts.mode)!
	$if !windows {
		os.chmod(path, opts.mode) or { file.close(); return err }
	}
	return file
}

fn log_backup_parts(path string) (string, string) {
	ext := os.file_ext(path)
	return path.trim_string_right(ext), ext
}

fn prune_log_backups(path string, opts LogOptions) ! {
	base, ext := log_backup_parts(os.file_name(path))
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

fn (mut logger AccessLog) write_line(line string) ! {
	if logger.options.output == 'discard' { return }
	if !logger.owned {
		logger.file.writeln(line)!
		logger.file.flush()
		return
	}
	path := logger.options.output.trim_string_left('file:')
	// Reopen under the shared generation mutex: rotation, reloads and external
	// log replacement must never leave a worker appending to an old descriptor.
	logger.file.close()
	logger.file = open_log_file(logger.options)!
	if !logger.options.roll_disabled {
		if i64(line.len + 1) > logger.options.roll_size { return error('log record exceeds roll_size') }
		elapsed := time.Duration(time.sys_mono_now() - logger.opened)
		if os.file_size(path) > 0 && (i64(os.file_size(path)) + line.len + 1 > logger.options.roll_size || (logger.options.roll_interval > 0 && elapsed >= logger.options.roll_interval)) {
			logger.file.close()
			base, ext := log_backup_parts(path)
			mut now := if logger.options.roll_local_time { time.now() } else { time.utc() }
			mut backup := ''
			for {
				stamp := now.format_ss_milli().replace(' ', 'T').replace(':', '-')
				backup = '${base}-${stamp}-size${ext}'
				if !os.exists(backup) && !os.exists(backup + '.gz') { break }
				now = now.add(time.millisecond)
			}
			os.rename(path, backup)!
			logger.file = open_log_file(logger.options)!
			logger.opened = time.sys_mono_now()
			if logger.options.compress {
				temporary := backup + '.gz.tmp'
				if C.vaddy_gzip_file(&char(backup.str), &char(temporary.str)) == 0 {
					os.chmod(temporary, logger.options.mode)!
					os.rename(temporary, backup + '.gz')!
					os.rm(backup)!
				} else {
					os.rm(temporary) or {}
					eprintln('vaddy: compression failed for ${backup}; keeping original')
				}
			}
			prune_log_backups(path, logger.options) or { eprintln('vaddy: log retention failed: ${err}') }
		}
	}
	logger.file.writeln(line)!
	logger.file.flush()
}
