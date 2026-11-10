#ifndef VADDY_PLATFORM_H
#define VADDY_PLATFORM_H
/* OS/OpenSSL adapters only: HTTP, proxy and certificate state machines are V. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include "platform_windows.h"
#else
#include "platform_posix.h"
#endif
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/x509v3.h>

static long long vaddy_cert_seconds(const char *path, int lifetime) {
    FILE *f = fopen(path, "r"); if (!f) return -1;
    X509 *cert = PEM_read_X509(f, NULL, NULL, NULL); fclose(f);
    if (!cert) return -1;
    if (X509_cmp_current_time(X509_get0_notBefore(cert)) > 0) { X509_free(cert); return -1; }
    int days = 0, seconds = 0;
    int ok = ASN1_TIME_diff(&days, &seconds, lifetime ? X509_get0_notBefore(cert) : NULL, X509_get0_notAfter(cert));
    X509_free(cert);
    return ok ? (long long)days * 86400 + seconds : -1;
}
static int vaddy_cert_host(const char *path, const char *host) {
    FILE *f = fopen(path, "r"); if (!f) return 0;
    X509 *cert = PEM_read_X509(f, NULL, NULL, NULL); fclose(f);
    if (!cert) return 0;
    int ok = X509_check_host(cert, host, 0, X509_CHECK_FLAG_NEVER_CHECK_SUBJECT, NULL);
    X509_free(cert); return ok == 1;
}
static void *vaddy_tls_context(const char *cert, const char *key) {
    SSL_CTX *ctx = SSL_CTX_new(TLS_server_method());
    if (!ctx) return NULL;
    SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
    SSL_CTX_set_options(ctx, SSL_OP_NO_COMPRESSION | SSL_OP_NO_RENEGOTIATION);
    SSL_CTX_set_mode(ctx, SSL_MODE_RELEASE_BUFFERS | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
    SSL_CTX_set_session_cache_mode(ctx, SSL_SESS_CACHE_SERVER);
    SSL_CTX_sess_set_cache_size(ctx, 1024);
    if (!SSL_CTX_use_certificate_chain_file(ctx, cert) || !SSL_CTX_use_PrivateKey_file(ctx, key, SSL_FILETYPE_PEM) || !SSL_CTX_check_private_key(ctx)) { SSL_CTX_free(ctx); return NULL; }
    return ctx;
}
static void *vaddy_tls_new(void *ctx, int64_t fd) {
    SSL *ssl = SSL_new(ctx); if (!ssl) return NULL;
    if (!SSL_set_fd(ssl, (int)fd)) { SSL_free(ssl); return NULL; }
    SSL_set_accept_state(ssl); return ssl;
}
static void *vaddy_upstream_context(const char *ca) {
    SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
    if (!ctx) return NULL;
    SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
    SSL_CTX_set_options(ctx, SSL_OP_NO_COMPRESSION | SSL_OP_NO_RENEGOTIATION);
    SSL_CTX_set_mode(ctx, SSL_MODE_RELEASE_BUFFERS | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
    int ok = *ca ? SSL_CTX_load_verify_locations(ctx, ca, NULL) : SSL_CTX_set_default_verify_paths(ctx);
    if (!ok) { SSL_CTX_free(ctx); return NULL; }
    return ctx;
}
static void *vaddy_upstream_tls(void *ctx, int64_t fd, const char *name) {
    SSL *ssl = SSL_new(ctx);
    if (!ssl) return NULL;
    int ok = SSL_set_fd(ssl, (int)fd);
    ASN1_OCTET_STRING *ip = a2i_IPADDRESS(name);
    if (ip) {
        ok = ok && X509_VERIFY_PARAM_set1_ip(SSL_get0_param(ssl), ASN1_STRING_get0_data(ip), ASN1_STRING_length(ip));
        ASN1_OCTET_STRING_free(ip);
    } else {
        ok = ok && SSL_set1_host(ssl, name) && SSL_set_tlsext_host_name(ssl, name);
    }
    static const unsigned char alpn[] = {8, 'h','t','t','p','/','1','.','1'};
    if (!ok || SSL_set_alpn_protos(ssl, alpn, sizeof alpn)) { SSL_free(ssl); return NULL; }
    SSL_set_connect_state(ssl);
    return ssl;
}
static int vaddy_upstream_handshake(void *ssl) { ERR_clear_error(); return SSL_connect(ssl); }
static int vaddy_tls_read(void *ssl, void *buf, int len) { ERR_clear_error(); return SSL_read(ssl, buf, len); }
static int vaddy_tls_write(void *ssl, const void *buf, int len) { ERR_clear_error(); return SSL_write(ssl, buf, len); }
static int vaddy_tls_handshake(void *ssl) { ERR_clear_error(); return SSL_accept(ssl); }
static int vaddy_tls_error(void *ssl, int result) { return SSL_get_error(ssl, result); }
static int vaddy_tls_pending(void *ssl) { return SSL_pending(ssl); }
static int vaddy_tls_has_pending(void *ssl) { return SSL_has_pending(ssl); }
static void vaddy_tls_free(void *ssl) { SSL_free(ssl); }
static void vaddy_tls_ctx_free(void *ctx) { SSL_CTX_free(ctx); }
#endif
