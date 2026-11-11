module main

#pkgconfig libzstd
#include "@VMODROOT/src/encode.h"

struct C.vaddy_encoder {
	consumed int
	written int
	finished int
}
fn C.vaddy_encoder_new(int, int) &C.vaddy_encoder
fn C.vaddy_encoder_free(&C.vaddy_encoder)
fn C.vaddy_encoder_step(&C.vaddy_encoder, voidptr, int, voidptr, int, int) int
