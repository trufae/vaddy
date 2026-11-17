module caddyfile

fn test_quoted_windows_paths_preserve_backslashes() ! {
	tokens := tokenize(r'header X-Path "C:\server\data"')!
	assert tokens[2].text == r'C:\server\data'
	escaped := tokenize(r'header X-Message "say \"hello\""')!
	assert escaped[2].text == 'say "hello"'
}
