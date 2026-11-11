module main

#pkgconfig libnghttp2
#include "@VMODROOT/src/http2.h"

struct C.vaddy_h2_stream {
mut:
	id int
	ready int
	remote_end int
	closed int
	response_end int
	response_started int
	header_count int
	header_len int
	input_len int
	output_len int
	error u32
	headers &u8
	input &u8
	output &u8
	next &C.vaddy_h2_stream
}
fn C.vaddy_h2_new(int) voidptr
fn C.vaddy_h2_free(voidptr)
fn C.vaddy_h2_receive(voidptr, voidptr, int) int
fn C.vaddy_h2_flush(voidptr) int
fn C.vaddy_h2_wire_len(voidptr) int
fn C.vaddy_h2_wire(voidptr) voidptr
fn C.vaddy_h2_wire_skip(voidptr, int)
fn C.vaddy_h2_first(voidptr) &C.vaddy_h2_stream
fn C.vaddy_h2_take(voidptr, &C.vaddy_h2_stream, voidptr, int) int
fn C.vaddy_h2_push(voidptr, &C.vaddy_h2_stream, voidptr, int) int
fn C.vaddy_h2_response(voidptr, &C.vaddy_h2_stream, voidptr, int, int) int
fn C.vaddy_h2_end(voidptr, &C.vaddy_h2_stream)
fn C.vaddy_h2_reset(voidptr, int, int)
fn C.vaddy_h2_remove(voidptr, &C.vaddy_h2_stream)
fn C.vaddy_h2_drain(voidptr)
fn C.vaddy_h2_wants_write(voidptr) int
fn C.vaddy_h2_finished(voidptr) int
fn C.vaddy_tls_is_h2(voidptr) int
