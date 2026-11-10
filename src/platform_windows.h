#ifndef VADDY_PLATFORM_WINDOWS_H
#define VADDY_PLATFORM_WINDOWS_H
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0600
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <io.h>
#include <sys/stat.h>
#include <signal.h>
#include <limits.h>

/* Sockets and queue/lock handles cross the V boundary without narrowing. */
static INIT_ONCE vaddy_wsa_once = INIT_ONCE_STATIC_INIT;
static volatile LONG vaddy_stopping;
static BOOL CALLBACK vaddy_wsa_start(PINIT_ONCE once, PVOID arg, PVOID *context) {
    WSADATA data;
    (void)once; (void)arg; (void)context;
    return WSAStartup(MAKEWORD(2, 2), &data) == 0;
}
static int vaddy_init_sockets(void) {
    return InitOnceExecuteOnce(&vaddy_wsa_once, vaddy_wsa_start, NULL, NULL) ? 0 : -1;
}
static void vaddy_private_files(void) { _umask(0077); }
static void vaddy_signal(int sig) { (void)sig; InterlockedExchange(&vaddy_stopping, 1); }
static BOOL WINAPI vaddy_console_signal(DWORD kind) {
    if (kind != CTRL_C_EVENT && kind != CTRL_BREAK_EVENT && kind != CTRL_CLOSE_EVENT) return FALSE;
    InterlockedExchange(&vaddy_stopping, 1); return TRUE;
}
static void vaddy_signals(void) {
    signal(SIGINT, vaddy_signal); signal(SIGTERM, vaddy_signal);
    SetConsoleCtrlHandler(vaddy_console_signal, TRUE);
}
static int vaddy_stopped(void) { return InterlockedCompareExchange(&vaddy_stopping, 0, 0) != 0; }
static int vaddy_again(void) {
    int e = WSAGetLastError();
    return e == WSAEWOULDBLOCK || e == WSAEINTR || e == WSAEINPROGRESS;
}
static int vaddy_close(int64_t fd) { return closesocket((SOCKET)fd); }
static int vaddy_nonblock(int64_t fd) {
    u_long one = 1; int yes = 1;
    if (ioctlsocket((SOCKET)fd, FIONBIO, &one)) return -1;
    if (!SetHandleInformation((HANDLE)(uintptr_t)fd, HANDLE_FLAG_INHERIT, 0)) return -1;
    setsockopt((SOCKET)fd, IPPROTO_TCP, TCP_NODELAY, (const char *)&yes, sizeof yes);
    return 0;
}
static long long vaddy_recv(int64_t fd, void *buf, size_t len, int flags) {
    if (len > INT_MAX) { WSASetLastError(WSAEINVAL); return -1; }
    return recv((SOCKET)fd, (char *)buf, (int)len, flags);
}
static long long vaddy_send(int64_t fd, const void *buf, size_t len, int flags) {
    if (len > INT_MAX) { WSASetLastError(WSAEINVAL); return -1; }
    return send((SOCKET)fd, (const char *)buf, (int)len, flags);
}
static int vaddy_socket_alive(int64_t fd) {
    char byte; int n = recv((SOCKET)fd, &byte, 1, MSG_PEEK);
    return n < 0 && WSAGetLastError() == WSAEWOULDBLOCK;
}

/* Winsock has no socketpair. A private loopback TCP pair supplies the same
 * byte-stream interface for worker notifications and the socket-I/O tests. */
