module log

import compress.gzip
import os
import src.caddyfile { Directive }
import sync
import time

fn test_log_rotation_compression_retention_and_reload_writers() ! {
	mut mutex := sync.new_mutex()
	defer { mutex.destroy() }
	dir := os.join_path(os.temp_dir(), 'vaddy-rotate-${os.getpid()}')
	defer { os.rmdir_all(dir) or {} }
	parsed := parse(caddyfile.parse('log {\n output file "${dir}/nested/access.log" {\n roll_size 1KiB\n roll_keep 2\n roll_keep_for 1d\n }\n}')![0], '')!
	assert parsed.output.roll_size == 1048576
	config := &Config{...parsed, output: Options{...parsed.output, roll_size: 1024}}
	mut logs := prepare([config], mutex)!
	mut logger := logs[config.output.output]!
	// A second generation's writer must follow rotations from the first.
	old_logs := prepare([config], mutex)!
	mut old := old_logs[config.output.output]!
	os.write_file('${dir}/nested/access-not-a-rotation.log.gz', 'unrelated')!
	for i in 0 .. 20 {
		logger.write_line('${i}: ' + 'x'.repeat(400))!
		old.write_line('${i}: ' + 'y'.repeat(400))!
	}
	backups := os.ls('${dir}/nested')!.filter(it.ends_with('-size.log.gz'))
	assert backups.len == 2
	for name in backups {
		data := gzip.decompress(os.read_bytes('${dir}/nested/${name}')!)!
		assert data.bytestr().split_into_lines().len == 2
	}
	assert os.read_lines('${dir}/nested/access.log')!.len == 2
	assert os.read_file('${dir}/nested/access-not-a-rotation.log.gz')! == 'unrelated'
	assert os.read_file('${dir}/nested/access.log')!.starts_with('19: ')
}

fn test_log_output_validation_and_disabled_rotation() ! {
	assert parse_size('1.1MiB')! == 2 * 1048576
	assert parse_duration('1.5d')! == 36 * time.hour
	for option in ['roll_size -1', 'mode 888', 'roll_keep nope', 'roll_keep_for -1h', 'roll_compression invalid'] {
		if _ := parse(caddyfile.parse('log {\n output file /unused {\n ${option}\n }\n}')![0], '') { assert false, option }
	}
}

fn test_parse_duration_compound_units_and_limits() ! {
	assert parse_duration('1h30m')! == 90 * time.minute
	assert parse_duration('+2h45m30.5s')! == 2 * time.hour + 45 * time.minute + 30500 * time.millisecond
	assert parse_duration('.5s')! == 500 * time.millisecond
	assert parse_duration('1.000000001s')! == time.second + time.nanosecond
	assert parse_duration('2us3µs4μs')! == 9 * time.microsecond
	assert parse_duration('9223372036854775807ns')! == time.Duration(max_i64)
	for value in ['0', '+0', '-0', '-0s'] { assert parse_duration(value)! == 0 }
	for value in ['', '++1s', '+', '-1ns', '1', '.s', '1..5s', '1s-1s', 'NaNs',
		'1w', '9223372036854775808ns', '18446744073709551616ns', '9223372036854775807ns1ns', '2562048h'] {
		if _ := parse_duration(value) { assert false, value }
	}
}

fn test_parse_duration_days() ! {
	assert parse_duration('1d')! == 24 * time.hour
	assert parse_duration('+1.5d12h')! == 48 * time.hour
	assert parse_duration('-0d')! == 0
	assert parse_duration('1d30m')! == 24 * time.hour + 30 * time.minute
	assert parse_duration('1m2d')! == time.minute + 48 * time.hour
	assert parse_duration('1d2d')! == 72 * time.hour
	assert parse_duration('0.001d')! == 86400 * time.millisecond
	for value in ['d', '1hd', '1.2.3d', '-1d', '-1.25d12h', '1dd', '2562048d'] {
		if _ := parse_duration(value) { assert false, value }
	}
}

fn test_log_file_replacement_between_writes() ! {
	mut mutex := sync.new_mutex()
	defer { mutex.destroy() }
	dir := os.join_path(os.temp_dir(), 'vaddy-log-replace-${os.getpid()}')
	defer { os.rmdir_all(dir) or {} }
	path := os.join_path(dir, 'access.log')
	config := &Config{output: Options{output: 'file:' + path, roll_size: 64}}
	logs := prepare([config], mutex)!
	mut logger := logs[config.output.output]!
	// Preparation, successful writes and rejected writes must all allow an
	// external rotation, including on Windows where open handles block renames.
	os.rename(path, path + '.prepared')!
	logger.write_line('before replacement')!
	os.rename(path, path + '.written')!
	assert os.read_lines(path + '.written')! == ['before replacement']
	if _ := logger.write_line('x'.repeat(64)) {
		assert false, 'oversized log record must be rejected'
	} else { assert err.msg() == 'log record exceeds roll_size' }
	os.rename(path, path + '.rejected')!
	assert os.file_size(path + '.rejected') == 0
	logger.write_line('after replacement')!
	assert os.read_lines(path)! == ['after replacement']
}

fn test_log_filters_preserve_repeated_query_values_and_redact_arrays() ! {
	filter := Filter{path: ['request', 'uri'], kind: 'query', actions: [Directive{args: ['replace', 'token', 'HIDDEN']}, Directive{args: ['delete', 'remove']}]}
	assert filter_string('/?token=one&token=two&remove=yes', filter)! == '/?token=HIDDEN&token=HIDDEN'
	assert filter_string('/?z=last&b=&a=one+two&z=first&b&token=secret', filter)! == '/?a=one+two&b=&b=&token=HIDDEN&z=last&z=first'
	assert filter_string('one=secret; two=kept', Filter{kind: 'cookie', actions: [Directive{args: ['delete', 'one']}]})! == 'two=kept'
	assert filter_string('one=secret; Path=/; Secure', Filter{kind: 'set_cookie', actions: [Directive{args: ['delete', 'one']}]})! == ''
}

fn test_hostname_and_named_log_selection() ! {
	assert host_matches('*.EXAMPLE.org', 'www.example.org')
	assert !host_matches('*.example.org', 'www.sub.example.org')
	config := Config{name: 'named', hostnames: ['*.example.org'], no_hostname: true}
	assert config.matches([], 'www.example.org', false)
	assert !config.matches([], 'example.org', true)
	assert config.matches(['named'], '', false)
	assert !Config{no_hostname: true}.matches([], '', true)
}
