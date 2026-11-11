module main

#include "@VMODROOT/src/files.h"
struct C.vaddy_file_info {
mut:
	size i64
	modified i64
}
fn C.vaddy_file_info(int, &C.vaddy_file_info) int
