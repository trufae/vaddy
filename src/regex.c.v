module main

#pkgconfig re2
#flag @VMODROOT/.build/regex.o
$if macos {
	#flag -lc++
} $else {
	#flag -lstdc++
}
#include "@VMODROOT/src/regex.h"

fn C.vaddy_regex_valid(&char) int
fn C.vaddy_regex_replace(&char, &char, &char, &char, int) int

fn regex_replace(pattern string, replacement string, input string) !string {
	mut result := []u8{len: header_limit}
	n := C.vaddy_regex_replace(&char(pattern.str), &char(replacement.str), &char(input.str), &char(result.data), result.len)
	if n < 0 { return error('invalid regex or replacement exceeds header limit') }
	return result[..n].bytestr()
}