static int vaddy_wakeup_pair(int64_t *fds) {
    SOCKET listener = INVALID_SOCKET, client = INVALID_SOCKET, peer = INVALID_SOCKET;
    struct sockaddr_in address = {0}, local = {0}, remote = {0};
    int length = sizeof address, yes = 1;
    if (vaddy_init_sockets()) return -1;
    listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listener == INVALID_SOCKET) goto fail;
    setsockopt(listener, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, (const char *)&yes, sizeof yes);
    address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(listener, (struct sockaddr *)&address, sizeof address) || listen(listener, 1) ||
        getsockname(listener, (struct sockaddr *)&address, &length)) goto fail;
    client = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (client == INVALID_SOCKET || connect(client, (struct sockaddr *)&address, sizeof address)) goto fail;
    length = sizeof local;
    if (getsockname(client, (struct sockaddr *)&local, &length)) goto fail;
    length = sizeof remote;
    peer = accept(listener, (struct sockaddr *)&remote, &length);
    if (peer == INVALID_SOCKET || remote.sin_port != local.sin_port ||
        remote.sin_addr.s_addr != local.sin_addr.s_addr) goto fail;
    if (vaddy_nonblock((int64_t)client) || vaddy_nonblock((int64_t)peer)) goto fail;
    closesocket(listener); fds[0] = (int64_t)client; fds[1] = (int64_t)peer; return 0;
fail:
    if (listener != INVALID_SOCKET) closesocket(listener);
    if (client != INVALID_SOCKET) closesocket(client);
    if (peer != INVALID_SOCKET) closesocket(peer);
    return -1;
}
static int vaddy_notify(int64_t fd) {
    char byte = 1; int n;
    do { n = send((SOCKET)fd, &byte, 1, 0); } while (n < 0 && WSAGetLastError() == WSAEINTR);
    return n == 1 || (n < 0 && WSAGetLastError() == WSAEWOULDBLOCK) ? 0 : -1;
}
struct vaddy_address { struct sockaddr_storage addr; int len; };
static struct vaddy_address *vaddy_resolve(const char *host, const char *port) {
    struct addrinfo hints = {0}, *list = NULL, *item;
    if (vaddy_init_sockets()) return NULL;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, port, &hints, &list)) return NULL;
    for (item = list; item && item->ai_family != AF_INET; item = item->ai_next) {}
    if (!item) item = list;
    struct vaddy_address *out = calloc(1, sizeof *out);
    if (out && item && item->ai_addrlen <= sizeof out->addr) {
        memcpy(&out->addr, item->ai_addr, item->ai_addrlen); out->len = (int)item->ai_addrlen;
    } else { free(out); out = NULL; }
    freeaddrinfo(list); return out;
}
static int64_t vaddy_connect(struct vaddy_address *addr) {
    SOCKET fd = socket(addr->addr.ss_family, SOCK_STREAM, IPPROTO_TCP);
    if (fd == INVALID_SOCKET) return -1;
    if (vaddy_nonblock((int64_t)fd)) { closesocket(fd); return -1; }
    if (connect(fd, (struct sockaddr *)&addr->addr, addr->len) && !vaddy_again()) {
        closesocket(fd); return -1;
    }
    return (int64_t)fd;
}
static int vaddy_connected(int64_t fd) {
    int error = 0, len = sizeof error;
    return getsockopt((SOCKET)fd, SOL_SOCKET, SO_ERROR, (char *)&error, &len) ? -1 : error;
}
static int64_t vaddy_listen(const char *host, const char *port) {
    struct addrinfo hints = {0}, *list, *it; SOCKET fd = INVALID_SOCKET;
    int one = 1, zero = 0;
    if (vaddy_init_sockets()) return -1;
    hints.ai_socktype = SOCK_STREAM; hints.ai_flags = AI_PASSIVE;
    if (getaddrinfo(host, port, &hints, &list)) return -1;
    for (it = list; it; it = it->ai_next) {
        fd = socket(it->ai_family, SOCK_STREAM, IPPROTO_TCP);
        if (fd == INVALID_SOCKET) continue;
        setsockopt(fd, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, (const char *)&one, sizeof one);
        if (it->ai_family == AF_INET6) setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, (const char *)&zero, sizeof zero);
        if (!vaddy_nonblock((int64_t)fd) && !bind(fd, it->ai_addr, (int)it->ai_addrlen) && !listen(fd, 256)) break;
        closesocket(fd); fd = INVALID_SOCKET;
    }
    freeaddrinfo(list); return fd == INVALID_SOCKET ? -1 : (int64_t)fd;
}
static int64_t vaddy_accept(int64_t fd, char *ip, int len) {
    struct sockaddr_storage addr; int size = sizeof addr;
    SOCKET client = accept((SOCKET)fd, (struct sockaddr *)&addr, &size);
    if (client == INVALID_SOCKET) return -1;
    if (vaddy_nonblock((int64_t)client) || getnameinfo((struct sockaddr *)&addr, size, ip, len, NULL, 0, NI_NUMERICHOST)) {
        closesocket(client); return -1;
    }
    if (!strncmp(ip, "::ffff:", 7)) memmove(ip, ip + 7, strlen(ip + 7) + 1);
    return (int64_t)client;
}

