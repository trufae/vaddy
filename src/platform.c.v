module main

#pkgconfig openssl
#include "@VMODROOT/src/platform.h"

struct C.vaddy_event {
mut:
	fd    int
	flags int
}

fn C.vaddy_cert_host(&char, &char) int
fn C.vaddy_socket_alive(int) int
fn C.vaddy_private_files()
fn C.vaddy_cert_seconds(&char, int) i64
fn C.vaddy_signals()
fn C.vaddy_wakeup_pair(&i32) int
fn C.vaddy_notify(int) int
fn C.vaddy_stopped() int
fn C.vaddy_resolve(&char, &char) voidptr
fn C.vaddy_connect(voidptr) int
fn C.vaddy_connected(int) int
fn C.vaddy_listen(&char, &char) int
fn C.vaddy_accept(int, &char, int) int
fn C.vaddy_again() int
fn C.vaddy_lock(&char) int
fn C.vaddy_queue() int
fn C.vaddy_watch(int, int, int, int) int
fn C.vaddy_wait(int, &C.vaddy_event, int, int) int
fn C.vaddy_tls_context(&char, &char) voidptr
fn C.vaddy_tls_new(voidptr, int) voidptr
fn C.vaddy_tls_read(voidptr, voidptr, int) int
fn C.vaddy_tls_write(voidptr, voidptr, int) int
fn C.vaddy_tls_handshake(voidptr) int
fn C.vaddy_tls_error(voidptr, int) int
fn C.vaddy_tls_pending(voidptr) int
fn C.vaddy_tls_has_pending(voidptr) int
fn C.vaddy_tls_free(voidptr)
fn C.vaddy_tls_ctx_free(voidptr)
fn C.recv(int, voidptr, uint, int) int
fn C.send(int, voidptr, uint, int) int
fn C.close(int) int
