module regex

#pkgconfig re2
#flag @VMODROOT/.build/regex.o
$if macos {
	#flag -lc++
} $else {
	#flag -lstdc++
}
#include "@VMODROOT/src/regex/regex.h"

fn C.vaddy_regex_valid(&char) int
fn C.vaddy_regex_replace(&char, &char, &char, &char, int) int

pub fn replace(pattern string, replacement string, input string, limit int) !string {
	mut result := []u8{len: limit}
	n := C.vaddy_regex_replace(&char(pattern.str), &char(replacement.str), &char(input.str), &char(result.data), result.len)
	if n < 0 { return error('invalid regex or replacement exceeds header limit') }
	return result[..n].bytestr()
}

pub fn valid(pattern string) bool {
	return C.vaddy_regex_valid(&char(pattern.str)) != 0
}
