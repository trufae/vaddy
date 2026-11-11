module main

fn test_serialized_header_scan_preserves_duplicates_and_values() {
	mut buffer := Buffer{}
	buffer.write_string('HTTP/1.1 200 OK\r\nSet-Cookie: a=1\r\nsEt-CoOkIe:\tb=2\r\nX-Value:  \twith:colon \t\r\nX-Empty:\r\n\r\nBody: not a header\r\n')
	assert buffer_header_fields(buffer) == [
		Field{'Set-Cookie', 'set-cookie', 'a=1'},
		Field{'sEt-CoOkIe', 'set-cookie', 'b=2'},
		Field{'X-Value', 'x-value', 'with:colon \t'},
		Field{'X-Empty', 'x-empty', ''},
	]
}

fn test_regex_substitutions_and_bounded_output() ! {
	assert regex_replace('(a)(b)', r'$2-${1}-$$-$0', 'ab ab')! == 'b-a-$-ab b-a-$-ab'
	assert regex_replace('(?P<word>ab)', r'${word}:$word', 'ab')! == 'ab:ab'
	assert regex_replace('(a)', r'$1suffix-${1}suffix', 'a')! == '-asuffix'
	assert regex_replace('', '-', 'é猫')! == '-é-猫-'
	assert regex_replace('a*', '-', 'aaab')! == '-b-'
	if _ := regex_replace('x', 'y'.repeat(header_limit), 'xx') { assert false }
	if _ := regex_replace('(?<=a)b', 'x', 'ab') { assert false }
}
