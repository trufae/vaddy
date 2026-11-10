module main

import os
import compress.gzip
import time

fn test_log_rotation_compression_retention_and_reload_writers() ! {
	dir := os.join_path(os.temp_dir(), 'vaddy-rotate-${os.getpid()}')
	defer { os.rmdir_all(dir) or {} }
	cfg := parse_config('http://localhost {\n log {\n output file "${dir}/nested/access.log" {\n roll_size 1KiB\n roll_keep 2\n roll_keep_for 1d\n }\n }\n redir * /new\n}')!
	assert cfg.sites[0].log_options.roll_size == 1048576
	mut logs := prepare_access_logs(cfg)!
	defer { close_access_logs(logs) }
	mut logger := logs[cfg.sites[0].log_output]!
	logger.options.roll_size = 1024
	// A second generation's writer must follow rotations from the first.
	old_logs := prepare_access_logs(cfg)!
	defer { close_access_logs(old_logs) }
	mut old := old_logs[cfg.sites[0].log_output]!
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