static wchar_t *vaddy_wide_path(const char *path) {
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
    if (!n) return NULL;
    wchar_t *wide = malloc((size_t)n * sizeof *wide);
    if (wide && !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, n)) { free(wide); return NULL; }
    return wide;
}
static int64_t vaddy_lock(const char *path) {
    wchar_t *wide = vaddy_wide_path(path);
    if (!wide) return -1;
    HANDLE handle = CreateFileW(wide, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    free(wide); return handle == INVALID_HANDLE_VALUE ? -1 : (int64_t)(intptr_t)handle;
}
static void vaddy_unlock(int64_t handle) { CloseHandle((HANDLE)(intptr_t)handle); }
static int vaddy_replace(const char *src, const char *dst) {
    wchar_t *from = vaddy_wide_path(src), *to = vaddy_wide_path(dst);
    int ok = from && to && MoveFileExW(from, to, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
    free(from); free(to); return ok ? 0 : -1;
}

struct vaddy_event { int64_t fd; int flags; };
struct vaddy_poll_queue { WSAPOLLFD *fds; size_t len, cap, cursor; };
static int64_t vaddy_queue(void) {
    if (vaddy_init_sockets()) return -1;
    struct vaddy_poll_queue *q = calloc(1, sizeof *q);
    return q ? (int64_t)(intptr_t)q : -1;
}
static void vaddy_queue_close(int64_t handle) {
    struct vaddy_poll_queue *q = (void *)(intptr_t)handle;
    free(q->fds); free(q);
}
static int vaddy_watch(int64_t handle, int64_t fd, int old, int flags) {
    struct vaddy_poll_queue *q = (void *)(intptr_t)handle;
    size_t i; (void)old;
    for (i = 0; i < q->len && q->fds[i].fd != (SOCKET)fd; i++) {}
    if (!flags) {
        if (i < q->len) q->fds[i] = q->fds[--q->len];
        return 0;
    }
    if (i == q->len) {
        if (q->len == q->cap) {
            size_t cap = q->cap ? q->cap * 2 : 64;
            WSAPOLLFD *fds = realloc(q->fds, cap * sizeof *fds);
            if (!fds) { WSASetLastError(WSAENOBUFS); return -1; }
            q->fds = fds; q->cap = cap;
        }
        q->len++;
    }
    q->fds[i].fd = (SOCKET)fd;
    q->fds[i].events = (short)(((flags & 1) ? POLLRDNORM : 0) | ((flags & 2) ? POLLWRNORM : 0));
    q->fds[i].revents = 0; return 0;
}
static int vaddy_wait(int64_t handle, struct vaddy_event *out, int max, int ms) {
    struct vaddy_poll_queue *q = (void *)(intptr_t)handle;
    if (!q->len) { Sleep((DWORD)ms); return 0; }
    int ready = WSAPoll(q->fds, (ULONG)q->len, ms), n = 0;
    if (ready <= 0) return ready;
    /* Rotate the scan so a large ready set cannot starve higher-index sockets. */
    size_t start = q->cursor % q->len;
    for (size_t scanned = 0; scanned < q->len && n < max; scanned++) {
        size_t i = (start + scanned) % q->len;
        short events = q->fds[i].revents;
        if (!events) continue;
        out[n].fd = (int64_t)q->fds[i].fd;
        out[n].flags = ((events & POLLRDNORM) ? 1 : 0) | ((events & POLLWRNORM) ? 2 : 0) |
            ((events & (POLLERR | POLLHUP | POLLNVAL)) ? 4 : 0);
        n++; q->cursor = i + 1;
    }
    return n;
}
#endif
