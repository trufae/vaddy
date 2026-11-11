module main

import os
import compress.gzip
import time

fn test_log_rotation_compression_retention_and_reload_writers() ! {
	dir := os.join_path(os.temp_dir(), 'vaddy-rotate-${os.getpid()}')
	defer { os.rmdir_all(dir) or {} }
	cfg := parse_config('http://localhost {\n log {\n output file "${dir}/nested/access.log" {\n roll_size 1KiB\n roll_keep 2\n roll_keep_for 1d\n }\n }\n redir * /new\n}')!
	assert cfg.sites[0].logs[0].output.roll_size == 1048576
	mut logs := prepare_access_logs(cfg)!
	defer { close_access_logs(logs) }
	mut logger := logs[cfg.sites[0].logs[0].output.output]!
	logger.options.roll_size = 1024
	// A second generation's writer must follow rotations from the first.
	old_logs := prepare_access_logs(cfg)!
	defer { close_access_logs(old_logs) }
	mut old := old_logs[cfg.sites[0].logs[0].output.output]!
	old.options.roll_size = 1024
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
	assert log_size('1.1MiB')! == 2 * 1048576
	assert log_duration('1.5d')! == 36 * time.hour
	for option in ['roll_size -1', 'mode 888', 'roll_keep nope', 'roll_keep_for -1h', 'roll_compression invalid'] {
		if _ := parse_config('http://localhost {\n log {\n output file /unused {\n ${option}\n }\n }\n redir * /new\n}') { assert false, option }
	}
}

fn test_log_file_replacement_between_writes() ! {
	dir := os.join_path(os.temp_dir(), 'vaddy-log-replace-${os.getpid()}')
	defer { os.rmdir_all(dir) or {} }
	path := os.join_path(dir, 'access.log')
	cfg := parse_config('http://localhost {\n log {\n output file "${path}"\n }\n redir * /new\n}')!
	logs := prepare_access_logs(cfg)!
	defer { close_access_logs(logs) }
	mut logger := logs[cfg.sites[0].logs[0].output.output]!
	logger.options.roll_size = 64
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
	filter := LogFilter{path: ['request', 'uri'], kind: 'query', actions: [Directive{args: ['replace', 'token', 'HIDDEN']}, Directive{args: ['delete', 'remove']}]}
	assert filter_log_string('/?token=one&token=two&remove=yes', filter)! == '/?token=HIDDEN&token=HIDDEN'
	assert filter_log_string('one=secret; two=kept', LogFilter{kind: 'cookie', actions: [Directive{args: ['delete', 'one']}]})! == 'two=kept'
	assert filter_log_string('one=secret; Path=/; Secure', LogFilter{kind: 'set_cookie', actions: [Directive{args: ['delete', 'one']}]})! == ''
}

fn test_named_log_defaults_and_hostname_selection() ! {
	cfg := parse_config('http://localhost {\n log named {\n output discard\n }\n log {\n output discard\n }\n redir * /new\n}')!
	assert cfg.sites[0].logs[1].name == 'log0'
	assert log_host_matches('*.EXAMPLE.org', 'www.example.org')
	assert !log_host_matches('*.example.org', 'www.sub.example.org')
}
