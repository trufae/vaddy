#ifndef VADDY_TEST_SUPPORT_H
#define VADDY_TEST_SUPPORT_H
#ifdef _WIN32
#include <psapi.h>
static long long vaddy_test_peak_rss(void) {
    PROCESS_MEMORY_COUNTERS usage;
    if (!GetProcessMemoryInfo(GetCurrentProcess(), &usage, sizeof usage)) return -1;
    return (long long)usage.PeakWorkingSetSize;
}
static long long vaddy_test_cpu_us(void) {
    FILETIME created, exited, kernel, user;
    ULARGE_INTEGER k, u;
    if (!GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user)) return -1;
    k.LowPart = kernel.dwLowDateTime; k.HighPart = kernel.dwHighDateTime;
    u.LowPart = user.dwLowDateTime; u.HighPart = user.dwHighDateTime;
    return (long long)((k.QuadPart + u.QuadPart) / 10);
}
#else
#include <sys/resource.h>
static long long vaddy_test_peak_rss(void) {
    struct rusage r; if (getrusage(RUSAGE_SELF, &r)) return -1;
#ifdef __APPLE__
    return r.ru_maxrss;
#else
    return (long long)r.ru_maxrss * 1024;
#endif
}
static long long vaddy_test_cpu_us(void) {
    struct rusage r; if (getrusage(RUSAGE_SELF, &r)) return -1;
    return ((long long)r.ru_utime.tv_sec + r.ru_stime.tv_sec) * 1000000 + r.ru_utime.tv_usec + r.ru_stime.tv_usec;
}
#endif
static int vaddy_test_socket_buffers(int64_t fd) {
    int size = 8192;
#ifdef _WIN32
    SOCKET socket_fd = (SOCKET)fd;
#else
    int socket_fd = (int)fd;
#endif
    return setsockopt(socket_fd, SOL_SOCKET, SO_SNDBUF, (const char *)&size, sizeof size) ||
        setsockopt(socket_fd, SOL_SOCKET, SO_RCVBUF, (const char *)&size, sizeof size);
}
static void *vaddy_test_tls_client(int64_t fd, const char *ca) {
    SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
    if (!ctx) return NULL;
    if (!SSL_CTX_load_verify_locations(ctx, ca, NULL)) { SSL_CTX_free(ctx); return NULL; }
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
    SSL *s = SSL_new(ctx); SSL_CTX_free(ctx);
    SSL_set_fd(s, (int)fd); SSL_set_tlsext_host_name(s, "localhost");
    SSL_set1_host(s, "localhost"); SSL_set_connect_state(s); return s;
}
static int vaddy_test_tls_connect(void *s) { ERR_clear_error(); return SSL_connect(s); }
#endif
